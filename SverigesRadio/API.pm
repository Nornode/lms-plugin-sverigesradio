package Plugins::SverigesRadio::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS qw(decode_json);
use URI::Escape;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log   = logger('plugin.sverigesradio');
my $cache = Slim::Utils::Cache->new();

use constant BASE_URL => 'https://api.sr.se/api/v2';

use constant TTL_CHANNELS   => 28800;   # 8h
use constant TTL_CATEGORIES => 86400;   # 24h
use constant TTL_PROGRAMS   => 7200;    # 2h
use constant TTL_EPISODES   => 3600;    # 1h
use constant TTL_SEARCH     => 300;     # 5m
use constant TTL_NOWPLAYING => 60;      # 60s
use constant TTL_STALE      => 604800;  # 7d stale-while-error fallback

my %VALID_QUALITIES = map { $_ => 1 } qw(hi normal lo);
my %inFlight;

sub normalizeQuality {
    my ($class, $q) = @_;
    return 'hi' unless defined $q && $VALID_QUALITIES{$q};
    return $q;
}

# --- Public methods -------------------------------------------------------

sub warmCache {
    my ($class, $quality) = @_;
    $quality = $class->normalizeQuality($quality);

    main::INFOLOG && $log->is_info && $log->info("SR API: warming cache in background (quality=$quality)");
    $class->channels($quality, sub {
        $class->programCategories(sub {
            $class->allPrograms(sub {
                main::INFOLOG && $log->is_info && $log->info("SR API: background cache warm-up complete");
            });
        });
    });
}

sub channels {
    my ($class, $quality, $cb) = @_;
    $quality = $class->normalizeQuality($quality);

    my $params = "audioquality=$quality&size=100";
    my $key    = 'sr_channels_' . $quality;

    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_getAll('/channels', $params, 'channels', sub {
            my ($channels, $failed) = @_;
            if (!$failed && $channels && @$channels) {
                $cache->set($key, $channels, TTL_CHANNELS);
                $cache->set("${key}_stale", $channels, TTL_STALE);
                return $done->($channels);
            }
            if (my $stale = $cache->get("${key}_stale")) {
                $log->warn("SR API: serving stale channels cache for $quality");
                return $done->($stale);
            }
            $done->($channels || []);
        });
    });
}

sub programCategories {
    my ($class, $cb) = @_;

    my $key = 'sr_programcategories';
    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_getAll('/programcategories', '', 'categories', sub {
            my ($cats, $failed) = @_;
            if (!$failed && $cats && @$cats) {
                $cache->set($key, $cats, TTL_CATEGORIES);
                $cache->set("${key}_stale", $cats, TTL_STALE);
                return $done->($cats);
            }
            if (my $stale = $cache->get("${key}_stale")) {
                $log->warn("SR API: serving stale categories cache");
                return $done->($stale);
            }
            $done->($cats || []);
        });
    });
}

sub programs {
    my ($class, $category_id, $cb) = @_;

    my $params = "categoryid=$category_id&hasondemand=true&isarchived=false&size=100";
    my $key    = 'sr_programs_cat_' . $category_id;

    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_getAll('/programs/index', $params, 'programs', sub {
            my ($progs, $failed) = @_;
            if (!$failed && $progs && @$progs) {
                $cache->set($key, $progs, TTL_PROGRAMS);
                $cache->set("${key}_stale", $progs, TTL_STALE);
                return $done->($progs);
            }
            if (my $stale = $cache->get("${key}_stale")) {
                $log->warn("SR API: serving stale programs cache for category $category_id");
                return $done->($stale);
            }
            $done->($progs || []);
        });
    });
}

sub allPrograms {
    my ($class, $cb) = @_;

    my $key = 'sr_programs_all';
    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_getAll('/programs/index', 'hasondemand=true&isarchived=false&size=100', 'programs', sub {
            my ($progs, $failed) = @_;
            if (!$failed && $progs && @$progs) {
                $cache->set($key, $progs, TTL_PROGRAMS);
                $cache->set("${key}_stale", $progs, TTL_STALE);
                return $done->($progs);
            }
            if (my $stale = $cache->get("${key}_stale")) {
                $log->warn("SR API: serving stale allPrograms cache");
                return $done->($stale);
            }
            $done->($progs || []);
        });
    });
}

sub episodes {
    my ($class, $program_id, $page, $cb) = @_;
    $page ||= 1;

    my $params = "programid=$program_id&page=$page&size=20";
    my $key    = 'sr_episodes_' . md5_hex($params);

    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_get('/episodes/index', $params, sub {
            my $data = shift;
            if ($data && ref $data eq 'HASH' && ref $data->{episodes} eq 'ARRAY') {
                my $result = {
                    episodes   => $data->{episodes},
                    pagination => $data->{pagination} || {},
                };
                if (@{ $result->{episodes} }) {
                    $cache->set($key, $result, TTL_EPISODES);
                    $cache->set("${key}_stale", $result, TTL_STALE);
                }
                return $done->($result);
            }
            if (my $stale = $cache->get("${key}_stale")) {
                $log->warn("SR API: serving stale episodes cache for program $program_id page $page");
                return $done->($stale);
            }
            $done->({ episodes => [], pagination => {} });
        });
    });
}

sub searchPrograms {
    my ($class, $query, $cb) = @_;

    my $lc = lc($query);
    $class->allPrograms(sub {
        my $all = shift || [];
        my @matched = grep {
            index(lc($_->{name}        // ''), $lc) >= 0 ||
            index(lc($_->{description} // ''), $lc) >= 0
        } @$all;
        $cb->(\@matched);
    });
}

sub searchEpisodes {
    my ($class, $query, $cb) = @_;

    my $params = 'query=' . URI::Escape::uri_escape_utf8($query) . '&size=20';
    my $key    = 'sr_search_' . md5_hex($params);

    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_get('/episodes/search', $params, sub {
            my $data = shift;
            if ($data && ref $data eq 'HASH' && ref $data->{episodes} eq 'ARRAY') {
                my $eps = $data->{episodes};
                $cache->set($key, $eps, TTL_SEARCH);
                return $done->($eps);
            }
            $done->([]);
        });
    });
}

sub nowPlaying {
    my ($class, $channel_id, $cb) = @_;

    my $key = 'sr_nowplaying_' . $channel_id;
    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    _coalesce($key, $cb, sub {
        my $done = shift;
        $class->_get('/scheduledepisodes/rightnow', "channelid=$channel_id", sub {
            my $data = shift;
            my $ep;
            if ($data && ref $data eq 'HASH' && ref $data->{channel} eq 'HASH') {
                my $cur = $data->{channel}{currentscheduledepisode};
                $ep = $cur if ref $cur eq 'HASH' && $cur->{title};
            }
            $cache->set($key, $ep, TTL_NOWPLAYING) if $ep;
            $done->($ep);
        });
    });
}

# --- Private helpers ------------------------------------------------------

sub _coalesce {
    my ($key, $cb, $fetcher) = @_;

    if ($inFlight{$key}) {
        push @{ $inFlight{$key} }, $cb;
        return;
    }

    $inFlight{$key} = [$cb];
    $fetcher->(sub {
        my ($result) = @_;
        my $cbs = delete $inFlight{$key} || [];
        for my $fn (@$cbs) {
            eval { $fn->($result) };
            $log->error("SR API callback error for $key: $@") if $@;
        }
    });
}

sub _get {
    my ($class, $path, $params, $cb, $retries) = @_;
    $retries = 1 unless defined $retries;

    my $sep = $params ? '&' : '';
    my $url = BASE_URL . $path . '?format=json' . $sep . $params;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { decode_json($http->content()) };
            if ($@ || ref $data ne 'HASH') {
                my $err = $@ || 'non-object JSON response';
                $log->error("SR API JSON error for $url: $err");
                if ($retries > 0) {
                    Slim::Utils::Timers::setTimer(undef, time() + 1, sub {
                        $class->_get($path, $params, $cb, $retries - 1);
                    });
                    return;
                }
                return $cb->(undef);
            }
            $cb->($data);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("SR API error for $url: $error");
            if ($retries > 0) {
                Slim::Utils::Timers::setTimer(undef, time() + 1, sub {
                    $class->_get($path, $params, $cb, $retries - 1);
                });
                return;
            }
            $cb->(undef);
        },
        { timeout => 15 }
    )->get($url);
}

# Fetch all pages, accumulating items under $list_key, then call $cb->(\@all, $failed)
sub _getAll {
    my ($class, $path, $params, $list_key, $cb) = @_;

    my @all;
    my $sep = $params ? '&' : '';
    my $base = BASE_URL . $path . '?format=json' . $sep . $params;

    my $fetchPage;
    $fetchPage = sub {
        my ($page, $retries) = @_;
        $retries = 1 unless defined $retries;
        my $page_url = $base . "&page=$page";

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http = shift;
                my $data = eval { decode_json($http->content()) };
                if ($@ || ref $data ne 'HASH') {
                    my $err = $@ || 'non-object JSON response';
                    $log->error("SR API page $page JSON error for $page_url: $err");
                    if ($retries > 0) {
                        Slim::Utils::Timers::setTimer(undef, time() + 1, sub {
                            $fetchPage->($page, $retries - 1);
                        });
                        return;
                    }
                    return $cb->(\@all, 1);
                }

                push @all, @{ $data->{$list_key} || [] };

                my $pagination = $data->{pagination} || {};
                if ($pagination->{nextpage}) {
                    $fetchPage->(($pagination->{page} || $page) + 1, 1);
                } else {
                    $cb->(\@all, 0);
                }
            },
            sub {
                my ($http, $error) = @_;
                $log->error("SR API page $page error for $page_url: $error");
                if ($retries > 0) {
                    Slim::Utils::Timers::setTimer(undef, time() + 1, sub {
                        $fetchPage->($page, $retries - 1);
                    });
                    return;
                }
                $cb->(\@all, 1);
            },
            { timeout => 15 }
        )->get($page_url);
    };

    $fetchPage->(1, 1);
}

1;

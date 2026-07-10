package Plugins::SverigesRadio::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(first);
use URI::Escape;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

my $log   = logger('plugin.sverigesradio');
my $cache = Slim::Utils::Cache->new();

use constant BASE_URL => 'https://api.sr.se/api/v2';

use constant TTL_CHANNELS   => 28800;   # 8h
use constant TTL_CATEGORIES => 86400;   # 24h
use constant TTL_PROGRAMS   => 7200;    # 2h
use constant TTL_EPISODES   => 3600;    # 1h
use constant TTL_SEARCH     => 300;     # 5m
use constant TTL_NOWPLAYING => 60;      # 60s

# --- Public methods -------------------------------------------------------

sub channels {
    my ($class, $quality, $cb) = @_;
    $quality ||= 'hi';

    my $params = "audioquality=$quality&size=100";
    my $key    = 'sr_channels_' . $quality;

    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    $class->_getAll('/channels', $params, 'channels', TTL_CHANNELS, sub {
        my $channels = shift;
        $cache->set($key, $channels, TTL_CHANNELS);
        $cb->($channels);
    });
}

sub programCategories {
    my ($class, $cb) = @_;

    my $key = 'sr_programcategories';
    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    $class->_getAll('/programcategories', '', 'categories', TTL_CATEGORIES, sub {
        my $cats = shift;
        $cache->set($key, $cats, TTL_CATEGORIES);
        $cb->($cats);
    });
}

sub programs {
    my ($class, $category_id, $cb) = @_;

    my $params = "categoryid=$category_id&hasondemand=true&size=100";
    my $key    = 'sr_programs_cat_' . $category_id;

    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    $class->_getAll('/programs/index', $params, 'programs', TTL_PROGRAMS, sub {
        my $progs = shift;
        $cache->set($key, $progs, TTL_PROGRAMS);
        $cb->($progs);
    });
}

sub allPrograms {
    my ($class, $cb) = @_;

    my $key = 'sr_programs_all';
    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    $class->_getAll('/programs/index', 'hasondemand=true&size=100', 'programs', TTL_PROGRAMS, sub {
        my $progs = shift;
        $cache->set($key, $progs, TTL_PROGRAMS);
        $cb->($progs);
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

    $class->_get('/episodes/index', $params, TTL_EPISODES, sub {
        my $data = shift;
        my $result = {
            episodes   => $data->{episodes}   || [],
            pagination => $data->{pagination} || {},
        };
        $cache->set($key, $result, TTL_EPISODES);
        $cb->($result);
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

    $class->_get('/episodes/search', $params, TTL_SEARCH, sub {
        my $data = shift;
        my $eps = $data->{episodes} || [];
        $cache->set($key, $eps, TTL_SEARCH);
        $cb->($eps);
    });
}

sub nowPlaying {
    my ($class, $channel_id, $cb) = @_;

    my $key = 'sr_nowplaying_' . $channel_id;
    if (my $cached = $cache->get($key)) {
        return $cb->($cached);
    }

    $class->_get('/scheduledepisodes', "channelid=$channel_id&size=10", TTL_NOWPLAYING, sub {
        my $data = shift;
        my $now  = time() * 1000;   # SR timestamps are milliseconds

        my $ep = first {
            defined $_->{starttimeutc} &&
            defined $_->{endtimeutc}   &&
            $_->{starttimeutc} <= $now &&
            $now <= $_->{endtimeutc}
        } @{ $data->{schedule} || [] };

        $cache->set($key, $ep, TTL_NOWPLAYING);
        $cb->($ep);
    });
}

# --- Private helpers ------------------------------------------------------

sub _get {
    my ($class, $path, $params, $ttl, $cb) = @_;

    my $sep = $params ? '&' : '';
    my $url = BASE_URL . $path . '?format=json' . $sep . $params;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content()) };
            if ($@) {
                $log->error("SR API JSON error for $url: $@");
                return $cb->({});
            }
            $cb->($data);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("SR API error for $url: $error");
            $cb->({});
        },
        { timeout => 15 }
    )->get($url);
}

# Fetch all pages, accumulating items under $list_key, then call $cb->(\@all)
sub _getAll {
    my ($class, $path, $params, $list_key, $ttl, $cb) = @_;

    my @all;

    my $fetchPage;
    $fetchPage = sub {
        my ($page) = @_;
        my $sep      = $params ? '&' : '';
        my $page_url = BASE_URL . $path . '?format=json' . $sep . $params . "&page=$page";

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http = shift;
                my $data = eval { from_json($http->content()) };
                if ($@ || !$data) {
                    $log->error("SR API page $page error: $@");
                    return $cb->(\@all);
                }

                push @all, @{ $data->{$list_key} || [] };

                my $pagination = $data->{pagination} || {};
                if ($pagination->{nextpage}) {
                    $fetchPage->($pagination->{page} + 1);
                } else {
                    $cb->(\@all);
                }
            },
            sub {
                my ($http, $error) = @_;
                $log->error("SR API page $page error: $error");
                $cb->(\@all);
            },
            { timeout => 15 }
        )->get($page_url);
    };

    $fetchPage->(1);
}

1;

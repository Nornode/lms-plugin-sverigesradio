package Plugins::SverigesRadio::Plugin;

use strict;

BEGIN { warn "[SverigesRadio] Plugin.pm: BEGIN\n"; }

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catfile);
use URI::Escape;

use Plugins::SverigesRadio::API;
use Slim::Formats::RemoteMetadata;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Utils::Timers;

warn "[SverigesRadio] Plugin.pm: modules loaded\n";

our $pluginDir;
BEGIN {
    $pluginDir = $INC{'Plugins/SverigesRadio/Plugin.pm'};
    $pluginDir =~ s/Plugin\.pm$//;
}

my $log   = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.sverigesradio',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_SR_DESC',
});

my $prefs = preferences('plugin.sverigesradio');

sub initPlugin {
    my ($class) = @_;

    warn "[SverigesRadio] initPlugin: entering (class=$class, pluginDir=$pluginDir)\n";
    $log->error("SverigesRadio initPlugin: starting");

    my $strings_file = catfile($pluginDir, 'strings.txt');
    warn "[SverigesRadio] initPlugin: loading strings from $strings_file\n";
    eval { Slim::Utils::Strings::loadFile($strings_file) };
    if ($@) {
        warn "[SverigesRadio] initPlugin: loadFile FAILED: $@\n";
        $log->error("loadFile failed: $@");
    }

    $prefs->init({
        quality         => 'hi',
        channels_filter => 'all',
    });
    warn "[SverigesRadio] initPlugin: prefs initialized\n";

    Slim::Player::ProtocolHandlers->registerHandler(
        'sverigesradio',
        'Plugins::SverigesRadio::ProtocolHandler'
    );
    warn "[SverigesRadio] initPlugin: protocol handler registered\n";

    Slim::Formats::RemoteMetadata->registerParser(
        match => qr{sverigesradio\.se/topsy/direkt}i,
        func  => \&_handleLiveMetadata,
    );

    Slim::Player::ProtocolHandlers->registerIconHandler(
        qr{sverigesradio\.se}i,
        sub { return $class->_pluginDataFor('icon') || 'html/images/radio.png' },
    );

    warn "[SverigesRadio] initPlugin: calling SUPER::initPlugin\n";
    eval {
        $class->SUPER::initPlugin(
            feed   => \&topLevelFeed,
            tag    => 'sverigesradio',
            menu   => 'radios',
            weight => 75,
        );
    };
    if ($@) {
        warn "[SverigesRadio] initPlugin: SUPER::initPlugin FAILED: $@\n";
        $log->error("SUPER::initPlugin failed: $@");
    }
    warn "[SverigesRadio] initPlugin: SUPER::initPlugin returned\n";

    Slim::Control::Request::subscribe(\&_onPlaybackChange,
        [['playlist'], ['newsong', 'pause', 'stop', 'resume']]);

    if (main::WEBUI) {
        warn "[SverigesRadio] initPlugin: loading Settings\n";
        eval {
            require Plugins::SverigesRadio::Settings;
            Plugins::SverigesRadio::Settings->new();
        };
        if ($@) {
            warn "[SverigesRadio] initPlugin: Settings load FAILED: $@\n";
            $log->error("Settings load failed: $@");
        }
    }

    warn "[SverigesRadio] initPlugin: DONE\n";
    $log->error("SverigesRadio initPlugin: complete");
}

sub shutdownPlugin {
    Slim::Control::Request::unsubscribe(\&_onPlaybackChange);
}

sub getDisplayName { return 'PLUGIN_SR_NAME' }

# --------------------------------------------------------------------------
# Top-level menu
# --------------------------------------------------------------------------

sub topLevelFeed {
    my ($client, $cb) = @_;

    $cb->({
        items => [
            {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_LIVE'),
                type  => 'link',
                url   => \&liveFeed,
                image => 'plugins/SverigesRadio/html/images/icon.png',
            },
            {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_ONDEMAND'),
                type  => 'link',
                url   => \&onDemandFeed,
                image => 'plugins/SverigesRadio/html/images/icon.png',
            },
            {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_SEARCH'),
                type  => 'search',
                url   => \&searchFeed,
                image => 'plugins/SverigesRadio/html/images/icon.png',
            },
        ],
    });
}

# --------------------------------------------------------------------------
# Live radio
# --------------------------------------------------------------------------

sub liveFeed {
    my ($client, $cb) = @_;

    my $quality = $prefs->get('quality') || 'hi';
    my $filter  = $prefs->get('channels_filter') || 'all';

    Plugins::SverigesRadio::API->channels($quality, sub {
        my $channels = shift;

        unless ($channels && @$channels) {
            return $cb->([{
                type => 'text',
                name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_ERROR'),
            }]);
        }

        if ($filter eq 'national') {
            my @national = grep { ($_->{channeltype} || '') eq 'Rikskanal' } @$channels;
            return $cb->({ items => [ map { _channelItem($_) } @national ] });
        }

        my @national = grep { ($_->{channeltype} || '') eq 'Rikskanal' } @$channels;
        my @local    = grep { ($_->{channeltype} || '') ne 'Rikskanal' } @$channels;

        my $items = [];

        if (@national) {
            push @$items, {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_NATIONAL'),
                type  => 'playlist',
                items => [ map { _channelItem($_) } @national ],
            };
        }

        if (@local) {
            push @$items, {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_LOCAL'),
                type  => 'playlist',
                items => [ map { _channelItem($_) } @local ],
            };
        }

        $cb->({ items => $items });
    });
}

sub _channelItem {
    my ($ch) = @_;
    return {
        type      => 'audio',
        name      => $ch->{name},
        line1     => $ch->{name},
        line2     => $ch->{tagline} || '',
        image     => $ch->{image}   || '',
        url       => 'sverigesradio://live/' . $ch->{id},
        on_select => 'play',
    };
}

# --------------------------------------------------------------------------
# On-demand browse
# --------------------------------------------------------------------------

sub onDemandFeed {
    my ($client, $cb) = @_;

    $cb->({
        items => [
            {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_SEARCH'),
                type  => 'search',
                url   => \&searchFeed,
            },
            {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_CATEGORIES'),
                type  => 'link',
                url   => \&categoriesFeed,
            },
            {
                name  => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_ALL_PROGRAMS'),
                type  => 'link',
                url   => \&allProgramsFeed,
            },
        ],
    });
}

sub categoriesFeed {
    my ($client, $cb) = @_;

    Plugins::SverigesRadio::API->programCategories(sub {
        my $cats = shift;

        unless ($cats && @$cats) {
            return $cb->([{ type => 'text', name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_ERROR') }]);
        }

        my $items = [ map {
            my $cat = $_;
            {
                type        => 'link',
                name        => $cat->{name},
                url         => \&programsFeed,
                passthrough => [{ category_id => $cat->{id} }],
            }
        } @$cats ];

        $cb->({ items => $items });
    });
}

sub programsFeed {
    my ($client, $cb, $params, $args) = @_;
    my $category_id = $args->{category_id};

    Plugins::SverigesRadio::API->programs($category_id, sub {
        my $programs = shift;

        unless ($programs && @$programs) {
            return $cb->([{ type => 'text', name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_NO_RESULTS') }]);
        }

        my $items = [ map { _programItem($_) } @$programs ];
        $cb->({ items => $items });
    });
}

sub allProgramsFeed {
    my ($client, $cb) = @_;

    Plugins::SverigesRadio::API->allPrograms(sub {
        my $programs = shift;

        unless ($programs && @$programs) {
            return $cb->([{ type => 'text', name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_ERROR') }]);
        }

        my $items = [ map { _programItem($_) } @$programs ];
        $cb->({ items => $items });
    });
}

sub _programItem {
    my ($prog) = @_;
    return {
        type        => 'link',
        name        => $prog->{name},
        line1       => $prog->{name},
        line2       => ($prog->{channel} && $prog->{channel}{name}) ? $prog->{channel}{name} : '',
        image       => $prog->{programimage} || '',
        url         => \&episodesFeed,
        passthrough => [{ program_id => $prog->{id}, program_name => $prog->{name}, program_image => $prog->{programimage} || '' }],
    };
}

sub episodesFeed {
    my ($client, $cb, $params, $args) = @_;
    my $program_id   = $args->{program_id};
    my $program_name = $args->{program_name} || '';
    my $program_image = $args->{program_image} || '';
    my $page         = $args->{page} || 1;

    Plugins::SverigesRadio::API->episodes($program_id, $page, sub {
        my $result = shift;
        my $episodes   = $result->{episodes}   || [];
        my $pagination = $result->{pagination} || {};

        unless (@$episodes) {
            return $cb->([{ type => 'text', name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_NO_RESULTS') }]);
        }

        my $items = [ map { _episodeItem($_, $program_name, $program_image) } @$episodes ];

        # Add "Next page" link if more episodes exist
        if ($pagination->{nextpage}) {
            push @$items, {
                type        => 'link',
                name        => Slim::Utils::Strings::cstring($client, 'NEXT'),
                url         => \&episodesFeed,
                passthrough => [{ program_id => $program_id, program_name => $program_name,
                                  program_image => $program_image, page => $page + 1 }],
            };
        }

        $cb->({ items => $items });
    });
}

sub _episodeItem {
    my ($ep, $program_name, $program_image) = @_;

    my $audio_url = ($ep->{listenpodfile} && $ep->{listenpodfile}{url})
                    ? $ep->{listenpodfile}{url} : undef;
    my $duration  = ($ep->{listenpodfile} && $ep->{listenpodfile}{duration})
                    ? $ep->{listenpodfile}{duration} : undef;

    return {
        type      => $audio_url ? 'audio' : 'text',
        name      => $ep->{title}   || $program_name,
        line1     => $ep->{title}   || $program_name,
        line2     => $program_name,
        image     => $ep->{imageurl} || $program_image,
        url       => $audio_url || '',
        on_select => 'play',
        ($duration ? (duration => $duration) : ()),
    };
}

# --------------------------------------------------------------------------
# Episode search
# --------------------------------------------------------------------------

sub searchFeed {
    my ($client, $cb, $params, $args) = @_;

    my $query = $args->{search} || ($params && $params->{search}) || '';
    $query =~ s/^\s+|\s+$//g;

    unless ($query) {
        return $cb->([{ type => 'text', name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_NO_RESULTS') }]);
    }

    Plugins::SverigesRadio::API->searchEpisodes($query, sub {
        my $episodes = shift;

        unless ($episodes && @$episodes) {
            return $cb->([{ type => 'text', name => Slim::Utils::Strings::cstring($client, 'PLUGIN_SR_NO_RESULTS') }]);
        }

        my $items = [ map {
            my $prog_name = ($_->{program} && $_->{program}{name}) ? $_->{program}{name} : '';
            _episodeItem($_, $prog_name, '')
        } @$episodes ];

        $cb->({ items => $items });
    });
}

# --------------------------------------------------------------------------
# Live metadata polling
# --------------------------------------------------------------------------

sub _onPlaybackChange {
    my $request = shift;
    my $client  = $request->client() or return;
    my $cmd     = $request->getRequest(1);

    my $song = $client->playingSong() or return;
    my $url  = $song->currentTrack()->url();

    Slim::Utils::Timers::killTimers($client, \&_pollNowPlaying);

    if ($url =~ m{^sverigesradio://live/(\d+)}) {
        my $channel_id = $1;
        if ($cmd eq 'newsong' || $cmd eq 'resume') {
            Slim::Utils::Timers::setTimer(
                $client, time() + 60, \&_pollNowPlaying, $channel_id
            );
        }
    }
}

sub _pollNowPlaying {
    my ($client, $channel_id) = @_;

    Plugins::SverigesRadio::API->nowPlaying($channel_id, sub {
        my $ep = shift or return;

        if (my $song = $client->playingSong()) {
            $song->pluginData(nowPlaying => $ep);
        }

        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    });

    # Reschedule every 60 s while this channel is playing
    my $url = '';
    if (my $song = $client->playingSong()) {
        $url = $song->currentTrack()->url() || '';
    }

    if ($url =~ m{^sverigesradio://live/\Q$channel_id\E}) {
        Slim::Utils::Timers::setTimer(
            $client, time() + 60, \&_pollNowPlaying, $channel_id
        );
    }
}

# Registered with RemoteMetadata for live stream URLs that bypass the custom scheme
sub _handleLiveMetadata {
    my ($client, $url, $metadata) = @_;
    # The ProtocolHandler already handles metadata for sverigesradio:// URLs.
    # This parser is a fallback for direct liveaudio URLs if ever used.
    return 1;
}

1;

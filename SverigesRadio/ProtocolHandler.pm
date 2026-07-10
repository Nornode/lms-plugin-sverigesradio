package Plugins::SverigesRadio::ProtocolHandler;

use strict;

BEGIN { warn "[SverigesRadio] ProtocolHandler.pm: BEGIN\n"; }

use base qw(Slim::Player::Protocols::HTTPS);

use Digest::MD5 qw(md5_hex);
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

warn "[SverigesRadio] ProtocolHandler.pm: loaded\n";

my $log   = logger('plugin.sverigesradio');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.sverigesradio');

# --------------------------------------------------------------------------
# Stream URL resolution
# --------------------------------------------------------------------------

sub scanUrl {
    my ($class, $url, $args) = @_;

    my ($channel_id) = $url =~ m{^sverigesradio://live/(\d+)$};

    unless ($channel_id) {
        $log->error("ProtocolHandler: cannot parse channel_id from $url");
        $args->{cb}->($args->{song}->currentTrack());
        return;
    }

    my $quality = $prefs->get('quality') || 'hi';

    Plugins::SverigesRadio::API->channels($quality, sub {
        my $channels = shift || [];
        my ($ch) = grep { $_->{id} == $channel_id } @$channels;

        if ($ch && $ch->{liveaudio} && $ch->{liveaudio}{url}) {
            $args->{song}->streamUrl($ch->{liveaudio}{url});
            $args->{song}->pluginData(channelInfo => $ch);

            main::INFOLOG && $log->is_info &&
                $log->info("SR live channel $channel_id → " . $ch->{liveaudio}{url});
        } else {
            $log->error("SR: no stream URL found for channel $channel_id");
        }

        $args->{cb}->($args->{song}->currentTrack());
    });
}

# --------------------------------------------------------------------------
# Metadata for the player display and web UI
# --------------------------------------------------------------------------

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my ($channel_id) = $url =~ m{^sverigesradio://live/(\d+)$};
    return {} unless $channel_id;

    # Layer 1: in-flight song data
    my $ch = {};
    my $ep = {};

    if (my $song = $client->currentSongForUrl($url)) {
        $ch = $song->pluginData('channelInfo')  || {};
        $ep = $song->pluginData('nowPlaying')   || {};
    }

    # Layer 2: persistent now-playing cache (refreshed by polling timer)
    unless ($ep && $ep->{title}) {
        my $cached_ep = $cache->get('sr_nowplaying_' . $channel_id);
        $ep = $cached_ep if $cached_ep;
    }

    # Layer 3: async fetch if nothing cached yet — returns empty now, UI updates on notify
    unless ($ep && $ep->{title}) {
        Plugins::SverigesRadio::API->nowPlaying($channel_id, sub {
            my $fetched = shift or return;
            if (my $song = $client->currentSongForUrl($url)) {
                $song->pluginData(nowPlaying => $fetched);
            }
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        });
    }

    my $title  = $ep->{title}    || ($ch->{name} ? $ch->{name} . ' (live)' : 'Sveriges Radio');
    my $artist = $ch->{name}     || 'Sveriges Radio';
    my $cover  = $ep->{imageurl} || $ch->{image} || '';

    return {
        title   => $title,
        artist  => $artist,
        album   => Slim::Utils::Strings::string('PLUGIN_SR_LIVE'),
        cover   => $cover,
        type    => 'MP3 (H)',
        bitrate => $prefs->get('quality') eq 'hi' ? '192 kbps' : '96 kbps',
    };
}

# --------------------------------------------------------------------------
# Capability overrides
# --------------------------------------------------------------------------

sub isRemote    { return 1 }
sub canSeek     { return 0 }   # Live streams do not support seeking
sub isLive      { return 1 }

# Mark as user-chosen for Last.fm / ListenBrainz scrobbling
sub audioScrobblerSource { return 'R' }  # R = radio/non-personalised

1;

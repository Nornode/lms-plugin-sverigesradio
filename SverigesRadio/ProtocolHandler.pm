package Plugins::SverigesRadio::ProtocolHandler;

use strict;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.sverigesradio');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.sverigesradio');

# --------------------------------------------------------------------------
# Connection constructor
# --------------------------------------------------------------------------

sub new {
    my ($class, $args) = @_;

    # Song::open passes $track->url (sverigesradio://live/<id>) unless this is
    # a redirect call. Substitute the resolved HTTPS stream URL.
    $args->{url} = $args->{song}->streamUrl unless $args->{redir};
    return $class->SUPER::new($args);
}

# --------------------------------------------------------------------------
# Stream URL resolution
# --------------------------------------------------------------------------

sub scanUrl {
    my ($class, $url, $args) = @_;

    my ($channel_id) = $url =~ m{^sverigesradio://live/(\d+)$};
    my $origCb = $args->{cb};
    my $song   = $args->{song};

    unless ($channel_id) {
        $log->error("ProtocolHandler: cannot parse channel_id from $url");
        $origCb->(undef, 'PLUGIN_SR_BAD_URL') if $origCb;
        return;
    }

    my $quality = Plugins::SverigesRadio::API->normalizeQuality($prefs->get('quality'));

    Plugins::SverigesRadio::API->channels($quality, sub {
        my $channels = shift || [];
        my ($ch) = grep { $_->{id} == $channel_id } @$channels;

        unless ($ch && $ch->{liveaudio} && $ch->{liveaudio}{url}) {
            $log->error("SR: no stream URL found for channel $channel_id (quality=$quality)");
            $origCb->(undef, 'PLUGIN_SR_NO_STREAM') if $origCb;
            return;
        }

        my $streamUrl = $ch->{liveaudio}{url};
        my $origTrack = $song->currentTrack();

        $song->streamUrl($streamUrl);
        $song->pluginData(channelInfo => $ch);

        main::INFOLOG && $log->is_info &&
            $log->info("SR live channel $channel_id -> $streamUrl");

        # Delegate to Slim::Utils::Scanner::Remote via SUPER::scanUrl so LMS
        # follows SR's 302 redirects and reads icy-br / content-type headers.
        $args->{cb} = sub {
            my ($scannedTrack, $error) = @_;
            if ($scannedTrack) {
                $song->streamUrl($scannedTrack->url);
                $origTrack->content_type($scannedTrack->content_type || 'mp3');
                if ($scannedTrack->bitrate) {
                    $origTrack->bitrate($scannedTrack->bitrate);
                }
                $origCb->($origTrack, $error) if $origCb;
            } else {
                $log->error("SR: scan failed for $streamUrl: " . ($error || 'unknown'));
                $origCb->(undef, $error || 'PROBLEM_OPENING_REMOTE_URL') if $origCb;
            }
        };

        $class->SUPER::scanUrl($streamUrl, $args);
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
    my $bitrate;

    if (my $song = $client->currentSongForUrl($url)) {
        $ch      = $song->pluginData('channelInfo') || {};
        $ep      = $song->pluginData('nowPlaying')  || {};
        $bitrate = $song->bitrate || ($song->currentTrack && $song->currentTrack->bitrate);
    }

    # Layer 2: persistent now-playing cache (refreshed by polling timer)
    unless ($ep && $ep->{title}) {
        my $cached_ep = $cache->get('sr_nowplaying_' . $channel_id);
        $ep = $cached_ep if $cached_ep;
    }

    # Layer 3: async fetch if nothing cached yet — returns fallback now, UI updates on notify
    unless ($ep && $ep->{title}) {
        Plugins::SverigesRadio::API->nowPlaying($channel_id, sub {
            my $fetched = shift or return;
            if (my $song = $client->currentSongForUrl($url)) {
                $song->pluginData(nowPlaying => $fetched);
            }
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        });
    }

    my $title  = $ep->{title}       || ($ch->{name} ? $ch->{name} . ' (live)' : 'Sveriges Radio');
    my $artist = $ch->{name}        || 'Sveriges Radio';
    my $cover  = $ep->{socialimage} || $ep->{imageurl} || $ch->{image} || '';

    my $bitrate_str;
    if ($bitrate && $bitrate > 0) {
        my $kbps = $bitrate >= 1000 ? int($bitrate / 1000) : int($bitrate);
        $bitrate_str = "$kbps kbps";
    } else {
        my $q = Plugins::SverigesRadio::API->normalizeQuality($prefs->get('quality'));
        $bitrate_str = $q eq 'hi' ? '160 kbps' : ($q eq 'lo' ? '96 kbps' : '128 kbps');
    }

    return {
        title   => $title,
        artist  => $artist,
        album   => Slim::Utils::Strings::string('PLUGIN_SR_LIVE'),
        cover   => $cover,
        type    => 'MP3 (CBR)',
        bitrate => $bitrate_str,
    };
}

# --------------------------------------------------------------------------
# Always proxy through LMS so hardware players (canHTTPS=0) can play SR
# HTTPS streams and follow SR's double 302 redirects cleanly.
# --------------------------------------------------------------------------

sub canDirectStream {
    return 0;
}

sub canDirectStreamSong {
    return 0;
}

# --------------------------------------------------------------------------
# Capability overrides
# --------------------------------------------------------------------------

sub isRemote        { return 1 }
sub canSeek         { return 0 }
sub isLive          { return 1 }
sub getFormatForURL { return 'mp3' }

# Mark as user-chosen for Last.fm / ListenBrainz scrobbling
sub audioScrobblerSource { return 'R' }  # R = radio/non-personalised

1;

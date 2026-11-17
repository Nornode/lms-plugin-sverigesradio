#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use Encode qw(encode_utf8 is_utf8);
use JSON::PP ();

# --------------------------------------------------------------------------
# Lightweight LMS & CPAN stubs so the plugin can be tested standalone
# --------------------------------------------------------------------------
BEGIN {
    $INC{'JSON/XS.pm'} = __FILE__;
    package JSON::XS;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        *{"${caller}::encode_json"} = \&JSON::PP::encode_json;
    }

    package URI::Escape;
    $INC{'URI/Escape.pm'} = __FILE__;
    use Encode qw(encode_utf8 decode_utf8);
    sub uri_escape_utf8 {
        my $s = shift // '';
        my $b = encode_utf8($s);
        $b =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/ge;
        return $b;
    }
    sub uri_unescape {
        my $s = shift // '';
        $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        return decode_utf8($s);
    }

    package main;
    sub WEBUI { 1 }
    sub INFOLOG { 1 }
    sub DEBUGLOG { 1 }

    package Slim::Utils::Log;
    $INC{'Slim/Utils/Log.pm'} = __FILE__;
    sub addLogCategory { return bless {}, 'MockLogger' }
    sub logger         { return bless {}, 'MockLogger' }
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::logger"} = \&logger;
    }

    package MockLogger;
    our @ERRORS;
    sub is_info { 1 }
    sub is_debug { 0 }
    sub info  {}
    sub warn  {}
    sub debug {}
    sub error { shift; push @ERRORS, join('', @_); }

    package Slim::Utils::Prefs;
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
    my %PREFS_STORE;
    sub preferences {
        my $ns = shift || 'default';
        $PREFS_STORE{$ns} ||= bless { data => {} }, 'MockPrefs';
        return $PREFS_STORE{$ns};
    }
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::preferences"} = \&preferences;
    }

    package MockPrefs;
    sub init {
        my ($self, $defaults) = @_;
        for my $k (keys %$defaults) {
            $self->{data}{$k} = $defaults->{$k} unless exists $self->{data}{$k};
        }
    }
    sub get { my ($self, $k) = @_; return $self->{data}{$k} }
    sub set { my ($self, $k, $v) = @_; $self->{data}{$k} = $v }

    package Slim::Utils::Cache;
    $INC{'Slim/Utils/Cache.pm'} = __FILE__;
    my %CACHE;
    sub new { return bless {}, 'Slim::Utils::Cache' }
    sub get { my ($self, $k) = @_; return $CACHE{$k} }
    sub set { my ($self, $k, $v, $ttl) = @_; $CACHE{$k} = $v }
    sub clear_all { %CACHE = () }

    package Slim::Utils::Strings;
    $INC{'Slim/Utils/Strings.pm'} = __FILE__;
    sub loadFile {}
    sub string   { return $_[0] }
    sub cstring  { return $_[1] }

    package Slim::Utils::Timers;
    $INC{'Slim/Utils/Timers.pm'} = __FILE__;
    our @TIMERS;
    our @KILLED;
    sub setTimer   { my ($obj, $when, $cb, @args) = @_; push @TIMERS, [$obj, $when, $cb, \@args]; }
    sub killTimers { my ($obj, $cb) = @_; push @KILLED, [$obj, $cb]; }

    package Slim::Networking::SimpleAsyncHTTP;
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = __FILE__;
    our @MOCK_RESPONSES; # queue of [ok_or_err, payload]
    sub new {
        my ($class, $ok_cb, $err_cb, $opts) = @_;
        return bless { ok_cb => $ok_cb, err_cb => $err_cb }, $class;
    }
    sub get {
        my ($self, $url) = @_;
        my $next = shift @MOCK_RESPONSES;
        if (!$next) {
            return $self->{err_cb}->($self, "no mock response queued for $url");
        }
        my ($ok, $payload) = @$next;
        if ($ok) {
            my $resp = bless { content => $payload }, 'MockHTTPResp';
            $self->{ok_cb}->($resp);
        } else {
            $self->{err_cb}->($self, $payload);
        }
    }

    package MockHTTPResp;
    sub content { shift->{content} }

    package Slim::Plugin::OPMLBased;
    $INC{'Slim/Plugin/OPMLBased.pm'} = __FILE__;
    sub initPlugin {}

    package Slim::Player::Protocols::HTTPS;
    $INC{'Slim/Player/Protocols/HTTPS.pm'} = __FILE__;
    our $LAST_NEW_ARGS;
    our $LAST_SCAN_URL;
    sub new {
        my ($class, $args) = @_;
        $LAST_NEW_ARGS = { %$args };
        return bless $args, $class;
    }
    sub scanUrl {
        my ($class, $url, $args) = @_;
        $LAST_SCAN_URL = $url;
        my $scanned = bless { url => 'https://edge1.sr.se/p1-mp3-96', content_type => 'mp3', bitrate => 96000 }, 'MockTrack';
        $args->{cb}->($scanned, undef);
    }

    package MockTrack;
    sub url          { my $s = shift; $s->{url} = shift if @_; return $s->{url} }
    sub content_type { my $s = shift; $s->{content_type} = shift if @_; return $s->{content_type} }
    sub bitrate      { my $s = shift; $s->{bitrate} = shift if @_; return $s->{bitrate} }

    package Slim::Player::ProtocolHandlers;
    $INC{'Slim/Player/ProtocolHandlers.pm'} = __FILE__;
    sub registerHandler {}
    sub registerIconHandler {}

    package Slim::Control::Request;
    $INC{'Slim/Control/Request.pm'} = __FILE__;
    sub subscribe {}
    sub unsubscribe {}
    sub notifyFromArray {}

    package Slim::Web::Pages;
    $INC{'Slim/Web/Pages.pm'} = __FILE__;
    sub addRawFunction {}
    sub addPageFunction {}
    sub addPageLinks {}

    package Slim::Web::Settings;
    $INC{'Slim/Web/Settings.pm'} = __FILE__;
    sub handler {}

    package Slim::Web::HTTP;
    $INC{'Slim/Web/HTTP.pm'} = __FILE__;
    sub closeHTTPSocket {}

    package Slim::Web::HTTP::CSRF;
    sub protectName { $_[1] }
    sub protectURI  { $_[1] }
}

# --------------------------------------------------------------------------
# Load plugin modules
# --------------------------------------------------------------------------
unshift @INC, 'SverigesRadio';
# Map Plugins::SverigesRadio::* to SverigesRadio/*.pm
{
    my @order = (
        ['Plugins/SverigesRadio/API.pm'             => './SverigesRadio/API.pm'],
        ['Plugins/SverigesRadio/ProtocolHandler.pm' => './SverigesRadio/ProtocolHandler.pm'],
        ['Plugins/SverigesRadio/Settings.pm'        => './SverigesRadio/Settings.pm'],
        ['Plugins/SverigesRadio/Plugin.pm'          => './SverigesRadio/Plugin.pm'],
    );
    for my $pair (@order) {
        my ($k, $path) = @$pair;
        require $path;
        $INC{$k} = $path;
    }
}

ok(1, 'All plugin modules compiled and loaded cleanly');

# --------------------------------------------------------------------------
# Test 1: quality normalization & pref migration
# --------------------------------------------------------------------------
is(Plugins::SverigesRadio::API->normalizeQuality('mp3'),    'hi',     'normalizeQuality maps legacy mp3 -> hi');
is(Plugins::SverigesRadio::API->normalizeQuality(undef),    'hi',     'normalizeQuality maps undef -> hi');
is(Plugins::SverigesRadio::API->normalizeQuality('normal'), 'normal', 'normalizeQuality keeps normal');
is(Plugins::SverigesRadio::API->normalizeQuality('lo'),     'lo',     'normalizeQuality keeps lo');

my $prefs = Slim::Utils::Prefs::preferences('plugin.sverigesradio');
$prefs->set('quality', 'mp3');
Plugins::SverigesRadio::Plugin->initPlugin();
is($prefs->get('quality'), 'hi', 'initPlugin migrates legacy quality=mp3 to hi');

# --------------------------------------------------------------------------
# Test 2: API cache poisoning prevention + stale-while-error fallback
# --------------------------------------------------------------------------
Slim::Utils::Cache->clear_all();
push @Slim::Networking::SimpleAsyncHTTP::MOCK_RESPONSES,
    [ 1, encode_utf8('{"channels":[{"id":132,"name":"P1","channeltype":"Rikskanal","liveaudio":{"url":"https://www.sverigesradio.se/topsy/direkt/srapi/132.mp3"}}],"pagination":{}}') ];

my $got_channels;
Plugins::SverigesRadio::API->channels('hi', sub { $got_channels = shift });
is(scalar @$got_channels, 1, 'channels fetched and returned');

# Expire primary cache, simulate network failure + retry failure -> should serve stale
my $c = Slim::Utils::Cache->new();
$c->set('sr_channels_hi', undef);
push @Slim::Networking::SimpleAsyncHTTP::MOCK_RESPONSES,
    [ 0, 'timeout' ],
    [ 0, 'timeout' ];

@Slim::Utils::Timers::TIMERS = ();
my $stale_channels;
Plugins::SverigesRadio::API->channels('hi', sub { $stale_channels = shift });
# Trigger retry timer synchronously
if (@Slim::Utils::Timers::TIMERS) {
    my $t = shift @Slim::Utils::Timers::TIMERS;
    $t->[2]->();
}
is(scalar @$stale_channels, 1, 'channels falls back to stale cache on network error');

# Ensure empty/failed calls do NOT poison cache when no stale exists
Slim::Utils::Cache->clear_all();
push @Slim::Networking::SimpleAsyncHTTP::MOCK_RESPONSES,
    [ 0, '500 Internal Server Error' ],
    [ 0, '500 Internal Server Error' ];
my $failed_cats;
Plugins::SverigesRadio::API->programCategories(sub { $failed_cats = shift });
if (@Slim::Utils::Timers::TIMERS) {
    my $t = shift @Slim::Utils::Timers::TIMERS;
    $t->[2]->();
}
is(scalar @$failed_cats, 0, 'failed programCategories returns empty');
ok(!defined $c->get('sr_programcategories'), 'failed response was NOT cached');

# --------------------------------------------------------------------------
# Test 3: nowPlaying uses /scheduledepisodes/rightnow and decodes Swedish UTF-8
# --------------------------------------------------------------------------
push @Slim::Networking::SimpleAsyncHTTP::MOCK_RESPONSES,
    [ 1, encode_utf8('{"channel":{"id":132,"currentscheduledepisode":{"title":"Kropp & Själ – Åäö","socialimage":"https://static-cdn.sr.se/img.jpg"}}}') ];
my $np;
Plugins::SverigesRadio::API->nowPlaying(132, sub { $np = shift });
is($np->{title}, "Kropp & Själ – Åäö", 'nowPlaying decodes UTF-8 title from rightnow endpoint');
is($np->{socialimage}, 'https://static-cdn.sr.se/img.jpg', 'nowPlaying preserves socialimage');

# --------------------------------------------------------------------------
# Test 4: ProtocolHandler new() & scanUrl() & canDirectStream*()
# --------------------------------------------------------------------------
is(Plugins::SverigesRadio::ProtocolHandler->canDirectStream(), 0, 'canDirectStream returns 0');
is(Plugins::SverigesRadio::ProtocolHandler->canDirectStreamSong(), 0, 'canDirectStreamSong returns 0');

# Seed channels cache for scanUrl
$c->set('sr_channels_hi', [{
    id => 132,
    name => 'P1',
    image => 'https://static-cdn.sr.se/p1.jpg',
    liveaudio => { url => 'https://www.sverigesradio.se/topsy/direkt/srapi/132-hi.mp3' },
}]);

{
    package MockSong;
    sub new { bless { track => bless({ url => $_[1] }, 'MockTrack'), streamUrl => $_[1], pd => {} }, $_[0] }
    sub currentTrack { shift->{track} }
    sub streamUrl    { my $s = shift; $s->{streamUrl} = shift if @_; return $s->{streamUrl} }
    sub pluginData   { my ($s, $k, $v) = @_; $s->{pd}{$k} = $v if defined $v; return $s->{pd}{$k} }
}

my $song = MockSong->new('sverigesradio://live/132');
my ($scan_track, $scan_err);
Plugins::SverigesRadio::ProtocolHandler->scanUrl('sverigesradio://live/132', {
    song => $song,
    cb   => sub { ($scan_track, $scan_err) = @_ },
});
is($Slim::Player::Protocols::HTTPS::LAST_SCAN_URL, 'https://www.sverigesradio.se/topsy/direkt/srapi/132-hi.mp3', 'scanUrl delegates to SUPER::scanUrl');
is($song->streamUrl, 'https://edge1.sr.se/p1-mp3-96', 'scanUrl captures redirected edge URL into song->streamUrl');
is($scan_track->url, 'sverigesradio://live/132', 'scanUrl preserves original sverigesradio:// track URL');
is($scan_track->content_type, 'mp3', 'scanUrl sets content_type mp3');
is($scan_track->bitrate, 96000, 'scanUrl captures scanned bitrate');

# Test ProtocolHandler->new substitutes streamUrl unless redir
my $sock1 = Plugins::SverigesRadio::ProtocolHandler->new({ url => 'sverigesradio://live/132', song => $song });
is($Slim::Player::Protocols::HTTPS::LAST_NEW_ARGS->{url}, 'https://edge1.sr.se/p1-mp3-96', 'new() substitutes resolved streamUrl');
my $sock2 = Plugins::SverigesRadio::ProtocolHandler->new({ url => 'https://edge2.sr.se/p1-mp3-96', redir => 'https://edge1.sr.se/p1-mp3-96', song => $song });
is($Slim::Player::Protocols::HTTPS::LAST_NEW_ARGS->{url}, 'https://edge2.sr.se/p1-mp3-96', 'new() preserves redir target URL');

# --------------------------------------------------------------------------
# Test 5: _programItem type=>'link' & _episodeItem broadcast fallback & HTTP
# --------------------------------------------------------------------------
my $prog_item = Plugins::SverigesRadio::Plugin::_programItem({ id => 909, name => 'P1 Dokumentär' });
is($prog_item->{type}, 'link', '_programItem uses type => link so XMLBrowser does not strip episodes');

$prefs->set('use_http_streams', 1);
my $ep_pod = Plugins::SverigesRadio::Plugin::_episodeItem({
    title => 'Ep 1',
    publishdateutc => '/Date(1794898800000)/',
    listenpodfile => { url => 'https://static-cdn.sr.se/test.mp3', duration => 900 },
}, 'P1 Dokumentär', '');
is($ep_pod->{url}, 'http://static-cdn.sr.se/test.mp3', '_episodeItem rewrites static-cdn.sr.se to plain HTTP when enabled');
like($ep_pod->{line2}, qr/15 min · P1 Dokumentär/, '_episodeItem includes duration and programme name in line2');

my $future_ms = (time() + 3600) * 1000;
my $ep_br = Plugins::SverigesRadio::Plugin::_episodeItem({
    title => 'Morgon i P4',
    broadcast => {
        availablestoputc => "/Date($future_ms)/",
        broadcastfiles => [{ url => 'https://lyssna-cdn.sr.se/show.m4a', duration => 3600 }],
    },
}, 'Morgon i P4', '');
is($ep_br->{type}, 'audio', '_episodeItem falls back to broadcastfiles for broadcast-only programmes');
is($ep_br->{url}, 'http://lyssna-cdn.sr.se/show.m4a', '_episodeItem rewrites lyssna-cdn.sr.se to plain HTTP');
is($ep_br->{mime}, 'audio/mp4', '_episodeItem sets audio/mp4 mime for .m4a broadcasts');

# --------------------------------------------------------------------------
# Test 6: _webProgramFeed encodes OPML as UTF-8 bytes (fixes line 540 crash)
# --------------------------------------------------------------------------
{
    package MockURI;
    sub query { 'id=909&name=P1%20Dokument%C3%A4r' }
    package MockReq;
    sub uri { bless {}, 'MockURI' }
    package MockResp;
    sub new          { bless {}, shift }
    sub request      { bless {}, 'MockReq' }
    sub code         { my $s = shift; $s->{code} = shift if @_; return $s->{code} }
    sub content_type { my $s = shift; $s->{ct}   = shift if @_; return $s->{ct} }
    sub content      { my $s = shift; $s->{body} = shift if @_; return $s->{body} }
    package MockHTTPClient;
    sub send_response { my ($s, $r) = @_; $s->{sent} = $r }
}

my $ep_key = 'sr_episodes_' . Digest::MD5::md5_hex('programid=909&page=1&size=20');
$c->set($ep_key, {
    episodes => [{
        title => 'Ett andetag från döden – en berättelse',
        listenpodfile => { url => 'https://static-cdn.sr.se/doc.mp3', duration => 1800 },
    }],
    pagination => {},
});

my $hc = bless {}, 'MockHTTPClient';
my $resp = MockResp->new();
Plugins::SverigesRadio::Plugin::_webProgramFeed($hc, $resp);
is($resp->code, 200, '_webProgramFeed returns HTTP 200');
ok(!is_utf8($resp->content), '_webProgramFeed output is raw UTF-8 octets (not Perl wide-char string)');
like($resp->content, qr/P1 Dokument/, '_webProgramFeed contains programme title');

# --------------------------------------------------------------------------
# Test 7: _onPlaybackChange kills timer even on 'stop' when playingSong is undef
# --------------------------------------------------------------------------
{
    package MockClient;
    sub playingSong { undef }
    package MockRequest;
    sub client     { bless {}, 'MockClient' }
    sub getRequest { 'stop' }
}
@Slim::Utils::Timers::KILLED = ();
Plugins::SverigesRadio::Plugin::_onPlaybackChange(bless {}, 'MockRequest');
is(scalar @Slim::Utils::Timers::KILLED, 1, '_onPlaybackChange kills polling timer on stop even when playingSong is undef');

done_testing();

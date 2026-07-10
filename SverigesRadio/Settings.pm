package Plugins::SverigesRadio::Settings;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.sverigesradio');
my $log   = logger('plugin.sverigesradio');

sub name {
    Slim::Web::HTTP::CSRF->protectName('PLUGIN_SR_SETTINGS');
}

sub page {
    Slim::Web::HTTP::CSRF->protectURI('plugins/SverigesRadio/settings/basic.html');
}

sub prefs {
    return ($prefs, qw(quality channels_filter));
}

sub beforeRender {
    my ($class, $params, $client) = @_;

    $params->{quality_options} = [
        { value => 'hi', label => 'PLUGIN_SR_QUALITY_HI' },
        { value => 'lo', label => 'PLUGIN_SR_QUALITY_LO' },
    ];

    $params->{filter_options} = [
        { value => 'all',      label => 'PLUGIN_SR_CHANNELS_ALL' },
        { value => 'national', label => 'PLUGIN_SR_CHANNELS_NAT' },
    ];
}

sub new {
    my $class = shift;
    Slim::Web::Pages->addPageFunction($class->page(), $class);
    Slim::Web::Pages->addPageLinks('setup', { $class->name() => $class->page() });
}

1;

package Plugins::YouTubeMusic::Settings::Player;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use constant SETTINGS_URL => 'plugins/YouTubeMusic/settings/player.html';

my $prefs = preferences('plugin.youtubemusic');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_YOUTUBEMUSIC_PLAYER_SETTINGS');
}

sub needsClient { 1 }

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL);
}

sub prefs { return ($prefs) }

sub handler {
    my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

    if ($paramRef->{saveSettings} && $client) {
        my $accounts = $prefs->get('accounts') || {};
        my $account = $paramRef->{pref_activeAccount} // '';
        if ($account eq '' || $account eq '-' || $accounts->{$account}) {
            $prefs->client($client)->set('activeAccount', $account);
        }
        my $fmt = $paramRef->{pref_streamFormat} // 'auto';
        $fmt = 'auto' unless $fmt =~ /^(?:auto|mp3|flac|aac)$/;
        $prefs->client($client)->set('streamFormat', $fmt);
        my $bitrate = $paramRef->{pref_bitrate} // '';
        $bitrate = '' unless $bitrate =~ /^(?:192|320)$/;
        $prefs->client($client)->set('bitrate', $bitrate);
    }

    if ($client) {
        my $stored = $prefs->get('accounts') || {};
        my @accountList;
        for my $id (sort keys %{$stored}) {
            push @accountList, { id => $id, name => $stored->{$id}{displayName} || $id };
        }
        $paramRef->{accountList} = \@accountList;
        $paramRef->{activeAccount} = $prefs->client($client)->get('activeAccount');
        $paramRef->{activeAccount} = '' if !defined $paramRef->{activeAccount};
        $paramRef->{serverAccount} = $prefs->get('activeAccount') || '';
        $paramRef->{streamFormat} = $prefs->client($client)->get('streamFormat') || 'auto';
        $paramRef->{bitrate} = $prefs->client($client)->get('bitrate') || '';
    }

    return $class->SUPER::handler($client, $paramRef, $callback, $httpClient, $response);
}

1;

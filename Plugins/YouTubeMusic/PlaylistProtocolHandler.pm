package Plugins::YouTubeMusic::PlaylistProtocolHandler;

# Lightweight pseudo-protocol handler for ytmplaylist://BROWSE_ID URLs.
# This handler never streams audio itself — it only implements
# explodePlaylist, which LMS calls when the user chooses "Play" or "Add"
# on a playlist/album menu item. We fetch every track in the playlist via
# the proxy and hand back the full list of ytm:// track URLs, which LMS
# then loads into the real playback queue (enabling prefetch, track
# advance, etc. exactly as if each song had been added individually).

use strict;
use warnings;

use Slim::Utils::Log;
use Plugins::YouTubeMusic::API;
use Plugins::YouTubeMusic::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.youtubemusic',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_YOUTUBEMUSIC',
});

sub isRemote { 1 }
sub isPlaylist { 1 }
sub isPlaylistURL { 1 }
sub canDirectStream { 0 }
sub contentType { 'ytmplaylist' }
sub getFormatForURL { 'ytmplaylist' }

sub explodePlaylist {
    my ($class, $client, $uri, $callback) = @_;

    my ($browse_id) = $uri =~ m{^ytmplaylist://(.+)$};
    unless ($browse_id) {
        $log->error("Malformed ytmplaylist:// URL: $uri");
        $callback->([]);
        return;
    }

    $log->info("Exploding playlist browseId=$browse_id");
    Plugins::YouTubeMusic::ProtocolHandler::cancel_radio($client) if $client;

    return _explode_liked($client, $callback) if $browse_id eq 'liked';
    return _explode_feed($client, $callback) if $browse_id eq 'feed';
    return _explode_recap($client, $callback) if $browse_id eq 'recap';
    return _explode_browse($client, $callback, $browse_id);
}

sub _explode_browse {
    my ($client, $callback, $browse_id) = @_;
    Plugins::YouTubeMusic::API->browsePlaylist($browse_id, sub {
        my $data = shift;
        _emit_tracks($client, $callback, ($data && ref $data eq 'HASH') ? $data->{items} : undef, $browse_id);
    }, $client);
}

sub _explode_liked {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->liked(sub {
        my $data = shift;
        _emit_tracks($client, $callback, ($data && ref $data eq 'HASH') ? $data->{items} : undef, 'liked');
    }, $client);
}

sub _explode_feed {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->browseHome(sub {
        my $sections = shift;
        my @songs;
        my $playlist;
        if (ref $sections eq 'ARRAY') {
            for my $section (@{$sections}) {
                next unless ref $section eq 'HASH';
                for my $item (@{ $section->{items} || [] }) {
                    next unless ref $item eq 'HASH';
                    if ($item->{videoId}) {
                        push @songs, $item;
                    } elsif (!$playlist && ($item->{type} || '') eq 'playlist' && $item->{browseId}) {
                        $playlist = $item->{browseId};
                    }
                    last if @songs >= 40;
                }
                last if @songs >= 40;
            }
        }
        if (@songs) {
            return _emit_tracks($client, $callback, \@songs, 'feed');
        }
        if ($playlist) {
            return _explode_browse($client, $callback, $playlist);
        }
        _explode_liked($client, $callback);
    }, $client);
}

sub _explode_recap {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->browseHome(sub {
        my $sections = shift;
        my $found = _recap_id($sections);
        if ($found) {
            return _explode_browse($client, $callback, $found);
        }
        Plugins::YouTubeMusic::API->library('playlists', sub {
            my $rows = shift;
            if (ref $rows eq 'ARRAY') {
                for my $pl (@{$rows}) {
                    next unless ref $pl eq 'HASH' && $pl->{browseId};
                    if (($pl->{title} || '') =~ /recap|replay|r[eé]cap/i) {
                        return _explode_browse($client, $callback, $pl->{browseId});
                    }
                }
            }
            $log->info('No Recap playlist, using liked songs');
            _explode_liked($client, $callback);
        }, $client);
    }, $client);
}

sub _recap_id {
    my $sections = shift;
    return '' unless ref $sections eq 'ARRAY';
    for my $section (@{$sections}) {
        next unless ref $section eq 'HASH';
        my $shelf = $section->{title} || '';
        for my $item (@{ $section->{items} || [] }) {
            next unless ref $item eq 'HASH' && ($item->{type} || '') eq 'playlist' && $item->{browseId};
            my $text = $shelf . ' ' . ($item->{title} || '');
            return $item->{browseId} if $text =~ /recap|replay|r[eé]cap/i;
        }
    }
    return '';
}

sub _emit_tracks {
    my ($client, $callback, $items, $label) = @_;
    unless ($items && ref $items eq 'ARRAY') {
        $log->error("Failed to explode playlist $label");
        $callback->([]);
        return;
    }

    my @urls;
    my $prefetched = 0;
    for my $track (@{$items}) {
        next unless ref $track eq 'HASH' && $track->{videoId};
        Plugins::YouTubeMusic::ProtocolHandler->primeMetadata($track->{videoId}, $track);
        if ($prefetched < 3) {
            Plugins::YouTubeMusic::API->prefetch($track->{videoId}, sub {}, $client);
            $prefetched++;
        }
        my $url = "ytm://$track->{videoId}";
        push @urls, $url;
        if ($track->{title}) {
            my $lms_track = Slim::Schema->objectForUrl({ url => $url, create => 1 });
            if ($lms_track) {
                $lms_track->title($track->{title});
                $lms_track->artist($track->{artist} || '');
                $lms_track->update();
            }
        }
    }

    $log->info("Exploded playlist $label into " . scalar(@urls) . " tracks");
    $callback->(\@urls);
}

1;

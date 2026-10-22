package Plugins::YouTubeMusic::ProtocolHandler;

# Implements the ytm:// protocol scheme for Lyrion Music Server.
#
# Flow:
#   1. LMS calls getNextTrack() when a ytm://VIDEO_ID URL is about to play.
#   2. We point the track at our local Python proxy's /stream/VIDEO_ID
#      endpoint (http://127.0.0.1:PORT/stream/VIDEO_ID), which internally
#      pipes yt-dlp's output through ffmpeg to produce a clean, sequential
#      MP3 stream. This avoids moov-atom-at-end-of-file issues that prevent
#      hardware Squeezebox decoders from playing raw YouTube CDN MP4/WebM.
#   3. Since the proxy is local plain HTTP, we extend the base HTTP handler
#      (no TLS needed) and just substitute the stream URL in new().

use strict;
use warnings;
use Time::HiRes;
use base qw(Slim::Player::Protocols::HTTP);

use Scalar::Util       qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Music::Info;
use Slim::Player::ProtocolHandlers;
use Slim::Player::Source;
use Slim::Player::Playlist;

use Plugins::YouTubeMusic::API;

my $prefs = preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.youtubemusic',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_YOUTUBEMUSIC',
});

# ── Capability declarations ──────────────────────────────────────────────────

sub isRemote        { 1 }
sub isAudio         { 1 }
sub isAudioURL      { 1 }
sub isPlaylistURL   { 0 }
sub canSeek         { 0 }
sub canDirectStream { 0 }
sub songBytes       {}

# Audio format — determined at startup by querying the proxy's /codec
# endpoint, which probes ffmpeg for available encoders. Defaults to mp3
# but falls back to aac on platforms like piCorePlayer where libmp3lame
# is not available.
my $_audio_format = 'mp3';
my %_radio_active;  # tracks which clients have radio running
my %_radio_gen;

sub cancel_radio {
    my ($client) = @_;
    return unless $client;
    my $id = $client->id // '';
    $_radio_gen{$id}++;
    delete $_radio_active{$id};
    Slim::Utils::Timers::killTimers($client, \&_delayed_radio);
}

sub arm_radio_after_stop {
    my ($client, $vid) = @_;
    return unless $client && $vid;
    my $id = $client->id // '';
    my $gen = $_radio_gen{$id} // 0;
    Slim::Utils::Timers::setTimer(
        $client, Time::HiRes::time() + 5, \&_delayed_radio, $vid, $gen
    );
}

sub _delayed_radio {
    my ($client, $vid, $gen) = @_;
    return unless $client && $vid;
    my $id = $client->id // '';
    return if ($_radio_gen{$id} // 0) != $gen;
    my $mode = eval { Slim::Player::Source::playmode($client) } // '';
    return unless $mode eq 'stop';
    return unless $prefs->get('autoplay') // 1;
    $log->info("Player stopped — continuing with radio");
    _start_radio($client, $vid);
    $client->execute(['play']);
}

sub _init_audio_format {
    my $port = preferences('plugin.youtubemusic')->get('proxy_port') || 9876;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { JSON::XS::decode_json($http->content) };
            if ($data && $data->{format}) {
                my $fmt = $data->{format};
                # Normalise format strings to what LMS expects
                $fmt = 'aac' if $fmt eq 'adts';
                $fmt = 'flc' if $fmt eq 'flac';
                $_audio_format = $fmt;
                $log->info("Audio format set to: $fmt");
            }
        },
        sub { $log->warn("Could not query codec from proxy, defaulting to mp3") },
    )->get("http://127.0.0.1:$port/codec");
}

sub formatOverride  { $_audio_format }
sub getFormatForURL { $_audio_format }
sub contentType     { $_audio_format }

# Substitute the local proxy stream URL before the base class opens the
# socket, same pattern used by RadioParadise's protocol handler.
sub new {
    my $class  = shift;
    my $args   = shift;
    my $client = $args->{client};
    my $song   = $args->{song};

    my $streamUrl = $song ? $song->streamUrl() : undef;
    unless ($streamUrl) {
        $log->error('No resolved stream URL available for ' . ($args->{url} // 'unknown'));
        return undef;
    }

    if ($args->{url} && $args->{redir}) {
        if ($args->{redir} ne $args->{url}) {
            $streamUrl = $args->{url};
        } else {
            $log->error("Redirection loop for url: $streamUrl");
        }
    }

    $log->info("Opening local proxy stream: $streamUrl");

    return $class->SUPER::new({
        url    => $streamUrl,
        song   => $song,
        client => $client,
    });
}

# ── Main resolution ───────────────────────────────────────────────────────────

# Extract a YouTube video ID from any of the URL shapes we handle:
#   ytm://VIDEO_ID                         (our native scheme)
#   youtube://VIDEO_ID                     (philippe44 compat)
#   youtube://www.youtube.com/v/VIDEO_ID   (philippe44 compat)
#   https://www.youtube.com/watch?v=ID     (plain YouTube URL)
#   https://youtu.be/VIDEO_ID             (short URL)
sub explodePlaylist {
    my ($class, $client, $url, $callback) = @_;
    # Handle OLAK5uy_ playlist URLs from browser address bar
    if ($url =~ m{[?&]list=(OLAK5uy_[A-Za-z0-9_\-]+)}) {
        my $list_id = $1;
        $log->info("explodePlaylist: resolving OLAK playlist $list_id");
        Plugins::YouTubeMusic::PlaylistProtocolHandler->explodePlaylist($client, "ytmplaylist://$list_id", $callback);
        return;
    }
    # Handle ytmplaylist:// URLs
    if ($url =~ m{^ytmplaylist://}) {
        Plugins::YouTubeMusic::PlaylistProtocolHandler->explodePlaylist($client, $url, $callback);
        return;
    }
    # Handle single ytm:// track URLs
    if ($url =~ m{^ytm://([A-Za-z0-9_\-]+)}) {
        $callback->([$url]);
        return;
    }
    # Handle real YouTube watch URLs
    my $vid = _extract_video_id($url);
    if ($vid) {
        $callback->(["ytm://$vid"]);
        return;
    }
    $log->warn("explodePlaylist: unrecognised URL $url");
    $callback->([]);
}

sub _extract_video_id {
    my ($url) = @_;
    my ($vid);
    ($vid) = $url =~ m{^ytm://([A-Za-z0-9_\-]+)}                    and return $vid;
    ($vid) = $url =~ m{^youtube://([A-Za-z0-9_\-]+)$}               and return $vid;
    ($vid) = $url =~ m{youtube://(?:www\.)?youtube\.com/v/([A-Za-z0-9_\-]+)} and return $vid;
    ($vid) = $url =~ m{[?&]v=([A-Za-z0-9_\-]+)}                     and return $vid;
    ($vid) = $url =~ m{music\.youtube\.com/watch\?.*v=([A-Za-z0-9_\-]+)}  and return $vid;
    ($vid) = $url =~ m{youtu\.be/([A-Za-z0-9_\-]+)}                and return $vid;
    return undef;
}


sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url   = $song->currentTrack()->url;
    # Check if this is an OLAK5uy_ playlist URL from browser address bar
    if ($url =~ m{[?&]list=(OLAK5uy_[A-Za-z0-9_\-]+)}) {
        my $list_id = $1;
        $log->info("Detected OLAK playlist URL, exploding ytmplaylist://$list_id");
        Plugins::YouTubeMusic::PlaylistProtocolHandler->explodePlaylist(
            $song->master(), "ytmplaylist://$list_id",
            sub {
                my $urls = shift;
                unless ($urls && @$urls) { $errorCb->("Failed to load playlist"); return; }
                $song->master()->execute(['playlist', 'clear']);
                $song->master()->execute(['playlist', 'add', $_]) for @$urls;
                $song->master()->execute(['play']);
                $successCb->() if $successCb;
            }
        );
        return;
    }
    my $vid = _extract_video_id($url);

    unless ($vid) {
        $log->error("Unrecognised URL: $url");
        $errorCb->('Invalid YouTube Music URL');
        return;
    }

    my $port       = $prefs->get('proxy_port') || 9876;
    my $server_ip  = Slim::Utils::Network::serverAddr() || '127.0.0.1';
    my $player     = eval { $song->master() } || eval { $song->owner() };
    cancel_radio($player) if $player;
    my $query      = Plugins::YouTubeMusic::API->streamQuery($player);
    my $streamUrl  = "http://$server_ip:$port/stream/$vid$query";

    # If autoplay is disabled, ensure repeat is off so player stops after queue ends
    unless ($prefs->get('autoplay') // 1) {
        $song->master()->execute(['playlist', 'repeat', 0]) if eval { $song->master() };
    }
    $log->info("Routing playback through local proxy: $streamUrl");

    $song->streamUrl($streamUrl);
    _fetch_metadata($vid, $song, $player);
    # Start downloading current track NOW before LMS opens the stream
    $log->info("EARLY PREFETCH START $vid");
    Plugins::YouTubeMusic::API->prefetch($vid, sub {}, $player);


    # Only trigger prefetch chain for the first track — subsequent tracks
    # are prefetched by the chain itself as playback progresses
    my $prefetch_client = eval { $song->master() };
    _prefetch_with_client($prefetch_client) if $prefetch_client;
    $successCb->();
}

sub _prefetch_with_client {
    my ($client) = @_;
    return unless $client;
    my $current_index = eval { Slim::Player::Source::playingSongIndex($client) };
    return unless defined $current_index;
    my $next_index = $current_index + 1;
    my $count      = eval { Slim::Player::Playlist::count($client) } || 0;
    $log->info("Prefetch: current=$current_index next=$next_index count=$count");
    if ($next_index < $count) {
        my $next_track = eval { Slim::Player::Playlist::track($client, $next_index) };
        my $next_url = $next_track ? eval { $next_track->url } : '';
        my ($next_vid) = ($next_url // '') =~ m{^ytm://([A-Za-z0-9_\-]+)};
        if ($next_vid) {
            $log->info("Prefetching next track: $next_vid");
            Plugins::YouTubeMusic::API->prefetch($next_vid, sub {}, $client);
        }
        my $next2_index = $next_index + 1;
        if ($next2_index < $count) {
            my $next2_track = eval { Slim::Player::Playlist::track($client, $next2_index) };
            my $next2_url = $next2_track ? eval { $next2_track->url } : '';
            my ($next2_vid) = ($next2_url // '') =~ m{^ytm://([A-Za-z0-9_\-]+)};
            Plugins::YouTubeMusic::API->prefetch($next2_vid, sub {}, $client) if $next2_vid;
        }
    }
    if (($prefs->get('autoplay') // 1) && ($count - $current_index) <= 1) {
        my $cur_track = eval { Slim::Player::Playlist::track($client, $current_index) };
        my $cur_url = $cur_track ? eval { $cur_track->url } : '';
        my ($cur_vid) = ($cur_url // '') =~ m{^ytm://([A-Za-z0-9_\-]+)};
        _start_radio($client, $cur_vid) if $cur_vid;
    }
}

sub _prefetch_next_track {
    my ($song) = @_;
    my $client = eval { $song->master() } || eval { $song->owner() };
    _prefetch_with_client($client) if $client;
}

# ── Metadata ──────────────────────────────────────────────────────────────────

# In-memory metadata cache keyed by video ID. We avoid writing to the
# track's DB relations (artist is a Contributor object, not a plain
# string, and fighting that plumbing for remote/ephemeral tracks isn't
# worth it) and instead let getMetadataFor read straight from here.
my %_metadata_cache;
my %_metadata_inflight;
my %_metadata_fail_until;

sub _secs {
    my ($value) = @_;
    return 0 unless defined $value && $value ne '';
    return int($value) if $value =~ /^\d+(?:\.\d+)?$/;
    if ($value =~ /^(?:(\d+):)?(\d+):(\d+)$/) {
        return (($1 || 0) * 3600) + ($2 * 60) + $3;
    }
    return 0;
}

sub _cache_ready {
    my ($video_id) = @_;
    my $cached = $_metadata_cache{$video_id} or return 0;
    return $cached->{title} && _secs($cached->{duration}) > 0;
}

sub _apply_meta {
    my ($song, $info) = @_;
    return unless $song && $info && ref $info eq 'HASH';
    my $track = eval { $song->currentTrack() } or return;
    $track->title($info->{title}) if $info->{title};
    my $cover = $info->{cover} || $info->{thumbnail} || '';
    $track->coverurl($cover) if $cover;
    my $secs = _secs($info->{duration});
    if ($secs > 0) {
        $track->secs($secs);
        Slim::Music::Info::setDuration($track, $secs);
        my $stream = eval { $song->streamUrl() };
        Slim::Music::Info::setDuration($stream, $secs) if $stream;
        $song->duration($secs);
        my $client = eval { $song->master() };
        $client->streamingProgressBar({ url => $stream, duration => $secs }) if $client && $stream;
    }
    eval { $track->update() };
}

sub parseHeaders {
    my $self = shift;
    my $ret  = $self->SUPER::parseHeaders(@_);
    my $song = ${*$self}{'song'};
    if ($song) {
        $song->isLive(0);
        my $url = eval { $song->currentTrack()->url } || '';
        my ($vid) = $url =~ m{^ytm://([A-Za-z0-9_\-]+)};
        _apply_meta($song, $_metadata_cache{$vid}) if $vid && $_metadata_cache{$vid};
    }
    return $ret;
}

sub primeMetadata {
    my ($class, $video_id, $info) = @_;
    return unless $video_id && $info;
    my $cur = $_metadata_cache{$video_id} || {};
    my $secs = _secs($info->{duration}) || _secs($cur->{duration});
    $_metadata_cache{$video_id} = {
        title    => $info->{title}     || $cur->{title} || '',
        artist   => $info->{artist}    || $cur->{artist} || '',
        album    => $info->{album}     || $cur->{album} || '',
        duration => $secs,
        cover    => $info->{thumbnail} || $info->{cover} || $cur->{cover} || '',
    };
}


sub reset_radio {
    my ($client) = @_;
    return unless $client;
    my $client_id = $client->id // '';
    delete $_radio_active{$client_id} if $client_id;
    $log->debug("Radio flag reset for $client_id");
}

sub _queue_still_on {
    my ($client, $video_id) = @_;
    return 0 unless $client && $video_id;
    my $cur = eval {
        Slim::Player::Playlist::track($client, Slim::Player::Source::playingSongIndex($client));
    };
    my $url = $cur ? (eval { $cur->url } // '') : '';
    return $url =~ m{^ytm://\Q$video_id\E(?:\?|$)};
}

sub _start_radio {
    my ($client, $video_id) = @_;
    return unless $client && $video_id;

    # Don't trigger radio if already running for this client
    my $client_id = $client->id // '';
    if ($_radio_active{$client_id}) {
        $log->debug("Radio already active for $client_id, skipping");
        return;
    }
    $_radio_active{$client_id} = 1;
    my $gen = $_radio_gen{$client_id} // 0;

    $log->info("Starting radio from videoId: $video_id");
    $log->info("Radio client: " . ($client->id // "unknown") . " name: " . ($client->name // "unknown"));

    Plugins::YouTubeMusic::API->browseRadio($video_id, sub {
        my $data = shift;
        if (($_radio_gen{$client_id} // 0) != $gen || !_queue_still_on($client, $video_id)) {
            delete $_radio_active{$client_id};
            return;
        }
        unless ($data && ref $data eq 'ARRAY' && @$data) {
            delete $_radio_active{$client_id};
            $log->warn("Radio returned no tracks for $video_id");
            return;
        }

        # Skip the first track if it's the same as current
        my @tracks = grep { $_->{videoId} && $_->{videoId} ne $video_id } @$data;
        unless (@tracks) {
            delete $_radio_active{$client_id};
            $log->warn("Radio returned no new tracks for $video_id");
            return;
        }

        # Prime metadata cache for radio tracks so queue shows
        # correct titles/artwork instead of raw video IDs
        for my $track (@tracks) {
            next unless $track->{videoId};
            Plugins::YouTubeMusic::ProtocolHandler->primeMetadata(
                $track->{videoId}, $track
            );
        }
        my @urls = map { "ytm://$_->{videoId}" } @tracks;
        $log->info("Adding " . scalar(@urls) . " radio tracks to queue");

        # Add tracks to the end of the current playlist
        # Add tracks individually — addtracks listRef can fail for some player types
        for my $url (@urls) {
            $client->execute(['playlist', 'add', $url]);
        }
        # Re-run prefetch now that queue has tracks
        _prefetch_with_client($client);
        # Reset radio flag after a delay so radio can fire again
        # when the added tracks eventually run out
        Slim::Utils::Timers::setTimer(
            $client, Time::HiRes::time() + 300,
            sub { delete $_radio_active{$client_id}; }
        );
    }, $client);
}

sub _remember_metadata {
    my ($video_id, $info) = @_;
    return 0 unless $video_id && $info && ref $info eq 'HASH' && ($info->{title} || $info->{artist});
    my $cur = $_metadata_cache{$video_id} || {};
    $_metadata_cache{$video_id} = {
        title    => $info->{title}     || $cur->{title} || '',
        artist   => $info->{artist}    || $cur->{artist} || '',
        album    => $info->{album}     || $cur->{album} || '',
        duration => _secs($info->{duration}) || _secs($cur->{duration}),
        cover    => $info->{thumbnail} || $info->{cover} || $cur->{cover} || '',
    };
    delete $_metadata_fail_until{$video_id};
    return 1;
}

sub _request_metadata {
    my ($video_id, $cb, $client) = @_;
    return if !$video_id || _cache_ready($video_id);
    return if $_metadata_inflight{$video_id};
    return if ($_metadata_fail_until{$video_id} || 0) > time();
    $_metadata_inflight{$video_id} = 1;
    Plugins::YouTubeMusic::API->getSongInfo($video_id, sub {
        my $info = shift;
        delete $_metadata_inflight{$video_id};
        unless (_remember_metadata($video_id, $info)) {
            $_metadata_fail_until{$video_id} = time() + 20;
            $cb->() if $cb;
            return;
        }
        $cb->($_metadata_cache{$video_id}) if $cb;
        Slim::Control::Request::notifyFromArray(undef, ['newmetadata']);
    }, $client);
}

sub _fetch_metadata {
    my ($video_id, $song, $client) = @_;
    _apply_meta($song, $_metadata_cache{$video_id}) if $_metadata_cache{$video_id};
    return if _cache_ready($video_id);
    _request_metadata($video_id, sub {
        my $info = shift;
        _apply_meta($song, $info) if $info;
    }, $client);
}

# ── getMetadataFor (called when building Now Playing info) ────────────────────

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my ($vid) = $url =~ m{^ytm://([A-Za-z0-9_\-]+)};
    return {} unless $vid;

    my $cached = $_metadata_cache{$vid};

    # One lookup per track. A cold queue used to fire get_song for every
    # row at once and exhaust the process file limit.
    _request_metadata($vid, undef, $client) unless _cache_ready($vid);
    $cached = $_metadata_cache{$vid};

    my $secs = $cached ? _secs($cached->{duration}) : 0;
    my %meta  = (
        title   => ($cached && $cached->{title})  ? $cached->{title}  : "YouTube Music - $vid",
        artist  => ($cached && $cached->{artist}) ? $cached->{artist} : '',
        album   => ($cached && $cached->{album}) ? $cached->{album} : ' | YouTube Music',
        cover   => ($cached && $cached->{cover})  ? $cached->{cover}
                    : Plugins::YouTubeMusic::Plugin->_pluginDataFor('icon'),
        type    => 'YouTube Music',
        bitrate => '192k CBR',
        duration => $secs > 0 ? $secs : undef,
    );

    return \%meta;
}

# ── Icon ──────────────────────────────────────────────────────────────────────

sub getIcon {
    return Plugins::YouTubeMusic::Plugin->_pluginDataFor('icon');
}

1;

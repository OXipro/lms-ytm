package Plugins::YouTubeMusic::API;

use strict;
use warnings;

use JSON::XS          qw(decode_json encode_json);
use Scalar::Util      qw(blessed);
use URI::Escape       qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

my $prefs = preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.youtubemusic',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_YOUTUBEMUSIC',
});

sub _proxy_url {
    my $port = $prefs->get('proxy_port') || 9876;
    return "http://127.0.0.1:$port";
}

sub accountId {
    my ($class, $client) = @_;
    return '' unless $client;
    my $id = $prefs->client($client)->get('activeAccount');
    return '' if defined $id && $id eq '-';
    $id = $prefs->get('activeAccount') if !defined $id || $id eq '';
    return ($id && $id ne '-') ? $id : '';
}

sub _account_qs {
    my ($client) = @_;
    my $id = __PACKAGE__->accountId($client);
    return '' unless $id;
    return '?account=' . uri_escape_utf8($id);
}

sub streamQuery {
    my ($class, $client) = @_;
    my @parts;
    my $id = $class->accountId($client);
    push @parts, 'account=' . uri_escape_utf8($id) if $id;
    my $fmt = 'auto';
    my $bitrate = '';
    if ($client) {
        $fmt = $prefs->client($client)->get('streamFormat') || 'auto';
        $bitrate = $prefs->client($client)->get('bitrate') || '';
    }
    $fmt = $prefs->get('codec') || 'auto' if !$fmt || $fmt eq 'auto';
    push @parts, 'codec=' . uri_escape_utf8($fmt) if $fmt && $fmt ne 'auto';
    push @parts, 'bitrate=' . uri_escape_utf8($bitrate) if $bitrate;
    return @parts ? '?' . join('&', @parts) : '';
}

sub _with_account {
    my ($path, $client) = @_;
    my $qs = _account_qs($client);
    return $path unless $qs;
    return $path . ($path =~ /\?/ ? '&' . substr($qs, 1) : $qs);
}

sub _get {
    my ($path, $cb) = @_;

    my $url = _proxy_url() . $path;
    $log->debug("API GET: $url");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { decode_json($http->content) };
            if ($@) {
                $log->error("JSON decode error for $url: $@");
                $cb->(undef);
            } else {
                $cb->($data);
            }
        },
        sub {
            my ($http, $err) = @_;
            $log->error("Proxy request failed ($url): $err");
            $cb->(undef);
        },
        { timeout => 30 }
    )->get($url);
}

sub search {
    my ($class, $query, $type, $cb, $client) = @_;
    my $q = uri_escape_utf8($query);
    _get(_with_account("/search?q=$q&type=$type", $client), $cb);
}

sub browseHome {
    my ($class, $cb, $client, $refresh) = @_;
    my $path = $refresh ? '/browse/home?refresh=1' : '/browse/home';
    _get(_with_account($path, $client), $cb);
}

sub browseCharts {
    my ($class, $cb, $client) = @_;
    _get(_with_account('/browse/charts', $client), $cb);
}

sub browsePlaylist {
    my ($class, $browse_id, $cb, $client) = @_;
    my $id = uri_escape_utf8($browse_id);
    _get(_with_account("/playlist?browseId=$id", $client), $cb);
}

sub browseAlbum {
    my ($class, $browse_id, $cb, $client) = @_;
    my $id = uri_escape_utf8($browse_id);
    _get(_with_account("/album?browseId=$id", $client), $cb);
}

sub browseArtist {
    my ($class, $browse_id, $cb, $client) = @_;
    my $id = uri_escape_utf8($browse_id);
    _get(_with_account("/artist?browseId=$id", $client), $cb);
}

sub getSongInfo {
    my ($class, $video_id, $cb, $client) = @_;
    _get(_with_account("/song?videoId=$video_id", $client), $cb);
}

sub prefetch {
    my ($class, $video_id, $cb, $client) = @_;
    $cb ||= sub {};
    _get('/prefetch/' . $video_id . $class->streamQuery($client), $cb);
}

sub browseNewReleases {
    my ($class, $cb, $client) = @_;
    _get(_with_account('/browse/new_releases', $client), $cb);
}
sub browseMoods {
    my ($class, $cb, $client) = @_;
    _get(_with_account('/browse/moods', $client), $cb);
}
sub browseMoodCategory {
    my ($class, $browse_id, $params, $cb, $client) = @_;
    _get(_with_account("/browse/mood_category?browseId=$browse_id&params=" . uri_escape_utf8($params // ''), $client), $cb);
}
sub browsePodcasts {
    my ($class, $cb, $client) = @_;
    _get(_with_account('/browse/podcasts', $client), $cb);
}

sub browseRadio {
    my ($class, $video_id, $cb, $client) = @_;
    _get(_with_account("/radio?videoId=$video_id", $client), $cb);
}

sub library {
    my ($class, $kind, $cb, $client) = @_;
    _get(_with_account("/library/$kind", $client), $cb);
}

sub liked {
    my ($class, $cb, $client) = @_;
    _get(_with_account('/library/liked', $client), $cb);
}

sub history {
    my ($class, $cb, $client) = @_;
    _get(_with_account('/history', $client), $cb);
}

sub accountStatus {
    my ($class, $account_id, $cb) = @_;
    return $cb->(undef) unless $account_id;
    _get('/accounts/status?id=' . uri_escape_utf8($account_id), $cb);
}

sub _post {
    my ($path, $body, $cb) = @_;
    my $url = _proxy_url() . $path;
    my $json = encode_json($body);
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { decode_json($http->content) };
            $cb->($@ ? undef : $data);
        },
        sub {
            my ($http, $err) = @_;
            $log->error("Proxy request failed ($url): $err");
            $cb->(undef);
        },
        { timeout => 30 }
    )->post($url, 'Content-Type' => 'application/json', $json);
}

sub _account_body {
    my ($class, $client, %fields) = @_;
    return {
        account => $class->accountId($client),
        %fields,
    };
}

sub songRating {
    my ($class, $video_id, $cb, $client) = @_;
    _get(_with_account('/library/rating?videoId=' . uri_escape_utf8($video_id), $client), $cb);
}

sub rateSong {
    my ($class, $video_id, $rating, $cb, $client) = @_;
    _post('/library/rate', $class->_account_body($client, videoId => $video_id, rating => $rating), $cb);
}

sub artistSubscribed {
    my ($class, $channel_id, $cb, $client) = @_;
    _get(_with_account('/library/subscribed?channelId=' . uri_escape_utf8($channel_id), $client), $cb);
}

sub setSubscription {
    my ($class, $channel_id, $subscribed, $cb, $client) = @_;
    _post('/library/subscribe', $class->_account_body($client, channelId => $channel_id, subscribed => $subscribed ? JSON::XS::true : JSON::XS::false), $cb);
}

sub savePlaylist {
    my ($class, $playlist_id, $browse_id, $rating, $cb, $client) = @_;
    _post('/library/save', $class->_account_body($client,
        playlistId => $playlist_id || '',
        browseId   => $browse_id || '',
        rating     => $rating,
    ), $cb);
}

sub addToPlaylist {
    my ($class, $playlist_id, $video_id, $cb, $client) = @_;
    _post('/library/playlist/add', $class->_account_body($client, playlistId => $playlist_id, videoId => $video_id), $cb);
}

sub createPlaylist {
    my ($class, $title, $video_ids, $cb, $client) = @_;
    _post('/library/playlist/create', $class->_account_body($client, title => $title, videoIds => $video_ids || []), $cb);
}

sub removeFromPlaylist {
    my ($class, $playlist_id, $video_id, $set_video_id, $cb, $client) = @_;
    _post('/library/playlist/remove', $class->_account_body($client,
        playlistId => $playlist_id,
        videoId    => $video_id,
        setVideoId => $set_video_id,
    ), $cb);
}

sub deletePlaylist {
    my ($class, $playlist_id, $cb, $client) = @_;
    _post('/library/playlist/delete', $class->_account_body($client, playlistId => $playlist_id), $cb);
}

sub searchSuggestions {
    my ($class, $query, $cb, $client) = @_;
    _get(_with_account('/search/suggestions?q=' . uri_escape_utf8($query // ''), $client), $cb);
}

sub forgetSearch {
    my ($class, $token, $cb, $client) = @_;
    _post('/search/forget', $class->_account_body($client, feedbackToken => $token), $cb);
}

sub addHistory {
    my ($class, $video_id, $cb, $client) = @_;
    _post('/history/add', $class->_account_body($client, videoId => $video_id), $cb);
}

sub removeHistory {
    my ($class, $token, $cb, $client) = @_;
    _post('/history/remove', $class->_account_body($client, feedbackToken => $token), $cb);
}

1;

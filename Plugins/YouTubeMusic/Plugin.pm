package Plugins::YouTubeMusic::Plugin;

use strict;
use Time::HiRes;
use warnings;
use base qw(Slim::Plugin::OPMLBased);

use POSIX          qw(SIGTERM);
use File::Spec     ();
use File::Spec::Functions qw(catdir catfile);
use Scalar::Util   qw(blessed);
use URI::Escape    qw(uri_unescape uri_escape_utf8);

use JSON::XS       qw(decode_json);
use Slim::Utils::Log;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);
use Slim::Player::ProtocolHandlers;
use Slim::Web::Graphics;
use Slim::Web::ImageProxy;

use Plugins::YouTubeMusic::API;
use Plugins::YouTubeMusic::PlaylistProtocolHandler;
use Plugins::YouTubeMusic::ProtocolHandler;

my $prefs = preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.youtubemusic',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_YOUTUBEMUSIC',
});

my $PROXY_PID;

sub initPlugin {
    my $class = shift;

    $prefs->init({
        proxy_port             => 9876,
        my_playlists           => [],
        accounts               => {},
        activeAccount          => '',
        shareCookiesWithYtdlp  => 0,
        codec                  => 'auto',
        autoplay               => 1,
    });
    $class->_write_share_flag();

    $class->_start_proxy();

    Slim::Player::ProtocolHandlers->registerHandler(
        'ytm', 'Plugins::YouTubeMusic::ProtocolHandler'
    );
    # Query proxy for available audio codec (handles piCorePlayer where
    # ffmpeg lacks libmp3lame and must fall back to aac)
    Slim::Utils::Timers::setTimer(
        undef, Time::HiRes::time() + 5,
        sub { Plugins::YouTubeMusic::ProtocolHandler::_init_audio_format() }
    );
    Slim::Player::ProtocolHandlers->registerHandler(
        'ytmplaylist', 'Plugins::YouTubeMusic::PlaylistProtocolHandler'
    );
    Slim::Web::ImageProxy->registerHandler(
        match => qr{(?:googleusercontent|ggpht|ytimg)\.com},
        func  => \&_artwork_url,
    );
    require Slim::Menu::TrackInfo;
    Slim::Menu::TrackInfo->registerInfoProvider(youtubemusicTrackInfo => (
        after => 'top',
        func  => \&trackInfoMenu,
    ));
    # Handle real YouTube Music URLs pasted directly into LMS



    $class->SUPER::initPlugin(
        feed   => \&_top_level,
        tag    => 'youtubemusic',
        menu   => 'radios',
        is_app => 1,
        weight => 10,
    );

    if (main::WEBUI) {
        require Plugins::YouTubeMusic::Settings;
        Plugins::YouTubeMusic::Settings->new($class);
        require Plugins::YouTubeMusic::Settings::Player;
        Plugins::YouTubeMusic::Settings::Player->new();
    }

    $log->info("YouTube Music plugin initialised");
}

sub shutdownPlugin {
    my $class = shift;
    Slim::Control::Request::unsubscribe(\&_on_playlist_stop);
    Slim::Control::Request::unsubscribe(\&_on_newsong);
    if ($PROXY_PID) {
        $log->info("Stopping YouTube Music proxy (PID $PROXY_PID)");
        if ($^O eq 'MSWin32') {
            # On Windows, use taskkill to terminate the process tree
            system("taskkill /F /T /PID $PROXY_PID >nul 2>&1");
        } else {
            eval { kill SIGTERM, $PROXY_PID };
            waitpid($PROXY_PID, 0);
        }
        $PROXY_PID = undef;
    }
}

sub getDisplayName { 'PLUGIN_YOUTUBEMUSIC' }
sub playerMenu     { undef }

sub accountsDir {
    my $dir = catdir(Slim::Utils::Prefs::dir(), 'plugin', 'youtubemusic');
    mkdir $dir unless -d $dir;
    return $dir;
}

sub accountIndex {
    my $path = catfile(__PACKAGE__->accountsDir(), 'index.json');
    return {} unless -f $path;
    open my $fh, '<:utf8', $path or return {};
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { decode_json($raw || '') };
    return ref $data eq 'HASH' ? $data : {};
}

sub accountPhoto {
    my ($class, $id) = @_;
    return '' unless $id;
    my $meta = $class->accountIndex()->{$id} || {};
    return $meta->{photo} || '';
}

sub _artwork_url {
    my ($url, $spec) = @_;
    $url = uri_unescape($url || '');
    my ($width, $height) = Slim::Web::Graphics->parseSpec($spec || '');
    $width = 0 if !$width || $width eq 'X';
    $height = 0 if !$height || $height eq 'X';
    my $px = $width > $height ? $width : $height;
    $px ||= 640;
    $px = 1280 if $px > 1280;

    if ($url =~ m{i\.ytimg\.com/.*/([A-Za-z0-9_-]{6,})/}) {
        my $id = $1;
        my $name = Slim::Web::ImageProxy->getRightSize("${px}x${px}", {
            120  => 'default',
            320  => 'mqdefault',
            480  => 'hqdefault',
            640  => 'sddefault',
            1280 => 'sddefault',
        }) || 'sddefault';
        return "https://i.ytimg.com/vi/$id/$name.jpg";
    }

    if ($url =~ /=w\d+-h\d+/) {
        $url =~ s/=w\d+-h\d+/=w${px}-h${px}/;
    } elsif ($url =~ /=s\d+/) {
        $url =~ s/=s\d+/=s${px}/;
    } else {
        $url =~ s/(\?.*)?$/=w${px}-h${px}-l90$1/;
    }
    return $url;
}

sub _write_share_flag {
    my $class = shift;
    my $path = File::Spec->catfile($class->accountsDir(), 'share_cookies');
    if (open my $fh, '>', $path) {
        print {$fh} ($prefs->get('shareCookiesWithYtdlp') ? '1' : '0');
        close $fh;
    }
}

sub _start_proxy {
    my $class  = shift;
    my $port   = $prefs->get('proxy_port') || 9876;
    my $script = File::Spec->catfile($class->_pluginDataFor('basedir'), 'ytmproxy.py');

    unless (-f $script) {
        $log->error("Proxy script not found at $script");
        return;
    }

    my $python_override = $prefs->get('path_python') || '';
    my $python = ($python_override && -f $python_override) ? $python_override : _find_python();
    if ($python_override && !-f $python_override) {
        $log->warn("Python override path not found: $python_override, falling back to auto-detect");
    }
    unless ($python) {
        $log->error("python3 not found in PATH");
        return;
    }

    $log->info("Starting YouTube Music proxy: $python $script --port $port");

    my $is_windows = $^O eq 'MSWin32';
    if ($is_windows) {
        # fork() is emulated on Windows via threads which conflicts with LMS
        # Use system(1,...) instead which spawns a true background process
        my $codec = $prefs->get('codec') || 'auto';
        my @win_args;
        push @win_args, '--ytdlp',    $prefs->get('path_ytdlp')  if $prefs->get('path_ytdlp');
        push @win_args, '--ffmpeg',   $prefs->get('path_ffmpeg') if $prefs->get('path_ffmpeg');
        push @win_args, '--node',     $prefs->get('path_node')   if $prefs->get('path_node');
        push @win_args, '--log-file',        $prefs->get('log_path')         if $prefs->get('log_path');
        push @win_args, '--no-node-worker'                                          if $prefs->get('disable_node_worker');
        push @win_args, '--accounts-dir', $class->accountsDir();
        my $pid = system(1, $python, $script, '--port', $port, '--log-level', 'WARNING', '--codec', $codec, @win_args);
        if (!$pid) {
            $log->error("system(1,...) failed: $!");
            return;
        }
        $PROXY_PID = $pid;
        $log->info("Proxy started (PID $pid) via system(1,...) on Windows");
    } else {
        my $pid = fork();
        if (!defined $pid) {
            $log->error("fork() failed: $!");
            return;
        }
        if ($pid == 0) {
            my $codec = $prefs->get('codec') || 'auto';
            my @extra_args;
            push @extra_args, '--ytdlp',    $prefs->get('path_ytdlp')  if $prefs->get('path_ytdlp');
            push @extra_args, '--ffmpeg',   $prefs->get('path_ffmpeg') if $prefs->get('path_ffmpeg');
            push @extra_args, '--node',     $prefs->get('path_node')   if $prefs->get('path_node');
            push @extra_args, '--log-file',        $prefs->get('log_path')         if $prefs->get('log_path');
            push @extra_args, '--no-node-worker'                                          if $prefs->get('disable_node_worker');
            push @extra_args, '--accounts-dir', $class->accountsDir();
            exec($python, $script, '--port', $port, '--log-level', 'WARNING', '--codec', $codec, @extra_args) or do {
                $log->error("exec failed: $!");
                exit 1;
            };
        }
        $PROXY_PID = $pid;
        $log->info("Proxy started (PID $pid)");
    }
}

sub _find_python {
    # On Windows use "where", on Unix use "which"
    my $is_windows = $^O eq 'MSWin32';
    my $finder = $is_windows ? 'where' : 'which';
    # Check python3 first (Unix), then python, then py (Windows launcher)
    my @candidates = $is_windows ? qw(python3 python py) : qw(python3 python);
    # On macOS, also check versioned binaries and common install paths
    # to avoid picking up Xcode's old Python 3.9 stub
    unless ($is_windows) {
        unshift @candidates, qw(python3.13 python3.12 python3.11 python3.10);
        push @candidates, '/usr/local/bin/python3', '/opt/homebrew/bin/python3',
                          '/usr/local/opt/python3/bin/python3';
    }
    my $best_path = '';
    my $best_ver  = 0;
    for my $py (@candidates) {
        my $null = $is_windows ? '2>nul' : '2>/dev/null';
        my $path = `$finder $py $null 2>/dev/null || echo $py`; chomp $path;
        # For absolute paths, skip the finder call
        if ($py =~ m{^/}) {
            $path = $py;
        }
        next unless defined $path && $path ne '';
        # "where" may return multiple lines — skip WindowsApps stub
        if ($is_windows) {
            my @paths = split /\n/, $path;
            my ($real) = grep { !/WindowsApps/i } @paths;
            $path = $real || $paths[0] || '';
        }
        $path =~ s/\r//g;  # strip carriage returns on any platform
        next unless $path && -e $path;
        $path =~ s/^"(.*)"$/$1/;  # strip surrounding quotes if any
        # Check version — require 3.10+ for yt-dlp-ejs compatibility
        my $ver_str = `"$path" -c "import sys; print(sys.version_info.major * 100 + sys.version_info.minor)" 2>/dev/null`;
        chomp $ver_str;
        my $ver = int($ver_str || 0);
        if ($ver >= 310 && $ver > $best_ver) {
            $best_ver  = $ver;
            $best_path = $path;
        } elsif ($ver > 0 && $best_ver == 0) {
            # Accept any Python if nothing 3.10+ found yet
            $best_path = $path;
        }
    }
    return $best_path if $best_path;
    # Last resort on Windows: check registry and common install paths
    if ($is_windows) {
        # Try registry first (works for all accounts including SYSTEM)
        eval {
            require Win32::TieRegistry;
            Win32::TieRegistry->import(Delimiter => "/");
            for my $ver (qw(3.13 3.12 3.11 3.10 3.9 3.8)) {
                my $key = "HKEY_LOCAL_MACHINE/SOFTWARE/Python/PythonCore/$ver/InstallPath//";
                my $p = $Win32::TieRegistry::Registry->{$key};
                if ($p) {
                    $p =~ s/\\$//;
                    $p .= "\\python.exe";
                    return $p if -e $p;
                }
            }
        };
        # Also scan all drives and all users
        for my $drive ('C', 'D', 'E', 'F') {
            # System-wide install
            for my $ver (qw(313 312 311 310 39 38)) {
                my $p = "$drive:\\Program Files\\Python$ver\\python.exe";
                return $p if -e $p;
                $p = "$drive:\\Program Files (x86)\\Python$ver\\python.exe";
                return $p if -e $p;
            }
            # Per-user installs - scan all user profiles
            for my $users_dir ("$drive:\\Users") {
                next unless -d $users_dir;
                opendir(my $dh, $users_dir) or next;
                my @users = grep { !/^\./ } readdir($dh);
                closedir($dh);
                for my $user (@users) {
                    for my $ver (qw(313 312 311 310 39 38)) {
                        my $p = "$users_dir\\$user\\AppData\\Local\\Programs\\Python\\Python$ver\\python.exe";
                        return $p if -e $p;
                    }
                }
            }
        }
    }
    return undef;
}

sub _register_proxy_handlers {
    for my $ep (qw(ytdlp_status ffmpeg_status codec ping)) {
        my $endpoint = $ep;
        Slim::Web::Pages->addRawFunction(
            "plugins/YouTubeMusic/proxy/$endpoint",
            sub {
                my ($httpClient, $response) = @_;
                my $port = $prefs->get('proxy_port') || 9876;
                Slim::Networking::SimpleAsyncHTTP->new(
                    sub {
                        my $http = shift;
                        $response->code(200);
                        $response->header('Content-Type', 'application/json');
                        $response->header('Access-Control-Allow-Origin', '*');
                        $response->content($http->content);
                        $httpClient->send_response($response);
                        Slim::Web::HTTP::closeHTTPSocket($httpClient);
                    },
                    sub {
                        $response->code(500);
                        $response->content('{"error":"proxy failed"}');
                        $httpClient->send_response($response);
                        Slim::Web::HTTP::closeHTTPSocket($httpClient);
                    },
                    { timeout => 35 }
                )->get("http://127.0.0.1:$port/$endpoint");
            }
        );
    }
}

sub postinitPlugin {
    my $class = shift;
    # Register youtube:// scheme only if nothing else has claimed it yet.
    # This runs after all plugins have initialised, so we can safely check
    # whether philippe44's LMS-YouTube (or another plugin) is already
    # handling it. If it is, we leave it alone; if not, we take it over
    # so existing Favorites and integrations keep working.
    if (!Slim::Player::ProtocolHandlers->handlerForURL('youtube://x')) {
        $log->info("Registering youtube:// compatibility shim");
        Slim::Player::ProtocolHandlers->registerHandler(
            'youtube', 'Plugins::YouTubeMusic::ProtocolHandler'
        );
        # Also register URL handler for real YouTube Music URLs
        if (Slim::Player::ProtocolHandlers->can('registerURLHandler')) {
            Slim::Player::ProtocolHandlers->registerURLHandler(
                qr{^https?://(?:(?:www|m|music)\.youtube\.com/(?:watch\?|playlist\?|channel/)|youtu\.be/)}i,
                'Plugins::YouTubeMusic::ProtocolHandler'
            );
            $log->info("Registered YouTube Music URL handler for music.youtube.com URLs");
        } else {
            $log->warn("registerURLHandler not available in this LMS version");
        }
    } else {
        $log->info("youtube:// already handled by another plugin, skipping URL handler registration");
    }

    # Register global search provider (closures capture query+type)
    Slim::Menu::GlobalSearch->registerInfoProvider( 'YouTube' => (
            after         => 'top',
            remote_search => 1,
            func          => sub {
                    my ( $client, $tags ) = @_;
                    my $q = $tags->{search} || '';
                    my $make = sub {
                            my ($type, $stringid) = @_;
                            return {
                                    name => cstring($client, $stringid),
                                    url  => sub {
                                            my ($client, $callback, $params) = @_;
                                            _globalSearch($client, $callback, { search => $q, type => $type });
                                    },
                            };
                    };
                    return {
                            name  => 'YouTube',
                            items => [
                                    $make->('songs',     'PLUGIN_YOUTUBEMUSIC_SONGS'),
                                    $make->('albums',    'PLUGIN_YOUTUBEMUSIC_ALBUMS'),
                                    $make->('artists',   'PLUGIN_YOUTUBEMUSIC_ARTISTS'),
                                    $make->('playlists', 'PLUGIN_YOUTUBEMUSIC_PLAYLISTS'),
                            ],
                    };
            },
    ) );
    $log->info("Registered YouTube Music global search provider");
    _register_proxy_handlers();

    # Subscribe to player stop events so we can trigger radio
    # when the queue empties and the player stops naturally
    Slim::Control::Request::subscribe(
        \&_on_playlist_stop,
        [['playlist'], ['stop']]
    );
    Slim::Control::Request::subscribe(
        \&_on_newsong,
        [['playlist'], ['newsong']]
    );
}


sub _ytm_icon {
    return __PACKAGE__->_pluginDataFor('icon')
        || 'plugins/YouTubeMusic/html/images/YouTubeMusic_svg.png';
}

sub _globalSearch {
    my ( $client, $callback, $params ) = @_;
    $params = {} unless ref($params) eq 'HASH';

    my $query = $params->{search} || $params->{searchTerm} || $params->{q} || $params->{query} || '';
    my $type  = $params->{type} || 'all';

    if (!$query) {
        $callback->({ items => [] });
        return;
    }

    Plugins::YouTubeMusic::API->search($query, $type, sub {
        my $results = shift || [];
        my $items = eval { _items_to_menu($client, $results) } || [];
        $callback->({ items => $items });
    }, $client);
}
sub _on_playlist_stop {
    my $request = shift;
    my $client  = $request->client() or return;

    # Only act on ytm:// tracks
    my $current = eval { Slim::Player::Playlist::track($client,
        Slim::Player::Source::playingSongIndex($client)) };
    return unless $current;
    my $url = eval { $current->url } // '';
    return unless $url =~ m{^ytm://};

    # Only trigger if queue is empty or nearly empty
    my $count = eval { Slim::Player::Playlist::count($client) } || 0;
    my $index = eval { Slim::Player::Source::playingSongIndex($client) } // 0;
    return unless ($count - $index) <= 1;

    my ($vid) = $url =~ m{^ytm://([A-Za-z0-9_\-]+)};
    return unless $vid;

    Plugins::YouTubeMusic::ProtocolHandler::arm_radio_after_stop($client, $vid);
}


sub _menu_row {
    my ($client, $name, $url, $icon, %extra) = @_;
    return {
        name => $name,
        url  => $url,
        icon => $icon,
        %extra,
    };
}

sub _auth_notice {
    my ($client, $data) = @_;
    return '' unless ref $data eq 'HASH' && $data->{authExpired};
    return cstring($client, 'PLUGIN_YOUTUBEMUSIC_AUTH_EXPIRED');
}

sub _feed_error {
    my ($client, $data, $fallback) = @_;
    my $expired = _auth_notice($client, $data);
    return $expired if $expired;
    return $data->{error} if ref $data eq 'HASH' && $data->{error};
    return $fallback;
}

sub _top_level {
    my ($client, $callback, $args) = @_;
    my $activeId = Plugins::YouTubeMusic::API->accountId($client);
    my $render = sub {
        my $status = shift;
        my @items;
        my $accounts = $prefs->get('accounts') || {};
        my $activeName = ($activeId && $accounts->{$activeId}) ? ($accounts->{$activeId}{displayName} || $activeId) : '';
        my $icon = _ytm_icon();
        my $has_accounts = scalar keys %{$accounts};
        my $expired = _auth_notice($client, $status);
        if ($expired) {
            push @items, { name => $expired, type => 'text' };
        }
        if ($has_accounts) {
            push @items, _menu_row(
                $client,
                $activeName || cstring($client, 'PLUGIN_YOUTUBEMUSIC_ACCOUNT_ANON'),
                \&_account_switcher,
                $icon,
                type => 'link',
            );
        }

        push @items, (
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_SEARCH'), \&_search_dispatch, '/html/images/search.png', type => 'search'),
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_HOME'), \&_home_menu, 'plugins/YouTubeMusic/html/images/featured_MTL_icon_home.png'),
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_CHARTS'), \&_charts_menu, 'plugins/YouTubeMusic/html/images/charts_MTL_icon_leaderboard.png'),
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_NEW_RELEASES'), \&_new_releases_menu, '/html/images/newmusic.png'),
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_MOODS'), \&_moods_menu, '/html/images/genres.png'),
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_MY_PLAYLISTS'), \&_my_playlists_menu, '/html/images/playlists.png'),
            _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_PODCASTS'), \&_podcasts_menu, '/html/images/radio.png'),
        );

        if ($activeId) {
            my $insert_at = ($expired ? 1 : 0) + ($has_accounts ? 1 : 0) + 1;
            splice @items, $insert_at, 0, (
                _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_LIBRARY'), \&_library_menu, '/html/images/musicfolder.png'),
                _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_HISTORY'), \&_history_menu, '/html/images/years.png'),
                _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_RECENT_SEARCHES'), \&_search_history, '/html/images/search.png'),
            );
        }

        $callback->({ items => \@items });
    };
    if ($activeId) {
        Plugins::YouTubeMusic::API->accountStatus($activeId, $render);
    } else {
        $render->(undef);
    }
}

sub _player_account_raw {
    my ($client) = @_;
    return '' unless $client;
    my $raw = $prefs->client($client)->get('activeAccount');
    return defined $raw ? $raw : '';
}

sub _account_switcher {
    my ($client, $callback) = @_;
    my $accounts = $prefs->get('accounts') || {};
    my $raw = _player_account_raw($client);
    my $icon = _ytm_icon();
    my $server_id = $prefs->get('activeAccount') || '';
    my $server_name = ($server_id && $accounts->{$server_id})
        ? ($accounts->{$server_id}{displayName} || $server_id)
        : '';
    my $default_label = cstring($client, 'PLUGIN_YOUTUBEMUSIC_PLAYER_ACCOUNT_DEFAULT');
    $default_label .= " ($server_name)" if $server_name;

    my @items = ({
        name        => $default_label . ($raw eq '' ? ' *' : ''),
        url         => \&_switch_account,
        passthrough => [{ accountId => '', useDefault => 1 }],
        icon        => $icon,
        type        => 'link',
    }, {
        name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_ACCOUNT_ANON') . ($raw eq '-' ? ' *' : ''),
        url         => \&_switch_account,
        passthrough => [{ accountId => '' }],
        icon        => $icon,
        type        => 'link',
    });
    for my $id (sort keys %{$accounts}) {
        my $name = $accounts->{$id}{displayName} || $id;
        my $photo = __PACKAGE__->accountPhoto($id);
        push @items, {
            name        => $name . ($raw eq $id ? ' *' : ''),
            url         => \&_switch_account,
            passthrough => [{ accountId => $id }],
            $photo ? (image => $photo) : (icon => $icon),
            type        => 'link',
        };
    }
    $callback->({ items => \@items });
}

sub _switch_account {
    my ($client, $callback, $args, $passthrough) = @_;
    my $accountId = $passthrough ? ($passthrough->{accountId} // '') : '';
    my $useDefault = $passthrough && $passthrough->{useDefault};
    if ($client) {
        if ($useDefault) {
            $prefs->client($client)->set('activeAccount', '');
        } elsif ($accountId && ($prefs->get('accounts') || {})->{$accountId}) {
            $prefs->client($client)->set('activeAccount', $accountId);
        } else {
            $prefs->client($client)->set('activeAccount', '-');
        }
    }
    _top_level($client, sub {
        my $feed = shift || {};
        $feed->{title} = cstring($client, 'PLUGIN_YOUTUBEMUSIC');
        $callback->($feed);
    });
}

sub _library_menu {
    my ($client, $callback) = @_;
    unless (Plugins::YouTubeMusic::API->accountId($client)) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_YOUTUBEMUSIC_ACCOUNT_REQUIRED'), type => 'text' }] });
        return;
    }
    $callback->({ items => [
        _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_LIKED'), \&_liked_menu, '/html/images/playlists.png'),
        _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_PLAYLISTS'), sub { _library_list('playlists', @_) }, '/html/images/playlists.png'),
        _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_ALBUMS'), sub { _library_list('albums', @_) }, '/html/images/albums.png'),
        _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_ARTISTS'), sub { _library_list('artists', @_) }, '/html/images/artists.png'),
        _menu_row($client, cstring($client, 'PLUGIN_YOUTUBEMUSIC_SUBSCRIPTIONS'), sub { _library_list('subscriptions', @_) }, '/html/images/artists.png'),
        {
            name => cstring($client, 'PLUGIN_YOUTUBEMUSIC_SAVE_QUEUE'),
            icon => '/html/images/playlists.png',
            url  => \&_save_queue,
            type => 'search',
        },
    ] });
}

sub _library_list {
    my ($kind, $client, $callback) = @_;
    Plugins::YouTubeMusic::API->library($kind, sub {
        my $data = shift;
        if (!$data || ref $data ne 'ARRAY') {
            my $err = _feed_error($client, $data, cstring($client, 'PLUGIN_YOUTUBEMUSIC_ERROR_PROXY_FAILED'));
            return $callback->({ items => [{ name => $err, type => 'text' }] });
        }
        $callback->({ items => _items_to_menu($client, $data), playall => 1 });
    }, $client);
}

sub _liked_menu {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->liked(sub {
        my $data = shift;
        unless ($data && ref $data eq 'HASH') {
            return $callback->({ items => [{ name => cstring($client, 'PLUGIN_YOUTUBEMUSIC_ERROR_PROXY_FAILED'), type => 'text' }] });
        }
        if ($data->{error}) {
            return $callback->({ items => [{ name => _feed_error($client, $data, $data->{error}), type => 'text' }] });
        }
        $callback->({ items => _items_to_menu($client, $data->{items} || [], { playall => 1 }), playall => 1 });
    }, $client);
}

sub _history_menu {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->history(sub {
        my $data = shift;
        if (!$data || ref $data ne 'ARRAY') {
            my $err = _feed_error($client, $data, cstring($client, 'PLUGIN_YOUTUBEMUSIC_ACCOUNT_REQUIRED'));
            return $callback->({ items => [{ name => $err, type => 'text' }] });
        }
        if (!@$data) {
            return $callback->({ items => [{ name => cstring($client, 'PLUGIN_YOUTUBEMUSIC_HISTORY_EMPTY'), type => 'text' }] });
        }
        my %groups;
        my @order;
        for my $item (@$data) {
            my $label = $item->{played} || cstring($client, 'PLUGIN_YOUTUBEMUSIC_HISTORY');
            if (!$groups{$label}) {
                $groups{$label} = [];
                push @order, $label;
            }
            push @{$groups{$label}}, $item;
        }
        my @items = map {
            my $label = $_;
            my $tracks = $groups{$label};
            {
                name => $label,
                icon => '/html/images/years.png',
                url  => sub {
                    my ($c, $cb) = @_;
                    $cb->({ items => _items_to_menu($c, $tracks, { playall => 1 }), playall => 1 });
                },
            }
        } @order;
        $callback->({ items => \@items });
    }, $client);
}

sub _search_dispatch {
    my ($client, $callback, $args, $pt) = @_;

    my $query = ($pt && $pt->{query}) || ($args->{search} // '');

    unless ($query) {
        return _search_history($client, $callback);
    }

    my @type_menus = map {
        my ($key, $label, $icon) = @$_;
        {
            name        => cstring($client, $label),
            icon        => $icon,
            url         => \&_search_results,
            passthrough => [{ query => $query, type => $key }],
        }
    } (
        [ songs     => 'PLUGIN_YOUTUBEMUSIC_SONGS',     '/html/images/playall.png' ],
        [ albums    => 'PLUGIN_YOUTUBEMUSIC_ALBUMS',    '/html/images/albums.png' ],
        [ artists   => 'PLUGIN_YOUTUBEMUSIC_ARTISTS',   '/html/images/artists.png' ],
        [ playlists => 'PLUGIN_YOUTUBEMUSIC_PLAYLISTS', '/html/images/playlists.png' ],
    );

    $callback->({ items => \@type_menus });
}

sub _search_results {
    my ($client, $callback, $args, $params) = @_;

    Plugins::YouTubeMusic::API->search(
        $params->{query},
        $params->{type},
        sub {
            my $results = shift;
            unless ($results && ref $results eq 'ARRAY') {
                return $callback->({ items => [], error => 'Search failed' });
            }
            $callback->({ items => _items_to_menu($client, $results) });
        },
        $client
    );
}

sub _section_cover {
    my ($section) = @_;
    for my $item (@{ $section->{items} // [] }) {
        return $item->{thumbnail} if $item->{thumbnail};
    }
    return '';
}

sub _section_link {
    my ($client, $section, $fallback) = @_;
    my $cover = _section_cover($section);
    return {
        name => $section->{title} || '',
        $cover ? (image => $cover) : (icon => $fallback),
        url  => sub {
            my ($c, $cb) = @_;
            $cb->({ items => _items_to_menu($c, $section->{items} // [], { playall => 1 }), playall => 1 });
        },
    };
}

sub _home_menu {
    my ($client, $callback, $args, $pt) = @_;
    my $refresh = (ref $pt eq 'HASH' && $pt->{refresh}) ? 1 : 0;

    Plugins::YouTubeMusic::API->browseHome(sub {
        my $sections = shift;
        unless ($sections && ref $sections eq 'ARRAY') {
            my $err = _feed_error($client, $sections, cstring($client, 'PLUGIN_YOUTUBEMUSIC_ERROR_PROXY_FAILED'));
            return $callback->({ items => [{ name => $err, type => 'text' }] });
        }

        my @items = (
            {
                name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_REFRESH'),
                icon        => 'plugins/YouTubeMusic/html/images/refresh_MTL_icon_refresh.png',
                url         => \&_home_menu,
                passthrough => [{ refresh => 1 }],
            },
        );
        push @items, map {
            _section_link($client, $_, '/html/images/albums.png')
        } @$sections;

        $callback->({ items => \@items });
    }, $client, $refresh);
}

sub _charts_menu {
    my ($client, $callback) = @_;

    Plugins::YouTubeMusic::API->browseCharts(sub {
        my $sections = shift;
        unless ($sections && ref $sections eq 'ARRAY') {
            return $callback->({ items => [] });
        }

        my @items = map {
            my $section = $_;
            my $row = _section_link($client, $section, '/html/images/playlists.png');
            $row->{name} ||= cstring($client, 'PLUGIN_YOUTUBEMUSIC_CHARTS');
            $row;
        } @$sections;

        $callback->({ items => \@items });
    }, $client);
}

sub _my_playlists_menu {
    my ($client, $callback) = @_;

    my $saved = $prefs->get('my_playlists') || [];
    $saved = [$saved] unless ref $saved eq 'ARRAY';

    my @items;

    # Saved playlist entries
    for my $entry (@$saved) {
        my ($name, $browse_id) = split /\|/, $entry, 2;
        next unless $name && $browse_id;
        push @items, {
            name        => $name,
            url         => \&_playlist_menu,
            play        => "ytmplaylist://$browse_id",
            icon        => '/html/images/playlists.png',
            type        => 'playlist',
            passthrough => [{ browseId => $browse_id, browse_type => 'playlist' }],
        };
    }

    # Always show an "Add Current Playlist" hint and management options
    push @items, {
        name => '+ Save a playlist (see Settings)',
        type => 'text',
    };

    $callback->({ items => \@items });
}

sub _new_releases_menu {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->browseNewReleases(sub {
        my $sections = shift;
        unless ($sections && ref $sections eq 'ARRAY') {
            return $callback->({ items => [] });
        }
        my @items = map {
            my $section = $_;
            my $row = _section_link($client, $section, '/html/images/newmusic.png');
            $row->{name} ||= cstring($client, 'PLUGIN_YOUTUBEMUSIC_NEW_RELEASES');
            $row;
        } @$sections;
        $callback->({ items => \@items });
    }, $client);
}

sub _moods_menu {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->browseMoods(sub {
        my $sections = shift;
        unless ($sections && ref $sections eq 'ARRAY') {
            return $callback->({ items => [] });
        }
        my @items;
        for my $section (@$sections) {
            my $title = $section->{title} || cstring($client, 'PLUGIN_YOUTUBEMUSIC_MOODS');
            my @cats;
            for my $item (@{ $section->{items} // [] }) {
                next unless $item->{browseId} || $item->{params};
                my $bid    = $item->{browseId} || 'FEmusic_moods_and_genres_category';
                my $params = $item->{params} // '';
                my $name   = $item->{title} || 'Unknown';
                push @cats, {
                    name => $name,
                    url  => sub {
                        my ($c, $cb) = @_;
                        Plugins::YouTubeMusic::API->browseMoodCategory($bid, $params, sub {
                            my $cat_sections = shift;
                            my @cat_items;
                            for my $cat_section (@{ $cat_sections // [] }) {
                                push @cat_items, @{ _items_to_menu($c, $cat_section->{items} // []) };
                            }
                            $cb->({ items => \@cat_items });
                        }, $c);
                    },
                };
            }
            next unless @cats;
            push @items, {
                name => $title,
                icon => '/html/images/genres.png',
                url  => sub {
                    my ($c, $cb) = @_;
                    $cb->({ items => \@cats });
                },
            };
        }
        $callback->({ items => \@items });
    }, $client);
}

sub _podcasts_menu {
    my ($client, $callback) = @_;
    Plugins::YouTubeMusic::API->browsePodcasts(sub {
        my $sections = shift;
        unless ($sections && ref $sections eq 'ARRAY') {
            return $callback->({ items => [] });
        }
        my @items = map {
            my $section = $_;
            {
                name => $section->{title} || cstring($client, 'PLUGIN_YOUTUBEMUSIC_PODCASTS'),
                icon => '/html/images/radio.png',
                url  => sub {
                    my ($c, $cb) = @_;
                    $cb->({ items => _items_to_menu($c, $section->{items} // [], { playall => 1 }), playall => 1 });
                },
            }
        } @$sections;
        $callback->({ items => \@items });
    }, $client);
}

sub _artist_menu {
    my ($client, $callback, $args, $params) = @_;

    Plugins::YouTubeMusic::API->browseArtist($params->{browseId}, sub {
        my $data = shift;
        unless ($data && ref $data eq 'HASH') {
            return $callback->({ items => [] });
        }

        my @items = map {
            my $section = $_;
            {
                name => $section->{title} || 'Tracks',
                icon => '/html/images/albums.png',
                url  => sub {
                    my ($c, $cb) = @_;
                    $cb->({ items => _items_to_menu($c, $section->{items} // [], { playall => 1 }), playall => 1 });
                },
            }
        } @{ $data->{sections} // [] };

        if (Plugins::YouTubeMusic::API->accountId($client) && $params->{browseId}) {
            unshift @items, {
                name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_SUBSCRIBE'),
                url         => \&_subscribe_menu,
                passthrough => [{ channelId => $params->{browseId} }],
                type        => 'link',
            };
        }

        $callback->({ items => \@items });
    }, $client);
}

sub _playlist_menu {
    my ($client, $callback, $args, $params) = @_;
my $type = $params->{browse_type} // 'playlist';

    my $api_method = ($type eq 'album') ? 'browseAlbum' : 'browsePlaylist';

    Plugins::YouTubeMusic::API->$api_method($params->{browseId}, sub {
        my $data = shift;
        unless ($data && ref $data eq 'HASH') {
            return $callback->({ items => [] });
        }
        # playall => 1 tells LMS to queue all tracks from the selected position
        # forward when tapped — prevents radio triggering on single track selection.
        my $album_title = $params->{album_title} // '';
        my $items = $data->{items} // [];
        if ($album_title) {
            # Inject album title into each track so it shows correctly in queue
            for my $item (@$items) {
                $item->{album} = $album_title if $item->{type} && $item->{type} eq 'song';
            }
        }
        my $prefetched = 0;
        for my $track (@$items) {
            last if $prefetched >= 3;
            next unless $track->{videoId};
            Plugins::YouTubeMusic::API->prefetch($track->{videoId}, sub {}, $client);
            $prefetched++;
        }

        my @menu = @{ _items_to_menu($client, $items, {
            playall    => 1,
            playlistId => $params->{playlistId} || $params->{browseId} || '',
        }) };
        unshift @menu, _library_actions($client, $params);
        $callback->({ items => \@menu, playall => 1 });
    }, $client);
}

sub _items_to_menu {
    my ($client, $items, $opts) = @_;
    my $playall = ($opts && $opts->{playall}) ? 1 : 0;
    my $ytm_icon = _ytm_icon();
    my %fallback_icon = (
        song     => $ytm_icon,
        album    => $ytm_icon,
        artist   => $ytm_icon,
        playlist => $ytm_icon,
    );
    my @menu;

    for my $item (@{ $items // [] }) {
        my $type = $item->{type} // '';

        if ($type eq 'song' && $item->{videoId}) {
            my $ytm_url = "ytm://$item->{videoId}";
            Plugins::YouTubeMusic::ProtocolHandler->primeMetadata($item->{videoId}, $item);
            my %song = (
                name      => $item->{title}  || 'Unknown',
                line2     => _song_line2($item),
                url       => $ytm_url,
                image     => $item->{thumbnail} || '',
                $item->{thumbnail} ? () : (icon => $fallback_icon{song}),
                play      => $ytm_url,
                type      => 'audio',
                on_select => 'play',
                $playall ? ( playall => 1 ) : (),
            );
            my @actions = _track_actions($client, $item->{videoId});
            if ($opts->{playlistId} && $item->{setVideoId}) {
                push @actions, {
                    name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_REMOVE_TRACK'),
                    url         => \&_remove_track,
                    passthrough => [{
                        playlistId => $opts->{playlistId},
                        videoId    => $item->{videoId},
                        setVideoId => $item->{setVideoId},
                    }],
                    type        => 'link',
                };
            }
            if ($item->{feedbackToken}) {
                push @actions, {
                    name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_REMOVE_HISTORY'),
                    url         => \&_remove_history,
                    passthrough => [{ feedbackToken => $item->{feedbackToken} }],
                    type        => 'link',
                };
            }
            $song{items} = \@actions if @actions;
            push @menu, \%song;
        }
        elsif ($type eq 'album' && $item->{browseId}) {
            push @menu, {
                name        => $item->{title}  || 'Unknown Album',
                line2       => join(' - ', grep { $_ } $item->{artist}, $item->{year}),
                image       => $item->{thumbnail} || '',
                $item->{thumbnail} ? () : (icon => $fallback_icon{album}),
                url         => \&_playlist_menu,
                play        => "ytmplaylist://$item->{browseId}",
                type        => 'playlist',
                passthrough => [{
                    browseId    => $item->{browseId},
                    playlistId  => $item->{playlistId} || '',
                    browse_type => 'album',
                    album_title => $item->{title},
                }],
            };
        }
        elsif ($type eq 'artist' && $item->{browseId}) {
            push @menu, {
                name        => $item->{name}   || 'Unknown Artist',
                image       => $item->{thumbnail} || '',
                $item->{thumbnail} ? () : (icon => $fallback_icon{artist}),
                url         => \&_artist_menu,
                passthrough => [{ browseId => $item->{browseId} }],
            };
        }
        elsif ($type eq 'playlist' && $item->{browseId}) {
            push @menu, {
                name        => $item->{title}  || 'Unknown Playlist',
                line2       => $item->{count}  || '',
                image       => $item->{thumbnail} || '',
                $item->{thumbnail} ? () : (icon => $fallback_icon{playlist}),
                url         => \&_playlist_menu,
                play        => "ytmplaylist://$item->{browseId}",
                type        => 'playlist',
                passthrough => [{
                    browseId    => $item->{browseId},
                    playlistId  => $item->{playlistId} || '',
                    browse_type => 'playlist',
                }],
            };
        }
        elsif ($item->{browseId}) {
            my $btype = $item->{type} // 'playlist';
            my %entry = (
                name        => $item->{title}    || $item->{name} || 'Unknown',
                line2       => $item->{subtitle} || '',
                image       => $item->{thumbnail} || '',
                url         => ($btype eq 'artist') ? \&_artist_menu : \&_playlist_menu,
                passthrough => [{
                    browseId    => $item->{browseId},
                    playlistId  => $item->{playlistId} || '',
                    browse_type => $btype,
                }],
            );
            unless ($btype eq 'artist') {
                $entry{play} = "ytmplaylist://$item->{browseId}";
                $entry{type} = 'playlist';
            }
            push @menu, \%entry;
        }
        elsif ($item->{videoId}) {
            my $ytm_url = "ytm://$item->{videoId}";
            Plugins::YouTubeMusic::ProtocolHandler->primeMetadata($item->{videoId}, $item);
            my %song = (
                name      => $item->{title}    || 'Unknown',
                line2     => $item->{subtitle} || '',
                url       => $ytm_url,
                image     => $item->{thumbnail} || '',
                play      => $ytm_url,
                type      => 'audio',
                on_select => 'play',
                $playall ? ( playall => 1 ) : (),
            );
            my @actions = _track_actions($client, $item->{videoId});
            $song{items} = \@actions if @actions;
            push @menu, \%song;
        }
    }

    return \@menu;
}

sub _song_line2 {
    my $item = shift;
    return join(' - ', grep { $_ }
        $item->{artist}   || '',
        $item->{album}    || '',
        $item->{duration} || '',
    );
}

sub _on_newsong {
    my $request = shift;
    my $client = $request->client() or return;
    return unless Plugins::YouTubeMusic::API->accountId($client);
    my $song = eval { Slim::Player::Playlist::song($client) };
    my $track = $song && eval { $song->currentTrack() };
    my $url = $track ? ($track->url || '') : '';
    my ($video_id) = $url =~ m{^ytm://([A-Za-z0-9_-]+)};
    return unless $video_id;
    Plugins::YouTubeMusic::API->addHistory($video_id, sub {}, $client);
}

sub trackInfoMenu {
    my ($client, $url) = @_;
    my ($video_id) = ($url || '') =~ m{^ytm://([A-Za-z0-9_-]+)};
    return unless $video_id;
    my @items = _track_actions($client, $video_id);
    return @items ? \@items : undef;
}

sub _track_actions {
    my ($client, $video_id) = @_;
    return () unless $video_id && Plugins::YouTubeMusic::API->accountId($client);
    return (
        {
            name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_LIKE'),
            url         => \&_like_menu,
            passthrough => [{ videoId => $video_id }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_ADD_TO_PLAYLIST'),
            url         => \&_playlist_picker,
            passthrough => [{ videoId => $video_id }],
            type        => 'link',
        },
    );
}

sub _library_actions {
    my ($client, $params) = @_;
    return () unless $params && Plugins::YouTubeMusic::API->accountId($client);
    my $browse = $params->{browseId} || '';
    my $pid = $params->{playlistId} || '';
    return () unless $browse || $pid;
    my $kind = $params->{browse_type} || 'playlist';
    my $pass = { browseId => $browse, playlistId => $pid, kind => $kind };
    my @items = (
        {
            name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_SAVE_LIBRARY'),
            url         => \&_save_library,
            passthrough => [{ %{$pass}, rating => 'LIKE' }],
            type        => 'link',
        },
        {
            name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_REMOVE_LIBRARY'),
            url         => \&_save_library,
            passthrough => [{ %{$pass}, rating => 'INDIFFERENT' }],
            type        => 'link',
        },
    );
    if ($kind eq 'playlist') {
        push @items, {
            name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_DELETE_PLAYLIST'),
            url         => \&_delete_playlist,
            passthrough => [ $pass ],
            type        => 'link',
        };
    }
    return @items;
}

sub _action_done {
    my ($client, $cb, $data, $ok_key) = @_;
    my $failed = !$data || ref $data ne 'HASH' || !$data->{ok};
    if ($failed) {
        my $msg = (ref $data eq 'HASH' && $data->{error})
            ? $data->{error}
            : cstring($client, 'PLUGIN_YOUTUBEMUSIC_ACTION_FAILED');
        return $cb->({ items => [{ name => $msg, type => 'text' }] });
    }
    my $text = cstring($client, $ok_key);
    $client->showBriefly({
        jive => { type => 'popupplay', text => [ $text ] },
    }) if $client;
    $cb->({ items => [{ name => $text, nextWindow => 'grandparent' }] });
}

sub _like_menu {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $video_id = $pt->{videoId} || '';
    return unless $video_id;
    Plugins::YouTubeMusic::API->songRating($video_id, sub {
        my $data = shift || {};
        my $status = $data->{likeStatus} || 'INDIFFERENT';
        my $like = $status eq 'LIKE' ? 'INDIFFERENT' : 'LIKE';
        my $dislike = $status eq 'DISLIKE' ? 'INDIFFERENT' : 'DISLIKE';
        $cb->({ items => [
            {
                name        => cstring($client, $status eq 'LIKE' ? 'PLUGIN_YOUTUBEMUSIC_UNLIKE' : 'PLUGIN_YOUTUBEMUSIC_LIKE'),
                url         => \&_rate_song,
                passthrough => [{ videoId => $video_id, rating => $like }],
                type        => 'link',
            },
            {
                name        => cstring($client, $status eq 'DISLIKE' ? 'PLUGIN_YOUTUBEMUSIC_UNDISLIKE' : 'PLUGIN_YOUTUBEMUSIC_DISLIKE'),
                url         => \&_rate_song,
                passthrough => [{ videoId => $video_id, rating => $dislike }],
                type        => 'link',
            },
        ] });
    }, $client);
}

sub _rate_song {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $key = $pt->{rating} eq 'LIKE' ? 'PLUGIN_YOUTUBEMUSIC_LIKED'
            : $pt->{rating} eq 'DISLIKE' ? 'PLUGIN_YOUTUBEMUSIC_DISLIKED'
            : 'PLUGIN_YOUTUBEMUSIC_RATING_CLEARED';
    Plugins::YouTubeMusic::API->rateSong($pt->{videoId}, $pt->{rating}, sub {
        _action_done($client, $cb, shift, $key);
    }, $client);
}

sub _subscribe_menu {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $channel_id = $pt->{channelId} || '';
    return unless $channel_id;
    Plugins::YouTubeMusic::API->artistSubscribed($channel_id, sub {
        my $data = shift || {};
        my $on = $data->{subscribed} ? 1 : 0;
        $cb->({ items => [{
            name        => cstring($client, $on ? 'PLUGIN_YOUTUBEMUSIC_UNSUBSCRIBE' : 'PLUGIN_YOUTUBEMUSIC_SUBSCRIBE'),
            url         => \&_set_subscription,
            passthrough => [{ channelId => $channel_id, subscribed => $on ? 0 : 1 }],
            type        => 'link',
        }] });
    }, $client);
}

sub _set_subscription {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $on = $pt->{subscribed} ? 1 : 0;
    Plugins::YouTubeMusic::API->setSubscription($pt->{channelId}, $on, sub {
        _action_done($client, $cb, shift, $on ? 'PLUGIN_YOUTUBEMUSIC_SUBSCRIBED' : 'PLUGIN_YOUTUBEMUSIC_UNSUBSCRIBED');
    }, $client);
}

sub _save_library {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $key = ($pt->{rating} || '') eq 'LIKE'
        ? 'PLUGIN_YOUTUBEMUSIC_SAVED'
        : 'PLUGIN_YOUTUBEMUSIC_REMOVED';
    Plugins::YouTubeMusic::API->savePlaylist($pt->{playlistId}, $pt->{browseId}, $pt->{rating}, sub {
        _action_done($client, $cb, shift, $key);
    }, $client);
}

sub _delete_playlist {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    Plugins::YouTubeMusic::API->deletePlaylist($pt->{playlistId} || $pt->{browseId}, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_PLAYLIST_DELETED');
    }, $client);
}

sub _playlist_picker {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $video_id = $pt->{videoId} || '';
    Plugins::YouTubeMusic::API->library('playlists', sub {
        my $data = shift;
        my @items = ({
            name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_NEW_PLAYLIST'),
            type        => 'search',
            url         => \&_create_playlist,
            passthrough => [{ videoId => $video_id }],
        });
        if (ref $data eq 'ARRAY') {
            for my $pl (@{$data}) {
                my $pid = $pl->{playlistId} || $pl->{browseId} || next;
                push @items, {
                    name        => $pl->{title} || 'Playlist',
                    image       => $pl->{thumbnail} || '',
                    url         => \&_add_to_playlist,
                    passthrough => [{ playlistId => $pid, videoId => $video_id }],
                    type        => 'link',
                };
            }
        }
        $cb->({ items => \@items });
    }, $client);
}

sub _add_to_playlist {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    Plugins::YouTubeMusic::API->addToPlaylist($pt->{playlistId}, $pt->{videoId}, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_ADDED');
    }, $client);
}

sub _create_playlist {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    my $title = $args->{search} // '';
    my @ids = grep { $_ } ($pt->{videoId} || '');
    Plugins::YouTubeMusic::API->createPlaylist($title, \@ids, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_PLAYLIST_CREATED');
    }, $client);
}

sub _remove_track {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    Plugins::YouTubeMusic::API->removeFromPlaylist($pt->{playlistId}, $pt->{videoId}, $pt->{setVideoId}, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_REMOVED');
    }, $client);
}

sub _remove_history {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    Plugins::YouTubeMusic::API->removeHistory($pt->{feedbackToken}, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_REMOVED');
    }, $client);
}

sub _queue_ids {
    my ($client) = @_;
    return () unless $client;
    my @ids;
    my $count = eval { Slim::Player::Playlist::count($client) } || 0;
    for (my $i = 0; $i < $count; $i++) {
        my $track = eval { Slim::Player::Playlist::track($client, $i) };
        my $url = $track ? ($track->url || '') : '';
        push @ids, $1 if $url =~ m{^ytm://([A-Za-z0-9_-]+)};
    }
    return @ids;
}

sub _save_queue {
    my ($client, $cb, $args) = @_;
    my $title = $args->{search} // '';
    my @ids = _queue_ids($client);
    unless (@ids) {
        return $cb->({ items => [{ name => cstring($client, 'PLUGIN_YOUTUBEMUSIC_QUEUE_EMPTY'), type => 'text' }] });
    }
    Plugins::YouTubeMusic::API->createPlaylist($title, \@ids, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_PLAYLIST_CREATED');
    }, $client);
}

sub _search_history {
    my ($client, $cb) = @_;
    unless (Plugins::YouTubeMusic::API->accountId($client)) {
        return $cb->({ items => [] });
    }
    Plugins::YouTubeMusic::API->searchSuggestions('', sub {
        my $rows = shift;
        my @items;
        if (ref $rows eq 'ARRAY') {
            for my $row (@{$rows}) {
                next unless ref $row eq 'HASH' && $row->{text} && $row->{fromHistory};
                my %item = (
                    name        => $row->{text},
                    url         => \&_search_dispatch,
                    passthrough => [{ query => $row->{text} }],
                    type        => 'link',
                );
                if ($row->{feedbackToken}) {
                    $item{items} = [{
                        name        => cstring($client, 'PLUGIN_YOUTUBEMUSIC_REMOVE_SEARCH'),
                        url         => \&_forget_search,
                        passthrough => [{ feedbackToken => $row->{feedbackToken} }],
                        type        => 'link',
                    }];
                }
                push @items, \%item;
            }
        }
        $cb->({ items => \@items });
    }, $client);
}

sub _forget_search {
    my ($client, $cb, $args, $pt) = @_;
    $pt = {} unless ref $pt eq 'HASH';
    Plugins::YouTubeMusic::API->forgetSearch($pt->{feedbackToken}, sub {
        _action_done($client, $cb, shift, 'PLUGIN_YOUTUBEMUSIC_REMOVED');
    }, $client);
}

1;

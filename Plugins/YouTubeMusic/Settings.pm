package Plugins::YouTubeMusic::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use HTTP::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.youtubemusic',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_YOUTUBEMUSIC',
});

sub name { 'PLUGIN_YOUTUBEMUSIC' }

sub page { 'plugins/YouTubeMusic/settings/basic.html' }

sub prefs { return ($prefs, qw(proxy_port autoplay codec path_python path_ytdlp path_ffmpeg path_node log_path disable_node_worker)) }

sub _proxy_json {
    my ($method, $path, $payload) = @_;
    require LWP::UserAgent;
    require JSON::XS;
    my $port = $prefs->get('proxy_port') || 9876;
    my $ua = LWP::UserAgent->new(timeout => 40);
    my $res = $ua->request(HTTP::Request->new(
        $method,
        "http://127.0.0.1:$port$path",
        ['Content-Type' => 'application/json'],
        defined $payload ? JSON::XS::encode_json($payload) : undef,
    ));
    my $data = eval { JSON::XS::decode_json($res->decoded_content || '') };
    return ($res, $data);
}

sub handler {
    my ($class, $client, $params) = @_;

    if ($params->{saveSettings}) {
        # Save proxy port
        my $port = int($params->{proxy_port} || 9876);
        $port = 9876 unless $port >= 1024 && $port <= 65535;
        $prefs->set('proxy_port', $port);

        # Save autoplay setting
        $prefs->set('autoplay', ($params->{pref_autoplay} // $params->{autoplay}) ? 1 : 0);
        # Save codec setting
        my $codec = $params->{pref_codec} || $params->{codec} || 'auto';
        $codec = 'auto' unless grep { $_ eq $codec } qw(auto mp3 flac aac);
        $prefs->set('codec', $codec);
        # Save playlists — collect all name/browseId pairs
        my @playlists;
        my $names = $params->{playlist_name};
        my $ids   = $params->{playlist_id};
        $names = [$names] if $names && !ref $names;
        $ids   = [$ids]   if $ids   && !ref $ids;

        if ($names && $ids) {
            for my $i (0 .. $#$names) {
                my $name = $names->[$i] // '';
                my $id   = $ids->[$i]   // '';
                $name =~ s/^\s+|\s+$//g;
                $id   =~ s/^\s+|\s+$//g;
                next unless $name && $id;
                push @playlists, "$name|$id";
            }
        }
        $prefs->set('my_playlists', \@playlists);
        # Save path overrides
        $prefs->set('path_python', $params->{pref_path_python} // $params->{path_python} // '');
        $prefs->set('path_ytdlp',  $params->{pref_path_ytdlp}  // $params->{path_ytdlp}  // '');
        $prefs->set('path_ffmpeg', $params->{pref_path_ffmpeg} // $params->{path_ffmpeg} // '');
        $prefs->set('path_node',   $params->{pref_path_node}   // $params->{path_node}   // '');
        $prefs->set('log_path',    $params->{pref_log_path}    // $params->{log_path}    // '');
        $prefs->set('disable_node_worker', $params->{pref_disable_node_worker} ? 1 : 0);
        $prefs->set('shareCookiesWithYtdlp', $params->{pref_shareCookiesWithYtdlp} ? 1 : 0);
        my $active = $params->{pref_activeAccount} // '';
        my $accounts = $prefs->get('accounts') || {};
        $active = '' unless $active eq '' || $accounts->{$active};
        $prefs->set('activeAccount', $active);

        my $delete_id = $params->{pref_deleteAccount} // '';
        if ($delete_id && $accounts->{$delete_id}) {
            _proxy_json('POST', '/accounts/delete', { id => $delete_id });
            delete $accounts->{$delete_id};
            $prefs->set('activeAccount', '') if ($prefs->get('activeAccount') || '') eq $delete_id;
            $prefs->set('accounts', $accounts);
        }

        my $material = $params->{pref_accountMaterial} // '';
        $material =~ s/^\s+|\s+$//g;
        if ($material) {
            my ($res, $data) = _proxy_json('POST', '/accounts/import', {
                name     => $params->{pref_accountName} || 'YouTube Music',
                authUser => $params->{pref_accountAuthUser} || '0',
                material => $material,
            });
            if ($data && $data->{ok} && $data->{id}) {
                $accounts->{$data->{id}} = {
                    displayName => $data->{name} || $data->{accountName} || 'YouTube Music',
                    authUser    => $data->{authUser} || '0',
                    hasCookies  => $data->{hasCookies} ? 1 : 0,
                    channel     => $data->{channelHandle} || '',
                };
                $prefs->set('accounts', $accounts);
                $prefs->set('activeAccount', $data->{id}) unless $prefs->get('activeAccount');
                $params->{accountImportStatus} = $data->{accountName}
                    ? "Saved account " . $data->{accountName} . ($data->{channelHandle} ? " (" . $data->{channelHandle} . ")" : '')
                    : "Saved account " . $accounts->{$data->{id}}{displayName};
                $params->{accountImportStatus} .= ". " . $data->{warning} if $data->{warning};
            } else {
                my $err = ($data && $data->{error}) ? $data->{error} : ($res ? $res->status_line : 'proxy down');
                $params->{accountImportStatus} = "Could not save account: $err";
            }
        }

        require Plugins::YouTubeMusic::Plugin;
        Plugins::YouTubeMusic::Plugin->_write_share_flag();
        $log->info("Saved " . scalar(@playlists) . " playlists");
    }

    $params->{my_playlists} = $prefs->get('my_playlists') || [];
    $params->{autoplay} = $prefs->get('autoplay') // 1;
    $params->{pref_autoplay} = $params->{autoplay};
    $params->{codec} = $prefs->get('codec') || 'auto';
    $params->{pref_codec} = $params->{codec};

    $params->{path_python} = $prefs->get('path_python') || '';
    $params->{path_ytdlp}  = $prefs->get('path_ytdlp')  || '';
    $params->{path_ffmpeg} = $prefs->get('path_ffmpeg') || '';
    $params->{path_node}   = $prefs->get('path_node')   || '';
    $params->{log_path}    = $prefs->get('log_path')    || '';
    $params->{disable_node_worker} = $prefs->get('disable_node_worker') // 0;
    $params->{shareCookiesWithYtdlp} = $prefs->get('shareCookiesWithYtdlp') ? 1 : 0;
    my $accounts = $prefs->get('accounts') || {};
    my @accountList;
    for my $id (sort keys %{$accounts}) {
        push @accountList, {
            id      => $id,
            name    => $accounts->{$id}{displayName} || $id,
            channel => $accounts->{$id}{channel} || '',
        };
    }
    $params->{accountList} = \@accountList;
    $params->{activeAccount} = $prefs->get('activeAccount') || '';
    return $class->SUPER::handler($client, $params);
}

1;

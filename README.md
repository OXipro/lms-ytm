# YouTube Music for Lyrion Music Server

Fork of [schmij97/lms-ytmusic](https://github.com/schmij97/lms-ytmusic) (GPL-2.0). The Perl plugin and the local Python proxy are kept. Account feeds go through [ytmusicapi](https://github.com/sigma67/ytmusicapi). Audio is still `yt-dlp` piped into `ffmpeg`, the same path the original plugin uses for Squeezebox hardware.

This project is not affiliated with Google or YouTube. It calls the unofficial YouTube Music InnerTube API. That API changes without notice.

## What a free account does

Browsing works with no account at all: search, home, charts, new releases, moods and genres, podcasts.

A normal (free) YouTube Music login adds, for the player that selects it:

- personalised Home
- library (playlists, liked songs, albums, artists, subscriptions)
- history
- moods and genres split into the sections YouTube returns, including "For you" when the account has one

Playback does not receive that login unless you opt in. The setting **Share cookies with yt-dlp** is off by default. Leave it off for free-account listening. Turn it on only when you want Premium audio quality and you have imported a Netscape `cookies.txt`. That file is a Google session cookie. yt-dlp will see it. A headers-only paste is enough for the catalogue and is not sent to yt-dlp.

## Authentication

ytmusicapi documents two setups. OAuth (TV / limited-input device client) is the simplest for some scripts, and it does not provide a cookie yt-dlp can use, so this plugin does not use it.

Use browser auth, as described in the [ytmusicapi browser setup](https://ytmusicapi.readthedocs.io/en/stable/setup/browser.html):

1. Open https://music.youtube.com and sign in.
2. In the browser developer tools, Network tab, filter for `browse`.
3. Copy the request headers of a logged-in POST (Firefox: copy request headers). The paste must include `cookie` and `x-goog-authuser`.
4. Or export a Netscape `cookies.txt` for `music.youtube.com` while logged in. It must contain `__Secure-3PAPISID`.

In LMS: Settings, Advanced, YouTube Music. Name the account, set Auth user (the `X-Goog-AuthUser` index, usually `0`; required when several Google accounts share one browser), paste, save. Files are stored under the LMS prefs directory `plugin/youtubemusic/`, mode `0600`. They are not written to the log.

Each player picks an account under player settings, or from the account row in the YouTube Music menu on the player (Radio, web, or controller). That row is shown whenever at least one account is saved. "No account" on a player forces anonymous browsing even if the server has a default.

## Audio

The proxy transcodes to a sequential stream because raw YouTube files do not start reliably on Radio, Boom, or Touch. Per player:

- format: Auto (server codec), MP3, FLAC, or AAC
- bitrate: 192 or 320 kbps for MP3 and AAC

MP3 192 is the default that hardware players accept. FLAC is for players that decode it. If ffmpeg has no `libmp3lame` (piCorePlayer's `pcp-ffmpeg` extension), the proxy still falls back to FLAC or AAC.

The app icon is the YouTube Music mark. Menu section icons are the stock LMS files under `/html/images/`. Cover art on tracks, albums, and playlists comes from YouTube.

## Requirements

- Lyrion Music Server 9
- Python 3.10+
- ffmpeg
- yt-dlp (the settings page can download it)
- `ytmusicapi` (the proxy installs it into the LMS cache on first start, including Debian/Ubuntu system Python)

## Install

Add this repository in LMS under Settings, Plugins, Additional repositories:

`https://raw.githubusercontent.com/OXipro/lms-ytm/main/repo.xml`

Install or update YouTube Music from the plugin list, then restart LMS.

You can also copy `Plugins/YouTubeMusic` into the LMS plugins directory and restart LMS.

## License

GPL-2.0. See [LICENSE](LICENSE). Upstream copyright remains with schmij97.

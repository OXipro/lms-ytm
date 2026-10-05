import json
import logging
import os
import re
import stat
import threading

_DIR = ""
_LOCK = threading.Lock()
_CLIENTS = {}
_ANON = None
_READY = None


def configure(directory):
    global _DIR
    _DIR = directory or ""
    if _DIR:
        os.makedirs(_DIR, mode=0o700, exist_ok=True)
        try:
            os.chmod(_DIR, 0o700)
        except OSError:
            pass


def reset_ready():
    global _READY
    _READY = None


def ready():
    global _READY
    if _READY is not None:
        return _READY
    try:
        import ytmusicapi  # noqa: F401
        _READY = True
    except ImportError:
        logging.warning("ytmusicapi is not installed; account feeds are disabled")
        _READY = False
    return _READY


def share_cookies_enabled():
    if not _DIR:
        return False
    path = os.path.join(_DIR, "share_cookies")
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip() == "1"
    except OSError:
        return False


def _headers_path(account_id):
    return os.path.join(_DIR, f"{account_id}.headers.json")


def _cookies_path(account_id):
    return os.path.join(_DIR, f"{account_id}.cookies.txt")


def _index_path():
    return os.path.join(_DIR, "index.json")


def _read_index():
    try:
        with open(_index_path(), encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_index(index):
    path = _index_path()
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(index, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _private(path):
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def list_accounts():
    index = _read_index()
    out = []
    for account_id in sorted(index):
        meta = index[account_id] or {}
        out.append({
            "id": account_id,
            "name": meta.get("name") or account_id,
            "authUser": meta.get("authUser") or "0",
            "hasCookies": bool(meta.get("hasCookies")) and os.path.isfile(_cookies_path(account_id)),
            "hasAuth": os.path.isfile(_headers_path(account_id)),
        })
    return out


def cookie_file(account_id):
    if not account_id or not share_cookies_enabled():
        return None
    path = _cookies_path(account_id)
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        return path
    return None


def _anon():
    global _ANON
    if _ANON is None:
        from ytmusicapi import YTMusic
        _ANON = YTMusic()
    return _ANON


def client_for(account_id):
    if not ready():
        raise RuntimeError("ytmusicapi is not installed")
    if not account_id:
        return _anon()
    path = _headers_path(account_id)
    if not os.path.isfile(path):
        logging.info("No auth file for account %s; using anonymous catalog", account_id)
        return _anon()
    mtime = os.path.getmtime(path)
    with _LOCK:
        cached = _CLIENTS.get(account_id)
        if cached and cached[0] == mtime:
            return cached[1]
    from ytmusicapi import YTMusic
    index = _read_index()
    user = (index.get(account_id) or {}).get("authUser") or None
    if user in ("", "0", 0, None):
        user = None
    yt = YTMusic(path, user=user)
    with _LOCK:
        _CLIENTS[account_id] = (mtime, yt)
    return yt


def delete_account(account_id):
    if not account_id or not re.fullmatch(r"a[0-9a-f]{8}", account_id):
        return False
    index = _read_index()
    index.pop(account_id, None)
    _write_index(index)
    for path in (_headers_path(account_id), _cookies_path(account_id)):
        try:
            os.remove(path)
        except OSError:
            pass
    with _LOCK:
        _CLIENTS.pop(account_id, None)
    return True


def _looks_like_netscape(text):
    if text.lstrip().startswith("# Netscape") or "HTTP Cookie File" in text[:400]:
        return True
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        return line.count("\t") >= 5
    return False


def netscape_cookie_header(text):
    pairs = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 7 and parts[5] and parts[6]:
            pairs.append(f"{parts[5]}={parts[6]}")
    return "; ".join(pairs)


def _auth_from_material(material, auth_user):
    text = (material or "").strip()
    if not text:
        raise ValueError("Paste browser request headers or a Netscape cookies.txt")
    netscape = None
    if text.startswith("{"):
        headers = json.loads(text)
        if not isinstance(headers, dict):
            raise ValueError("Auth JSON must be an object")
    elif _looks_like_netscape(text):
        netscape = text if text.endswith("\n") else text + "\n"
        cookie = netscape_cookie_header(text)
        if "__Secure-3PAPISID" not in cookie and "SAPISID" not in cookie:
            raise ValueError("Cookie file has no SAPISID. Export cookies for music.youtube.com while logged in.")
        raw = f"cookie: {cookie}\nx-goog-authuser: {auth_user or '0'}\n"
        from ytmusicapi.auth.browser import setup_browser
        headers = json.loads(setup_browser(headers_raw=raw))
    else:
        raw = text
        if "x-goog-authuser" not in raw.lower():
            raw += f"\nx-goog-authuser: {auth_user or '0'}\n"
        from ytmusicapi.auth.browser import setup_browser
        headers = json.loads(setup_browser(headers_raw=raw))
    lower = {str(k).lower(): v for k, v in headers.items()}
    if "authorization" not in lower or "SAPISIDHASH" not in str(lower.get("authorization")):
        headers["authorization"] = "SAPISIDHASH 1_placeholder"
    if "x-goog-authuser" not in lower:
        headers["x-goog-authuser"] = auth_user or "0"
    else:
        headers["x-goog-authuser"] = auth_user or lower["x-goog-authuser"]
    return headers, netscape


def import_account(name, auth_user, material):
    if not ready():
        raise RuntimeError("ytmusicapi is not installed. Install it for the same Python that runs this proxy.")
    if not _DIR:
        raise RuntimeError("Accounts directory is not configured")
    auth_user = str(auth_user or "0").strip() or "0"
    if not re.fullmatch(r"\d+", auth_user):
        raise ValueError("Auth user must be a number (X-Goog-AuthUser, usually 0)")
    headers, netscape = _auth_from_material(material, auth_user)
    import secrets
    account_id = "a" + secrets.token_hex(4)
    path = _headers_path(account_id)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(headers, handle, indent=2, sort_keys=True)
        handle.write("\n")
    _private(path)
    has_cookies = False
    if netscape:
        cookie_path = _cookies_path(account_id)
        with open(cookie_path, "w", encoding="utf-8") as handle:
            handle.write(netscape)
        _private(cookie_path)
        has_cookies = True
    index = _read_index()
    index[account_id] = {
        "name": (name or "YouTube Music").strip()[:80] or "YouTube Music",
        "authUser": auth_user,
        "hasCookies": has_cookies,
    }
    _write_index(index)
    info = {"accountName": "", "channelHandle": ""}
    try:
        info = client_for(account_id).get_account_info() or info
    except Exception as exc:
        logging.warning("Account %s saved but get_account_info failed: %s", account_id, exc)
        info["warning"] = str(exc)
    return {
        "ok": True,
        "id": account_id,
        "name": index[account_id]["name"],
        "authUser": auth_user,
        "hasCookies": has_cookies,
        "accountName": info.get("accountName") or "",
        "channelHandle": info.get("channelHandle") or "",
        "warning": info.get("warning") or "",
    }


def _thumb(value):
    if not value:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("url") or _thumb(value.get("thumbnails"))
    if isinstance(value, list):
        best = ""
        best_w = -1
        for entry in value:
            if not isinstance(entry, dict):
                continue
            url = entry.get("url") or ""
            width = entry.get("width") or 0
            if url and width >= best_w:
                best = url
                best_w = width
        return best
    return ""


def _artists(item):
    artists = item.get("artists")
    if isinstance(artists, str):
        return artists
    if isinstance(artists, list):
        names = []
        for artist in artists:
            if isinstance(artist, dict) and artist.get("name"):
                names.append(artist["name"])
            elif isinstance(artist, str):
                names.append(artist)
        return ", ".join(names)
    artist = item.get("artist")
    if isinstance(artist, dict):
        return artist.get("name") or ""
    return artist or item.get("author") or ""


def _album_name(item):
    album = item.get("album")
    if isinstance(album, dict):
        return album.get("name") or ""
    return album or ""


def _playlist_browse_id(item):
    browse_id = item.get("browseId") or ""
    playlist_id = item.get("playlistId") or ""
    if browse_id.startswith("VL"):
        return browse_id
    if playlist_id:
        return playlist_id if playlist_id.startswith("VL") else "VL" + playlist_id
    return browse_id


def map_item(item):
    if not isinstance(item, dict):
        return None
    kind = (item.get("resultType") or item.get("type") or "").lower()
    video_id = item.get("videoId") or ""
    browse_id = item.get("browseId") or ""
    if kind in ("song", "video", "episode") or (video_id and kind not in ("album", "artist", "playlist")):
        if video_id and kind != "playlist":
            if kind in ("album", "artist"):
                pass
            else:
                return {
                    "type": "song",
                    "title": item.get("title") or "",
                    "artist": _artists(item),
                    "album": _album_name(item),
                    "duration": item.get("duration") or "",
                    "videoId": video_id,
                    "thumbnail": _thumb(item.get("thumbnails") or item.get("thumbnail")),
                    "url": f"ytm://{video_id}",
                    "played": item.get("played") or "",
                }
    if kind == "artist" or browse_id.startswith("UC"):
        return {
            "type": "artist",
            "name": item.get("artist") if isinstance(item.get("artist"), str) else (item.get("name") or item.get("title") or ""),
            "title": item.get("title") or item.get("name") or "",
            "browseId": browse_id,
            "thumbnail": _thumb(item.get("thumbnails") or item.get("thumbnail")),
            "subtitle": item.get("subscribers") or "",
        }
    if kind == "album" or browse_id.startswith("MPRE"):
        return {
            "type": "album",
            "title": item.get("title") or "",
            "artist": _artists(item),
            "year": item.get("year") or "",
            "browseId": browse_id,
            "thumbnail": _thumb(item.get("thumbnails") or item.get("thumbnail")),
        }
    playlist_id = _playlist_browse_id(item)
    if kind in ("playlist", "community_playlist", "featured_playlist") or playlist_id.startswith("VL"):
        return {
            "type": "playlist",
            "title": item.get("title") or "",
            "browseId": playlist_id,
            "thumbnail": _thumb(item.get("thumbnails") or item.get("thumbnail")),
            "subtitle": item.get("description") or item.get("count") or "",
            "count": str(item.get("count") or item.get("trackCount") or ""),
        }
    if video_id:
        return map_item({**item, "resultType": "song"})
    return None


def _map_many(items):
    out = []
    for item in items or []:
        mapped = map_item(item)
        if mapped:
            out.append(mapped)
    return out


def _rows_from_home(rows):
    sections = []
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        items = _map_many(row.get("contents") or row.get("items") or [])
        if items:
            sections.append({"title": row.get("title") or "Home", "items": items})
    return sections


def _call(account_id, fn):
    if not ready():
        return None
    try:
        return fn(client_for(account_id))
    except Exception:
        logging.exception("ytmusicapi call failed")
        return None


def home(account_id):
    def run(yt):
        return _rows_from_home(yt.get_home(limit=6))
    return _call(account_id, run)


def search(account_id, query, kind):
    filters = {
        "songs": "songs",
        "videos": "videos",
        "albums": "albums",
        "artists": "artists",
        "playlists": "playlists",
        "podcasts": "podcasts",
        "episodes": "episodes",
    }
    filt = filters.get(kind or "songs")
    if not filt:
        return None

    def run(yt):
        return _map_many(yt.search(query, filter=filt, limit=30))
    return _call(account_id, run)


def moods(account_id):
    def run(yt):
        raw = yt.get_mood_categories()
        sections = []
        if isinstance(raw, dict):
            for title, cats in raw.items():
                items = []
                for cat in cats or []:
                    if not isinstance(cat, dict):
                        continue
                    params = cat.get("params") or ""
                    if not params:
                        continue
                    items.append({
                        "title": cat.get("title") or "Category",
                        "params": params,
                        "browseId": "FEmusic_moods_and_genres_category",
                        "type": "mood_category",
                    })
                if items:
                    sections.append({"title": title or "Moods and Genres", "items": items})
        return sections
    return _call(account_id, run)


def mood_category(account_id, params):
    def run(yt):
        playlists = yt.get_mood_playlists(params)
        items = _map_many(playlists)
        return [{"title": "Playlists", "items": items}] if items else []
    return _call(account_id, run)


def charts(account_id):
    def run(yt):
        data = yt.get_charts("ZZ")
        sections = []
        for key, title in (("videos", "Top videos"), ("genres", "Genres"), ("artists", "Artists")):
            items = _map_many(data.get(key) or [])
            if items:
                sections.append({"title": title, "items": items})
        return sections
    return _call(account_id, run)


def new_releases(account_id):
    def run(yt):
        data = yt.get_explore()
        items = _map_many(data.get("new_releases") or [])
        return [{"title": "New Releases", "items": items}] if items else []
    return _call(account_id, run)


def playlist(account_id, browse_id):
    def run(yt):
        if browse_id.startswith("MPRE"):
            return _album_payload(yt.get_album(browse_id))
        playlist_id = browse_id[2:] if browse_id.startswith("VL") else browse_id
        data = yt.get_playlist(playlist_id, limit=300)
        items = []
        for track in data.get("tracks") or []:
            mapped = map_item(track if track.get("resultType") else {**track, "resultType": "song"})
            if mapped and mapped.get("type") == "song":
                if not mapped.get("thumbnail"):
                    mapped["thumbnail"] = _thumb(data.get("thumbnails"))
                if not mapped.get("album"):
                    mapped["album"] = data.get("title") or ""
                items.append(mapped)
        return {"title": data.get("title") or "", "items": items}
    return _call(account_id, run)


def _album_payload(data):
    items = []
    for track in data.get("tracks") or []:
        mapped = map_item({**track, "resultType": "song"})
        if not mapped:
            continue
        if not mapped.get("album"):
            mapped["album"] = data.get("title") or ""
        if not mapped.get("thumbnail"):
            mapped["thumbnail"] = _thumb(data.get("thumbnails"))
        items.append(mapped)
    return {"title": data.get("title") or "", "items": items}


def album(account_id, browse_id):
    def run(yt):
        if browse_id.startswith("MPRE"):
            return _album_payload(yt.get_album(browse_id))
        return playlist(account_id, browse_id)
    if browse_id.startswith("MPRE"):
        return _call(account_id, run)
    return playlist(account_id, browse_id)


def artist(account_id, channel_id):
    def run(yt):
        data = yt.get_artist(channel_id)
        sections = []
        for key, title in (
            ("songs", "Songs"),
            ("videos", "Videos"),
            ("albums", "Albums"),
            ("singles", "Singles"),
            ("playlists", "Playlists"),
        ):
            block = data.get(key)
            if isinstance(block, dict):
                raw_items = block.get("results") or block.get("items") or []
            elif isinstance(block, list):
                raw_items = block
            else:
                continue
            items = _map_many(raw_items)
            if items:
                sections.append({"title": title, "items": items})
        return {"title": data.get("name") or data.get("title") or "", "sections": sections}
    return _call(account_id, run)


def _library_rows(items, title):
    mapped = _map_many(items)
    return [{"title": title, "items": mapped}] if mapped else []


def library_playlists(account_id):
    return _call(account_id, lambda yt: _map_many(yt.get_library_playlists(limit=100)))


def library_albums(account_id):
    return _call(account_id, lambda yt: _map_many(yt.get_library_albums(limit=100)))


def library_artists(account_id):
    return _call(account_id, lambda yt: _map_many(yt.get_library_artists(limit=100)))


def library_subscriptions(account_id):
    return _call(account_id, lambda yt: _map_many(yt.get_library_subscriptions(limit=100)))


def liked(account_id):
    def run(yt):
        data = yt.get_liked_songs(limit=200)
        tracks = data.get("tracks") or []
        items = []
        for track in tracks:
            mapped = map_item({**track, "resultType": "song"})
            if mapped:
                items.append(mapped)
        return {"title": data.get("title") or "Liked Songs", "items": items}
    return _call(account_id, run)


def history(account_id):
    def run(yt):
        return _map_many(yt.get_history())
    return _call(account_id, run)


def radio(account_id, video_id):
    def run(yt):
        data = yt.get_watch_playlist(videoId=video_id, limit=25)
        items = []
        for track in data.get("tracks") or []:
            mapped = map_item({**track, "resultType": "song"})
            if mapped:
                items.append(mapped)
        return items
    return _call(account_id, run)


def song_info(account_id, video_id):
    def run(yt):
        data = yt.get_song(video_id)
        details = data.get("videoDetails") or {}
        thumbs = (details.get("thumbnail") or {}).get("thumbnails") or []
        length = details.get("lengthSeconds")
        try:
            duration = int(length) if length else 0
        except (TypeError, ValueError):
            duration = 0
        if not details.get("title") and not details.get("videoId"):
            return None
        return {
            "title": details.get("title") or "",
            "artist": details.get("author") or "",
            "album": "",
            "duration": duration,
            "thumbnail": _thumb(thumbs),
            "videoId": details.get("videoId") or video_id,
        }
    return _call(account_id, run)


def test_account(account_id):
    yt = client_for(account_id)
    info = yt.get_account_info()
    return {
        "ok": True,
        "accountName": info.get("accountName") or "",
        "channelHandle": info.get("channelHandle") or "",
    }

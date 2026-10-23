import hashlib
import json
import logging
import os
import re
import stat
import threading
import time
import urllib.parse

_DIR = ""
_LOCK = threading.Lock()
_CLIENT_LOCKS = {}
_CLIENTS = {}
_ANON = None
_READY = None
_EMFILE_LOGGED = 0.0
_SONG_CACHE = {}
_SONG_INFLIGHT = {}
_SONG_TTL = 6 * 3600
_SONG_FAIL_TTL = 20
_AUTH = {}
_AUTH_TTL = 600
_AUTH_RETRY = 90
_MOBILE_HOME = None
AUTH_MESSAGE = "YouTube Music session expired. Re-import your cookies in Settings."


class AuthExpired(Exception):
    """YouTube returned a signed-out page for an account that should be logged in."""


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
        state = _AUTH.get(account_id) or {}
        expired = bool(state) and not state.get("ok") and state.get("reason") in ("signed_out", "no_auth")
        out.append({
            "id": account_id,
            "name": meta.get("name") or account_id,
            "authUser": meta.get("authUser") or "0",
            "hasCookies": bool(meta.get("hasCookies")) and os.path.isfile(_cookies_path(account_id)),
            "hasAuth": os.path.isfile(_headers_path(account_id)),
            "authExpired": expired,
            "authReason": state.get("reason") or "",
            "accountName": state.get("name") or "",
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


def _client_lock(account_id):
    key = account_id or ""
    with _LOCK:
        lock = _CLIENT_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            _CLIENT_LOCKS[key] = lock
        return lock


def _close_yt(yt):
    session = getattr(yt, "_session", None) or getattr(yt, "session", None)
    if session is None:
        return
    try:
        session.close()
    except Exception:
        logging.debug("Failed to close a YouTube Music session", exc_info=True)


def _tame_session(yt):
    """Keep one account from opening an unbounded number of TLS sockets."""
    session = getattr(yt, "_session", None) or getattr(yt, "session", None)
    if session is None:
        return
    try:
        from requests.adapters import HTTPAdapter
        adapter = HTTPAdapter(pool_connections=2, pool_maxsize=4, pool_block=True)
        session.mount("https://", adapter)
        session.mount("http://", adapter)
    except Exception:
        logging.debug("Could not cap the YouTube Music connection pool", exc_info=True)


def client_for(account_id):
    if not ready():
        raise RuntimeError("ytmusicapi is not installed")
    if not account_id:
        yt = _anon()
        _tame_session(yt)
        return yt
    path = _headers_path(account_id)
    if not os.path.isfile(path):
        logging.info("No auth file for account %s; using anonymous catalog", account_id)
        yt = _anon()
        _tame_session(yt)
        return yt
    mtime = os.path.getmtime(path)
    with _LOCK:
        cached = _CLIENTS.get(account_id)
        if cached and cached[0] == mtime:
            return cached[1]
        old = cached
    _install_auth_hash()
    from ytmusicapi import YTMusic
    index = _read_index()
    # onBehalfOfUser is a 21-digit brand-account id. X-Goog-AuthUser (0, 1, …)
    # is already stored in the headers file and must not be sent as that id.
    user = _brand_user((index.get(account_id) or {}).get("authUser"))
    yt = YTMusic(path, user=user)
    _tame_session(yt)
    with _LOCK:
        current = _CLIENTS.get(account_id)
        if current and current[0] == mtime and current is not old:
            _close_yt(yt)
            return current[1]
        _CLIENTS[account_id] = (mtime, yt)
    if old and old[1] is not yt:
        _close_yt(old[1])
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
        old = _CLIENTS.pop(account_id, None)
        _AUTH.pop(account_id, None)
    if old:
        _close_yt(old[1])
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
    with _LOCK:
        _AUTH.pop(account_id, None)
    state = verify_auth(account_id, force=True)
    warning = ""
    if not state.get("ok"):
        warning = AUTH_MESSAGE if state.get("reason") in ("signed_out", "no_auth") else (
            "Saved the account, but YouTube Music did not answer the session check."
        )
    return {
        "ok": True,
        "id": account_id,
        "name": index[account_id]["name"],
        "authUser": auth_user,
        "hasCookies": has_cookies,
        "accountName": state.get("name") or "",
        "channelHandle": state.get("handle") or "",
        "authExpired": not state.get("ok") and state.get("reason") in ("signed_out", "no_auth"),
        "warning": warning,
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
    if not video_id:
        playlist_id = item.get("playlistId") or ""
        if playlist_id.startswith("RDAMVM") and len(playlist_id) > 6:
            video_id = playlist_id[6:]
            kind = kind or "song"
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
        title = row.get("title") or "Home"
        if re.search(r"using\b.+\baccount", title, re.I):
            title = "Home"
        items = _map_many(row.get("contents") or row.get("items") or [])
        if items:
            sections.append({"title": title, "items": items})
    return sections


def _is_too_many_files(exc):
    seen = set()
    current = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, OSError) and getattr(current, "errno", None) == 24:
            return True
        current = current.__cause__ or current.__context__
    return False


def _log_call_failure(exc):
    global _EMFILE_LOGGED
    if _is_too_many_files(exc):
        now = time.time()
        if now - _EMFILE_LOGGED > 30:
            _EMFILE_LOGGED = now
            logging.error(
                "YouTube Music requests stopped: too many open files. "
                "Waiting for the current requests to finish."
            )
        return
    logging.warning("ytmusicapi call failed: %s", _exc_brief(exc))
    logging.debug("ytmusicapi call failed", exc_info=True)


def _exc_brief(exc):
    text = str(exc).replace("\n", " ")
    cut = text.find(" on {")
    if cut > 0:
        text = text[:cut]
    return text[:300]


def _exc_is_signed_out(exc):
    text = str(exc)
    return (
        "signInEndpoint" in text
        or "Sign in" in text
        or "Looking for what" in text
    )


def _brand_user(value):
    user = str(value or "").strip()
    if user.isdigit() and len(user) >= 15:
        return user
    return None


def _cookie_value(cookie, name):
    for part in (cookie or "").split(";"):
        part = part.strip()
        if part.startswith(name + "="):
            return part.split("=", 1)[1]
    return ""


def _sapisid_token(secret, origin, timestamp):
    digest = hashlib.sha1(f"{timestamp} {secret} {origin}".encode()).hexdigest()
    return timestamp + "_" + digest


def _sapisid_authorization(cookie, sapisid, origin):
    """YouTube rejects a lone SAPISIDHASH on current Music web clients."""
    timestamp = str(int(time.time()))
    sid = _cookie_value(cookie, "SAPISID") or sapisid
    first_party = _cookie_value(cookie, "__Secure-1PAPISID") or sid
    third_party = _cookie_value(cookie, "__Secure-3PAPISID") or sapisid
    return " ".join((
        "SAPISIDHASH " + _sapisid_token(sid, origin, timestamp),
        "SAPISID1PHASH " + _sapisid_token(first_party, origin, timestamp),
        "SAPISID3PHASH " + _sapisid_token(third_party, origin, timestamp),
    ))


def _install_auth_hash():
    """Send the 1P and 3P hashes ytmusicapi still omits."""
    try:
        import ytmusicapi.ytmusic as ytm
    except ImportError:
        return
    if getattr(ytm.YTMusic, "_lms_auth_hash", False):
        return
    original = ytm.YTMusic.headers.fget

    def headers(self):
        built = original(self)
        sapisid = getattr(self, "sapisid", None)
        origin = getattr(self, "origin", None)
        if sapisid and origin:
            cookie = ""
            try:
                cookie = self.base_headers.get("cookie") or ""
            except Exception:
                cookie = ""
            built["authorization"] = _sapisid_authorization(cookie, sapisid, origin)
        return built

    ytm.YTMusic.headers = property(headers)
    ytm.YTMusic._lms_auth_hash = True


def _walk(node, limit=20000):
    stack = [node]
    seen = 0
    while stack:
        current = stack.pop()
        seen += 1
        if seen > limit:
            break
        if isinstance(current, dict):
            yield current
            stack.extend(current.values())
        elif isinstance(current, list):
            stack.extend(current)


def _payload_signed_out(node):
    for current in _walk(node):
        if "signInEndpoint" in current:
            return True
        endpoint = current.get("navigationEndpoint")
        if isinstance(endpoint, dict) and "signInEndpoint" in endpoint:
            return True
    return False


def _has_account_menu(node):
    for current in _walk(node):
        if "multiPageMenuRenderer" in current:
            return True
        if current.get("style") == "MULTI_PAGE_MENU_STYLE_TYPE_ACCOUNT":
            return True
    return False


def _account_identity(response):
    name = ""
    handle = ""
    for current in _walk(response):
        header = current.get("activeAccountHeaderRenderer")
        if not isinstance(header, dict):
            header = current if "accountName" in current else None
        if not isinstance(header, dict):
            continue
        found = _runs_text(header.get("accountName") or {})
        if not found:
            continue
        name = found
        handle = _runs_text(header.get("channelHandle") or {}) or handle
        break
    return name, handle


def _reject_if_signed_out(response, where):
    if _payload_signed_out(response):
        raise AuthExpired(where)


def _notifier_message(response):
    messages = []
    for current in _walk(response):
        renderer = current.get("messageRenderer") or current.get("musicNotifierShelfRenderer")
        if not isinstance(renderer, dict):
            continue
        text = _runs_text(renderer.get("text") or renderer.get("title") or {})
        if text and text not in messages:
            messages.append(text)
    return "; ".join(messages[:3])


def _remember_auth(account_id, ok, reason, name="", handle="", where=""):
    with _LOCK:
        prev = _AUTH.get(account_id) or {}
        changed = prev.get("ok") != ok or prev.get("reason") != reason
        state = {
            "at": time.time(),
            "ok": bool(ok),
            "reason": reason,
            "name": name or "",
            "handle": handle or "",
        }
        _AUTH[account_id] = state
    if changed and account_id:
        if ok and reason == "ok":
            logging.info("Account %s session is signed in as %s", account_id, name or "unknown")
        elif reason == "signed_out":
            place = f" while loading {where}" if where else ""
            logging.warning(
                "Account %s is signed out%s. Home, likes, and history need a fresh cookie import.",
                account_id,
                place,
            )
        elif reason == "no_auth":
            logging.warning("Account %s has no saved auth headers", account_id)
        elif reason == "request_failed":
            logging.warning("Account %s session check could not reach YouTube Music", account_id)
    return dict(state)


def _note_signed_out(account_id, where):
    if account_id:
        _remember_auth(account_id, False, "signed_out", where=where)


def auth_expired(account_id):
    state = _AUTH.get(account_id) or {}
    return bool(state) and not state.get("ok") and state.get("reason") in ("signed_out", "no_auth")


def _auth_payload(reason):
    expired = reason in ("signed_out", "no_auth")
    return {
        "error": AUTH_MESSAGE if expired else "YouTube Music account request failed",
        "authExpired": expired,
        "reason": reason,
        "items": [],
    }


def verify_auth(account_id, force=False):
    """True when the saved headers still open a signed-in YouTube Music session.

    An expired cookie comes back as the signed-out home and library, with HTTP 200.
    """
    if not account_id:
        return {"ok": True, "reason": "", "name": "", "handle": ""}
    now = time.time()
    with _LOCK:
        state = _AUTH.get(account_id)
        if state and not force:
            ttl = _AUTH_TTL if state.get("ok") else _AUTH_RETRY
            if now - state.get("at", 0) < ttl:
                return dict(state)
    if not os.path.isfile(_headers_path(account_id)):
        return _remember_auth(account_id, False, "no_auth")
    if not ready():
        return _remember_auth(account_id, False, "request_failed")
    try:
        with _client_lock(account_id):
            response = client_for(account_id)._send_request("account/account_menu", {})
    except Exception as exc:
        logging.warning("Account %s auth check failed: %s", account_id, _exc_brief(exc))
        return _remember_auth(account_id, False, "request_failed")
    name, handle = _account_identity(response)
    if name:
        return _remember_auth(account_id, True, "ok", name, handle)
    if _payload_signed_out(response) or _has_account_menu(response):
        return _remember_auth(account_id, False, "signed_out")
    keys = list(response)[:8] if isinstance(response, dict) else []
    logging.warning("Account %s account menu had no name (keys: %s). Not blocking feeds.", account_id, keys)
    return _remember_auth(account_id, True, "unconfirmed")


def auth_status(account_id, force=False):
    state = verify_auth(account_id, force=force)
    expired = (not state.get("ok")) and state.get("reason") in ("signed_out", "no_auth")
    return {
        "ok": bool(state.get("ok")),
        "authExpired": expired,
        "reason": state.get("reason") or "",
        "accountName": state.get("name") or "",
        "channelHandle": state.get("handle") or "",
        "error": AUTH_MESSAGE if expired else "",
    }


def _call(account_id, fn, require_auth=False):
    if not ready():
        return None
    if require_auth and account_id:
        state = verify_auth(account_id)
        if not state.get("ok") and state.get("reason") in ("signed_out", "no_auth"):
            return _auth_payload(state.get("reason"))
    try:
        with _client_lock(account_id):
            return fn(client_for(account_id))
    except AuthExpired as exc:
        _note_signed_out(account_id, str(exc) or "feed")
        return _auth_payload("signed_out")
    except Exception as exc:
        if account_id and _exc_is_signed_out(exc):
            _note_signed_out(account_id, "request")
            return _auth_payload("signed_out")
        _log_call_failure(exc)
        return None


def _section_list(response):
    if not isinstance(response, dict):
        return None
    continuation = (response.get("continuationContents") or {}).get("sectionListContinuation")
    if isinstance(continuation, dict):
        return continuation
    tabs = (
        (response.get("contents") or {})
        .get("singleColumnBrowseResultsRenderer", {})
        .get("tabs")
        or []
    )
    for tab in tabs:
        if not isinstance(tab, dict):
            continue
        section = (
            (tab.get("tabRenderer") or {})
            .get("content", {})
            .get("sectionListRenderer")
        )
        if isinstance(section, dict):
            return section
    return None


def _continuation_query(section):
    for cont in (section or {}).get("continuations") or []:
        if not isinstance(cont, dict):
            continue
        token = (cont.get("nextContinuationData") or {}).get("continuation")
        if not token:
            token = (
                (cont.get("continuationItemRenderer") or {})
                .get("continuationEndpoint", {})
                .get("continuationCommand", {})
                .get("token")
            )
        if token:
            quoted = urllib.parse.quote(str(token), safe="")
            return f"&ctoken={quoted}&continuation={quoted}&type=next"
    return ""


def _shelf_title(shelf):
    header = shelf.get("header") or {}
    if isinstance(header, dict):
        for value in header.values():
            if not isinstance(value, dict):
                continue
            text = _runs_text(value.get("title") or {})
            if text:
                return text
    return _runs_text(shelf.get("title") or {})


def _renderer_thumbs(renderer):
    for path in (
        ("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
        ("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
    ):
        node = renderer
        for key in path:
            if not isinstance(node, dict):
                node = None
                break
            node = node.get(key)
        if node:
            return node
    return []


def _watch_video_id(renderer):
    watch = (renderer.get("navigationEndpoint") or {}).get("watchEndpoint") or {}
    if watch.get("videoId"):
        return watch["videoId"]
    playlist_id = watch.get("playlistId") or ""
    if playlist_id.startswith("RDAMVM") and len(playlist_id) > 6:
        return playlist_id[6:]
    return _video_id_from_list_item(renderer)


def _page_type(renderer):
    browse = (renderer.get("navigationEndpoint") or {}).get("browseEndpoint") or {}
    return (
        (browse.get("browseEndpointContextSupportedConfigs") or {})
        .get("browseEndpointContextMusicConfig", {})
        .get("pageType")
        or ""
    )


def _home_item(renderer):
    if not isinstance(renderer, dict):
        return None
    video_id = _watch_video_id(renderer)
    browse = (renderer.get("navigationEndpoint") or {}).get("browseEndpoint") or {}
    browse_id = browse.get("browseId") or ""
    page_type = _page_type(renderer)
    title = _runs_text(renderer.get("title") or {}) or _column_text(renderer, 0)
    thumbs = _renderer_thumbs(renderer)
    subtitle = _runs_text(renderer.get("subtitle") or {}) or _column_text(renderer, 1)
    subtitle_parts = [part.strip() for part in re.split(r"\s*[•·]\s*", subtitle) if part.strip()] if subtitle else []
    artist = subtitle_parts[0] if subtitle_parts else ""
    # A Quick picks card carries both a song id and a radio playlist id.
    # The song is what YouTube Music shows in that row.
    if video_id and "PLAYLIST" not in page_type and not browse_id.startswith("VL"):
        album = _column_text(renderer, 2)
        return {
            "resultType": "song",
            "title": title,
            "videoId": video_id,
            "artist": artist,
            "album": album,
            "thumbnails": thumbs,
        }
    if browse_id.startswith("MPRE") or "ALBUM" in page_type:
        return {
            "resultType": "album",
            "title": title,
            "artist": artist,
            "browseId": browse_id,
            "thumbnails": thumbs,
        }
    if browse_id.startswith("UC") or "ARTIST" in page_type or "USER_CHANNEL" in page_type:
        return {
            "resultType": "artist",
            "artist": title,
            "title": title,
            "browseId": browse_id,
            "subscribers": subtitle,
            "thumbnails": thumbs,
        }
    if browse_id.startswith("VL") or "PLAYLIST" in page_type:
        return {
            "resultType": "playlist",
            "title": title,
            "browseId": browse_id if browse_id.startswith("VL") else "VL" + browse_id,
            "thumbnails": thumbs,
            "subtitle": subtitle,
        }
    return None


_SHELF_KEYS = (
    "musicCarouselShelfRenderer",
    "musicImmersiveCarouselShelfRenderer",
    "musicShelfRenderer",
    "musicPlaylistShelfRenderer",
    "gridRenderer",
)


def _row_from_section(section):
    if not isinstance(section, dict):
        return None
    shelf = None
    for key in _SHELF_KEYS:
        if isinstance(section.get(key), dict):
            shelf = section[key]
            break
    if shelf is None:
        return None
    items = []
    for entry in shelf.get("contents") or shelf.get("items") or []:
        if not isinstance(entry, dict):
            continue
        renderer = (
            entry.get("musicTwoRowItemRenderer")
            or entry.get("musicResponsiveListItemRenderer")
            or entry.get("musicMultiRowListItemRenderer")
            or entry.get("playlistPanelVideoRenderer")
        )
        item = _home_item(renderer) if renderer else None
        if item:
            items.append(item)
    if not items:
        return None
    return {"title": _shelf_title(shelf) or "Home", "contents": items}


def _home_via_mobile(yt):
    """Android Music 7.21.50 is rejected with HTTP 400. Try once, then stay on web."""
    global _MOBILE_HOME
    if _MOBILE_HOME is False:
        return None
    mobile = getattr(yt, "as_mobile", None)
    if not mobile:
        _MOBILE_HOME = False
        return None
    try:
        with mobile():
            rows = _home_rows(yt, limit=12)
    except AuthExpired:
        raise
    except Exception as exc:
        brief = _exc_brief(exc)
        if "400" in brief or "invalid argument" in brief.lower():
            if _MOBILE_HOME is not False:
                logging.warning(
                    "Mobile home is rejected (%s). Later home loads use the web home only.",
                    brief,
                )
            _MOBILE_HOME = False
        else:
            logging.warning("Mobile home failed: %s", brief)
        return None
    _MOBILE_HOME = True
    return rows


def _home_rows(yt, limit=12):
    body = {"browseId": "FEmusic_home"}
    response = yt._send_request("browse", body)
    _reject_if_signed_out(response, "home")
    rows = []
    seen_tokens = set()
    for _ in range(2):
        section = _section_list(response) or {}
        for entry in section.get("contents") or []:
            row = _row_from_section(entry)
            if row:
                rows.append(row)
        if len(rows) >= min(limit, 8):
            break
        query = _continuation_query(section)
        if not query or query in seen_tokens:
            break
        seen_tokens.add(query)
        response = yt._send_request("browse", body, query)
    return rows[:8]


def home(account_id):
    def run(yt):
        rows = _home_via_mobile(yt)
        if not rows:
            try:
                rows = _home_rows(yt, limit=12)
            except AuthExpired:
                raise
            except Exception as exc:
                logging.warning("Home browse failed, using get_home: %s", _exc_brief(exc))
                rows = yt.get_home(limit=12)
        if not rows:
            logging.warning("Home browse returned no rows for account %s", account_id or "anonymous")
        return _rows_from_home(rows)
    return _call(account_id, run, require_auth=bool(account_id))


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


def _mood_playlists(yt, params):
    """Same browse as ytmusicapi, but a title without a link must not abort the list."""
    from ytmusicapi.navigation import (
        CAROUSEL_CONTENTS,
        GRID_ITEMS,
        SECTION_LIST,
        SINGLE_COLUMN_TAB,
        nav,
    )
    from ytmusicapi.parsers.browsing import parse_playlist

    response = yt._send_request(
        "browse",
        {"browseId": "FEmusic_moods_and_genres_category", "params": params},
    )
    sections = nav(response, SINGLE_COLUMN_TAB + SECTION_LIST, True) or []
    playlists = []
    for section in sections:
        path = None
        if "gridRenderer" in section:
            path = GRID_ITEMS
        elif "musicCarouselShelfRenderer" in section:
            path = CAROUSEL_CONTENTS
        elif "musicImmersiveCarouselShelfRenderer" in section:
            path = ["musicImmersiveCarouselShelfRenderer", "contents"]
        if not path:
            continue
        for result in nav(section, path, True) or []:
            if not isinstance(result, dict):
                continue
            data = (
                result.get("musicTwoRowItemRenderer")
                or result.get("musicResponsiveListItemRenderer")
                or result
            )
            try:
                parsed = parse_playlist(data)
            except Exception:
                logging.debug("Skipping a mood playlist row without a link", exc_info=True)
                continue
            if parsed:
                playlists.append(parsed)
    return playlists


def mood_category(account_id, params):
    def run(yt):
        try:
            playlists = yt.get_mood_playlists(params)
        except Exception:
            logging.warning("get_mood_playlists failed, parsing the shelf directly")
            playlists = _mood_playlists(yt, params)
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
    return _call(account_id, lambda yt: _map_many(yt.get_library_playlists(limit=100)), require_auth=True)


def library_albums(account_id):
    return _call(account_id, lambda yt: _map_many(yt.get_library_albums(limit=100)), require_auth=True)


def library_artists(account_id):
    return _call(account_id, lambda yt: _map_many(yt.get_library_artists(limit=100)), require_auth=True)


def _songs_from_response(response):
    found = []
    seen = set()

    def add(item, played):
        video_id = item.get("videoId") if isinstance(item, dict) else ""
        if not video_id or video_id in seen:
            return
        seen.add(video_id)
        if played and not item.get("played"):
            item = {**item, "played": played}
        found.append(item)

    def take_shelf(shelf, played):
        label = _shelf_title(shelf) or played
        for entry in shelf.get("contents") or shelf.get("items") or []:
            if not isinstance(entry, dict):
                continue
            renderer = (
                entry.get("musicResponsiveListItemRenderer")
                or entry.get("musicTwoRowItemRenderer")
                or entry.get("musicMultiRowListItemRenderer")
                or entry.get("playlistPanelVideoRenderer")
            )
            item = _home_item(renderer) if renderer else None
            if item and item.get("resultType") == "song":
                add(item, label)

    def walk(node, played):
        if isinstance(node, dict):
            for key in _SHELF_KEYS:
                shelf = node.get(key)
                if isinstance(shelf, dict):
                    take_shelf(shelf, played)
            for value in node.values():
                walk(value, played)
        elif isinstance(node, list):
            for value in node:
                walk(value, played)

    walk(response, "")
    return found


def _artists_from_response(response, limit=100):
    found = []
    seen = set()

    def consider(renderer):
        if len(found) >= limit or not isinstance(renderer, dict):
            return
        item = _home_item(renderer)
        browse_id = item.get("browseId") if item else ""
        if not item or item.get("resultType") != "artist" or not browse_id or browse_id in seen:
            return
        seen.add(browse_id)
        found.append(item)

    def walk(node):
        if len(found) >= limit:
            return
        if isinstance(node, dict):
            renderer = (
                node.get("musicResponsiveListItemRenderer")
                or node.get("musicTwoRowItemRenderer")
                or node.get("musicMultiRowListItemRenderer")
            )
            if renderer:
                consider(renderer)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(response)
    return found


def library_subscriptions(account_id):
    def run(yt):
        items = []
        try:
            items = yt.get_library_subscriptions(limit=100) or []
        except Exception as exc:
            if _exc_is_signed_out(exc):
                raise AuthExpired("subscriptions") from exc
            logging.warning("Account %s get_library_subscriptions failed: %s", account_id, _exc_brief(exc))
        mapped = _map_many(items)
        if mapped:
            return mapped
        response = yt._send_request("browse", {"browseId": "FEmusic_library_corpus_artists"})
        _reject_if_signed_out(response, "subscriptions")
        return _map_many(_artists_from_response(response, limit=100))
    return _call(account_id, run, require_auth=True)


def _liked_payload(tracks, title):
    items = []
    for track in tracks or []:
        if not isinstance(track, dict):
            continue
        raw = track if track.get("resultType") or track.get("type") else {**track, "resultType": "song"}
        mapped = map_item(raw)
        if mapped and mapped.get("type") == "song":
            items.append(mapped)
    return {"title": title or "Liked Songs", "items": items}


def liked(account_id):
    def run(yt):
        try:
            data = yt.get_liked_songs(limit=200) or {}
        except Exception as exc:
            if _exc_is_signed_out(exc):
                raise AuthExpired("liked songs") from exc
            logging.warning("Account %s get_liked_songs failed: %s", account_id, _exc_brief(exc))
            data = {}
        payload = _liked_payload(data.get("tracks"), data.get("title"))
        if payload["items"]:
            return payload
        response = yt._send_request("browse", {"browseId": "VLLM"})
        _reject_if_signed_out(response, "liked songs")
        fallback = _liked_payload(_songs_from_response(response), "Liked Songs")
        if not fallback["items"]:
            note = _notifier_message(response)
            if note and "sign in" in note.lower():
                raise AuthExpired("liked songs")
            logging.info("Account %s liked songs is empty%s", account_id, f" ({note})" if note else "")
        return fallback
    return _call(account_id, run, require_auth=True)


def _runs_text(node):
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return ""
    if node.get("simpleText"):
        return node["simpleText"]
    runs = node.get("runs") or []
    return "".join((run.get("text") or "") for run in runs if isinstance(run, dict))


def _video_id_from_list_item(renderer):
    overlay = (
        renderer.get("overlay", {})
        .get("musicItemThumbnailOverlayRenderer", {})
        .get("content", {})
        .get("musicPlayButtonRenderer", {})
        .get("playNavigationEndpoint", {})
        .get("watchEndpoint", {})
        .get("videoId")
    )
    if overlay:
        return overlay
    watch = renderer.get("navigationEndpoint", {}).get("watchEndpoint", {})
    if watch.get("videoId"):
        return watch["videoId"]
    playlist_item = renderer.get("playlistItemData") or {}
    return playlist_item.get("videoId") or ""


def _column_text(renderer, index):
    try:
        runs = renderer["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"]
        return runs[0].get("text", "") if runs else ""
    except (IndexError, KeyError, TypeError):
        return ""


def _list_item_thumb(renderer):
    thumbs = (
        renderer.get("thumbnail", {})
        .get("musicThumbnailRenderer", {})
        .get("thumbnail", {})
        .get("thumbnails")
        or []
    )
    return _thumb(thumbs)


def _history_items(response):
    found = []
    seen = set()

    def add_renderer(renderer, played):
        video_id = _video_id_from_list_item(renderer)
        if not video_id or video_id in seen:
            return
        seen.add(video_id)
        found.append({
            "type": "song",
            "title": _column_text(renderer, 0),
            "artist": _column_text(renderer, 1),
            "album": _column_text(renderer, 2),
            "videoId": video_id,
            "thumbnail": _list_item_thumb(renderer),
            "url": f"ytm://{video_id}",
            "played": played or "History",
        })

    def walk(node, played):
        if isinstance(node, dict):
            shelf = node.get("musicShelfRenderer")
            if isinstance(shelf, dict):
                label = _runs_text(shelf.get("title") or {}) or played
                for entry in shelf.get("contents") or []:
                    if not isinstance(entry, dict):
                        continue
                    renderer = entry.get("musicResponsiveListItemRenderer")
                    if isinstance(renderer, dict):
                        add_renderer(renderer, label)
            renderer = node.get("musicResponsiveListItemRenderer")
            if isinstance(renderer, dict):
                add_renderer(renderer, played)
            for value in node.values():
                walk(value, played)
        elif isinstance(node, list):
            for value in node:
                walk(value, played)

    walk(response, "")
    return found


def history(account_id):
    def run(yt):
        yt._check_auth()
        response = yt._send_request("browse", {"browseId": "FEmusic_history"})
        _reject_if_signed_out(response, "history")
        items = _map_many(_songs_from_response(response)) or _history_items(response)
        if items:
            return items
        note = _notifier_message(response)
        if note and "sign in" in note.lower():
            raise AuthExpired("history")
        try:
            return _map_many(yt.get_history())
        except Exception as exc:
            if _exc_is_signed_out(exc):
                raise AuthExpired("history") from exc
            logging.warning(
                "Account %s history returned no tracks (%s): %s",
                account_id,
                note or "no notice",
                _exc_brief(exc),
            )
            return []
    return _call(account_id, run, require_auth=True)


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


def _song_cache_get(video_id):
    hit = _SONG_CACHE.get(video_id)
    if not hit or hit[0] <= time.time():
        return None, False
    return hit[1], True


def song_info(account_id, video_id):
    if not video_id:
        return None
    cached, fresh = _song_cache_get(video_id)
    if fresh:
        return cached

    with _LOCK:
        event = _SONG_INFLIGHT.get(video_id)
        if event is None:
            event = threading.Event()
            _SONG_INFLIGHT[video_id] = event
            owner = True
        else:
            owner = False
    if not owner:
        event.wait(timeout=25)
        cached, fresh = _song_cache_get(video_id)
        return cached if fresh else None

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

    try:
        result = _call(account_id, run)
        _SONG_CACHE[video_id] = (time.time() + (_SONG_TTL if result else _SONG_FAIL_TTL), result)
        if len(_SONG_CACHE) > 2000:
            now = time.time()
            expired = [key for key, value in _SONG_CACHE.items() if value[0] <= now]
            for key in expired:
                _SONG_CACHE.pop(key, None)
        return result
    finally:
        with _LOCK:
            _SONG_INFLIGHT.pop(video_id, None)
        event.set()


def test_account(account_id):
    return auth_status(account_id, force=True)

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="lms-ytm"
IMAGE="lms-ytm:dev"
HTTP_PORT="${LMS_HTTP_PORT:-9000}"
CLI_PORT="${LMS_CLI_PORT:-9090}"
DATA="$ROOT/lms"

usage() {
    echo "Usage: $0 {start|stop|restart|logs}" >&2
    exit 1
}

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required" >&2
    exit 1
fi

ensure_prefs() {
    mkdir -p "$DATA/config/prefs" "$DATA/config/logs" "$DATA/config/cache" "$DATA/music" "$DATA/playlist"
    if [[ ! -f "$DATA/config/prefs/server.prefs" ]]; then
        cat > "$DATA/config/prefs/server.prefs" <<'EOF'
---
_version: 10
wizardDone: 1
language: EN
mediadirs:
- /music
playlistdir: /playlist
EOF
    fi
}

build_image() {
    docker build -t "$IMAGE" "$ROOT/docker"
}

run_container() {
    ensure_prefs
    build_image
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    local -a extra=()
    [[ -e /etc/localtime ]] && extra+=(-v /etc/localtime:/etc/localtime:ro)
    [[ -e /etc/timezone ]] && extra+=(-v /etc/timezone:/etc/timezone:ro)
    docker run -d \
        --name "$NAME" \
        -e "PUID=$(id -u)" \
        -e "PGID=$(id -g)" \
        -e "HTTP_PORT=${HTTP_PORT}" \
        -p "${HTTP_PORT}:${HTTP_PORT}/tcp" \
        -p "${CLI_PORT}:9090/tcp" \
        -p "3483:3483/tcp" \
        -p "3483:3483/udp" \
        -v "$DATA/config:/config" \
        -v "$DATA/music:/music" \
        -v "$DATA/playlist:/playlist" \
        -v "$ROOT/Plugins/YouTubeMusic:/plugin/YouTubeMusic" \
        "${extra[@]}" \
        "$IMAGE" >/dev/null
    echo "http://127.0.0.1:${HTTP_PORT}/"
}

cmd="${1:-start}"
case "$cmd" in
    start) run_container ;;
    stop) docker rm -f "$NAME" >/dev/null 2>&1 || true ;;
    restart) run_container ;;
    logs) docker logs -f "$NAME" ;;
    *) usage ;;
esac

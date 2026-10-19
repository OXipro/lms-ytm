#!/bin/bash
set -euo pipefail

mkdir -p /config/cache/Plugins /config/prefs /config/logs
if [[ ! -L /config/cache/Plugins/YouTubeMusic ]]; then
    rm -rf /config/cache/Plugins/YouTubeMusic
fi
ln -sfn /plugin/YouTubeMusic /config/cache/Plugins/YouTubeMusic
exec start-container

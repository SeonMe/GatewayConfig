#!/bin/bash

# 目标目录
DEST_DIR="/etc/dae"

# 下载 geoip.dat
curl -fsSL -o "$DEST_DIR/geoip.dat" \
  "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" || {
    echo "Failed to download geoip.dat"
    exit 1
}

# 下载 geosite.dat
curl -fsSL -o "$DEST_DIR/geosite.dat" \
  "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" || {
    echo "Failed to download geosite.dat"
    exit 1
}

echo "Successfully updated geoip.dat and geosite.dat in $DEST_DIR"
#!/bin/bash

# 环境配置
tmp_dir=/tmp/geodat
router_dir=/tmp/router
dae_dir=/etc/dae
app_dir=/opt/date_update

set -euo pipefail

# Download
## mkdir dir
mkdir -p "$tmp_dir" "$router_dir"
if [ ! -d "$app_dir" ]; then
    mkdir -p "$app_dir"
fi
## geoview & produce.py
### geoview
if [ ! -f "$app_dir/geoview" ]; then
    curl -fsSL -o "$app_dir/geoview" https://github.com/snowie2000/geoview/releases/latest/download/geoview-linux-amd64 || { echo "Failed to download geoview"; exit 1; }
else
    echo "geoview already exists, skipping download."
fi

### produce.py
if [ ! -f "$app_dir/produce.py" ]; then
    curl -fsSL -o "$app_dir/produce.py" https://raw.githubusercontent.com/SeonMe/GatewayConfig/refs/heads/main/Shellscript/produce.py || { echo "Failed to download produce.py"; exit 1; }
else
    echo "produce.py already exists, skipping download."
fi

## DAE & MosDNS
curl -fsSL -o "$tmp_dir/geoip.dat"   "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" || { echo "Failed to download geoip.dat"; exit 1; }
curl -fsSL -o "$tmp_dir/geosite.dat" "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" || { echo "Failed to download geosite.dat"; exit 1; }
## brid router
curl -fsSL -o "$router_dir/ipv4-address-space.csv" "https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.csv" || { echo "Failed to download ipv4-address-space.csv"; exit 1; }
curl -fsSL -o "$router_dir/delegated-apnic-latest"  "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest" || { echo "Failed to download delegated-apnic-latest"; exit 1; }
curl -fsSL -o "$router_dir/china_ip_list.txt"       "https://raw.githubusercontent.com/SeonMe/GatewayConfig/refs/heads/main/china_ipv4_list.txt" || { echo "Failed to download china_ip_list.txt"; exit 1; }


# DAE
rm -f "$dae_dir/geoip.dat" "$dae_dir/geosite.dat"
cp "$tmp_dir/geosite.dat" "$dae_dir/geosite.dat"
cp "$tmp_dir/geoip.dat" "$dae_dir/geoip.dat"


# MosNDS
## 删除原文件
rm -f /etc/mosdns/geodat/*
## GEOIP
"$app_dir/geoview" -type geoip -input "$tmp_dir/geoip.dat" -list private -output /etc/mosdns/geodat/geoip_private.txt
"$app_dir/geoview" -type geoip -input "$tmp_dir/geoip.dat" -list cn -output /etc/mosdns/geodat/geoip_cn.txt
## GEOSITE
"$app_dir/geoview" -type geosite -input "$tmp_dir/geosite.dat" -list geolocation-\!cn -output /etc/mosdns/geodat/geosite_geolocation-nocn.txt
"$app_dir/geoview" -type geosite -input "$tmp_dir/geosite.dat" -list gfw -output /etc/mosdns/geodat/geosite_gfw.txt
"$app_dir/geoview" -type geosite -input "$tmp_dir/geosite.dat" -list cn -output /etc/mosdns/geodat/geosite_cn.txt


# bird
pushd "$router_dir" > /dev/null || exit 1
python3 "$app_dir/produce.py"
rm -f /etc/bird/routes4.conf /etc/bird/routes6.conf
mv routes4.conf /etc/bird/routes4.conf
mv routes6.conf /etc/bird/routes6.conf
birdc configure
popd > /dev/null

systemctl restart mosdns.service
systemctl reload dae.service

rm -rf "$tmp_dir" "$router_dir"

echo "All updates completed successfully."
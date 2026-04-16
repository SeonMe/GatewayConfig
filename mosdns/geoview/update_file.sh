#!/bin/bash

### geoview github repositories
# https://github.com/snowie2000/geoview

### Download
curl -o /opt/geoview/geoip.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat
curl -o /opt/geoview/geosite.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat

### Delete Old txt
rm /etc/mosdns/geodat/*

### GEOIP
/opt/geoview/geoview -type geoip -input geoip.dat -list private -output /etc/mosdns/geodat/geoip_private.txt
/opt/geoview/geoview -type geoip -input geoip.dat -list cn -output /etc/mosdns/geodat/geoip_cn.txt
### GEOSITE
/opt/geoview/geoview -type geosite -input geosite.dat -list category-ads-all -output /etc/mosdns/geodat/geosite_category-ads-all.txt
/opt/geoview/geoview -type geosite -input geosite.dat -list geolocation-\!cn -output /etc/mosdns/geodat/geosite_geolocation-nocn.txt
/opt/geoview/geoview -type geosite -input geosite.dat -list gfw -output /etc/mosdns/geodat/geosite_gfw.txt
/opt/geoview/geoview -type geosite -input geosite.dat -list cn -output /etc/mosdns/geodat/geosite_cn.txt
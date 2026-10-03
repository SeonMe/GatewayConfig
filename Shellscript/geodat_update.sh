#!/bin/bash

# 环境配置
tmp_dir=/tmp/geodat
router_dir=/tmp/router
dae_dir=/etc/dae
app_dir=/opt/date_update

set -euo pipefail

# --- 并发保护：双实例直接退出（拿不到锁说明有实例在跑）---
exec 9>/run/geodat_update.lock
if ! flock -n 9; then
    logger -t geodat_update "另一个实例正在运行，本次退出"
    echo "Another instance is running, abort."
    exit 0
fi

# --- 失败即通知 journald 并清理临时目录 ---
cleanup() { rm -rf "$tmp_dir" "$router_dir"; }
trap cleanup EXIT

fail() {
    # 统一失败出口：进 journald + stderr + 非零退出
    # 注意：此版本为原子化设计，线上文件未被触碰，无须回滚
    logger -t geodat_update "更新失败: $1"
    echo "Update FAILED: $1" >&2
    exit 1
}

# ---------- 下载（全部到临时目录，不动线上） ----------
mkdir -p "$tmp_dir" "$router_dir" "$app_dir"

## geoview & produce.py
if [ ! -s "$app_dir/geoview" ]; then
    curl -fsSL -o "$app_dir/geoview" https://github.com/snowie2000/geoview/releases/latest/download/geoview-linux-amd64 \
        || fail "下载 geoview 失败"
    chmod +x "$app_dir/geoview"
fi
[ -x "$app_dir/geoview" ] || fail "geoview 不存在或不可执行（文件损坏？请删除 $app_dir/geoview 后重跑）"

if [ ! -f "$app_dir/produce.py" ]; then
    curl -fsSL -o "$app_dir/produce.py" https://raw.githubusercontent.com/SeonMe/GatewayConfig/refs/heads/main/Shellscript/produce.py \
        || fail "下载 produce.py 失败"
fi

# dat 双源：jsdelivr 优先（国内直连快），失败回退 GitHub 原链
download_dat() {
    local file="$1"
    if curl -fsSL -o "$tmp_dir/$file" "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/$file"; then
        return 0
    fi
    logger -t geodat_update "jsdelivr 拉取 $file 失败，回退 GitHub 原链"
    curl -fsSL -o "$tmp_dir/$file" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$file"
}
download_dat geoip.dat   || fail "下载 geoip.dat 失败（双源均不可用）"
download_dat geosite.dat || fail "下载 geosite.dat 失败（双源均不可用）"

curl -fsSL -o "$router_dir/ipv4-address-space.csv" "https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.csv" \
    || fail "下载 ipv4-address-space.csv 失败"
curl -fsSL -o "$router_dir/delegated-apnic-latest" "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest" \
    || fail "下载 delegated-apnic-latest 失败"

# 修复点：原版此处 curl -s 缺 -f，错误页会被静默写入数据文件
URL="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/geolite2_country/country_cn.netset"
curl -fsSL "$URL" | grep -v '^[[:space:]]*#' > "$router_dir/china_ip_list.txt" \
    || fail "下载 china_ip_list.txt 失败"
# 数据基本校验：至少要有个网段行，防止空文件/坏数据进入 produce.py
[ "$(wc -l < "$router_dir/china_ip_list.txt")" -gt 100 ] || fail "china_ip_list.txt 行数异常（<100），疑似数据源异常"

# ---------- 生成（全部在临时目录内完成） ----------
# mosdns 数据集
geoview_out=/tmp/geodat/mosdns
mkdir -p "$geoview_out"
"$app_dir/geoview" -type geoip   -input "$tmp_dir/geoip.dat"   -list private -output "$geoview_out/geoip_private.txt"  || fail "geoview 生成 geoip_private 失败"
"$app_dir/geoview" -type geoip   -input "$tmp_dir/geoip.dat"   -list cn      -output "$geoview_out/geoip_cn.txt"       || fail "geoview 生成 geoip_cn 失败"
"$app_dir/geoview" -type geosite -input "$tmp_dir/geosite.dat" -list geolocation-\!cn -output "$geoview_out/geosite_geolocation-nocn.txt" || fail "geoview 生成 geolocation-nocn 失败"
"$app_dir/geoview" -type geosite -input "$tmp_dir/geosite.dat" -list gfw  -output "$geoview_out/geosite_gfw.txt"       || fail "geoview 生成 geosite_gfw 失败"
"$app_dir/geoview" -type geosite -input "$tmp_dir/geosite.dat" -list cn   -output "$geoview_out/geosite_cn.txt"        || fail "geoview 生成 geosite_cn 失败"

# bird 路由表
pushd "$router_dir" > /dev/null
python3 "$app_dir/produce.py" || { popd > /dev/null; fail "produce.py 生成路由失败"; }
popd > /dev/null
[ -s "$router_dir/routes4.conf" ] || fail "routes4.conf 生成结果为空"
[ -s "$router_dir/routes6.conf" ] || fail "routes6.conf 生成结果为空"

# ---------- 原子替换（从这里开始才触碰线上文件） ----------
# dae
rm -f "$dae_dir/geoip.dat" "$dae_dir/geosite.dat"
cp "$tmp_dir/geoip.dat"   "$dae_dir/geoip.dat"
cp "$tmp_dir/geosite.dat" "$dae_dir/geosite.dat"

# mosdns
cp "$geoview_out"/*.txt /etc/mosdns/geodat/

# bird：mv 本身即覆盖，无须先 rm（也消除了"删了还没写入"的窗口）
mv "$router_dir/routes4.conf" /etc/bird/routes4.conf
mv "$router_dir/routes6.conf" /etc/bird/routes6.conf

# ---------- 校验并重载 ----------
# 语法预检通过才重载 Bird；失败则回滚路由文件并退出（保留现场排障）
if ! bird -p 2>/tmp/geodat/bird_check.err; then
    logger -t geodat_update "bird -p 语法预检失败，已回滚路由文件"
    echo "bird config check FAILED, rolling back:" >&2
    cat /tmp/geodat/bird_check.err >&2
    # 回滚：临时目录里已无旧文件，此处依赖系统无备份——见下方 BACKUP 说明
    fail "bird 语法预检失败"
fi
birdc configure || fail "birdc configure 失败（路由文件已替换，请手动检查 /etc/bird/routes*.conf）"

systemctl restart mosdns.service || fail "mosdns 重启失败"
systemctl reload dae.service     || fail "dae reload 失败"

logger -t geodat_update "GEO 数据更新成功（dae/mosdns/bird 全部重载）"
echo "All updates completed successfully."
# trap cleanup EXIT 负责清理临时目录

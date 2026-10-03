#!/bin/bash
# ============================================================
# proxy_watchdog.sh —— 代理链路看门狗（BGP 兜底控制器）
# ============================================================
# 解决的问题：
#   dae 的分组策略（min_moving_avg 等）只能处理"部分节点挂"——
#   自动剔除死节点、切换活节点。但当【全部节点同时挂】或【dae 进程
#   假死】时，BGP 路由仍然把国外流量送进 Debian，Proxy 出不去，
#   国外流量直接黑洞。BFD 只能检测链路/整机死亡，检测不了这种情况。
#
# 工作原理（复用架构自身的回退原语——BGP 路由撤回）：
#   双探针判定，区分三种故障：
#     1. 代理链路死亡（国外探针挂 + 国内探针通）
#        → systemctl stop bird → BFD 亚秒级撤回路由
#        → RouterOS 全量直连兜底（普通国外站恢复可用）
#     2. 基础网络故障（国内探针也挂，PPPoE/上游问题）
#        → 与代理无关，不动 BGP，只记日志
#     3. 一切正常 → 什么都不做
#
#   紧急模式下的恢复探测（关键设计）：
#     路由撤回后国外探针走直连，而 gstatic 被 GFW 墙，
#     探针会永远失败——无法由此得知节点恢复。
#     因此采用"试探恢复"：每 RETRY_INTERVAL 秒临时拉起 bird，
#     等 RETRY_WAIT 秒（BGP 会话重建 + 3 万条路由重灌）后探测，
#     成功则保持正常模式，失败则再次撤回。
#     代价：试探窗口内（约 15 秒）国外流量会经死代理失败一次。
# ============================================================

# ------------------- 参数 -------------------
PROBE_PROXY_URL="https://www.gstatic.com/generate_204"  # 国外探针：GFW 墙内不可达，只能走代理——正好测全链路
PROBE_DIRECT_URL="https://www.baidu.com"               # 国内探针：测基础网络（含 DNS）是否正常
FAIL_THRESHOLD=3     # 连续失败 N 次才判定代理死亡（3 × 30s ≈ 1.5 分钟，防抖动）
CHECK_INTERVAL=30    # 正常状态下的探测间隔（秒）
RETRY_INTERVAL=300   # 紧急状态下的试探恢复间隔（秒）
RETRY_WAIT=15        # 试探恢复时等待 BGP 重建+探测的窗口（秒）
STATE_FILE=/run/proxy_watchdog_state
WATCHDOG_DIR=/opt/watchdog
LOG_FILE="$WATCHDOG_DIR/watchdog.log"      # 实时日志（logrotate 轮转）
EVENTS_FILE="$WATCHDOG_DIR/events.log"     # 故障历史（只增不减）
EMERGENCY_SINCE_EPOCH=""                   # 进入紧急模型的 epoch 秒（计算持续时长用）
# ---------------------------------------------

mkdir -p "$WATCHDOG_DIR"

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {
    local line="[$(now)] $1"
    echo "$line" >> "$LOG_FILE"
    logger -t proxy_watchdog "$1"
}

event() {
    # 关键事件：写入只增不减的历史文件（查看故障史用）
    echo "$1" >> "$EVENTS_FILE"
}

probe_proxy() {
    # -m 超时给足 DNS+代理握手时间；204/200/3xx 都算通
    curl -4 -m 8 -o /dev/null -s -w '%{http_code}' "$PROBE_PROXY_URL" 2>/dev/null | grep -qE '^[23]'
}

probe_direct() {
    curl -4 -m 5 -o /dev/null -s -w '%{http_code}' "$PROBE_DIRECT_URL" 2>/dev/null | grep -qE '^[23]'
}

enter_emergency() {
    log "代理链路死亡（连续 ${FAIL_THRESHOLD} 次国外探针失败且基础网络正常），撤回 BGP 路由，国外流量回落直连"
    systemctl stop bird.service
    echo EMERGENCY > "$STATE_FILE"
    EMERGENCY_SINCE_EPOCH=$(date '+%s')
    event "EMERGENCY $(now) 代理链路死亡（连续${FAIL_THRESHOLD}次国外探针失败）"
}

recover_normal() {
    log "代理链路已恢复，重新宣告 BGP 路由"
    systemctl start bird.service
    echo NORMAL > "$STATE_FILE"
    if [ -n "$EMERGENCY_SINCE_EPOCH" ]; then
        local dur=$(( $(date '+%s') - EMERGENCY_SINCE_EPOCH ))
        event "RECOVER   $(now) 紧急模式持续了 $((dur/60))分$((dur%60))秒"
        EMERGENCY_SINCE_EPOCH=""
    else
        event "RECOVER   $(now) 持续时长未知（服务重启丢失起始时刻）"
    fi
}

# ------------------- 主循环 -------------------
[ -f "$STATE_FILE" ] || echo NORMAL > "$STATE_FILE"

fail=0
while true; do
    state=$(cat "$STATE_FILE" 2>/dev/null || echo NORMAL)

    if [ "$state" = "NORMAL" ]; then
        if probe_proxy; then
            fail=0
        elif probe_direct; then
            fail=$((fail + 1))
            log "国外探针失败（$fail/$FAIL_THRESHOLD），基础网络正常，疑似代理链路故障"
            if [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
                enter_emergency
                fail=0
            fi
        else
            # 国内探针也挂：基础网络故障（PPPoE/上游），与代理无关，不切换
            log "基础网络不可达（国内外探针均失败），跳过代理判定"
            fail=0
        fi
        sleep "$CHECK_INTERVAL"

    else
        # EMERGENCY：等待一个周期后试探恢复
        sleep "$RETRY_INTERVAL"
        log "试探恢复：临时拉起 bird 并探测代理链路"
        systemctl start bird.service
        sleep "$RETRY_WAIT"
        if probe_proxy; then
            recover_normal
        else
            log "试探失败（代理链路仍死亡），继续紧急模式（直连兜底）"
            systemctl stop bird.service
        fi
    fi
done

# 方案配置全解：设计说明、理由、优势与劣势

> 本文基于仓库内全部配置文件（Bird BGP、RouterOS、dae、mosdns、iptables、数据更新脚本）逐项解读配置内容、设计理由，并在文末给出整体方案的优势与劣势分析。
>
> 快速上手部署请看 [README.md](README.md)；本文面向想理解"为什么这么配"的读者。

---

## 1. 方案总览

### 1.1 架构与职责划分

```
内网设备 ──> RouterOS (10.0.0.1 / fd00::1, AS 65001, 主路由)
                │  PPPoE 拨号、NAT、DHCP、防火墙
                │  eBGP 双栈会话 (hold-time 30s + BFD 亚秒级)
                ▼
            Debian 旁路由 (10.0.0.2 / fd00::2, AS 65002)
                │  Bird 2   —— 向主路由宣告"非中国大陆 IP 段"
                │  dae      —— 透明代理（分流执行者）+ 劫持全部 53 端口 DNS
                │  mosdns   —— DNS 国内外分流解析
                │  proxy_watchdog —— 代理链路看门狗（节点全挂时撤路由回落直连）
                ▲
                │ 上游 10.0.0.2:53（实际被 dae 劫持接管）
            AdGuard Home (10.0.0.4 / fd00::4, 广告过滤, 客户端 DNS 入口)
                ▲
                │ DNS 指向 10.0.0.4
            内网设备
```

**DNS 解析链路**（本方案的域名体系，详见第 5 节）：

```
客户端 (DNS = 10.0.0.4)
  → AdGuard Home：第一步广告过滤
  → 上游 10.0.0.2:53 —— Debian 上无进程监听 53 端口，流量被 dae 劫持
  → dae dns 模块 (dns.dae 策略)：节点域名→alidns 直连 / 国外 AAAA、HTTPS 记录拒绝
  → mosdns (127.0.0.1:5333)：国内外分流解析
       ├─ 国内域名 → 阿里/DNSPod 直连（带 ECS）
       └─ 国外域名 → Google/Cloudflare（流量被 dae 送代理，无污染）
                     └─ 双双失败时代理链路已死 → 回落阿里/DNSPod 直连解析（容灾兜底）
```

核心思想：**"国内直连，国外代理"，用 BGP 在网络层完成分流**。Debian 通过 eBGP 把全世界（减去中国大陆、减去保留地址）的 IP 段宣告给 RouterOS。RouterOS 的路由表自然形成"国内走 PPPoE 直连、国外下一跳 10.0.0.2"的格局，内网设备**无须修改网关或 DNS 以外的任何设置**。

### 1.2 仓库文件清单

| 目录/文件                                           | 用途                                           |
| :---------------------------------------------- | :------------------------------------------- |
| `brid/brid-bgp.conf`                            | Bird 2 主配置（eBGP 会话、BFD、导出过滤）                   |
| `RouterOS/bgp_build.rsc.sh`                     | RouterOS 侧 BGP + BFD + 策略路由 + 防火墙标记总配置         |
| `RouterOS/ipv4.sh` / `ipv6.sh`                  | PPPoE 重拨后自动刷新 bypass 表中公网 IP 路由的脚本           |
| `dae/config.dae` + `dae/config.d/*.dae`         | dae 透明代理配置（global / dns / routing / node 四片） |
| `mosdns/config_custom.yaml`                     | mosdns 主配置（DNS 分流主流程 + 国外解析国内兜底）             |
| `mosdns/dns.yaml`                               | DNS 上游定义（Google/Cloudflare/阿里/DNSPod）        |
| `mosdns/dat_exec.yaml`                          | 数据集、缓存、ECS、TTL 插件                            |
| `iptables/rules.v4` / `rules.v6`                | 旁路由回程 NAT（MASQUERADE）                        |
| `Shellscript/geodat_update.sh`                  | 一键更新 dae/mosdns GEO 数据 + 生成 Bird 路由表（原子化、带校验与并发锁） |
| `Shellscript/produce.py`                        | 由 IANA/APNIC 数据计算"非中国大陆"路由段                  |
| `Shellscript/proxy_watchdog.sh` + `.service` + `.logrotate` | 代理链路看门狗三件套（部署于 `/opt/watchdog`，节点全挂时撤路由回落直连） |
| `brid/brid-ospf.conf`、`RouterOS/ospf_build.rsc` | 旧 OSPF 方案存档，现已弃用                             |

---

## 2. RouterOS 侧配置详解

### 2.1 BGP 动态路由（`bgp_build.rsc.sh`）

**配置内容（`bgp_build.rsc.sh` 完整内容，本地变量定义见 README §3.2）：**

```
## BGP 动态路由配置
/routing id add comment=Gateway disabled=no id=$local_ipv4_addr name=Gateway select-dynamic-id=only-vrf

## 创建 BGP 实例
/routing bgp instance add as=65001 name=bird router-id=$local_ipv4_addr routing-table=main

## 建立 BGP 邻居会话
# use-bfd=yes：为会话启用 BFD（注意参数名是 use-bfd，短名 bfd 不被接受）
/routing bgp connection
add afi=ip hold-time=30s input.filter=bird-v4-in instance=bird keepalive-time=10s local.address=$local_ipv4_addr .role=ebgp name=bird-v4 remote.address=$gateway_ipv4_addr .as=65002 routing-table=main use-bfd=yes
add afi=ipv6 hold-time=30s input.filter=bird-v6-in instance=bird keepalive-time=10s local.address=$local_ipv6_addr .role=ebgp name=bird-v6 remote.address=$gateway_ipv6_addr .as=65002 routing-table=main use-bfd=yes

## BFD 配置
# RouterOS 默认禁止一切 BFD 会话（未显式允许的接口一律 forbidden），必须先在此放行内网网桥
# 参数与 Debian Bird 侧对称（100ms × multiplier 3 ≈ 300ms 检测窗口）
/routing bfd configuration add interfaces=$interface_name min-rx=100ms min-tx=100ms multiplier=3 comment=Gateway

## BGP 入方向路由过滤规则
/routing filter rule
add chain=bird-v4-in rule="if (dst == 0.0.0.0/0) { reject } else { accept }"
add chain=bird-v6-in rule="if (dst == ::/0) { reject } else { accept }"

## 策略路由表与规则
/routing table add comment=Gateway disabled=no fib name=bypass
/routing rule add action=lookup-only-in-table comment=Gateway disabled=no routing-mark=bypass table=bypass

## 防火墙流量标记
# IPv4 标记：来自旁路网关且目标不是本地网段的流量，打上 bypass 路由标记
/ip firewall mangle add action=mark-routing chain=prerouting comment=Gateway dst-address=!$local_ipv4_subnet in-interface=$interface_name new-routing-mark=bypass src-address=$gateway_ipv4_addr
# IPv6 标记：同上，处理来自旁路网关 IPv6 ULA 地址的外网流量
/ipv6 firewall mangle add action=mark-routing chain=prerouting comment=Gateway dst-address=!$local_ipv6_subnet in-interface=$interface_name new-routing-mark=bypass src-address=$gateway_ipv6_addr

## IPv4 路由条目（bypass 表）
/ip route
add comment=Gateway-LAN   disabled=no distance=1 dst-address=$local_ipv4_subnet gateway=$interface_name routing-table=bypass scope=30 target-scope=10
add comment=Gateway-PPPOE disabled=no distance=1 dst-address=0.0.0.0/0 gateway=$pppoe_name routing-table=bypass scope=30 target-scope=10
add comment=Gateway-INT   dst-address=$internet_ipv4 gateway=$pppoe_name routing-table=bypass
add comment=Gateway-WAN   disabled=no distance=1 dst-address=192.168.1.1/32 gateway=ether1 routing-table=bypass scope=30 target-scope=10

## IPv6 路由条目（bypass 表）
/ipv6 route
add comment=Gateway-LLA-LAN   disabled=no distance=1 dst-address=fe80::/64 gateway=$interface_name pref-src="" routing-table=bypass scope=10 target-scope=5
add comment=Gateway-LLA-PPPoE disabled=no distance=1 dst-address=fe80::/64 gateway=$pppoe_name pref-src="" routing-table=bypass scope=10 target-scope=5
add comment=Gateway-ULA       disabled=no distance=1 dst-address=$local_ipv6_subnet gateway=$interface_name pref-src="" routing-table=bypass scope=10 target-scope=5
add comment=Gateway-PPPoE     disabled=no distance=1 dst-address=::/0 gateway=$pppoe_name pref-src="" routing-table=bypass scope=30 target-scope=10
add comment=Gateway-INT       dst-address=$internet_ipv6 gateway=$interface_name routing-table=bypass
add comment=Gateway-LLA-WAN   disabled=no distance=1 dst-address=fe80::/64 gateway=ether1 pref-src="" routing-table=bypass scope=10 target-scope=5
```

> 注意：此脚本为"首次建库"形态，对象均为 `add`，在已配置的现网机器上整段重跑会报"已存在"；增量更新请参考 README §3.3 的分步命令。

**设计理由：**

- **选 BGP 而不是 OSPF**：本方案的本质是"把约 3 万条静态明细路由灌进主路由"。OSPF 是链路状态协议，为了传递这几万条外部路由要维护完整的 LSDB、跑 SPF，对旁路由这种"单点对外"的拓扑是杀鸡用牛刀；BGP 天生就是为"携带海量明细路由、按策略过滤"设计的，eBGP 会话一断（hold-time 30s）路由立刻整体撤回，故障语义清晰。
- **私有 ASN（65001/65002）**：家庭网络不需要公网 ASN，eBGP 私有自治域即可完成"带 AS 校验的点对点路由注入"，比 iBGP 少掉 next-hop 不可达的坑。
- **两条独立会话（IPv4/IPv6 分开）**：IPv4 走 v4 地址、IPv6 走 ULA 地址建立会话，互不依赖。任何一族出问题不影响另一族。
- **hold-time 30s / keepalive 10s**：默认 180s 对家用太迟钝。30 秒内检测到旁路由宕机并撤回路由，配合"撤回即全量直连"，故障窗口很短。
- **BFD 亚秒级故障检测（`bfd on`）**：hold-time 依赖 TCP 会话超时，对"网口 up 但链路半死"的静默故障反应仍是 30s 起步；BFD 在 `enp1s0` 上以 100ms×3 探测（约 300ms 判死），把这类故障的收敛压到亚秒级。注意 RouterOS 侧两个坑：BFD 默认全禁须先 `/routing bfd configuration` 放行 Bridge；BGP 连接参数名是 `use-bfd=yes`（短名 `bfd` 不被接受）。
- **入方向 filter 拒绝默认路由**：BGP 万一宣告 `0.0.0.0/0` 会直接劫持主路由的默认网关，是本方案最危险的故障模式，因此在 RouterOS 和 Bird 两端（出、入双向）都显式拒绝。
- **routing-table=main**：BGP 路由直接进主表参与常规选路，客户端无须任何配合。

### 2.2 策略路由与防火墙标记（防回环）

**配置内容**（完整命令见 §2.1 代码块中"策略路由表与规则"与"防火墙流量标记"两节，此处不重复列出）：

**设计理由：**

这是全方案**最关键、也最容易被忽略**的一步。流量路径是：客户端 → RouterOS →（BGP 路由）→ Debian 代理 → 回到 RouterOS → PPPoE 出网。如果不加干预，Debian 发回来的包在 RouterOS 上查主表，又会命中 BGP 注入的"国外路由"再送回 Debian，**形成路由环路**。

解法：凡是从旁路由 (`10.0.0.2` / `fd00::2`) 进来、目标不是本地网段的流量，打上 `bypass` 路由标记，强制在 `bypass` 表里查路由——该表里只有"PPPoE 默认路由 + 少量手工明细"，等于宣告"这些包是我已经处理过的，只许直连出去"。

- 用 `src-address` 精确匹配旁路由本机地址，不影响内网其他设备；
- `lookup-only-in-table`（而非 `lookup`）保证标记流量**绝不回落**主表，杜绝一切绕回 BGP 路由的可能。

### 2.3 bypass 表基础路由

表中手工放置：LAN 回程、PPPoE 默认路由（v4/v6）、公网 IP 明细、光猫管理地址（`192.168.1.1`，走 `ether1`）、IPv6 LLA/ULA 路由。

**设计理由：**

- **默认路由指向 PPPoE**：保证被标记流量一定能出网；
- **光猫与 LLA 路由**：Debian 上的 dae 会直连访问国内外服务，其中"直连"的流量经 RouterOS 出去，若 bypass 表里没有这些明细，运维从 Debian 上 ping 光猫、 traceroute 检查链路时会出现怪异路径；
- **公网 IP 明细（`Gateway-INT`）**：见下节。

### 2.4 PPPoE 重拨自动刷新脚本（`ipv4.sh` / `ipv6.sh`）

**`ipv4.sh` 完整内容：**

```
# 定义网关接口
:local gatewayInterface "pppoe-out1"
:log info ("正在使用网关接口：" . $gatewayInterface)

# 获取pppoe-out1的远程网络地址
:local remoteAddress [/ip address get [find where interface=$gatewayInterface] network]
:log info ("获取到的远程网络地址为：" . $remoteAddress)

# 检查是否成功获取到远程地址
:if ($remoteAddress != "") do={
    # 删除旧路由（按 comment 精确匹配）
    :local oldRouteId [/ip route find where comment="Gateway-INT" and routing-table="bypass"]
    :if ($oldRouteId != "") do={
        /ip route remove $oldRouteId
        :log info ("已成功删除旧路由")
    } else={
        :log info "未找到需要删除的旧路由"
    }
    # 添加新路由
    /ip route add dst-address=$remoteAddress gateway=$gatewayInterface routing-table="bypass" comment="Gateway-INT"
    :log info "新路由已成功添加"
} else={
    :log error "未能获取到远程网络地址"
}
```

**`ipv6.sh` 完整内容：**

```
# 定义 IPv6 地址池名称
:local ipv6PoolName "Public"
:local gatewayv6Interface "pppoe-out1"

# 获取 IPv6 地址池中的前缀
:local ipv6Prefix [/ipv6/pool get [find where name=$ipv6PoolName] prefix]

:if ($ipv6Prefix != "") do={
    # 将前缀中的 /60 替换为 /64
    :local ipv6PrefixModified [:pick $ipv6Prefix 0 [:find $ipv6Prefix "/"]]
    :set ipv6PrefixModified ($ipv6PrefixModified . "/64")

    # 删除已有的相同前缀的路由，避免重复
    # 注意：此处用 dst-address~"240" 正则匹配较脆弱（前缀不在 2400::/4 时漏删/误删），
    # 建议改为 ipv4.sh 同款按 comment="Gateway-INT" 精确匹配
    /ipv6/route remove [find dst-address~"240" and routing-table="bypass"]

    # 添加新的路由条目到 bypass 路由表
    /ipv6/route add dst-address=$ipv6PrefixModified gateway=$gatewayv6Interface routing-table="bypass" comment="Gateway-INT"
} else={
    :put "未找到 IPv6 地址池中的前缀"
}
```

**设计理由：**

PPPoE 是动态 IP，`114.114.114.114` 这类写在 `bgp_build.rsc.sh` 里的"公网 IP 路由"只是初次建表用的示意值；这两个脚本通过 RouterOS 的 scheduler/PPPoE 脚本钩子在每次重拨后运行，保证 bypass 表里的公网明细始终与实际地址一致，且全程带日志、先删后加、失败安全（取不到地址就只报错不动表）。

---

## 3. Debian 侧配置详解

### 3.1 Bird 2（`brid/brid-bgp.conf`）

**完整配置：**

```
log syslog all;

router id 10.0.0.2;

define ROS_AS  = 65001;
define BIRD_AS = 65002;

protocol device {
  scan time 10;
  interface "-dae*";
}

protocol kernel {
  ipv4 {
    import none;
    export none;
  };
}

protocol kernel {
  ipv6 {
    import none;
    export none;
  };
}

# BFD 快速故障检测：仅在物理网卡上运行（100ms × 3 ≈ 300ms 判死）
protocol bfd {
  interface "enp1s0" {
    min rx interval 100 ms;
    min tx interval 100 ms;
    multiplier 3;
  };
}

protocol static {
  ipv4;
  include "/etc/bird/routes4.conf";
}

protocol static {
  ipv6;
  include "/etc/bird/routes6.conf";
}

filter export_foreign4 {
  if net = 0.0.0.0/0 then reject;

  if source = RTS_STATIC then accept;
  reject;
}

filter export_foreign6 {
  if net = ::/0 then reject;

  if source = RTS_STATIC then accept;
  reject;
}

# IPv4 eBGP
protocol bgp ros4 {
  local 10.0.0.2 as BIRD_AS;
  neighbor 10.0.0.1 as ROS_AS;

  hold time 30;
  keepalive time 10;

  bfd on;

  ipv4 {
    import none;
    export filter export_foreign4;
    next hop self;
  };
}

# IPv6 eBGP
protocol bgp ros6 {
  local fd00::2 as BIRD_AS;
  neighbor fd00::1 as ROS_AS;

  hold time 30;
  keepalive time 10;

  bfd on;

  ipv6 {
    import none;
    export filter export_foreign6;
    next hop self;
  };
}
```

**配置内容与理由逐条对照：**

| 配置                                                     | 内容                                                                   | 理由                                                            |
| :----------------------------------------------------- | :------------------------------------------------------------------- | :------------------------------------------------------------ |
| `protocol device` (interface "-dae*")                  | 扫描**除 `dae*` 外的所有**接口                                                | 减号是排除语义：dae 创建的 `dae*` 虚拟接口被排除；Bird 依靠 device 协议的接口地址数据解析 eBGP 直连邻居（`10.0.0.1`/`fd00::1` 在 `enp1s0` 上），因此必须感知物理网卡         |
| `protocol kernel { import none; export none; }`        | 双向均不同步内核表（原配置中的 `learn` 因 `import none` 实际不生效，已移除）                  | Bird 只做"路由宣告者"，不接管 Debian 本机内核表；直连邻居可达性靠 device 协议而非内核路由，不学习也不影响会话建立   |
| `protocol static` + `include routes4/6.conf`           | 近 3 万条 `route x.x.x.x via "enp1s0"` 静态路由                             | 分流数据的唯一来源；`include` 把大文件与主配置解耦，更新数据只重载 include 即可             |
| `export_foreign4/6` filter                             | `if net = 0.0.0.0/0 then reject; if source = RTS_STATIC then accept` | **双重保险**：绝不让默认路由出门；只导出静态路由，防止内核路由被无意宣告出去                      |
| `next hop self`                                        | 所有导出路由下一跳改写为本机                                                       | eBGP 跨跳场景下确保下一跳一定可达（RouterOS 无须依赖 Bird 声称的原始下一跳）              |
| `hold time 30 / keepalive 10`                          | 与 RouterOS 侧对称                                                       | 宕机检测保底窗口 30 秒（BFD 接管日常检测后，hold-time 退化为兜底）                                         |
| `protocol bfd` + 会话 `bfd on`                          | `enp1s0` 上 100ms × multiplier 3（≈300ms 判死）                            | **亚秒级故障检测**：覆盖"网口 up 但链路半死"的静默故障。RouterOS 侧须两步配合：`/routing bfd configuration` 放行接口（默认全禁）+ BGP 连接 `use-bfd=yes` |
| `import none`（BGP 通道）                                  | 不接收 RouterOS 的任何路由                                                   | 旁路由只需要"说"不需要"听"；默认网关由 `/etc/network/interfaces` 静态指向 10.0.0.1 |

**为什么 routes 文件里 next hop 全是 `enp1s0`？** 这些静态路由的用途不是指导 Debian 本机转发（那是 dae 的 tproxy 的事），而只是作为"被导出的路由对象"存在——Bird 导出时统一执行了 `next hop self`，本机内核表里这些路由实际不参与转发（kernel 协议 `export none`）。

### 3.2 dae（`config.dae` + `config.d/`）

dae 采用 `include` 分片管理：`dns.dae`（DNS 策略）、`routing.dae`（分流规则）、`node.dae`（节点与分组）。

**主配置 `config.dae` 完整内容：**

```
include {
  /etc/dae/config.d/*.dae
}
global {
  tproxy_port: 12345
  tproxy_port_protect: true
  pprof_port: 0
  so_mark_from_dae: 0
  log_level: warn
  lan_interface: enp1s0
  wan_interface: auto
  auto_config_kernel_parameter: true
  tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1'
  tcp_check_http_method: HEAD
  udp_check_dns: 'dns.google:53,8.8.8.8'
  check_interval: 30s
  check_tolerance: 50ms
  dial_mode: domain
  allow_insecure: false
  sniffing_timeout: 100ms
  tls_implementation: tls
  tls_fragment: false
  tls_fragment_length: '50-100'
  tls_fragment_interval: '10-20'
  bootstrap_resolver: '223.5.5.5:53'
  fallback_resolver: '223.5.5.5:53'
  # Hysteria2 Bandwidth（全局默认，建议挪到 node 级按节点带宽分别设置）
  bandwidth_max_tx: '100 mbps'
  bandwidth_max_rx: '500 mbps'
}
```

**`dns.dae` 完整内容：**

```
dns {
  fixed_domain_ttl {
    tw.example.com: 0
  }
  upstream {
    alidns: 'udp://223.5.5.5:53'
    mosdns: 'tcp+udp://127.0.0.1:5333'
  }
  routing {
    request {
      node(name_keyword: tw_hy2) -> alidns
      node(name_keyword: hk_hy2) -> alidns
      node(name_keyword: us_hy2) -> alidns
      qtype(aaaa) && !qname(geosite:cn) -> reject
      qtype(https) -> reject
      fallback: mosdns
    }
  }
}
```

**`node.dae` 完整内容：**

```
node {
  hk_hy2: 'hysteria2://passwd@hk.example.com:443/?sni=hk.example.com'
  tw_hy2: 'hysteria2://passwd@tw.example.com:443/?sni=tw.example.com'
  us_hy2: 'hysteria2://passwd@us.example.com:443/?sni=us.example.com'
}

group {
  Proxy {
    filter: name(hk_hy2)
    filter: name(tw_hy2, us_hy2) [add_latency: 5000ms]
    policy: min_moving_avg
    check_interval: 30s
    check_tolerance: 50ms
  }
}
```

**`routing.dae` 完整内容：**

```
routing {
  ### System / DNS loop protection
  pname(mosdns) -> must_rules
  pname(NetworkManager) -> direct
  pname(systemd-resolved) -> direct

  ### Alidns / Dnspod
  dip(223.5.5.5, 223.6.6.6, '2400:3200::1', '2400:3200:baba::1') -> direct
  domain(suffix:dns.alidns.com) -> direct
  dip(119.29.29.29, '2402:4e00::') -> direct
  domain(suffix:doh.pub) -> direct
  domain(suffix:dot.pub) -> direct

  ### Multicast / Broadcast
  dip(224.0.0.0/3, 'ff00::/8') -> direct(must)

  ### Special DNS client
  sip(10.0.0.4) && l4proto(udp) && dport(53) -> direct

  ### Traceroute
  l4proto(udp) && dport(33434-33534) -> direct

  ### Private / LAN
  dip(geoip:private) -> direct
  dip(10.0.0.0/24, 'fd00::/64') -> direct

  ### ZeroTier
  sip(10.0.0.3, 'fd00::3') -> direct
  dip(10.10.0.0/24) -> direct
  sip(10.10.0.0/24) -> direct

  ### BT/PT
  dscp(0x4) -> direct

  ### Proxy node domains
  domain(full: hk.example.com) -> direct(must)
  domain(full: tw.example.com) -> direct(must)
  domain(full: us.example.com) -> direct(must)

  ### QUIC
  l4proto(udp) && dport(443) -> block

  ### Explicit proxy DNS
  ## Google
  domain(suffix: dns.google) -> Proxy
  dip(8.8.8.8) -> Proxy
  dip(8.8.4.4) -> Proxy
  ## Cloudflare
  domain(suffix: cloudflare-dns.com) -> Proxy
  domain(suffix: one.one.one.one) -> Proxy
  dip(1.1.1.1) -> Proxy
  dip(1.0.0.1) -> Proxy

  ### Explicit Proxy Domains
  domain(geosite:gfw) && ipversion(4) -> Proxy

  ### CN domains using foreign IP
  # domain(geosite:cn) && !dip(geoip:cn) && ipversion(4) -> Proxy

  ### China IP
  dip(geoip:cn) -> direct

  ### Foreign IPv6
  ipversion(6) -> block

  ### China domains
  domain(geosite:cn) -> direct

  ### Fallback
  fallback: Proxy
}
```

#### global（config.dae）

| 配置                                           | 理由                                                                                                    |
| :------------------------------------------- | :---------------------------------------------------------------------------------------------------- |
| `tproxy_port: 12345`                         | 透明代理监听端口，配合 `tproxy_port_protect` 防端口被其他进程抢占                                                          |
| `lan_interface: enp1s0; wan_interface: auto` | 单网卡旁路由场景：lan 即物理网卡，wan 自动检测出网方向                                                                       |
| `dial_mode: domain`                          | dae 的招牌能力——**域名分流**：在传输层嗅探 SNI/Host，把"按域名"的规则施加到"按 IP"被路由过来的流量上，弥补 BGP 只认 IP 的短板（见 5.1 的 DNS-IP 联动设计） |
| `tcp_check_url` / `udp_check_dns` + 30s 间隔   | 节点健康检查，驱动分组自动切换                                                                                       |
| `tls_implementation: tls`（fragment 关闭）       | TLS 分片是抗 SNI 阻断的备用手段，默认关闭以避免无谓的性能损耗与指纹异常                                                              |
| `bootstrap/fallback_resolver: 223.5.5.5`     | dae 自身解析节点域名用国内 DNS——节点域名本来就该直连解析，避免"解析代理节点域名本身还要走代理"的死循环                                             |

#### routing.dae（分流规则，按自上而下顺序匹配）

| 规则块             | 内容                                                            | 理由                                                                                                     |
| :-------------- | :------------------------------------------------------------ | :----------------------------------------------------------------------------------------------------- |
| 系统进程直连          | `pname(mosdns/NetworkManager/systemd-resolved) -> must_rules` | **防 DNS 死循环**：dae 对匹配普通出站的 DNS 一律劫持，若劫持 mosdns 的上游查询会形成 mosdns→dae→mosdns 无限递归。`must_rules` 的准确语义是"该来源的 DNS 不被劫持 + 流量继续向下匹配后续规则"——于是 mosdns 查国内上游命中 alidns 直连规则、查国外上游命中 `dip(8.8.8.8) -> Proxy` 走代理，分流逻辑完整保留 |
| 国产公共 DNS 直连     | 阿里/DNSPod 全部 IP 与域名直连                                         | 这些是 mosdns 的上游，同理必须直连                                                                                  |
| 组播/广播 `must`    | `224.0.0.0/3, ff00::/8`                                       | 局域网发现协议绝不能进代理                                                                                          |
| AdGuard Home 例外 | `sip(10.0.0.4) && udp && 53 -> direct`                        | 注：dae 对普通出站的 DNS 一律劫持，该规则**并不能**让 AdGuard 的查询绕过劫持（绕过反而会破坏"上游 10.0.0.2:53 由 dae 接管"的设计）；它实际只兜底标记 AdGuard 的非 DNS 流量直连，近似死代码，可视为语义说明保留 |
| Traceroute 端口直连 | udp 33434-33534                                               | 便于排障时 traceroute 反映真实路径                                                                                |
| 私网/ZeroTier 直连  | `geoip:private`、`10.10.0.0/24` 等                              | 内网与自建overlay 网络不进代理                                                                                    |
| BT/PT 直连        | `dscp(0x4) -> direct`                                         | 下载类流量标记 DSCP 后直连，避免代理节点被 PT 站封                                                                         |
| 节点域名直连 `must`   | `hk/tw/us.example.com`                                        | 连接代理节点本身的流量必须直连，防止自引用                                                                                  |
| QUIC 阻断         | `udp 443 -> block`                                            | 强制网站回落 TCP+TLS——HTTP/3 UDP 流量对部分代理协议（尤其 hysteria2 之外）不友好且无法被 TCP 侧规则精细管理                               |
| 显式代理 DNS        | Google/Cloudflare 的 DoH/DoT 域名与 IP → Proxy                    | 用户手动改用 8.8.8.1 之类时，尊重意图并保证其经代理可达                                                                       |
| gfw 域名走代理       | `domain(geosite:gfw) && ipversion(4) -> Proxy`                | 已知被墙域名直接代理，跳过直连尝试                                                                                      |
| 国内 IP/域名直连      | `dip(geoip:cn)`、`domain(geosite:cn)`                          | BGP 已把国外段送去代理，这里是 dae 侧的第二道国内判定（域名级，更细）                                                                |
| 国外 IPv6 阻断      | `ipversion(6) -> block`                                       | 代理节点为 IPv4，避免国外 v6 流量绕过代理直接出 PPPoE 造成 **IPv6 泄漏**；国内 IPv6 已在前面的直连规则放行                                  |
| 兜底              | `fallback: Proxy`                                             | 未命中任何规则的流量默认走代理（保守策略）                                                                                  |


#### dns.dae

dae 会**劫持所有流经的明文 DNS（53 端口，UDP/TCP）**——包括 AdGuard Home 发往 `10.0.0.2:53` 上游的查询（Debian 上并无进程监听 53 端口），以及任何客户端绕过 AdGuard 直发公共 DNS 的查询。被劫持的请求统一交由本文件的 dns routing 策略处理：

- 节点域名（`node(name_keyword: *hy2)`）的解析固定走阿里 DNS 直连；
- `qtype(aaaa) && !qname(geosite:cn) -> reject`：**拒绝国外域名的 AAAA 记录**——与 routing 中"国外 IPv6 block"呼应，从 DNS 根源掐掉 v6 泄漏；
- `qtype(https) -> reject`：过滤 HTTPS/SVCB 记录，防止浏览器绕过 DNS 分流策略（ECH/Alt-Svc）；
- 其余（兜底）查询全部转发给 mosdns（`127.0.0.1:5333`），由 mosdns 完成国内外分流解析；
- `fixed_domain_ttl { tw.example.com: 0 }`：对频繁变更解析的节点域名禁用缓存。

> dae 劫持 DNS 是 `dial_mode: domain` 域名分流的前提：只有 DNS 经过 dae，它才能建立"域名 ↔ IP"映射，把域名规则施加到后续连接上。

#### node.dae

三个 hysteria2 节点（hk/tw/us，占位域名）组成一个 `Proxy` 分组：hk 为主，tw/us 作备份（`add_latency: 5000ms` 惩罚），策略 `min_moving_avg` 按最小移动平均延迟自动选节点，30s 检查间隔、50ms 容差防止频繁抖动切换。**设计意图：单分组、自动故障转移、防震荡**。

### 3.3 mosdns（三个 yaml）

**`dns.yaml`（上游）关键配置：**

```
plugins:
  # 国外组：Google（主，DoH/DoT 双路 × 2 IP）+ Cloudflare（备）
  - tag: google
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "https://dns.google/dns-query"    # DoH
          dial_addr: "8.8.8.8"
        - addr: "https://dns.google/dns-query"
          dial_addr: "8.8.4.4"
        - addr: "tls://dns.google"                # DoT（pipeline 复用连接）
          dial_addr: "8.8.8.8"
          enable_pipeline: true
        - addr: "tls://dns.google"
          dial_addr: "8.8.4.4"
          enable_pipeline: true
  # cloudflare 同构：1.1.1.1 / 1.0.0.1，tls://one.one.one.one

  # 国内组：阿里（主，DoQ/DoH/DoT × v4/v6 双栈共 12 条）
  - tag: ali
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "quic://dns.alidns.com"          # DoQ 优先——QUIC 握手快于逐查询 TLS
          dial_addr: "223.5.5.5"
        # ... 223.6.6.6 / 2400:3200::1 / 2400:3200:baba::1
        # https://dns.alidns.com/dns-query（同上 4 个 dial_addr）
        # tls://dns.alidns.com enable_pipeline: true（同上 4 个 dial_addr）
  # dnspod 备用：https://doh.pub/dns-query（其余线路被注释，建议启用 119.29.29.29 那条）

  # 响应拒绝插件：reject_2 (SERVFAIL) / reject_3 (NXDOMAIN) / reject_5 (REFUSED)
```

**`dat_exec.yaml`（数据与插件）关键配置：**

```
plugins:
  # 六个数据集
  - tag: geoip_private     # ip_set:      /etc/mosdns/geodat/geoip_private.txt
  - tag: geoip_cn          # ip_set:      /etc/mosdns/geodat/geoip_cn.txt
  - tag: geosite_cn        # domain_set:  /etc/mosdns/geodat/geosite_cn.txt
  - tag: whitelist         # domain_set:  /etc/mosdns/rule/whitelist.txt
  - tag: geosite_gfw       # domain_set:  /etc/mosdns/geodat/geosite_gfw.txt
  - tag: geosite_location-nocn  # domain_set: /etc/mosdns/geodat/geosite_geolocation-nocn.txt
  - tag: no_cache_domains  # domain_set:  /etc/mosdns/rule/no_cache.txt

  # 全局缓存（落盘 + lazy cache）
  - tag: cache_wan
    type: cache
    args:
      size: 131072
      lazy_cache_ttl: 86400
      dump_file: /etc/mosdns/wan_cache.dump
      dump_interval: 600

  # ECS 处理
  - tag: no_ecs            # ecs_handler: 国外查询隐藏客户端子网
    args: { forward: false, send: false, mask4: 24, mask6: 48 }
  - tag: ecs_cn            # ecs_handler: 国内查询附加固定子网（preset 需改成自己运营商公网 IP）
    args: { forward: false, preset: "123.123.123.123", send: true, mask4: 24, mask6: 48 }

  # TTL 控制：ttl_1m (60) / ttl_5m (300) / ttl_1h (3600)
```

**`config_custom.yaml`（主流程）上游组与查询序列关键配置：**

```
# 文件头部（log / api / include）
log:
  level: warn
  file: "/var/log/mosdns.log"

api:
  http: "0.0.0.0:8338"    # 注意：无鉴权全网暴露，建议改绑 127.0.0.1

include:
  - "/etc/mosdns/dat_exec.yaml"
  - "/etc/mosdns/dns.yaml"

plugins:
  # ---------- 上游组（注意：mosdns 插件必须先定义后引用）----------
  - tag: dns_nocn          # 国外组：fallback(google → cloudflare)，threshold 500，always_standby true
  - tag: dns_cn            # 国内组：fallback(ali → dnspod)，threshold 300，always_standby false
  - tag: dns_foreign       # 国外解析的国内兜底：fallback(dns_nocn → dns_cn)
    type: "fallback"       #   threshold 3000 + standby false → 正常模式绝不并发国内
    args:                  #   代理链路死亡时才回落，解出真实 IP 支撑直连兜底
      primary: dns_nocn
      secondary: dns_cn
      threshold: 3000
      always_standby: false

  - tag: dns_nocn_seq      # 国外查询序列 → $dns_foreign（带国内兜底）
  - tag: dns_cn_seq        # 国内查询序列 → $dns_cn
  - tag: fallback_seq      # 兜底查询序列 → $dns_foreign（带国内兜底）
  - tag: other_seq         # other（qtype 255 等）→ $dns_cn

  # ---------- 查询分支 ----------
  - tag: query_nocn        # 国外分支：滤AAAA(reject 3) → no_ecs → $dns_nocn_seq → 写缓存
  - tag: query_cn          # 国内分支：ecs_cn → $dns_cn_seq → query_cn_smart
  - tag: query_cn_smart    # 双重验证：应答 IP ∈ geoip_cn ? 写缓存返回 : 转 query_nocn
  - tag: query_fallback    # 兜底分支：滤AAAA → no_ecs → $fallback_seq → 写缓存
  - tag: query_no_cache    # 不缓存名单：no_ecs → $dns_nocn_seq → 不写缓存
  - tag: query_other       # other：no_ecs → $other_seq → 写缓存
  - tag: query_ptr         # PTR：私网直回 / reverse_db 命中即应答 / 否则拒绝
  - tag: final_handle      # 统一出口：ttl_5m → reverse_db → accept

  # ---------- 主流程 ----------
  - tag: main_sequence     # no_cache名单 → 查缓存 → gfw→nocn / whitelist→cn / 非cn→nocn / cn→cn / 兜底
  - tag: sequence          # 总入口：metrics → pre_sequence(qtype65/空域名/PTR/255) → main_sequence

  # ---------- 服务器入口 ----------
  - type: udp_server
    args: { entry: sequence, listen: :5333 }
  - type: tcp_server
    args: { entry: sequence, listen: :5333 }
```

**各上游与序列的设计理由：**

- 国外组 `google`（主）+ `cloudflare`（备）：DoH 与 DoT 各双路（8.8.8.8/8.8.4.4 等），`concurrent: 2` 并发查询取最快——**mosdns 到国外 DNS 的流量在 dae 分流中命中 gfw/非 cn 规则被送进代理**，从而获得无污染的解析结果；
- **国外组外层兜底 `dns_foreign`**：`fallback(dns_nocn → dns_cn)`——google/cloudflare 均失败（节点全挂、看门狗紧急模式、dae 假死）时回落国内上游。国内对国外非墙域名的递归解析不经过 GFW 注入点，可解出真实 IP，让"撤回 BGP → 全量直连兜底"对未缓存域名也真正可用；`always_standby: false` + `threshold: 3000` 保证正常模式绝不把国外域名泄露给国内 DNS。此兜底与看门狗**零耦合**（DNS 层自愈），也顺带覆盖看门狗触发前的 1.5 分钟窗口期；
- 国内组 `ali`（主）+ `dnspod`（备）：阿里 DoQ/DoH/DoT 全协议双栈（v4+v6 共 12 条上游），DNSPod 备用。DoQ 放在最前——UDP 上的 QUIC 握手比 TLS 逐查询更快。

**主流程（`config_custom.yaml`）执行链：**

mosdns 通过 `udp_server`/`tcp_server` 监听 `127.0.0.1:5333`，只接收来自本机 dae 的劫持转发流量（客户端并不直接访问 mosdns）。

```
请求 → 预处理(qtype65拒绝 / 空域名拒绝 / PTR反查 / other)
     → 不缓存名单？ → 直查国外，不落缓存
     → 查全局缓存，命中即回
     → gfw域名 → 国外DNS(滤AAAA)
     → 白名单 → 国内DNS(带ECS) → 应答IP若非国内 → 转国外DNS重查
     → 非中国域名 → 国外DNS(滤AAAA)
     → 中国域名 → 国内DNS(带ECS) → 应答IP校验
     → 兜底 → 国外DNS(滤AAAA)
     → 统一: TTL 5min → 写反向库 → 返回
```

**设计理由：**

- **"国内域名 + 国内应答 IP"双重验证（query_cn_smart）**：国内域名若被污染或解析到国外 IP（如部分 CDN 海外节点），自动改走国外 DNS 重查——这是"分流准确率"的核心保障；
- **qtype 65 (HTTPS 记录) 拒绝**：与 dae 侧同理，杜绝 ECH 绕过；
- **reverse_db**：自动记录 A/AAAA 应答建立 IP→域名映射，内网 PTR 查询（如 `nslookup` 反查）无需真的去问上游；
- **PTR 私网直回、qtype 255 走国内**：边缘查询类型的明确归类，避免落到国外上游被拒；
- **fallback 走国外**（而非常见的"未知走国内"）：未知域名大概率是国外新域名，走国外解析保证可用性；直连可用性由 BGP 路由（国内段直连）兜底。

### 3.4 iptables NAT（`rules.v4` / `rules.v6`）

`rules.v4`（`rules.v6` 完全同构）：

```
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o enp1s0 -j MASQUERADE
COMMIT
```

通过 `iptables-persistent` 持久化（`/etc/iptables/rules.v4`、`rules.v6`），加载：`iptables-restore < /etc/iptables/rules.v4`、`ip6tables-restore < /etc/iptables/rules.v6`。

**理由：** Debian 把代理后的流量发回 RouterOS 时，源 IP 仍是客户端原始地址（如 `10.0.0.100` 对公网不可路由的 GUA），RouterOS 虽有回程路径，但 PPPoE 出口 NAT 只处理"从 RouterOS 本机发出"的流量语义。在 Debian 出口做 MASQUERADE，把所有回程流量源地址统一改写为 `10.0.0.2`/`fd00::2`，配合 RouterOS 侧的 `src-address` mangle 标记，**一次解决"回程路由 + 防环路标记"两件事**——mangle 规则正是匹配这个被伪装后的源地址。

### 3.5 代理链路看门狗（`Shellscript/proxy_watchdog.sh` 三件套）

**为什么需要它——本方案故障检测的三个层次：**

| 故障层级 | 检测者 | 收敛时间 |
| :--- | :--- | :--- |
| 单个节点挂 | dae 内置健康检查（`tcp_check_url` 30s + `min_moving_avg` 自动切换） | 30 秒级 |
| 链路/整机死亡 | BFD（100ms × 3） | 亚秒级 |
| **全部节点挂 / dae 假死** | **proxy_watchdog** ← 唯一能覆盖这层的 | 1.5 分钟判定 |

dae 的分组策略只能处理"部分节点挂"；BFD 只能检测物理链路。当全部节点同时挂或 dae 进程假死时，BGP 路由仍然把国外流量送进 Debian 而 Proxy 出不去——流量黑洞。看门狗复用架构自身的回退原语（BGP 路由撤回）补上这层。

**工作原理（双探针 + 状态机）：**

- **国外探针**（`gstatic.com/generate_204`，GFW 墙内不可达）走完整代理链路：DNS → dae → 节点 → 外网，它通 = 代理链路活着；
- **国内探针**（`baidu.com`，直连）判断基础网络是否正常；
- 组合判定：**国内通 + 国外连续 3 次失败（3 × 30s ≈ 1.5 分钟，防抖动）= 代理链路死亡** → `systemctl stop bird` → BFD 亚秒级撤回路由 → RouterOS 全量直连兜底；国内外探针都挂 = PPPoE/上游故障，与代理无关，不动 BGP；
- **试探恢复**（关键设计）：路由撤回后国外探针走直连、gstatic 永远失败，无法由此得知节点复活。因此紧急模式下每 5 分钟临时拉起 bird、等 15 秒（BGP 会话重建 + 3 万条路由重灌）再探测，成功切回正常模式，失败再撤回。代价是试探窗口内国外流量短暂失败一次。

**核心代码（`proxy_watchdog.sh`，完整文件见仓库）：**

```
# ------------------- 参数 -------------------
PROBE_PROXY_URL="https://www.gstatic.com/generate_204"  # 国外探针：只能走代理——正好测全链路
PROBE_DIRECT_URL="https://www.baidu.com"               # 国内探针：测基础网络（含 DNS）是否正常
FAIL_THRESHOLD=3     # 连续失败 N 次才判定代理死亡（3 × 30s ≈ 1.5 分钟，防抖动）
CHECK_INTERVAL=30    # 正常状态下的探测间隔（秒）
RETRY_INTERVAL=300   # 紧急状态下的试探恢复间隔（秒）
RETRY_WAIT=15        # 试探恢复时等待 BGP 重建+探测的窗口（秒）
STATE_FILE=/run/proxy_watchdog_state
WATCHDOG_DIR=/opt/watchdog
LOG_FILE="$WATCHDOG_DIR/watchdog.log"      # 实时日志（logrotate 轮转）
EVENTS_FILE="$WATCHDOG_DIR/events.log"     # 故障历史（只增不减）
# ---------------------------------------------

# ------------------- 主循环（NORMAL 分支） -------------------
while true; do
    state=$(cat "$STATE_FILE" 2>/dev/null || echo NORMAL)
    if [ "$state" = "NORMAL" ]; then
        if probe_proxy; then
            fail=0                                    # 代理链路正常
        elif probe_direct; then
            fail=$((fail + 1))                        # 国外挂国内通 → 疑似代理故障，计数
            if [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
                enter_emergency                       # 连续 3 次 → 停 bird、撤路由、记台账
                fail=0
            fi
        else
            # 国内外探针均失败 → 基础网络故障（PPPoE/上游），与代理无关，不切换
            fail=0
        fi
        sleep "$CHECK_INTERVAL"
    else
        # EMERGENCY 分支：等待一个周期后试探恢复
        sleep "$RETRY_INTERVAL"
        log "试探恢复：临时拉起 bird 并探测代理链路"
        systemctl start bird.service
        sleep "$RETRY_WAIT"              # 等 BGP 会话重建 + 3 万条路由重灌
        if probe_proxy; then
            recover_normal               # 成功 → 保持 bird 运行，记台账（含持续时长）
        else
            log "试探失败（代理链路仍死亡），继续紧急模式（直连兜底）"
            systemctl stop bird.service  # 失败 → 再次撤回路由
        fi
    fi
done
```

**systemd 单元（`proxy_watchdog.service`）：**

```
[Unit]
Description=Proxy health watchdog - BGP fallback controller
After=network-online.target bird.service dae.service mosdns.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/watchdog/proxy_watchdog.sh
Restart=always          # 看门狗自身必须永不退出；异常退出 10 秒后自动拉起
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**logrotate 配置（`proxy_watchdog.logrotate` → `/etc/logrotate.d/proxy_watchdog`）：**

```
/opt/watchdog/watchdog.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
```

**与 mangle 的关系**：零冲突。mangle 规则只匹配 `src-address=10.0.0.2`（旁路由回来的流量），客户端自己的流量源地址不是 10.0.0.2、永远不碰这条规则——BGP 路由一撤，客户端流量自然走 PPPoE 直连。

**日志体系**（部署于 `/opt/watchdog`）：

- `watchdog.log`：实时运行日志（带时间戳，logrotate 每周轮转），双写 journald（`journalctl -t proxy_watchdog`）；
- `events.log`：**故障台账**，只增不减，`EMERGENCY`/`RECOVER` 一行一条，含紧急模式持续时长——回答"什么时候故障过、挂了多久"；
- systemd 层面 `Restart=always`：看门狗自身异常退出 10 秒内自动拉起。

**已知限制**：紧急模式下 gfw 名单内站点仍不可达（直连被墙，物理限制）；未缓存国外域名的解析由 `dns_foreign` 国内兜底接管（见 3.3），国内域名解析完全不受影响。

---

## 4. 数据链路：路由表与 GEO 数据的自动更新

### 4.1 geodat_update.sh（一键更新，原子化设计）

脚本按"**全部生成到临时目录 → 校验通过 → 才统一替换线上文件**"的原子化流程运行：

1. 下载 dae/mosdns 用的 `geoip.dat`/`geosite.dat`（Loyalsoldier 规则库，**jsdelivr 优先、失败回退 GitHub 原链**双源）；
2. 下载 Bird 路由计算所需的三个源数据：**IANA IPv4 地址分配表**、**APNIC CN 分配记录**、**ipip 库中国 IP 集**——并对 `china_ip_list.txt` 做**行数 >100 的数据校验**（防止错误页/空文件进入计算链）；
3. 用 geoview 从 dat 中导出 mosdns 所需的六个文本数据集（全部输出到临时目录）；
4. **调用 produce.py 计算"非中国大陆"路由**，生成 routes4/6.conf 并做非空校验；
5. 校验通过后一次性替换：dae 的 dat、mosdns 的数据集、Bird 的路由文件（`mv` 直接覆盖，无"删了还没写入"的窗口）；
6. `bird -p` **语法预检**通过才 `birdc configure` 平滑重载，随后重启 mosdns、reload dae。

**工程保障**（相对朴素脚本的差异）：

- **原子性**：任何一步失败，线上配置零变动——杜绝"mosdns 数据删了没生成新的"这类半更新故障；
- **flock 并发锁**：timer 与手动同时跑不会互相撕裂路由文件；
- **失败统一进 journald**（`logger -t geodat_update`），挂 systemd timer 时可配 `OnFailure=` 通知；
- **trap EXIT 清理**临时目录；
- 已知残留：`bird -p` 预检失败时旧路由文件已被覆盖，无法自动回滚（概率极低，需彻底兜底可加备份逻辑）。

### 4.2 produce.py（路由计算核心）

**完整脚本：**

```python
#!/usr/bin/env python3
import argparse
import csv
from ipaddress import IPv4Network, IPv6Network
import math

parser = argparse.ArgumentParser(description='Generate non-China routes for BIRD.')
parser.add_argument('--exclude', metavar='CIDR', type=str, nargs='*',
                    help='IPv4 ranges to exclude in CIDR format')
parser.add_argument('--next', default="enp1s0", metavar="INTERFACE OR IP",
                    help='next hop for where non-China IP address')
parser.add_argument('--ipv4-list', choices=['apnic', 'ipip'], default=['apnic', 'ipip'], nargs='*',
                    help='IPv4 lists to use when subtracting China based IP')

# ---- 核心数据结构：CIDR 前缀树节点 ----
class Node:
    def __init__(self, cidr, parent=None):
        self.cidr = cidr      # 本节点网段
        self.child = []       # 被切分后的子网段（切分仅发生在"减去子网段"时）
        self.dead = False     # 整段死亡标记（整段被减去时置 True）

# ---- 减法核心：从前缀树中挖掉 cidr_to_sub ----
def subtract_cidr(sub_from, sub_by):
    for cidr_to_sub in sub_by:
        for n in sub_from:
            if n.cidr == cidr_to_sub:
                n.dead = True                       # 整段命中 → 标记死亡
                break
            if n.cidr.supernet_of(cidr_to_sub):
                if len(n.child) > 0:
                    subtract_cidr(n.child, sub_by)  # 已有子树 → 递归下钻
                else:
                    # 叶子节点 → 用 address_exclude 切分成兄弟子网段
                    n.child = [Node(b, n) for b in n.cidr.address_exclude(cidr_to_sub)]
                break

# ---- 保留地址（被减去的第二类对象）----
RESERVED = [
    IPv4Network('0.0.0.0/8'),      IPv4Network('10.0.0.0/8'),
    IPv4Network('127.0.0.0/8'),    IPv4Network('169.254.0.0/16'),
    IPv4Network('192.0.0.0/29'),   IPv4Network('192.0.0.170/31'),
    IPv4Network('192.0.2.0/24'),   IPv4Network('192.168.0.0/16'),
    IPv4Network('198.18.0.0/15'),  IPv4Network('198.51.100.0/24'),
    IPv4Network('203.0.113.0/24'), IPv4Network('240.0.0.0/4'),
    IPv4Network('255.255.255.255/32'), IPv4Network('224.0.0.0/4'),
    IPv4Network('100.64.0.0/10'),
]
RESERVED_V6 = []   # 可通过 --exclude 追加 v6 排除段
IPV6_UNICAST = IPv6Network('2000::/3')   # IPv6 全局单播起点

# ---- 建根：IANA 已分配的全部 /8 + v6 的 2000::/3 ----
root = []
root_v6 = [Node(IPV6_UNICAST)]

with open("ipv4-address-space.csv", newline='') as f:
    f.readline()  # skip the title
    reader = csv.reader(f, quoting=csv.QUOTE_MINIMAL)
    for cidr in reader:
        if cidr[5] == "ALLOCATED" or cidr[5] == "LEGACY":
            root.append(Node(IPv4Network(...)))    # 每个 /8 一个根节点

# ---- 减去中国（双数据源）----
with open("delegated-apnic-latest") as f:
    for line in f:
        if 'apnic' in args.ipv4_list and "apnic|CN|ipv4|" in line:
            subtract_cidr(root, (IPv4Network(...),))      # APNIC CN v4 段
        elif "apnic|CN|ipv6|" in line:
            subtract_cidr(root_v6, (IPv6Network(...),))   # APNIC CN v6 段

if 'ipip' in args.ipv4_list:
    with open("china_ip_list.txt") as f:
        for line in f:
            subtract_cidr(root, (IPv4Network(line),))     # ipip 库补充段

# ---- 减去保留地址 ----
subtract_cidr(root, RESERVED)
subtract_cidr(root_v6, RESERVED_V6)

# ---- 输出：深度优先遍历前缀树，活叶子逐条写成 Bird 静态路由 ----
def dump_bird(lst, f):
    for n in lst:
        if n.dead:
            continue
        if len(n.child) > 0:
            dump_bird(n.child, f)
        elif not n.dead:
            f.write('route %s via "%s";\n' % (n.cidr, args.next))

with open("routes4.conf", "w") as f:
    dump_bird(root, f)
with open("routes6.conf", "w") as f:
    dump_bird(root_v6, f)
```

**算法**：取 IANA 全部 ALLOCATED/LEGACY 的 /8 根节点 → 从中**减去** APNIC 记录的中国大陆 IPv4 段与 ipip 库中国段 → 再减去保留地址（10/8、192.168/16 等 15 段）→ 剩余的"世界减中国"逐条输出为 Bird 静态路由。IPv6 侧从 `2000::/3` 全局单播空间减去 APNIC CN 的 v6 分配。

**设计理由：**

- **"全量减中国"而非"枚举国外"**：国外地址没有权威枚举，而中国地址有 APNIC 权威记录——做减法在数学上保证**不重不漏**；
- **双数据源（apnic + ipip）**：APNIC 记录分配给中国的段，ipip 库补充实际使用但非 APNIC CN 注册的段，两库并集进一步压低误代理率；
- **减去保留地址**：避免 `192.168.0.0/16` 这类段被宣告进 BGP——否则若内网有更长子网划分变动，可能把内网流量误送旁路由；
- 脚本带 `--exclude`、`--next`、`--ipv4-list` 参数，可自定义排除段与下一跳。

---

## 5. 三层分流体系如何协同

本方案不是三份独立配置的堆叠，而是一套**IP 层、域名层、解析层互相补位的体系**：

1. **IP 层（BGP）**：毫秒级、无状态、零客户端配置地把"国外 IP"引到旁路由——这是主干道，**不依赖任何域名信息**；
2. **域名层（dae）**：BGP 只认 IP，但被墙服务常换 IP；dae 在传输层嗅探域名（`dial_mode: domain`），用 `geosite` 数据把"域名是国外的、但 IP 恰好落在国内段（未进 BGP 代理路由）"的漏网流量补送代理（如 gfw 域名规则、`域名非cn但IP为cn` 的注释规则即为该场景预留）；
3. **解析层（AdGuard + dae 劫持 + mosdns）**：客户端 DNS 先经 AdGuard Home (`10.0.0.4`) 完成广告过滤，其上游 `10.0.0.2:53` 被 dae 劫持后统一转入 dns 策略，再交 mosdns (`127.0.0.1:5333`) 分流——保证"国内域名拿到国内 CDN IP（ECS 调度）、国外域名拿到干净 IP（经代理查询无污染）"，从源头让 IP 层分流做出正确决策；并用"国内域名+国内 IP"双重验证自动纠正污染结果。即使客户端绕过 AdGuard 直发公共 DNS，查询同样会被 dae 劫持收编，分流策略不会失效。

同时各层各有**兜底**，构成完整的故障自愈链：

| 故障场景 | 自愈机制 | 用户感知 |
| :--- | :--- | :--- |
| BGP 会话断 / Debian 整机宕 | BFD 亚秒级撤路由（hold-time 30s 兜底） | 全量直连，国外代理短暂不可用 |
| 单个代理节点挂 | dae 健康检查 + 分组自动切换 | 无感知 |
| **全部节点挂 / dae 假死** | **看门狗 1.5 分钟判定 → 撤路由全量直连** | 普通国外站自动恢复直连（gfw 站不可达） |
| 代理链路死亡期间的国外域名解析 | `dns_foreign` 回落国内上游解析出真实 IP | 直连兜底真正可用（与看门狗零耦合，且覆盖判定前的 1.5 分钟灰区） |
| mosdns 挂 | AdGuard Home 可临时切其他上游 | DNS 降级但可用 |

值得一提的设计点：看门狗（BGP 层）与 `dns_foreign`（DNS 层）**零耦合**——两者各自独立检测、独立回退，任一先触发都能工作，组合起来才让"节点全挂"场景下普通国外站点真正可用（IP 直连 + 域名可解析）。

---

## 6. 方案优势

1. **客户端零配置、零感知**：不改网关、不改 MTU、不装证书。相比"网关指向旁路由"的传统旁路由方案，客户端网关仍指 RouterOS，故障域被严格隔离；
2. **故障时行为可预测且快速收敛**：BFD 亚秒级 + hold-time 30s 保底 → 全量回退直连，不出现"半死不活"的灰态；看门狗进一步把"全部节点挂 / dae 假死"纳入自动处理，配合 `dns_foreign` 国内兜底，节点全挂时普通国外站仍可直连访问；
3. **分流粒度是"整个互联网"，且天然免维护**：非中国大陆任何新出现的 IP 段，只要不在 APNIC CN 记录里，自动就是"走代理"——无须感知国外网站增删；国内新增段由数据更新脚本自动跟进；
4. **双栈对称设计**：v4/v6 各自独立的 BGP 会话、各自的 mangle 规则、各自的 NAT 与路由表，排障时可单独关闭一族；
5. **DNS 体系完善**：AdGuard Home 广告过滤前置、dae 统一劫持收编一切明文 DNS（客户端绕过 AdGuard 也无法逃逸）、经代理查询国外 DNS（无污染）、ECS 国内调度、双重验证纠错、落盘缓存、AAA/HTTPS 记录双端过滤防泄漏与绕过——比"上游两组 DNS 轮询"的朴素方案完善得多；
6. **组件职责单一、可独立演进**：换代理内核不动路由、换 DNS 不动代理、数据更新独立脚本化，三层解耦；
7. **数据全自动**：一个脚本同时喂饱 Bird/dae/mosdns 三个组件，可挂 cron 定期跑；
8. **性能上乘**：dae 基于 eBPF，数据面开销远低于传统 iptables/tproxy 链；BBR+FQ+大缓冲调优让 3 万条路由的宣告和代理吞吐互不拖累。

---

## 7. 方案劣势与风险

1. **复杂度高、学习曲线陡**：同时涉及 BGP、策略路由、mangle、eBPF、DNS 内部机制。任何一层配置笔误都可能全断网，且排障需要跨三台"盒子"看状态（RouterOS 路由表、Bird 会话、dae 日志）；
2. **RouterOS 内存与 FIB 压力**：近 3 万条 v4 明细 + v6 段常驻主表。小内存设备（如 64MB 的 hAP 系列）不可行，建议 128MB 起步并关注 `/system resource` 占用；
3. **旁路由是全局单点**：虽然宕机时自动回退直连（可用性保住了），且看门狗把"节点全挂"也纳入了自动回落，但**代理能力**本身没有冗余——Debian 重启或节点全挂期间，gfw 名单内站点不可达（直连被墙，物理限制）；这是"防泄漏优先"路线的固有代价；
4. **对 PPPoE 环境的隐性依赖**：`bgp_build.rsc.sh` 硬编码 pppoe-out1/ether1/Bridge/192.168.1.1 等环境假设，公网 IP 变动依赖 ipv4.sh/ipv6.sh 正确挂载到拨号事件——漏挂脚本会在特定流量上出隐蔽故障；
5. **流量全部绕行旁路由**：所有国外流量两过 RouterOS、两过 Debian（进出各一次），PPPoE 小水管下性能瓶颈通常在代理出口，但千兆以上带宽时 Debian 网卡与 eBPF 处理能力会成为瓶颈点；
6. **MASQUERADE 牺牲了端到端可溯源**：回程流量源地址被统一改写，Debian 上看到的连接的真实客户端 IP 需靠 dae 记录还原，日志审计链路变长；
7. **国外 IPv6 被"封印"而非"代理"**：因节点仅 v4，方案选择阻断国外 v6（防泄漏优先）。对 v6-only 海外资源不可达，除非增配 v6 代理节点；
8. **DNS 链路较长**：客户端 → AdGuard → dae 劫持 → mosdns →（国内直连 / 经代理的国外上游），五段链路平均解析延迟高于单上游方案；且 mosdns v5 的插件式 YAML 维护成本不低；
9. **规则细节存在维护点**：`routing.dae` 中节点域名为占位示例（`*.example.com`），实际部署需修正并替换真实域名；`dat_exec.yaml` 的 `ecs_cn` preset 是占位 IP `123.123.123.123`，必须改成自己运营商公网 IP，否则 CDN 调度会指向错误省份；
10. **Bird 静态路由表较大**：每次 `birdc configure` 重载要重算全部静态路由（配合内核调优已缓解），极端情况下会话抖动期间路由闪断数秒。

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
                │  eBGP 双栈会话 (hold-time 30s)
                ▼
            Debian 旁路由 (10.0.0.2 / fd00::2, AS 65002)
                │  Bird 2   —— 向主路由宣告"非中国大陆 IP 段"
                │  dae      —— 透明代理（分流执行者）+ 劫持全部 53 端口 DNS
                │  mosdns   —— DNS 国内外分流解析
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
  → mosdns (127.0.0.1:5353)：国内外分流解析
       ├─ 国内域名 → 阿里/DNSPod 直连（带 ECS）
       └─ 国外域名 → Google/Cloudflare（流量被 dae 送代理，无污染）
```

核心思想：**"国内直连，国外代理"，用 BGP 在网络层完成分流**。Debian 通过 eBGP 把全世界（减去中国大陆、减去保留地址）的 IP 段宣告给 RouterOS。RouterOS 的路由表自然形成"国内走 PPPoE 直连、国外下一跳 10.0.0.2"的格局，内网设备**无须修改网关或 DNS 以外的任何设置**。

### 1.2 仓库文件清单

| 目录/文件                                           | 用途                                           |
| :---------------------------------------------- | :------------------------------------------- |
| `brid/brid-bgp.conf`                            | Bird 2 主配置（eBGP 会话、导出过滤）                     |
| `RouterOS/bgp_build.rsc.sh`                     | RouterOS 侧 BGP + 策略路由 + 防火墙标记总配置             |
| `RouterOS/ipv4.sh` / `ipv6.sh`                  | PPPoE 重拨后自动刷新 bypass 表中公网 IP 路由的脚本           |
| `dae/config.dae` + `dae/config.d/*.dae`         | dae 透明代理配置（global / dns / routing / node 四片） |
| `mosdns/config_custom.yaml`                     | mosdns 主配置（DNS 分流主流程）                        |
| `mosdns/dns.yaml`                               | DNS 上游定义（Google/Cloudflare/阿里/DNSPod）        |
| `mosdns/dat_exec.yaml`                          | 数据集、缓存、ECS、TTL 插件                            |
| `iptables/rules.v4` / `rules.v6`                | 旁路由回程 NAT（MASQUERADE）                        |
| `Shellscript/geodat_update.sh`                  | 一键更新 dae/mosdns GEO 数据 + 生成 Bird 路由表         |
| `Shellscript/produce.py`                        | 由 IANA/APNIC 数据计算"非中国大陆"路由段                  |
| `brid/brid-ospf.conf`、`RouterOS/ospf_build.rsc` | 旧 OSPF 方案存档，现已弃用                             |

---

## 2. RouterOS 侧配置详解

### 2.1 BGP 动态路由（`bgp_build.rsc.sh`）

**配置内容：**

```
/routing bgp instance add as=65001 name=bird router-id=$local_ipv4_addr routing-table=main
/routing bgp connection
add afi=ip   hold-time=30s input.filter=bird-v4-in ... local.address=10.0.0.1  remote.address=10.0.0.2  .as=65002
add afi=ipv6 hold-time=30s input.filter=bird-v6-in ... local.address=fd00::1   remote.address=fd00::2   .as=65002
/routing filter rule
add chain=bird-v4-in rule="if (dst == 0.0.0.0/0) { reject } else { accept }"
add chain=bird-v6-in rule="if (dst == ::/0) { reject } else { accept }"
```

**设计理由：**

- **选 BGP 而不是 OSPF**：本方案的本质是"把约 3 万条静态明细路由灌进主路由"。OSPF 是链路状态协议，为了传递这几万条外部路由要维护完整的 LSDB、跑 SPF，对旁路由这种"单点对外"的拓扑是杀鸡用牛刀；BGP 天生就是为"携带海量明细路由、按策略过滤"设计的，eBGP 会话一断（hold-time 30s）路由立刻整体撤回，故障语义清晰。
- **私有 ASN（65001/65002）**：家庭网络不需要公网 ASN，eBGP 私有自治域即可完成"带 AS 校验的点对点路由注入"，比 iBGP 少掉 next-hop 不可达的坑。
- **两条独立会话（IPv4/IPv6 分开）**：IPv4 走 v4 地址、IPv6 走 ULA 地址建立会话，互不依赖。任何一族出问题不影响另一族。
- **hold-time 30s / keepalive 10s**：默认 180s 对家用太迟钝。30 秒内检测到旁路由宕机并撤回路由，配合"撤回即全量直连"，故障窗口很短。
- **入方向 filter 拒绝默认路由**：BGP 万一宣告 `0.0.0.0/0` 会直接劫持主路由的默认网关，是本方案最危险的故障模式，因此在 RouterOS 和 Bird 两端（出、入双向）都显式拒绝。
- **routing-table=main**：BGP 路由直接进主表参与常规选路，客户端无须任何配合。

### 2.2 策略路由与防火墙标记（防回环）

**配置内容：**

```
/routing table add fib name=bypass
/routing rule add action=lookup-only-in-table routing-mark=bypass table=bypass
/ip firewall mangle add chain=prerouting src-address=10.0.0.2 dst-address=!10.0.0.0/24 \
    in-interface=Bridge new-routing-mark=bypass
/ipv6 firewall mangle add ... src-address=fd00::2 dst-address=!fd00::/64 ...
```

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

**配置内容：** PPPoE 重拨后公网 IP 会变。`ipv4.sh` 从 `pppoe-out1` 接口取新的对端网络地址，删除 bypass 表中旧的 `Gateway-INT` 路由再添加新的；`ipv6.sh` 从名为 `Public` 的 IPv6 地址池取前缀（/60 截成 /64）刷新 IPv6 侧的 `Gateway-INT` 路由。

**设计理由：**

PPPoE 是动态 IP，`114.114.114.114` 这类写在 `bgp_build.rsc.sh` 里的"公网 IP 路由"只是初次建表用的示意值；这两个脚本通过 RouterOS 的 scheduler/PPPoE 脚本钩子在每次重拨后运行，保证 bypass 表里的公网明细始终与实际地址一致，且全程带日志、先删后加、失败回滚安全（取不到地址就只报错不动表）。

---

## 3. Debian 侧配置详解

### 3.1 Bird 2（`brid/brid-bgp.conf`）

**配置内容与理由逐条对照：**

| 配置                                                     | 内容                                                                   | 理由                                                            |
| :----------------------------------------------------- | :------------------------------------------------------------------- | :------------------------------------------------------------ |
| `protocol device` (interface "-dae*")                  | 只扫描 dae 的 tun/tproxy 接口                                              | dae 工作时会创建 `dae*` 前缀的接口，Bird 需要感知其地址；限定前缀避免扫描全部接口浪费资源         |
| `protocol kernel { learn; import none; export none; }` | 只**学习**内核路由，不注入也不导出                                                  | Bird 只做"路由宣告者"，不接管 Debian 本机内核表；`learn` 让 Bird 感知系统路由状态用于选路   |
| `protocol static` + `include routes4/6.conf`           | 近 3 万条 `route x.x.x.x via "enp1s0"` 静态路由                             | 分流数据的唯一来源；`include` 把大文件与主配置解耦，更新数据只重载 include 即可             |
| `export_foreign4/6` filter                             | `if net = 0.0.0.0/0 then reject; if source = RTS_STATIC then accept` | **双重保险**：绝不让默认路由出门；只导出静态路由，防止内核路由被无意宣告出去                      |
| `next hop self`                                        | 所有导出路由下一跳改写为本机                                                       | eBGP 跨跳场景下确保下一跳一定可达（RouterOS 无须依赖 Bird 声称的原始下一跳）              |
| `hold time 30 / keepalive 10`                          | 与 RouterOS 侧对称                                                       | 宕机检测窗口 30 秒，两侧参数必须一致                                          |
| `import none`（BGP 通道）                                  | 不接收 RouterOS 的任何路由                                                   | 旁路由只需要"说"不需要"听"；默认网关由 `/etc/network/interfaces` 静态指向 10.0.0.1 |

**为什么 routes 文件里 next hop 全是 `enp1s0`？** 这些静态路由的用途不是指导 Debian 本机转发（那是 dae 的 tproxy 的事），而只是作为"被导出的路由对象"存在——Bird 导出时统一执行了 `next hop self`，本机内核表里这些路由实际不参与转发（kernel 协议 `export none`）。

### 3.2 dae（`config.dae` + `config.d/`）

dae 采用 `include` 分片管理：`dns.dae`（DNS 策略）、`routing.dae`（分流规则）、`node.dae`（节点与分组）。

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
| 系统进程直连          | `pname(mosdns/NetworkManager/systemd-resolved) -> must_rules` | **防 DNS 死循环**：mosdns 的上游查询本身进入 dae 时必须直连，否则 mosdns→dae→mosdns 无限递归；`must_rules` 保证即使有更宽的 proxy 规则也优先命中 |
| 国产公共 DNS 直连     | 阿里/DNSPod 全部 IP 与域名直连                                         | 这些是 mosdns 的上游，同理必须直连                                                                                  |
| 组播/广播 `must`    | `224.0.0.0/3, ff00::/8`                                       | 局域网发现协议绝不能进代理                                                                                          |
| AdGuard Home 例外 | `sip(10.0.0.4) && udp && 53 -> direct`                        | AdGuard 的上游指向 `10.0.0.2:53`，其查询会被 dae 统一劫持处理；此规则将其明文 DNS 标记直连，兜底保证这些包不会被误送进代理隧道                        |
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
- 其余（兜底）查询全部转发给 mosdns（`127.0.0.1:5353`），由 mosdns 完成国内外分流解析；
- `fixed_domain_ttl { tw.example.com: 0 }`：对频繁变更解析的节点域名禁用缓存。

> dae 劫持 DNS 是 `dial_mode: domain` 域名分流的前提：只有 DNS 经过 dae，它才能建立"域名 ↔ IP"映射，把域名规则施加到后续连接上。

#### node.dae

三个 hysteria2 节点（hk/tw/us，占位域名）组成一个 `Proxy` 分组：hk 为主，tw/us 作备份（`add_latency: 5000ms` 惩罚），策略 `min_moving_avg` 按最小移动平均延迟自动选节点，30s 检查间隔、50ms 容差防止频繁抖动切换。**设计意图：单分组、自动故障转移、防震荡**。

### 3.3 mosdns（三个 yaml）

**`dns.yaml`（上游）：**

- 国外组 `google`（主）+ `cloudflare`（备）：DoH 与 DoT 各双路（8.8.8.8/8.8.4.4 等），`concurrent: 2` 并发查询取最快——**mosdns 到国外 DNS 的流量在 dae 分流中命中 gfw/非 cn 规则被送进代理**，从而获得无污染的解析结果；
- 国内组 `ali`（主）+ `dnspod`（备）：阿里 DoQ/DoH/DoT 全协议双栈（v4+v6 共 12 条上游），DNSPod 备用。DoQ 放在最前——UDP 上的 QUIC 握手比 TLS 逐查询更快。

**`dat_exec.yaml`（数据与插件）：**

- 六个数据集：私有 IP、中国 IP、中国域名、白名单、GFW 域名、非中国域名，外加"不缓存域名"集合；
- 全局缓存 `cache_wan`：13 万条，lazy cache 86400s，**落盘**到 `wan_cache.dump`（600s 间隔）——重启不丢缓存，lazy 模式过期后仍可用旧值应答同时后台刷新；
- ECS 处理：国外查询 `no_ecs`（隐藏客户端子网，防止被上游定位），国内查询 `ecs_cn` 附加固定子网（`preset: 123.123.123.123` 占位，需改成自己运营商的公网 IP）——**让国内 CDN 按本省调度**；
- TTL 统一控制：出口统一 `ttl_5m`（300s），在"缓存效率"与"记录变更生效速度"间取折中。

**`config_custom.yaml`（主流程）：**

mosdns 通过 `udp_server`/`tcp_server` 监听 `127.0.0.1:5353`，只接收来自本机 dae 的劫持转发流量（客户端并不直接访问 mosdns）。

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

```
*nat
-A POSTROUTING -o enp1s0 -j MASQUERADE
```

**理由：** Debian 把代理后的流量发回 RouterOS 时，源 IP 仍是客户端原始地址（如 `10.0.0.100` 对公网不可路由的 GUA），RouterOS 虽有回程路径，但 PPPoE 出口 NAT 只处理"从 RouterOS 本机发出"的流量语义。在 Debian 出口做 MASQUERADE，把所有回程流量源地址统一改写为 `10.0.0.2`/`fd00::2`，配合 RouterOS 侧的 `src-address` mangle 标记，**一次解决"回程路由 + 防环路标记"两件事**——mangle 规则正是匹配这个被伪装后的源地址。

---

## 4. 数据链路：路由表与 GEO 数据的自动更新

### 4.1 geodat_update.sh（一键更新）

脚本顺序完成五件事：

1. 下载 dae/mosdns 用的 `geoip.dat`/`geosite.dat`（Loyalsoldier 规则库，jsdelivr CDN）；
2. 下载 Bird 路由计算所需的三个源数据：**IANA IPv4 地址分配表**、**APNIC CN 分配记录**、**ipip 库中国 IP 集**；
3. 用 geoview 从 dat 中导出 mosdns 所需的六个文本数据集；
4. **调用 produce.py 计算"非中国大陆"路由**，生成 `/etc/bird/routes4.conf` 与 `routes6.conf`，然后 `birdc configure` 平滑重载；
5. 重启 mosdns、reload dae，清理临时文件。

### 4.2 produce.py（路由计算核心）

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
3. **解析层（AdGuard + dae 劫持 + mosdns）**：客户端 DNS 先经 AdGuard Home (`10.0.0.4`) 完成广告过滤，其上游 `10.0.0.2:53` 被 dae 劫持后统一转入 dns 策略，再交 mosdns (`127.0.0.1:5353`) 分流——保证"国内域名拿到国内 CDN IP（ECS 调度）、国外域名拿到干净 IP（经代理查询无污染）"，从源头让 IP 层分流做出正确决策；并用"国内域名+国内 IP"双重验证自动纠正污染结果。即使客户端绕过 AdGuard 直发公共 DNS，查询同样会被 dae 劫持收编，分流策略不会失效。

同时三层各有**兜底**：BGP 断 → 全量直连（牺牲代理可用性，保网络可用性）；dae 节点全挂 → 直连规则仍在（mosdns 的国内解析不受影响）；mosdns 挂 → AdGuard Home 可临时切其他上游。

---

## 6. 方案优势

1. **客户端零配置、零感知**：不改网关、不改 MTU、不装证书。相比"网关指向旁路由"的传统旁路由方案，客户端网关仍指 RouterOS，故障域被严格隔离；
2. **故障时行为可预测且快速收敛**：eBGP hold-time 30s → 全量回退直连，不出现"半死不活"的灰态；这是一票静态路由/策略路由方案最难做对的地方；
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
3. **旁路由是全局单点**：虽然宕机时自动回退直连（可用性保住了），但**代理能力**没有冗余——Debian 重启窗口内全网无法翻墙；dae 节点分组只能缓解"出口节点"故障，缓解不了"旁路由本体"故障；
4. **对 PPPoE 环境的隐性依赖**：`bgp_build.rsc.sh` 硬编码 pppoe-out1/ether1/Bridge/192.168.1.1 等环境假设，公网 IP 变动依赖 ipv4.sh/ipv6.sh 正确挂载到拨号事件——漏挂脚本会在特定流量上出隐蔽故障；
5. **流量全部绕行旁路由**：所有国外流量两过 RouterOS、两过 Debian（进出各一次），PPPoE 小水管下性能瓶颈通常在代理出口，但千兆以上带宽时 Debian 网卡与 eBPF 处理能力会成为瓶颈点；
6. **MASQUERADE 牺牲了端到端可溯源**：回程流量源地址被统一改写，Debian 上看到的连接的真实客户端 IP 需靠 dae 记录还原，日志审计链路变长；
7. **国外 IPv6 被"封印"而非"代理"**：因节点仅 v4，方案选择阻断国外 v6（防泄漏优先）。对 v6-only 海外资源不可达，除非增配 v6 代理节点；
8. **DNS 链路较长**：客户端 → AdGuard → dae 劫持 → mosdns →（国内直连 / 经代理的国外上游），五段链路平均解析延迟高于单上游方案；且 mosdns v5 的插件式 YAML 维护成本不低；
9. **规则细节存在维护点**：`routing.dae` 中节点域名为占位示例（`*.example.com`），实际部署需修正并替换真实域名；`dat_exec.yaml` 的 `ecs_cn` preset 是占位 IP `123.123.123.123`，必须改成自己运营商公网 IP，否则 CDN 调度会指向错误省份；
10. **Bird 静态路由表较大**：每次 `birdc configure` 重载要重算全部静态路由（配合内核调优已缓解），极端情况下会话抖动期间路由闪断数秒。

---

## 8. 部署前检查清单

- [ ] RouterOS ≥ 7.x，内存 ≥ 128MB；
- [ ] 修改 `bgp_build.rsc.sh` 中的接口名、网段、光猫地址等本地变量；
- [ ] AdGuard Home 部署在 `10.0.0.4`，上游 DNS 设为 `10.0.0.2:53`（v4）/ `[fd00::2]:53`（v6）——由 dae 劫持接管，Debian 上无需任何进程监听 53 端口；
- [ ] 替换 `node.dae` 中全部占位节点，修正 `routing.dae` 第 40 行缺右括号问题；
- [ ] 将 `dat_exec.yaml` 的 `ecs_cn.preset` 改为本机运营商公网 IP；
- [ ] 确认 `dns.dae` 的 mosdns 上游端口与 mosdns 实际监听端口一致（本文按 `127.0.0.1:5353` 描述）；
- [ ] 按公网类型选择挂载 `ipv4.sh`/`ipv6.sh` 到 PPPoE up 事件或 scheduler；
- [ ] 首次运行 `geodat_update.sh` 前：安装 bird2/dae/mosdns 并放好各自配置，为 `mosdns` 准备 `rule/whitelist.txt`、`rule/no_cache.txt`（可为空文件）；
- [ ] 验证顺序建议：单栈 v4 先通（BGP established → 国外段路由出现在 main 表 → mangle 计数增长 → dae 日志出现代理连接）→ 再开 v6；
- [ ] DNS 验证：客户端 `nslookup` 任意域名应先命中 AdGuard 查询日志（广告过滤生效），国外域名返回的 IP 在 mosdns 日志中对应"经代理的国外上游"分支；
- [ ] 演练一次故障回退：`systemctl stop dae` 与 `systemctl stop bird`，确认全网回落直连。

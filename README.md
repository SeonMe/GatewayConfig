# 基于 RouterOS + Debian 旁路由的 OSPF 智能分流全指南（IPv4/IPv6 双栈）

## 1. 方案概述与网络拓扑

### 1.1 核心原理
本方案的核心思想是 **“国内直连，国外代理”**，并通过动态路由协议 **OSPF** 自动、精准地控制流量路径：

- **RouterOS（主路由）**：负责 PPPoE 拨号、NAT、DHCP、防火墙。
- **Debian（旁路由）**：运行 **Bird 2**（OSPF 路由守护进程）、**dae**（透明代理）和 **mosdns**（DNS 分流）。
- **流量走向**：
    1. 内网设备默认网关指向 RouterOS (`10.0.0.1`)。
    2. Debian 通过 Bird 2 将 **所有非中国大陆 IP 的路由段** 通过 OSPF 广播给 RouterOS，下一跳指向自己 (`10.0.0.2`)。
    3. RouterOS 收到这些 OSPF 路由后，会将访问国外 IP 的流量自动转发给 Debian 处理（代理），而访问国内 IP 的流量则由 RouterOS 直接经 PPPoE 发出。
    4. 即使旁路由 Debian 宕机，OSPF 邻居关系断开，RouterOS 会自动移除这些特殊路由，流量恢复默认路径（全部直连），保证网络高可用。
    5. 主路由无须给内网设备修改网关指向，所有流量均由 OSPF 处理。

### 1.2 设备信息与地址规划
| 设备 | 角色 | 操作系统 | IP 地址 | 备注 |
| :--- | :--- | :--- | :--- | :--- |
| **RouterOS** | 主路由 | RouterOS 7.x | `10.0.0.1/24`<br>IPv6 ULA: `fd00::1/64` | OSPF Router ID: `10.0.0.1` |
| **Bypass Gateway** | 旁路网关 | Debian 13 | `10.0.0.2/24`<br>IPv6 ULA: `fd00::2/64` | OSPF Router ID: `10.0.0.2` |
| **AdGuard Home** | 广告过滤<br/>DNS服务器 | Debian 13 | `10.0.0.4` | 上游 DNS：<br/>`10.0.0.2:53`<br/>`[fd00:2]:53` |
| **内网设备** | 客户端 | Windows/macOS/Linux | 由 RouterOS DHCP 分配 | 默认网关<br/> `10.0.0.1` |

---

## 2. Bypass Debian 配置
### 2.1 Dae
根据 config.dae，dae 监听 tproxy_port: 12345，DNS 上游指向 mosdns (127.0.0.1:5333)。

安装 dae（请参考官方文档），并将配置文件放置于 /etc/dae/config.yaml。

关键路由规则解读：

- `pname(mosdns) -> direct`：避免 DNS 流量死循环。

- `domain(geosite:cn) -> direct`：国内域名直连。

- `fallback: Proxy`：其余流量走代理。


### 2.2 MonDNS
安装 mosdns（假设已安装 v5 版本）

配置文件结构：

- `config_custom.yaml`：主配置入口。

- `dat_exec.yaml`：数据集定义与执行插件。

- `dns.yaml`：上游 DNS 服务器定义。

所有配置文件均在仓库中，自行下载即可，略作调整路径。

根据 `dat_exec.yaml`,需要自行准备 `geoip_private.txt`、`geoip_cn.txt`、`geosite_cn.txt`、`whitelist.txt`、`geosite_gfw.txt`、`geosite_geolocation-nocn.txt` 文件，可使用仓库内脚本生成。

### 2.3 Brid

安装 Bird 2：

```
apt install bird2
```

配置 `/etc/bird/bird.conf` 前需要先 ` systemctl stop bird.service` ，否则修改配置将不会生效。

配置文件直接使用仓库内提供的文件即可。

### 2.4 运行环境优化

因为将近三万条路由，使用过程中 `brid` 会产生堆栈溢出，因此需要对运行环境进行优化。

#### 2.4.1 网络接口配置
编辑 `/etc/network/interfaces` ,在你的网络配置下方增加启动参数。

```
source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug enp1s0
iface enp1s0 inet static
    address 10.0.0.2/24
    gateway 10.0.0.1
    # 以下部分为增加的内容
    ## --- 网卡传输队列 ---
    post-up /sbin/ip link set enp1s0 txqueuelen 50000
    ## --- 流量控制与排队规则 ---
    ## 应用 FQ (Fair Queuing) 调度算法，并精细化配置数据包限制与量子参数（优化大带宽下的吞吐与延迟）
    post-up /sbin/tc qdisc replace dev enp1s0 root fq limit 65535 flow_limit 3000 quantum 3028 initial_quantum 15140
```

#### 2.4.2 内核参数优化
```
# --- 文件句柄限制 ---
# 系统级允许打开的最大文件句柄数
fs.file-max = 1024000

# --- 网络栈读写缓冲区 ---
# 套接字接收/发送缓冲区的最大值和默认值（用于高带宽网络优化）
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432

# --- 网络接口队列 ---
# 网卡接收数据包的最大积压队列长度
net.core.netdev_max_backlog = 100000

# --- socket 的辅助缓冲区 ---
net.core.optmem_max = 1048576

# --- 邻居表（ARP/NDP 缓存） ---
# 邻居表垃圾回收（GC）阈值，防止高并发下表溢出
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 32768

net.ipv6.neigh.default.gc_thresh1 = 4096
net.ipv6.neigh.default.gc_thresh2 = 8192
net.ipv6.neigh.default.gc_thresh3 = 32768

# --- IPv6 分片重组 ---
# IPv6 分片数据包重组占用的内存阈值（高/低水位）
net.ipv6.ip6frag_high_thresh = 67108864
net.ipv6.ip6frag_low_thresh = 50331648

# --- IP 路由与转发 ---
# 开启 IPv4/IPv6 数据包转发（作为路由器或 NAT 网关时必须开启）
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1

# 禁用 ICMP 重定向发送（增强安全性并减少冗余流量）
net.ipv4.conf.all.send_redirects = 0

# 强制接受 IPv6 路由器通告 (RA)，即使在开启转发的情况下
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.enp1s0.accept_ra = 2

# --- 队列规则与拥塞控制 ---
# 设置默认排队规则为 FQ（Fair Queuing）
net.core.default_qdisc = fq
# 启用 Google BBR 拥塞控制算法
net.ipv4.tcp_congestion_control = bbr
```

#### 2.4.3  配置 iptables/nftables 伪装（NAT）

由于旁路由需要将代理后的流量发回主路由，必须进行源地址伪装（MASQUERADE），否则主路由不认识回程流量。

需要使用 `iptables` 做持久化。

```
 apt install iptables-persistent
```

IPv4 NAT 规则保存至 `/etc/iptables/rules.v4`
```
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o enp1s0 -j MASQUERADE
COMMIT
```
IPv6 NAT 规则保存至 `/etc/iptables/rules.v6`
```
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o enp1s0 -j MASQUERADE
COMMIT
```
加载规则
```
iptables-restore < /etc/iptables/rules.v4
ip6tables-restore < /etc/iptables/rules.v6
```
---

## 3. RouterOS 配置

### 3.1 基础网络确认
确保 RouterOS 已配置好：

- 内网网桥接口名称：Bridge（根据实际情况修改）。
- PPPoE 拨号接口名称：pppoe-out1（根据实际情况修改）。
- 内网 IPv4 地址：10.0.0.1/24

### 3.2 定义本地变量（仅用于理解，非执行代码）
```
## 定义本地变量
## 采用基于 SLAAC 的 IPv6 GUA(公网) + ULA(私有) 方案

:local interface_name "Bridge"          # 内网网桥接口名称
:local local_ipv4_addr "10.0.0.1"       # 路由器自身的本地 IPv4 地址
:local local_ipv4_subnet "10.0.0.0/24"  # 本地 IPv4 局域网网段
:local local_ipv6_subnet "fd00::/64"    # 本地 IPv6 ULA (私有) 网段
:local internet_ipv4 "114.114.114.114"  # 公网 IPv4 地址
:local internet_ipv6 "2400::/64"        # 公网 IPv6 地址
:local pppoe_name "pppoe-out1"          # PPPoE 拨号接口名称
:local gateway_ipv4_addr "10.0.0.2"     # 旁路网关的 IPv4 地址
:local gateway_ipv6_addr "fd00::2"      # 旁路网关的 IPv6 ULA 地址
```
### 3.3 配置 OSPF 动态路由
OSPF 用于接收旁路由广播的国外 IP 段。
```
## OSPF 动态路由配置
/routing id
# 设置路由器 ID，通常使用本地 IPv4 地址以示唯一性
add comment=Gateway disabled=no id=$local_ipv4_addr name=Gateway select-dynamic-id=only-vrf
/routing ospf instance
# 创建 OSPF 实例：v2 负责 IPv4，v3 负责 IPv6
add comment=Gateway disabled=no name=ipv4 router-id=$local_ipv4_addr version=2
add comment=Gateway disabled=no name=ipv6 router-id=$local_ipv4_addr version=3
/routing ospf area
# 创建 OSPF 区域（Area 0），用于逻辑隔离路由域
add comment=Gateway disabled=no instance=ipv4 name=ipv4
add comment=Gateway disabled=no instance=ipv6 name=ipv6
/routing ospf interface-template
# 配置接口模板：设置网桥接口为点对点(ptp)类型，并设定优先级与开销
add area=ipv4 comment=Gateway cost=10 disabled=no interfaces=$interface_name priority=32 retransmit-interval=10s transmit-delay=5s type=ptp
add area=ipv6 comment=Gateway cost=10 disabled=no interfaces=$interface_name priority=32 retransmit-interval=10s transmit-delay=5s type=ptp
```
### 3.4 配置策略路由与防火墙标记（旁路网关专用）
关键步骤：RouterOS 必须将来自旁路由 (10.0.0.2) 且目标是外网的流量 强制走主路由表，否则流量会死循环（旁路由发给主路由，主路由又查 OSPF 表发回旁路由）。
```
## 策略路由表与规则
/routing table
# 创建名为 bypass 的自定义路由表，用于存放分流路由
add comment=Gateway disabled=no fib name=bypass
/routing rule
# 配置路由规则：强制在 bypass 路由表中查找标记流量
add action=lookup-only-in-table comment=Gateway disabled=no routing-mark=bypass table=bypass

## 防火墙流量标记
/ip firewall mangle
# IPv4 标记：来自旁路网关且目标不是本地网段的流量，打上 bypass 路由标记
add action=mark-routing chain=prerouting comment=Gateway dst-address=!$local_ipv4_subnet in-interface=$interface_name new-routing-mark=bypass src-address=$gateway_ipv4_addr
/ipv6 firewall mangle
# IPv6 标记：同上，处理来自旁路网关 IPv6 ULA 地址的外网流量
add action=mark-routing chain=prerouting comment=Gateway dst-address=!$local_ipv6_subnet in-interface=$interface_name new-routing-mark=bypass src-address=$gateway_ipv6_addr
```
### 3.5 向 bypass 路由表添加基础路由
这些路由确保打了 bypass 标记的数据包能正确上网，而不会再次匹配 OSPF 注入的外网路由。
```
## IPv4 路由条目
/ip route
# 局域网回程路由
add comment=Gateway-LAN   disabled=no distance=1 dst-address=$local_ipv4_subnet gateway=$interface_name routing-table=bypass scope=30 target-scope=10
# 默认全网路由：指向 PPPoE 拨号接口，实现上外网
add comment=Gateway-PPPOE disabled=no distance=1 dst-address=0.0.0.0/0 gateway=$pppoe_name routing-table=bypass scope=30 target-scope=10
# 公网 IPv4 地址路由
add comment=Gateway-INT   dst-address=$internet_ipv4 gateway=$pppoe_name routing-table=bypass
# 光猫访问路由：确保在 bypass 表下也能通过物理网口 ether1 访问光猫管理界面
add comment=Gateway-WAN   disabled=no distance=1 dst-address=192.168.1.1/32 gateway=ether1 routing-table=bypass scope=30 target-scope=10

## IPv6 路由条目
/ipv6 route
# 链路本地地址 (LLA) 路由：确保内网与 PPPoE 接口的链路发现正常
add comment=Gateway-LLA-LAN   disabled=no distance=1 dst-address=fe80::/64 gateway=$interface_name pref-src="" routing-table=bypass scope=10 target-scope=5
add comment=Gateway-LLA-PPPoE disabled=no distance=1 dst-address=fe80::/64 gateway=$pppoe_name pref-src="" routing-table=bypass scope=10 target-scope=5
# ULA (唯一本地地址) 路由：确保私有 IPv6 网段互通
add comment=Gateway-ULA       disabled=no distance=1 dst-address=$local_ipv6_subnet gateway=$interface_name pref-src="" routing-table=bypass scope=10 target-scope=5
# 默认全网路由：指向 PPPoE，用于 IPv6 外网访问
add comment=Gateway-PPPoE     disabled=no distance=1 dst-address=::/0 gateway=$pppoe_name pref-src="" routing-table=bypass scope=30 target-scope=10
# 公网 IPv6 地址路由
add comment=Gateway-INT       dst-address=$internet_ipv6 gateway=$interface_name routing-table=bypass
# 光猫访问路由：通过 LLA 地址访问连接在 ether1 上的光猫
add comment=Gateway-LLA-WAN   disabled=no distance=1 dst-address=fe80::/64 gateway=ether1 pref-src="" routing-table=bypass scope=10 target-scope=5
```
### 3.6 DNS 配置
直接关掉 `RouterOS` DNS 功能，IPv4 使用 `DHCP Server` 下发客户端 DNS，IPv6 使用 `ND` 下发 IPv6 DNS。
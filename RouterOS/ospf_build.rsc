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
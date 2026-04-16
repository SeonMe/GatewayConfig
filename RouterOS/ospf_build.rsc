## Local Variable
## 这部分需要自行修改
# 1.如果您未配置 ND ，IPv6_LAN 默认是 fe80::/64，可自行 /ipv6 route print 查看
# 2.如果您配置了 ND ，IPv6本地地址通常自行设置，如有请在 /ipv6 route 自行添加一条 Gateway-LAN
# 3.其他的可自行修改及配置
:local ROS_IP "10.0.0.1"
:local IPv4_LAN "10.0.0.0/24"
:local IPv6_LAN "fe80::/64"
:local Gateway_MAC "6E:6E:6E:6E:6E:6E"
:local INT_IPv4 "114.114.114.114"
:local INT_IPv6 "2400::/64"
:local LAN_NAME "Bridge"
:local PPPOE_NAME "pppoe-out1"

## OSPF
/routing id
add comment=Gateway disabled=no id=$ROS_IP name=Gateway select-dynamic-id=only-vrf
/routing ospf instance
add comment=Gateway disabled=no name=ipv4 router-id=$ROS_IP version=2
add comment=Gateway disabled=no name=ipv6 router-id=$ROS_IP version=3
/routing ospf area
add comment=Gateway disabled=no instance=ipv4 name=ipv4
add comment=Gateway disabled=no instance=ipv6 name=ipv6
/routing ospf interface-template
add area=ipv4 comment=Gateway cost=10 disabled=no interfaces=$LAN_NAME priority=32 retransmit-interval=10s transmit-delay=5s type=ptp
add area=ipv6 comment=Gateway cost=10 disabled=no interfaces=$LAN_NAME priority=32 retransmit-interval=10s transmit-delay=5s type=ptp
/routing table
add comment=Gateway disabled=no fib name=bypass
/routing rule
add action=lookup-only-in-table comment=Gateway disabled=no routing-mark=bypass table=bypass

## Firewall
/ip firewall mangle
add action=mark-routing chain=prerouting comment=Gateway dst-address=!$IPv4_LAN in-interface=$LAN_NAME new-routing-mark=bypass passthrough=no src-mac-address=$Gateway_MAC
/ipv6 firewall mangle
add action=mark-routing chain=prerouting comment=Gateway dst-address=!$IPv6_LAN in-interface=$LAN_NAME new-routing-mark=bypass src-mac-address=$Gateway_MAC

## Route
/ip route
add comment=Gateway-LAN disabled=no distance=1 dst-address=$IPv4_LAN gateway=$LAN_NAME routing-table=bypass scope=30 target-scope=10
add comment=Gateway-PPPOE disabled=no distance=1 dst-address=0.0.0.0/0 gateway=$PPPOE_NAME routing-table=bypass scope=30 target-scope=10
add comment=Gateway-INT dst-address=$INT_IP gateway=$PPPOE_NAME routing-table=bypass
/ipv6 route
add comment=Gateway-LAN disabled=no distance=1 dst-address=$IPv6_LAN gateway=$LAN_NAME routing-table=bypass scope=10 target-scope=5
add comment=Gateway-PPPOE disabled=no distance=1 dst-address=$IPv6_LAN gateway=$PPPOE_NAME routing-table=bypass scope=10 target-scope=5
add comment=Gateway-INT dst-address=$INT_IPv6 gateway=$PPPOE_NAME routing-table=bypass

## ZeroTier
# 1.如果您使用 ZeroTier，请如下配置
:local ZT_Server_IP "10.10.0.1"
:local ZT_LAN "10.10.0.0/24"

/routing table
add comment=ZeroTier disabled=no fib name=zerotier
/ip firewall nat
add action=masquerade chain=srcnat comment=ZeroTier out-interface=$LAN_NAME
/ipv6 firewall nat
add action=masquerade chain=srcnat comment=ZeroTier out-interface=$LAN_NAME
/ip route
add comment=ZeroTier disabled=no distance=1 dst-address=$ZT_LAN gateway=$ZT_Server_IP routing-table=main scope=30 target-scope=10
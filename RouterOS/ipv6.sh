# 定义 IPv6 地址池名称
:local ipv6PoolName "Public"
:local gatewayv6Interface "pppoe-out1"

# 获取 IPv6 地址池中的前缀
:local ipv6Prefix [/ipv6/pool get [find where name=$ipv6PoolName] prefix]

# 确保成功获取 IPv6 前缀
:if ($ipv6Prefix != "") do={
    # 将前缀中的 /60 替换为 /64
    :local ipv6PrefixModified [:pick $ipv6Prefix 0 [:find $ipv6Prefix "/"]]
    :set ipv6PrefixModified ($ipv6PrefixModified . "/64")
    :put ("修改后的 IPv6 前缀部分: " . $ipv6PrefixModified)

    # 删除已有的相同前缀的路由，避免重复
    /ipv6/route remove [find dst-address~"240" and routing-table="bypass"]

    # 添加新的路由条目到 bypass 路由表
    /ipv6/route add dst-address=$ipv6PrefixModified gateway=$gatewayv6Interface routing-table="bypass" comment="Gateway-INT"
} else={
    :put "未找到 IPv6 地址池中的前缀"
}
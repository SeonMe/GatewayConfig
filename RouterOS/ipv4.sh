# 定义网关接口
:local gatewayInterface "pppoe-out1"
:log info ("正在使用网关接口：" . $gatewayInterface)

# 获取pppoe-out1的远程网络地址
:local remoteAddress [/ip address get [find where interface=$gatewayInterface] network]
:log info ("获取到的远程网络地址为：" . $remoteAddress)

# 检查是否成功获取到远程地址
:if ($remoteAddress != "") do={

    # 删除旧路由
    :log info ("准备查找并删除旧路由")
    :local oldRouteId [/ip route find where comment="Gateway-INT" and routing-table="bypass"]
    :log info ("找到的旧路由ID为：" . $oldRouteId)

    :if ($oldRouteId != "") do={
        /ip route remove $oldRouteId
        :log info ("已成功删除旧路由")
    } else={
        :log info "未找到需要删除的旧路由"
    }

    # 添加新路由
    :log info ("正在添加新路由")
    /ip route add dst-address=$remoteAddress gateway=$gatewayInterface routing-table="bypass" comment="Gateway-INT"
    :log info "新路由已成功添加"
} else={
    :log error "未能获取到远程网络地址"
}

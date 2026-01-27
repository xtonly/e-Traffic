# e-Traffic

# 一键管理脚本

wget --no-check-certificate -O eTraffic.sh https://raw.githubusercontent.com/xtonly/e-Traffic/refs/heads/main/eTraffic.sh && chmod +x eTraffic.sh && ./eTraffic.sh

菜单说明：

输入 1 安装：

脚本会自动检查并安装 bc 和 iptables。

会提示你输入规则（例如 8080:200:24）。

自动创建 Cron 定时任务（每分钟执行）。

自动初始化 iptables 统计链。

输入 2 编辑规则：

直接打开配置文件。你可以添加多行，监控多个端口。

格式：端口:流量限制(GB):封禁时长(小时)

输入 4 卸载：

这是重点：它会读取当前的配置，自动删除所有由此脚本创建的 DROP 封锁规则和统计链，确保你的端口恢复连通。

删除定时任务和残留文件。

🛡️ 脚本逻辑解析（安全保障）
前置检查：安装时自动判断系统（CentOS/Debian/Ubuntu），缺啥补啥。

流量统计：通过创建专属链 TRAFFIC_IN_端口 和 TRAFFIC_OUT_端口，利用 iptables 计数器累加流量，不依赖不可靠的日志分析。

解封机制：

当流量超标 -> 添加 DROP 规则 -> 记录封锁时间到 /tmp/traffic_guard_locks。

每分钟检查 -> 如果时间到了 -> 删除 DROP 规则 -> 重置 计数器 -> 端口恢复。

卸载无忧：专门编写了 clean_iptables 函数，卸载时会彻底清理环境，不会导致卸载后端口依然被封的情况。

# e-Traffic

# 一键管理脚本

wget --no-check-certificate -O eTraffic.sh https://raw.githubusercontent.com/xtonly/e-Traffic/refs/heads/main/eTraffic.sh && chmod +x eTraffic.sh && ./eTraffic.sh

💡 使用方法

想封10分钟？

在菜单 1 中输入：27932 1 10m

(解释：端口 27932，流量限制 1GB，超标封禁 10分钟)

想封24小时？

在菜单 1 中输入：27932 1 24

(解释：没有 m 后缀，默认单位为 小时)

想封半小时？

你可以输入 30m，或者 0.5 (即0.5小时)，脚本都能自动识别并正确计算。

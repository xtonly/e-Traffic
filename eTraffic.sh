#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v2.9 Stable-Loopback
# 修复核心：
# 1. [白名单] 封禁规则增加 `! -s 127.0.0.1`，防止切断 Xray 内部回落/转发
# 2. [稳定性] 移除 `ss -K` 暴力断连，防止导致 Xray 进程不稳定
# 3. [精准性] 优化 IPv6 规则，防止误伤本地链路地址
# ==============================================================

# --- 全局路径配置 ---
INSTALL_PATH="/usr/local/bin/traffic_guard.sh"
CONFIG_PATH="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"

# --- 颜色定义 ---
RES='\033[0m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'

pause_and_return() {
    echo ""
    read -n 1 -s -r -p ">>> 按任意键返回主菜单..."
}

check_dependencies() {
    if [ -f /etc/redhat-release ]; then CMD="yum install -y"; else CMD="apt-get install -y"; fi
    for pkg in bc iptables ip6tables nano net-tools; do
        if ! command -v $pkg &> /dev/null; then
            echo -e "${YELLOW}正在安装依赖: $pkg ...${RES}"
            $CMD $pkg >/dev/null 2>&1
        fi
    done
}

# 2. 生成核心监控脚本
create_monitor_script() {
    # 自动获取 SSH 端口
    SSH_PORT=$(netstat -tnlp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n 1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    cat > "$INSTALL_PATH" << EOF
#!/bin/bash
CONF_FILE="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
SAFE_SSH_PORT="$SSH_PORT"
mkdir -p "\$LOCK_DIR"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"; }

# 清理函数
clean_rules() {
    local port=\$1
    if ! [[ "\$port" =~ ^[0-9]+$ ]]; then return; fi
    
    # 清理 IPv4
    iptables -D INPUT -p tcp --dport "\$port" ! -s 127.0.0.1 -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "\$port" ! -s 127.0.0.1 -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "\$port" ! -d 127.0.0.1 -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --sport "\$port" ! -d 127.0.0.1 -j DROP 2>/dev/null
    # 兼容清理旧版规则 (不带 -s 127.0.0.1 的)
    iptables -D INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "\$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "\$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --sport "\$port" -j DROP 2>/dev/null
    
    # 清理统计链
    iptables -D INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -D INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -D OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -F "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -X "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -F "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -X "TRAFFIC_OUT_\$port" 2>/dev/null

    # 清理 IPv6
    ip6tables -D INPUT -p tcp --dport "\$port" ! -s ::1 -j DROP 2>/dev/null
    ip6tables -D INPUT -p udp --dport "\$port" ! -s ::1 -j DROP 2>/dev/null
    ip6tables -D OUTPUT -p tcp --sport "\$port" ! -d ::1 -j DROP 2>/dev/null
    ip6tables -D OUTPUT -p udp --sport "\$port" ! -d ::1 -j DROP 2>/dev/null
    # 兼容清理旧版
    ip6tables -D INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null
    ip6tables -D INPUT -p udp --dport "\$port" -j DROP 2>/dev/null
    ip6tables -D OUTPUT -p tcp --sport "\$port" -j DROP 2>/dev/null
    ip6tables -D OUTPUT -p udp --sport "\$port" -j DROP 2>/dev/null

    ip6tables -D INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -D INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -D OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    ip6tables -D OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    ip6tables -F "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -X "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -F "TRAFFIC_OUT_\$port" 2>/dev/null
    ip6tables -X "TRAFFIC_OUT_\$port" 2>/dev/null
}

# 初始化链
init_chain() {
    local port=\$1
    if ! [[ "\$port" =~ ^[0-9]+$ ]]; then return; fi

    # IPv4
    iptables -N "TRAFFIC_IN_\$port" 2>/dev/null
    if ! iptables -C INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port"
        iptables -I INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port"
    fi
    iptables -N "TRAFFIC_OUT_\$port" 2>/dev/null
    if ! iptables -C OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null; then
        iptables -I OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port"
        iptables -I OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port"
    fi

    # IPv6
    ip6tables -N "TRAFFIC_IN_\$port" 2>/dev/null
    if ! ip6tables -C INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null; then
        ip6tables -I INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port"
        ip6tables -I INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port"
    fi
    ip6tables -N "TRAFFIC_OUT_\$port" 2>/dev/null
    if ! ip6tables -C OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null; then
        ip6tables -I OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port"
        ip6tables -I OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port"
    fi
}

get_bytes() {
    local port=\$1
    if ! [[ "\$port" =~ ^[0-9]+$ ]]; then echo 0; return; fi
    local v4_in=\$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v4_out=\$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v6_in=\$(ip6tables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v6_out=\$(ip6tables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    echo \$((\${v4_in:-0} + \${v4_out:-0} + \${v6_in:-0} + \${v6_out:-0}))
}

block_action() {
    local port=\$1
    if [ -z "\$port" ] || ! [[ "\$port" =~ ^[0-9]+$ ]]; then return; fi
    if [ "\$port" == "\$SAFE_SSH_PORT" ]; then return; fi

    # IPv4 封锁 (排除本地回环)
    # 解释: ! -s 127.0.0.1 确保本机访问本机不被阻断
    if ! iptables -C INPUT -p tcp --dport "\$port" ! -s 127.0.0.1 -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "\$port" ! -s 127.0.0.1 -j DROP
        iptables -I INPUT 1 -p udp --dport "\$port" ! -s 127.0.0.1 -j DROP
        iptables -I OUTPUT 1 -p tcp --sport "\$port" ! -d 127.0.0.1 -j DROP
        iptables -I OUTPUT 1 -p udp --sport "\$port" ! -d 127.0.0.1 -j DROP
    fi
    
    # IPv6 封锁 (排除本地回环)
    if ! ip6tables -C INPUT -p tcp --dport "\$port" ! -s ::1 -j DROP 2>/dev/null; then
        ip6tables -I INPUT 1 -p tcp --dport "\$port" ! -s ::1 -j DROP
        ip6tables -I INPUT 1 -p udp --dport "\$port" ! -s ::1 -j DROP
        ip6tables -I OUTPUT 1 -p tcp --sport "\$port" ! -d ::1 -j DROP
        ip6tables -I OUTPUT 1 -p udp --sport "\$port" ! -d ::1 -j DROP
        log "ALERT: Port \$port limit exceeded. BLOCKED."
        # 已移除 ss -K，防止误杀进程
    fi
}

unblock_action() {
    local port=\$1
    clean_rules "\$port"
    init_chain "\$port"
    log "INFO: Port \$port expired. UNBLOCKED."
}

# 清理模式
if [ "\$1" == "cleanup" ]; then
    if [ -f "\$CONF_FILE" ]; then
        while read -r line; do
            line=\$(echo "\$line" | tr -d '\r')
            [[ "\$line" =~ ^#.*$ ]] && continue
            [ -z "\$line" ] && continue
            port=\$(echo \$line | awk -F: '{print \$1}')
            clean_rules "\$port"
        done < "\$CONF_FILE"
    fi
    rm -rf "\$LOCK_DIR"
    exit 0
fi

# 监控模式
NOW=\$(date +%s)
if [ -f "\$CONF_FILE" ]; then
    while read -r line; do
        line=\$(echo "\$line" | tr -d '\r')
        [[ "\$line" =~ ^#.*$ ]] && continue
        [ -z "\$line" ] && continue
        IFS=':' read -r port limit_gb block_hours <<< "\$line"
        if ! [[ "\$port" =~ ^[0-9]+$ ]]; then continue; fi

        init_chain "\$port"
        lock_file="\$LOCK_DIR/\$port.lock"
        
        if [ -f "\$lock_file" ]; then
            block_time=\$(cat "\$lock_file")
            [ -z "\$block_time" ] && block_time=\$NOW && echo \$NOW > "\$lock_file"
            elapsed=\$((\$NOW - \$block_time))
            unlock_sec=\$((\$block_hours * 3600))
            if [ "\$elapsed" -ge "\$unlock_sec" ]; then
                unblock_action "\$port"
                rm -f "\$lock_file"
            else
                block_action "\$port"
            fi
            continue
        fi
        
        total_bytes=\$(get_bytes "\$port")
        limit_bytes=\$(echo "\$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        
        if [ "\$total_bytes" -ge "\$limit_bytes" ]; then
            echo "\$NOW" > "\$lock_file"
            block_action "\$port"
            log "Port \$port reached limit (\${limit_gb}GB). Blocking."
        fi
    done < "\$CONF_FILE"
fi
EOF
    chmod +x "$INSTALL_PATH"
}

# 3. 仪表盘
show_status() {
    if [ ! -f "$CONFIG_PATH" ]; then echo -e "${RED}请先安装！${RES}"; return; fi
    echo -e "${BOLD}正在获取数据 (IPv4 + IPv6)...${RES}"
    SEP="+----------+----------------+----------------+----------+------------+"
    echo "$SEP"
    printf "| %-8s | %-14s | %-14s | %-8s | %-10s |\n" " PORT" " USED" " LIMIT" " USAGE" " STATUS"
    echo "$SEP"
    
    while read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        IFS=':' read -r port limit_gb block_hours <<< "$line"
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then continue; fi

        v4_in=$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
        v4_out=$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
        v6_in=$(ip6tables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
        v6_out=$(ip6tables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
        bytes=$((${v4_in:-0} + ${v4_out:-0} + ${v6_in:-0} + ${v6_out:-0}))

        if [ "$bytes" -gt 1073741824 ]; then
            used_human=$(echo "scale=2; $bytes/1024/1024/1024" | bc)
            used_unit="GB"
        else
            used_human=$(echo "scale=2; $bytes/1024/1024" | bc)
            used_unit="MB"
        fi

        limit_bytes=$(echo "$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        if [ "$limit_bytes" -gt 0 ]; then percent=$(echo "scale=1; ($bytes * 100) / $limit_bytes" | bc); else percent="0"; fi

        if [ -f "$LOCK_DIR/$port.lock" ]; then
            status_txt="BLOCKED"
            color_code="${RED}"
        else
            status_txt="ACTIVE"
            color_code="${GREEN}"
        fi
        
        printf "| %-8s | %-14s | %-14s | %-8s | %b%-10s%b |\n" \
            " $port" " $used_human $used_unit" " ${limit_gb} GB" " $percent%" "$color_code" " $status_txt" "${RES}"
        echo "$SEP"
    done < "$CONFIG_PATH"
}

# 4. 安装
install_monitor() {
    check_dependencies
    echo "--------------------------------------------------------"
    echo -e "${YELLOW}配置监控规则 (IPv4/IPv6 双栈监控)${RES}"
    echo "格式: 端口 流量(GB) 时间(小时)   示例: 8080 500 24"
    echo "--------------------------------------------------------"
    > "$CONFIG_PATH"
    while true; do
        echo -e "${BLUE}>> 请输入规则 (回车结束):${RES}"
        read -p "> " input_rule
        if [ -z "$input_rule" ]; then break; fi
        clean_rule=$(echo "$input_rule" | tr -s ' ' ':')
        if [[ $(echo "$clean_rule" | grep -o ":" | wc -l) -lt 2 ]]; then echo -e "${RED}格式错误!${RES}"; continue; fi
        echo "$clean_rule" >> "$CONFIG_PATH"
        echo -e "${GREEN}已添加: $clean_rule${RES}"
    done
    [ ! -s "$CONFIG_PATH" ] && echo "80:100:24" > "$CONFIG_PATH"
    create_monitor_script
    if ! crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null; echo "* * * * * $INSTALL_PATH >/dev/null 2>&1") | crontab -
    fi
    bash "$INSTALL_PATH"
    echo -e "${GREEN}安装完成！已开启本地回环白名单保护。${RES}"
}

# 6. 救砖工具
force_reset() {
    echo -e "${RED}${BOLD}即将清空所有防火墙规则...${RES}"
    iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
    ip6tables -P INPUT ACCEPT; ip6tables -P OUTPUT ACCEPT; ip6tables -F
    echo -e "${GREEN}网络限制已解除。${RES}"
}

uninstall_monitor() {
    if [ -f "$INSTALL_PATH" ]; then bash "$INSTALL_PATH" cleanup; fi
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    rm -f "$INSTALL_PATH" "$CONFIG_PATH" "$LOG_FILE"
    rm -rf "$LOCK_DIR"
    echo -e "${GREEN}卸载完成！${RES}"
}

while true; do
    clear
    echo -e "${BLUE}==============================================${RES}"
    echo -e "${BOLD}    VPS 流量监控管家 (v2.9 Stable)${RES}"
    echo -e "${BLUE}==============================================${RES}"
    echo " 1. 安装/重置监控 (Install)"
    echo " 2. 编辑规则 (Edit)"
    echo " 3. 查看实时流量 (Status)"
    echo " 4. 查看日志 (Logs)"
    echo " 5. 彻底卸载 (Uninstall)"
    echo -e "${RED} 6. 暴力重置防火墙 (Emergency Reset)${RES}"
    echo " 0. 退出 (Exit)"
    echo -e "${BLUE}==============================================${RES}"
    read -p "请输入数字 [0-6]: " choice
    case "$choice" in
        1) install_monitor; pause_and_return ;;
        2) [ -f "$CONFIG_PATH" ] && nano "$CONFIG_PATH" || echo "请先安装"; pause_and_return ;;
        3) show_status; pause_and_return ;;
        4) [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" || echo "无日志"; pause_and_return ;;
        5) uninstall_monitor; pause_and_return ;;
        6) force_reset; pause_and_return ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done

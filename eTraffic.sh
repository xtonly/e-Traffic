#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v3.8 Compatibility
# 修复日志：
# 1. [关键] 引入 "Stateful" 状态检测：强制放行已建立连接，防止断流
# 2. [白名单] 新增 "Self-IP" 白名单：自动放行公网IP的回环流量，修复Hairpin NAT问题
# 3. [安全] 卸载/解封逻辑优化：只删除特定规则，绝不执行 iptables -F (防止误删代理规则)
# ==============================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG_PATH="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
INSTALL_PATH="/usr/local/bin/traffic_guard.sh"

# 颜色
RES='\033[0m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'

pause_and_return() { echo ""; read -n 1 -s -r -p ">>> 按任意键返回主菜单..."; }

check_dependencies() {
    if [ -f /etc/redhat-release ]; then CMD="yum install -y"; else CMD="apt-get install -y"; fi
    for pkg in bc iptables ip6tables nano net-tools cronie; do
        if ! command -v $pkg &> /dev/null; then echo -e "${YELLOW}安装依赖: $pkg${RES}"; $CMD $pkg >/dev/null 2>&1; fi
    done
    systemctl enable crond >/dev/null 2>&1
    systemctl start crond >/dev/null 2>&1
}

create_monitor_script() {
    # 1. 获取 SSH 端口
    SSH_PORT=$(netstat -tnlp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n 1 | tr -d '[:space:]')
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    
    # 2. 获取本机公网 IP (用于白名单)
    MY_IP=$(curl -s4 ifconfig.me | tr -d '[:space:]')
    
    cat > "$INSTALL_PATH" << EOF
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF_FILE="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
SAFE_SSH_PORT="$SSH_PORT"
SELF_IP="$MY_IP"

mkdir -p "\$LOCK_DIR"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"; }

# --- 核心：建立安全基石 (Stateful + Whitelist) ---
setup_foundation() {
    # 1. 放行所有 "已建立" 连接 (Stateful)
    # 这确保了正常的业务流量不会被脚本误杀中断
    if ! iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi
    if ! ip6tables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        ip6tables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi

    # 2. 放行 lo (本地回环)
    if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 2 -i lo -j ACCEPT
    fi
    if ! ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
        ip6tables -I INPUT 2 -i lo -j ACCEPT
    fi
    
    # 3. 放行本机公网 IP (解决 Hairpin NAT 问题)
    if [ ! -z "\$SELF_IP" ]; then
        if ! iptables -C INPUT -s "\$SELF_IP" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 3 -s "\$SELF_IP" -j ACCEPT
        fi
    fi
}

clean_rules() {
    local port=\$1
    if ! echo "\$port" | grep -qE '^[0-9]+$'; then return; fi
    
    # 精准删除封禁规则 (不再暴力 flush)
    while iptables -D INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p udp --dport "\$port" -j DROP 2>/dev/null; do :; done
    while ip6tables -D INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; do :; done
    while ip6tables -D INPUT -p udp --dport "\$port" -j DROP 2>/dev/null; do :; done
    
    # 清理计数链
    iptables -F "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -X "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -F "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -X "TRAFFIC_OUT_\$port" 2>/dev/null
    
    ip6tables -F "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -X "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -F "TRAFFIC_OUT_\$port" 2>/dev/null
    ip6tables -X "TRAFFIC_OUT_\$port" 2>/dev/null
    
    # 清理引用 (从 INPUT/OUTPUT 链中移除跳转)
    iptables -D INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -D INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -D OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    
    ip6tables -D INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -D INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    ip6tables -D OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    ip6tables -D OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
}

init_chain() {
    local port=\$1
    if ! echo "\$port" | grep -qE '^[0-9]+$'; then return; fi
    setup_foundation

    # 建立计数链 (追加到末尾，不影响前面的白名单)
    iptables -N "TRAFFIC_IN_\$port" 2>/dev/null
    if ! iptables -C INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null; then
        iptables -A INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port"
        iptables -A INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port"
    fi
    iptables -N "TRAFFIC_OUT_\$port" 2>/dev/null
    if ! iptables -C OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null; then
        iptables -A OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port"
        iptables -A OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port"
    fi

    ip6tables -N "TRAFFIC_IN_\$port" 2>/dev/null
    if ! ip6tables -C INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null; then
        ip6tables -A INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port"
        ip6tables -A INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port"
    fi
    ip6tables -N "TRAFFIC_OUT_\$port" 2>/dev/null
    if ! ip6tables -C OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null; then
        ip6tables -A OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port"
        ip6tables -A OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port"
    fi
}

get_bytes() {
    local port=\$1
    if ! echo "\$port" | grep -qE '^[0-9]+$'; then echo 0; return; fi
    local v4_in=\$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v4_out=\$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v6_in=\$(ip6tables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v6_out=\$(ip6tables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    echo \$((\${v4_in:-0} + \${v4_out:-0} + \${v6_in:-0} + \${v6_out:-0}))
}

block_action() {
    local port=\$1
    if [ -z "\$port" ]; then return; fi
    if ! echo "\$port" | grep -qE '^[0-9]+$'; then return; fi
    if [ "\$port" == "\$SAFE_SSH_PORT" ]; then return; fi
    
    setup_foundation

    # 封禁规则：插入到 Index 4 (在所有白名单之后)
    if ! iptables -C INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; then
        iptables -I INPUT 4 -p tcp --dport "\$port" -j DROP
        iptables -I INPUT 4 -p udp --dport "\$port" -j DROP
    fi
    if ! ip6tables -C INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; then
        ip6tables -I INPUT 4 -p tcp --dport "\$port" -j DROP
        ip6tables -I INPUT 4 -p udp --dport "\$port" -j DROP
        log "ALERT: Port \$port BLOCKED."
    fi
}

unblock_action() {
    local port=\$1
    clean_rules "\$port"
    init_chain "\$port"
    log "INFO: Port \$port UNBLOCKED."
}

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

NOW=\$(date +%s)
if [ -f "\$CONF_FILE" ]; then
    setup_foundation
    while read -r line; do
        line=\$(echo "\$line" | tr -d '\r')
        [[ "\$line" =~ ^#.*$ ]] && continue
        [ -z "\$line" ] && continue
        IFS=':' read -r port limit_gb raw_time <<< "\$line"
        if ! echo "\$port" | grep -qE '^[0-9]+$'; then continue; fi

        init_chain "\$port"
        lock_file="\$LOCK_DIR/\$port.lock"
        
        if [[ "\$raw_time" == *"m"* ]]; then
            time_val=\${raw_time%m}
            unlock_sec=\$(echo "\$time_val * 60" | bc | cut -d. -f1)
        else
            unlock_sec=\$(echo "\$raw_time * 3600" | bc | cut -d. -f1)
        fi
        
        if [ -f "\$lock_file" ]; then
            block_time=\$(cat "\$lock_file")
            [ -z "\$block_time" ] && block_time=\$NOW && echo \$NOW > "\$lock_file"
            elapsed=\$((\$NOW - \$block_time))
            if [ "\$elapsed" -ge "\$unlock_sec" ]; then
                unblock_action "\$port"
                rm -f "\$lock_file"
            else
                block_action "\$port"
            fi
            continue
        fi
        
        total_bytes=\$(get_bytes "\$port")
        if ! command -v bc &> /dev/null; then continue; fi
        limit_bytes=\$(echo "\$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        
        if [ "\$total_bytes" -ge "\$limit_bytes" ]; then
            echo "\$NOW" > "\$lock_file"
            block_action "\$port"
            log "Port \$port limit reached. Blocking."
        fi
    done < "\$CONF_FILE"
fi
EOF
    sed -i 's/\r//g' "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
}

show_status() {
    if [ ! -f "$CONFIG_PATH" ]; then echo -e "${RED}请先安装！${RES}"; return; fi
    echo -e "${BOLD}实时数据 (IPv4+IPv6)${RES}"
    SEP="+----------+----------------+----------------+----------+------------+"
    echo "$SEP"
    printf "| %-8s | %-14s | %-14s | %-8s | %-10s |\n" " PORT" " USED" " LIMIT" " USAGE" " STATUS"
    echo "$SEP"
    
    while read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        IFS=':' read -r port limit_gb raw_time <<< "$line"
        if ! echo "$port" | grep -qE '^[0-9]+$'; then continue; fi

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

install_monitor() {
    check_dependencies
    echo "--------------------------------------------------------"
    echo -e "${YELLOW}配置监控规则${RES}"
    echo -e "👉 10分钟写法: ${BOLD}10m${RES}"
    echo -e "👉 1小时写法:  ${BOLD}1${RES}"
    echo -e "示例: ${BOLD}8080 500 10m${RES}"
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
    systemctl restart crond >/dev/null 2>&1
    bash "$INSTALL_PATH"
    echo -e "${GREEN}安装完成！已启用白名单保护 (Self-IP + Established)。${RES}"
}

restart_proxy() {
    echo -e "${BOLD}尝试重启代理服务以修复规则...${RES}"
    systemctl restart shoes 2>/dev/null || systemctl restart eshoes 2>/dev/null || systemctl restart xray 2>/dev/null
    echo -e "${GREEN}服务重启尝试完成。${RES}"
}

uninstall_monitor() {
    if [ -f "$INSTALL_PATH" ]; then bash "$INSTALL_PATH" cleanup; fi
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    rm -f "$INSTALL_PATH" "$CONFIG_PATH" "$LOG_FILE"
    rm -rf "$LOCK_DIR"
    echo -e "${GREEN}卸载完成！${RES}"
}

manual_check() {
    echo -e "${BOLD}正在强制执行检测...${RES}"
    bash "$INSTALL_PATH"
    echo -e "${GREEN}执行完毕！${RES}"
}

while true; do
    clear
    echo -e "${BLUE}==============================================${RES}"
    echo -e "${BOLD}    VPS 流量监控管家 (v3.8 Final Compat)${RES}"
    echo -e "${BLUE}==============================================${RES}"
    echo " 1. 安装/重置监控 (Install)"
    echo " 2. 编辑规则 (Edit)"
    echo " 3. 查看实时流量 (Status)"
    echo " 4. 查看日志 (Logs)"
    echo " 5. 彻底卸载 (Uninstall)"
    echo -e "${YELLOW} 6. 修复代理服务 (Restart Proxy)${RES}"
    echo -e "${YELLOW} 7. 手动强制执行检测 (Force Check)${RES}"
    echo " 0. 退出 (Exit)"
    echo -e "${BLUE}==============================================${RES}"
    read -p "请输入数字 [0-7]: " choice
    case "$choice" in
        1) install_monitor; pause_and_return ;;
        2) [ -f "$CONFIG_PATH" ] && nano "$CONFIG_PATH" || echo "请先安装"; pause_and_return ;;
        3) show_status; pause_and_return ;;
        4) [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" || echo "无日志"; pause_and_return ;;
        5) uninstall_monitor; pause_and_return ;;
        6) restart_proxy; pause_and_return ;;
        7) manual_check; pause_and_return ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done

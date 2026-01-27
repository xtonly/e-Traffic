#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v2.8 Final-Rescue
# 更新日志：
# 1. [重磅] 新增 IPv6 支持 (ip6tables)：同步监控和封锁 IPv6 流量
# 2. [安全] SSH 自动白名单：脚本会自动识别并保护 SSH 端口，防自杀
# 3. [救砖] 新增 "6. 暴力重置防火墙"：一键清除所有规则，以防万一
# 4. [修复] 配置文件清洗：自动处理 Windows 换行符和空格
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
    # 自动获取当前 SSH 端口 (IPv4/IPv6)
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

# 清理函数 (IPv4 + IPv6)
clean_rules() {
    local port=\$1
    if ! [[ "\$port" =~ ^[0-9]+$ ]]; then return; fi
    
    # IPv4 清理
    iptables -D INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "\$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "\$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --sport "\$port" -j DROP 2>/dev/null
    iptables -D INPUT -p tcp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -D INPUT -p udp --dport "\$port" -j "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -D OUTPUT -p udp --sport "\$port" -j "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -F "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -X "TRAFFIC_IN_\$port" 2>/dev/null
    iptables -F "TRAFFIC_OUT_\$port" 2>/dev/null
    iptables -X "TRAFFIC_OUT_\$port" 2>/dev/null

    # IPv6 清理
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

# 初始化链 (IPv4 + IPv6)
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
    # IPv4 统计
    local v4_in=\$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v4_out=\$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    # IPv6 统计
    local v6_in=\$(ip6tables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v6_out=\$(ip6tables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_\$port" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    
    echo \$((\${v4_in:-0} + \${v4_out:-0} + \${v6_in:-0} + \${v6_out:-0}))
}

block_action() {
    local port=\$1
    if [ -z "\$port" ] || ! [[ "\$port" =~ ^[0-9]+$ ]]; then return; fi
    # 安全锁：绝对不封 SSH 端口
    if [ "\$port" == "\$SAFE_SSH_PORT" ]; then return; fi

    # IPv4 封锁
    if ! iptables -C INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "\$port" -j DROP
        iptables -I INPUT 1 -p udp --dport "\$port" -j DROP
        iptables -I OUTPUT 1 -p tcp --sport "\$port" -j DROP
        iptables -I OUTPUT 1 -p udp --sport "\$port" -j DROP
    fi
    # IPv6 封锁
    if ! ip6tables -C INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; then
        ip6tables -I INPUT 1 -p tcp --dport "\$port" -j DROP
        ip6tables -I INPUT 1 -p udp --dport "\$port" -j DROP
        ip6tables -I OUTPUT 1 -p tcp --sport "\$port" -j DROP
        ip6tables -I OUTPUT 1 -p udp --sport "\$port" -j DROP
        log "ALERT: Port \$port limit exceeded. BLOCKED (v4+v6)."
        # 杀掉连接
        timeout 2 ss -K dport = :\$port >/dev/null 2>&1
    fi
}

unblock_action() {
    local port=\$1
    clean_rules "\$port"
    init_chain "\$port"
    log "INFO: Port \$port expired. UNBLOCKED."
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

# 3. 仪表盘 (显示总流量 v4+v6)
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

        # 获取 v4+v6 总流量
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
        if [[ $(echo "$clean_rule" | grep -o ":" | wc -l) -lt 2 ]]; then
             echo -e "${RED}格式错误!${RES}"; continue
        fi
        echo "$clean_rule" >> "$CONFIG_PATH"
        echo -e "${GREEN}已添加: $clean_rule${RES}"
    done
    [ ! -s "$CONFIG_PATH" ] && echo "80:100:24" > "$CONFIG_PATH"
    create_monitor_script
    if ! crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null; echo "* * * * * $INSTALL_PATH >/dev/null 2>&1") | crontab -
    fi
    bash "$INSTALL_PATH"
    echo -e "${GREEN}安装完成！已启用双栈监控与 SSH 保护。${RES}"
}

# 6. 救砖工具 (Force Reset)
force_reset() {
    echo -e "${RED}${BOLD}警告：这将清除所有 INPUT/OUTPUT 链中的 DROP 规则！${RES}"
    read -p "确认执行？(y/n): " confirm
    if [ "$confirm" == "y" ]; then
        iptables -S INPUT | grep "DROP" | sed 's/-A/-D/' | while read rule; do iptables $rule; done
        iptables -S OUTPUT | grep "DROP" | sed 's/-A/-D/' | while read rule; do iptables $rule; done
        ip6tables -S INPUT | grep "DROP" | sed 's/-A/-D/' | while read rule; do ip6tables $rule 2>/dev/null; done
        ip6tables -S OUTPUT | grep "DROP" | sed 's/-A/-D/' | while read rule; do ip6tables $rule 2>/dev/null; done
        echo -e "${GREEN}防火墙规则已强制重置，网络应已恢复。${RES}"
    fi
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
    echo -e "${BOLD}    VPS 流量监控管家 (v2.8 Final Rescue)${RES}"
    echo -e "${BLUE}==============================================${RES}"
    echo " 1. 安装/重置监控 (Install)"
    echo " 2. 编辑规则 (Edit)"
    echo " 3. 查看实时流量 (Status - IPv4+IPv6)"
    echo " 4. 查看日志 (Logs)"
    echo " 5. 彻底卸载 (Uninstall)"
    echo -e "${RED} 6. 暴力重置防火墙 (Network Rescue)${RES}"
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

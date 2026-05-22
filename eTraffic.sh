#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v4.1 Ultimate
# 融合极致排版UI、全局网卡监控与内外网流量智能分离
# ==============================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

# ================== 颜色代码与风格统一 ==================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
RESET='\033[0m'
BOLD='\033[1m'

# ================== 基础配置路径 ==================
CONFIG_PORT="/etc/traffic_guard_ports.conf"
CONFIG_GLOBAL="/etc/traffic_guard_global.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
INSTALL_PATH="/usr/local/bin/traffic_guard.sh"

# ================== 环境探测与缓存 ==================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 用户运行此脚本${RESET}"
   exit 1
fi

# 探测出海主网卡
DEFAULT_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
[[ -z "$DEFAULT_IFACE" ]] && DEFAULT_IFACE="eth0"

# 提取系统信息
if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYS_PRETTY_NAME=${PRETTY_NAME}
else
    SYS_PRETTY_NAME="Unknown Linux"
fi

PUBLIC_IPV4=$(curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 api.ipify.org || echo "无法获取")

# ================== 交互辅助函数 ==================
pause_and_return() { echo ""; read -n 1 -s -r -p ">>> 按任意键返回主菜单..."; }

check_dependencies() {
    if [ -f /etc/redhat-release ]; then CMD="yum install -y"; else CMD="apt-get install -y"; fi
    for pkg in bc iptables ip6tables nano net-tools cronie iproute2 jq; do
        if ! command -v $pkg &> /dev/null; then 
            echo -e "${YELLOW}正在安装必要依赖: $pkg${RESET}"
            $CMD $pkg >/dev/null 2>&1
        fi
    done
    systemctl enable crond >/dev/null 2>&1 || systemctl enable cron >/dev/null 2>&1
    systemctl start crond >/dev/null 2>&1 || systemctl start cron >/dev/null 2>&1
}

# ================== 核心守护进程生成引擎 ==================
create_monitor_script() {
    # 1. 获取 SSH 端口 (作为绝对白名单防御)
    SSH_PORT=$(netstat -tnlp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n 1 | tr -d '[:space:]')
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    
    # 2. 获取本机公网 IP (用于解决 Hairpin NAT 问题)
    MY_IP=$(curl -s4 ifconfig.me | tr -d '[:space:]')
    
    cat > "$INSTALL_PATH" << EOF
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF_PORT="$CONFIG_PORT"
CONF_GLOBAL="$CONFIG_GLOBAL"
LOG_FILE="$LOG_FILE"
LOCK_DIR="$LOCK_DIR"
SAFE_SSH_PORT="$SSH_PORT"
SELF_IP="$MY_IP"
MAIN_IFACE="$DEFAULT_IFACE"

mkdir -p "\$LOCK_DIR"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"; }

# --- 核心安全基石 ---
setup_foundation() {
    # Stateful 放行：保障已有业务不断流
    for cmd in iptables ip6tables; do
        if ! \$cmd -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            \$cmd -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
        fi
        if ! \$cmd -C INPUT -i lo -j ACCEPT 2>/dev/null; then
            \$cmd -I INPUT 2 -i lo -j ACCEPT
        fi
    done
    if [ ! -z "\$SELF_IP" ]; then
        if ! iptables -C INPUT -s "\$SELF_IP" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 3 -s "\$SELF_IP" -j ACCEPT
        fi
    fi
}

# --- 全局内外网流量精准监控链 ---
setup_global_accounting() {
    # IPv4 外网审计
    iptables -N G_IN 2>/dev/null
    iptables -N G_OUT 2>/dev/null
    iptables -C INPUT -i "\$MAIN_IFACE" -j G_IN 2>/dev/null || iptables -A INPUT -i "\$MAIN_IFACE" -j G_IN
    iptables -C OUTPUT -o "\$MAIN_IFACE" -j G_OUT 2>/dev/null || iptables -A OUTPUT -o "\$MAIN_IFACE" -j G_OUT
    
    # 剔除内网网段
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
        iptables -C G_IN -s \$net -j RETURN 2>/dev/null || iptables -A G_IN -s \$net -j RETURN
        iptables -C G_OUT -d \$net -j RETURN 2>/dev/null || iptables -A G_OUT -d \$net -j RETURN
    done
    # 标记公网流量落点 (挂载注释用于快速 grep 提取)
    iptables -C G_IN -m comment --comment "Global_Ext_In" -j RETURN 2>/dev/null || iptables -A G_IN -m comment --comment "Global_Ext_In" -j RETURN
    iptables -C G_OUT -m comment --comment "Global_Ext_Out" -j RETURN 2>/dev/null || iptables -A G_OUT -m comment --comment "Global_Ext_Out" -j RETURN

    # IPv6 外网审计
    ip6tables -N G_IN 2>/dev/null
    ip6tables -N G_OUT 2>/dev/null
    ip6tables -C INPUT -i "\$MAIN_IFACE" -j G_IN 2>/dev/null || ip6tables -A INPUT -i "\$MAIN_IFACE" -j G_IN
    ip6tables -C OUTPUT -o "\$MAIN_IFACE" -j G_OUT 2>/dev/null || ip6tables -A OUTPUT -o "\$MAIN_IFACE" -j G_OUT
    for net in fc00::/7 fe80::/10; do
        ip6tables -C G_IN -s \$net -j RETURN 2>/dev/null || ip6tables -A G_IN -s \$net -j RETURN
        ip6tables -C G_OUT -d \$net -j RETURN 2>/dev/null || ip6tables -A G_OUT -d \$net -j RETURN
    done
    ip6tables -C G_IN -m comment --comment "Global_Ext_In" -j RETURN 2>/dev/null || ip6tables -A G_IN -m comment --comment "Global_Ext_In" -j RETURN
    ip6tables -C G_OUT -m comment --comment "Global_Ext_Out" -j RETURN 2>/dev/null || ip6tables -A G_OUT -m comment --comment "Global_Ext_Out" -j RETURN
}

# --- 端口级监控链 ---
init_port_chain() {
    local port=\$1
    iptables -N "T_IN_\$port" 2>/dev/null
    iptables -C INPUT -p tcp --dport "\$port" -j "T_IN_\$port" 2>/dev/null || iptables -A INPUT -p tcp --dport "\$port" -j "T_IN_\$port"
    iptables -C INPUT -p udp --dport "\$port" -j "T_IN_\$port" 2>/dev/null || iptables -A INPUT -p udp --dport "\$port" -j "T_IN_\$port"
    iptables -N "T_OUT_\$port" 2>/dev/null
    iptables -C OUTPUT -p tcp --sport "\$port" -j "T_OUT_\$port" 2>/dev/null || iptables -A OUTPUT -p tcp --sport "\$port" -j "T_OUT_\$port"
    iptables -C OUTPUT -p udp --sport "\$port" -j "T_OUT_\$port" 2>/dev/null || iptables -A OUTPUT -p udp --sport "\$port" -j "T_OUT_\$port"
}

get_global_bytes() {
    local v4_in=\$(iptables -L G_IN -v -n -x 2>/dev/null | grep "Global_Ext_In" | awk '{print \$2}')
    local v4_out=\$(iptables -L G_OUT -v -n -x 2>/dev/null | grep "Global_Ext_Out" | awk '{print \$2}')
    local v6_in=\$(ip6tables -L G_IN -v -n -x 2>/dev/null | grep "Global_Ext_In" | awk '{print \$2}')
    local v6_out=\$(ip6tables -L G_OUT -v -n -x 2>/dev/null | grep "Global_Ext_Out" | awk '{print \$2}')
    echo \$((\${v4_in:-0} + \${v4_out:-0} + \${v6_in:-0} + \${v6_out:-0}))
}

get_port_bytes() {
    local p=\$1
    local v4_i=\$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="T_IN_\$p" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    local v4_o=\$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="T_OUT_\$p" '\$3 == t {sum+=\$2} END {printf "%.0f", sum}')
    echo \$((\${v4_i:-0} + \${v4_o:-0}))
}

# ================= 主循环逻辑 =================
NOW=\$(date +%s)
setup_foundation
setup_global_accounting

# 1. 检查全局限额
if [ -f "\$CONF_GLOBAL" ]; then
    source "\$CONF_GLOBAL"
    if [ "\$GLOBAL_LIMIT_GB" -gt 0 ]; then
        gb_bytes=\$(echo "\$GLOBAL_LIMIT_GB * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        cur_bytes=\$(get_global_bytes)
        lock_file="\$LOCK_DIR/global.lock"
        
        if [ "\$cur_bytes" -ge "\$gb_bytes" ]; then
            if [ ! -f "\$lock_file" ]; then
                touch "\$lock_file"
                # 全局封禁：在建立连接和本地回环后，阻断所有外网新请求（保留SSH）
                iptables -I INPUT 4 -i "\$MAIN_IFACE" -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP
                iptables -I INPUT 4 -i "\$MAIN_IFACE" -p udp -m comment --comment "GLOBAL_BLOCK" -j DROP
                log "CRITICAL: Global traffic limit reached! External access blocked."
            fi
        else
            if [ -f "\$lock_file" ]; then
                rm -f "\$lock_file"
                while iptables -D INPUT -i "\$MAIN_IFACE" -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; do :; done
                while iptables -D INPUT -i "\$MAIN_IFACE" -p udp -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; do :; done
                log "INFO: Global traffic lock released."
            fi
        fi
    fi
fi

# 2. 检查端口级限额
if [ -f "\$CONF_PORT" ]; then
    while read -r line; do
        [[ -z "\$line" || "\$line" =~ ^#.*$ ]] && continue
        IFS=':' read -r port limit_gb raw_time <<< "\$line"
        if ! echo "\$port" | grep -qE '^[0-9]+$'; then continue; fi

        init_port_chain "\$port"
        lock_file="\$LOCK_DIR/port_\$port.lock"
        
        if [[ "\$raw_time" == *"m"* ]]; then
            unlock_sec=\$(echo "\${raw_time%m} * 60" | bc | cut -d. -f1)
        else
            unlock_sec=\$(echo "\$raw_time * 3600" | bc | cut -d. -f1)
        fi
        
        if [ -f "\$lock_file" ]; then
            block_time=\$(cat "\$lock_file")
            elapsed=\$((\$NOW - \$block_time))
            if [ "\$elapsed" -ge "\$unlock_sec" ]; then
                # 解封
                while iptables -D INPUT -p tcp --dport "\$port" -j DROP 2>/dev/null; do :; done
                rm -f "\$lock_file"
                log "INFO: Port \$port UNBLOCKED."
            fi
            continue
        fi
        
        limit_bytes=\$(echo "\$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        total_bytes=\$(get_port_bytes "\$port")
        
        if [ "\$total_bytes" -ge "\$limit_bytes" ]; then
            echo "\$NOW" > "\$lock_file"
            if [ "\$port" != "\$SAFE_SSH_PORT" ]; then
                iptables -I INPUT 4 -p tcp --dport "\$port" -j DROP
                iptables -I INPUT 4 -p udp --dport "\$port" -j DROP
                log "ALERT: Port \$port BLOCKED (Traffic Limit)."
            fi
        fi
    done < "\$CONF_PORT"
fi
EOF
    sed -i 's/\r//g' "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
}

# ================== 界面：实时看板 ==================
show_status() {
    clear
    echo -e "${CYAN}========= 全局与网卡流量 (已剔除内网数据) =========${RESET}"
    if [ -f "$INSTALL_PATH" ]; then
        bash "$INSTALL_PATH" >/dev/null 2>&1 # 强制刷新一次计数器
        
        # 抓取全局
        v4_in=$(iptables -L G_IN -v -n -x 2>/dev/null | grep "Global_Ext_In" | awk '{print $2}')
        v4_out=$(iptables -L G_OUT -v -n -x 2>/dev/null | grep "Global_Ext_Out" | awk '{print $2}')
        g_bytes=$((${v4_in:-0} + ${v4_out:-0}))
        
        if [ "$g_bytes" -gt 1073741824 ]; then
            g_used=$(echo "scale=2; $g_bytes/1024/1024/1024" | bc)
            g_unit="GB"
        else
            g_used=$(echo "scale=2; $g_bytes/1024/1024" | bc)
            g_unit="MB"
        fi

        g_limit="未设置"
        g_status="${GREEN}运行中${RESET}"
        if [ -f "$CONFIG_GLOBAL" ]; then
            source "$CONFIG_GLOBAL"
            if [ "$GLOBAL_LIMIT_GB" -gt 0 ]; then
                g_limit="${GLOBAL_LIMIT_GB} GB"
                if [ -f "$LOCK_DIR/global.lock" ]; then g_status="${RED}全网熔断阻断中${RESET}"; fi
            fi
        fi
        
        echo -e " ${BLUE}主网卡:${RESET} ${WHITE}${DEFAULT_IFACE}${RESET}    ${BLUE}总限额:${RESET} ${WHITE}${g_limit}${RESET}    ${BLUE}外部已用:${RESET} ${YELLOW}${g_used} ${g_unit}${RESET}    ${BLUE}状态:${RESET} ${g_status}"
    else
        echo -e "${RED}未安装守护进程！请先启动服务。${RESET}"
    fi

    echo ""
    echo -e "${CYAN}========= 端口级实时审计 (包含入站/出站) =========${RESET}"
    SEP="+----------+----------------+----------------+----------+------------+"
    echo "$SEP"
    printf "| %-8s | %-14s | %-14s | %-8s | %-10s |\n" " PORT" " USED" " LIMIT" " USAGE" " STATUS"
    echo "$SEP"
    
    if [ -f "$CONFIG_PORT" ]; then
        while read -r line; do
            [[ -z "$line" || "$line" =~ ^#.*$ ]] && continue
            IFS=':' read -r port limit_gb raw_time <<< "$line"
            if ! echo "$port" | grep -qE '^[0-9]+$'; then continue; fi

            v4_i=$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="T_IN_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
            v4_o=$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="T_OUT_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
            bytes=$((${v4_i:-0} + ${v4_o:-0}))

            if [ "$bytes" -gt 1073741824 ]; then
                used_h=$(echo "scale=2; $bytes/1024/1024/1024" | bc)
                unit="GB"
            else
                used_h=$(echo "scale=2; $bytes/1024/1024" | bc)
                unit="MB"
            fi

            limit_bytes=$(echo "$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
            if [ "$limit_bytes" -gt 0 ]; then percent=$(echo "scale=1; ($bytes * 100) / $limit_bytes" | bc); else percent="0"; fi

            if [ -f "$LOCK_DIR/port_$port.lock" ]; then
                s_txt="BLOCKED"
                color_code="${RED}"
            else
                s_txt="ACTIVE"
                color_code="${GREEN}"
            fi
            
            printf "| %-8s | %-14s | %-14s | %-8s | %b%-10s%b |\n" \
                " $port" " $used_h $unit" " ${limit_gb} GB" " $percent%" "$color_code" " $s_txt" "${RESET}"
            echo "$SEP"
        done < "$CONFIG_PORT"
    else
        printf "| %-60s |\n" " 未配置任何端口监控规则"
        echo "$SEP"
    fi
}

# ================== 界面：配置管理 ==================
menu_global_config() {
    clear
    echo -e "${CYAN}============= [1] 全局出海流量限额配置 =============${RESET}"
    echo -e "${YELLOW}说明：只统计公网流量，自动屏蔽内网IP，到达限额后将阻断外部连接（保留SSH）${RESET}"
    echo -e "${MAGENTA}------------------------------------------------------${RESET}"
    read -p "请输入整机每月公网流量上限 (单位:GB, 输入0为不限制): " g_limit
    if [[ "$g_limit" =~ ^[0-9]+$ ]]; then
        echo "GLOBAL_LIMIT_GB=$g_limit" > "$CONFIG_GLOBAL"
        echo -e "${GREEN}全局配置已生效！${RESET}"
    else
        echo -e "${RED}输入无效！${RESET}"
    fi
}

menu_port_config() {
    clear
    echo -e "${CYAN}============= [2] 独立端口控制规则 =============${RESET}"
    echo -e "${YELLOW}格式示例: 8080:500:10m (端口8080 限额500G 超额封锁10分钟后解封)${RESET}"
    echo -e "${MAGENTA}--------------------------------------------------${RESET}"
    touch "$CONFIG_PORT"
    while true; do
        echo -e "${BLUE}>> 请输入规则 (直接回车结束并保存):${RESET}"
        read -p "> " input_rule
        if [ -z "$input_rule" ]; then break; fi
        clean_rule=$(echo "$input_rule" | tr -s ' ' ':')
        if [[ $(echo "$clean_rule" | grep -o ":" | wc -l) -lt 2 ]]; then echo -e "${RED}格式错误!${RESET}"; continue; fi
        echo "$clean_rule" >> "$CONFIG_PORT"
        echo -e "${GREEN}已添加: $clean_rule${RESET}"
    done
}

service_install() {
    check_dependencies
    create_monitor_script
    
    # [修复点 1] 兜底创建缓存目录，防止部分强依赖该目录的系统组件抽风
    mkdir -p /root/.cache
    
    # [修复点 2] 改用系统级 cron 配置，比 crontab 管道写入更稳如老狗
    echo "* * * * * root bash $INSTALL_PATH >/dev/null 2>&1" > /etc/cron.d/traffic_guard
    chmod 644 /etc/cron.d/traffic_guard
    
    # 兼容重启 cron 服务
    systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1
    
    bash "$INSTALL_PATH"
    echo -e "${GREEN}守护进程与内外网分流环境安装/重载成功！${RESET}"
}

service_uninstall() {
    # 优先清理系统级 cron，同时兼容清理可能残留的用户级旧规则
    rm -f /etc/cron.d/traffic_guard
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab - 2>/dev/null
    
    rm -f "$INSTALL_PATH" "$CONFIG_PORT" "$CONFIG_GLOBAL" "$LOG_FILE"
    rm -rf "$LOCK_DIR"
    
    # 清理iptables链
    iptables -D INPUT -i "$DEFAULT_IFACE" -j G_IN 2>/dev/null
    iptables -F G_IN 2>/dev/null && iptables -X G_IN 2>/dev/null
    iptables -D OUTPUT -o "$DEFAULT_IFACE" -j G_OUT 2>/dev/null
    iptables -F G_OUT 2>/dev/null && iptables -X G_OUT 2>/dev/null
    
    ip6tables -D INPUT -i "$DEFAULT_IFACE" -j G_IN 2>/dev/null
    ip6tables -F G_IN 2>/dev/null && ip6tables -X G_IN 2>/dev/null
    ip6tables -D OUTPUT -o "$DEFAULT_IFACE" -j G_OUT 2>/dev/null
    ip6tables -F G_OUT 2>/dev/null && ip6tables -X G_OUT 2>/dev/null
    
    echo -e "${GREEN}卸载与清理完成！${RESET}"
}

# ================== 主菜单 ==================
while true; do
    clear
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "${CYAN}             VPS 流量监控与全网管家 4.1                     ${RESET}"
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e " ${BLUE}系统环境 :${RESET} ${WHITE}${SYS_PRETTY_NAME}${RESET}"
    echo -e " ${BLUE}出海网卡 :${RESET} ${WHITE}${DEFAULT_IFACE} ${YELLOW}(自动嗅探并隔离内网)${RESET}"
    echo -e " ${BLUE}公网 IPv4:${RESET} ${GREEN}${PUBLIC_IPV4}${RESET}"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    echo -e "  ${YELLOW}1.${RESET} 全局流量管理 (设置网卡出海总上限)"
    echo -e "  ${YELLOW}2.${RESET} 端口流量管理 (添加/编辑独立监控规则)"
    echo -e "  ${YELLOW}3.${RESET} 实时流量看板 (查看全局与各端口情况)"
    echo -e "  ${YELLOW}4.${RESET} 重载监控服务 (修改配置后请执行此项)"
    echo -e "  ${YELLOW}5.${RESET} 彻底卸载清理 (清空规则与拦截)"
    echo -e "  ${YELLOW}6.${RESET} 查看执行日志 (拦截记录)"
    echo -e "  ${RED}9.${RESET} 修复代理服务 (重启常用 Proxy / 刷新端口占用)"
    echo -e "  ${WHITE}0.${RESET} 退出脚本"
    echo -e "${MAGENTA}=========================================================${RESET}"
    read -p "  请输入选项: " choice
    case "$choice" in
        1) menu_global_config; service_install; pause_and_return ;;
        2) menu_port_config; service_install; pause_and_return ;;
        3) show_status; pause_and_return ;;
        4) service_install; pause_and_return ;;
        5) service_uninstall; pause_and_return ;;
        6) [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" || echo "暂无日志产生"; pause_and_return ;;
        9) echo -e "${BOLD}尝试重启代理服务以修复规则...${RESET}"; systemctl restart shoes 2>/dev/null || systemctl restart eshoes 2>/dev/null || systemctl restart xray 2>/dev/null; echo -e "${GREEN}服务重启尝试完成。${RESET}"; pause_and_return ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done

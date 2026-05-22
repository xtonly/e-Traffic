#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v5.0 Ultimate
# 融合极致排版UI、全局网卡监控、内外网分离与绝对底层记账链架构
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

DEFAULT_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
[[ -z "$DEFAULT_IFACE" ]] && DEFAULT_IFACE="eth0"

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
    local missing_pkgs=""

    if [ -f /etc/redhat-release ]; then 
        CMD="yum install -y"
        CRON_PKG="cronie"
    else 
        CMD="apt-get -y install"
        CRON_PKG="cron"
    fi

    ! command -v bc &> /dev/null && missing_pkgs+=" bc"
    ! command -v iptables &> /dev/null && missing_pkgs+=" iptables"
    ! command -v nano &> /dev/null && missing_pkgs+=" nano"
    ! command -v netstat &> /dev/null && missing_pkgs+=" net-tools"
    ! command -v crontab &> /dev/null && missing_pkgs+=" $CRON_PKG"
    ! command -v ip &> /dev/null && missing_pkgs+=" iproute2"
    ! command -v jq &> /dev/null && missing_pkgs+=" jq"

    if [ -n "$missing_pkgs" ]; then
        echo -e "${YELLOW}--> 正在集中安装缺失的依赖: ${missing_pkgs}${RESET}"
        if [[ "$CMD" == *"apt-get"* ]]; then apt-get update >/dev/null 2>&1; fi
        $CMD $missing_pkgs >/dev/null 2>&1
    fi

    systemctl enable crond >/dev/null 2>&1 || systemctl enable cron >/dev/null 2>&1
    systemctl start crond >/dev/null 2>&1 || systemctl start cron >/dev/null 2>&1
}

# ================== 核心守护进程生成引擎 ==================
create_monitor_script() {
    SSH_PORT=$(sshd -T 2>/dev/null | grep -i "^port " | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    if [[ -z "$SSH_PORT" || ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        SSH_PORT=$(grep -iE "^Port\s+[0-9]+" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    fi
    [[ -z "$SSH_PORT" || ! "$SSH_PORT" =~ ^[0-9]+$ ]] && SSH_PORT=22
    
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

# --- 终极核心：重构防火墙链架构 ---
setup_foundation() {
    for cmd in iptables ip6tables; do
        # 创建我们私有的三层处理链
        \$cmd -N TG_ACCT_IN 2>/dev/null
        \$cmd -N TG_ACCT_OUT 2>/dev/null
        \$cmd -N TG_BLOCK 2>/dev/null
        \$cmd -N TG_SAFE 2>/dev/null
        
        # 严格按照从上到下的顺序挂载：记账(第一) -> 阻断(第二) -> 白名单(第三)
        if ! \$cmd -C INPUT -j TG_SAFE 2>/dev/null; then \$cmd -I INPUT 1 -j TG_SAFE; fi
        if ! \$cmd -C INPUT -j TG_BLOCK 2>/dev/null; then \$cmd -I INPUT 1 -j TG_BLOCK; fi
        if ! \$cmd -C INPUT -j TG_ACCT_IN 2>/dev/null; then \$cmd -I INPUT 1 -j TG_ACCT_IN; fi
        
        if ! \$cmd -C OUTPUT -j TG_ACCT_OUT 2>/dev/null; then \$cmd -I OUTPUT 1 -j TG_ACCT_OUT; fi

        # 填充防断流与防自锁白名单
        if ! \$cmd -C TG_SAFE -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            \$cmd -A TG_SAFE -m state --state ESTABLISHED,RELATED -j ACCEPT
        fi
        if ! \$cmd -C TG_SAFE -i lo -j ACCEPT 2>/dev/null; then
            \$cmd -A TG_SAFE -i lo -j ACCEPT
        fi
    done
    
    # IPv4 专属节点自反白名单
    if [ ! -z "\$SELF_IP" ]; then
        if ! iptables -C TG_SAFE -s "\$SELF_IP" -j ACCEPT 2>/dev/null; then
            iptables -A TG_SAFE -s "\$SELF_IP" -j ACCEPT
        fi
    fi
}

setup_global_accounting() {
    for cmd in iptables ip6tables; do
        \$cmd -N G_IN 2>/dev/null
        \$cmd -N G_OUT 2>/dev/null
        
        # 将流量计挂载到记账主链
        \$cmd -C TG_ACCT_IN -i "\$MAIN_IFACE" -j G_IN 2>/dev/null || \$cmd -A TG_ACCT_IN -i "\$MAIN_IFACE" -j G_IN
        \$cmd -C TG_ACCT_OUT -o "\$MAIN_IFACE" -j G_OUT 2>/dev/null || \$cmd -A TG_ACCT_OUT -o "\$MAIN_IFACE" -j G_OUT
        
        # 剔除内网网段
        for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10; do
            \$cmd -C G_IN -s \$net -j RETURN 2>/dev/null || \$cmd -A G_IN -s \$net -j RETURN 2>/dev/null
            \$cmd -C G_OUT -d \$net -j RETURN 2>/dev/null || \$cmd -A G_OUT -d \$net -j RETURN 2>/dev/null
        done
        
        # 挂上注释签，方便统计
        \$cmd -C G_IN -m comment --comment "Global_Ext_In" -j RETURN 2>/dev/null || \$cmd -A G_IN -m comment --comment "Global_Ext_In" -j RETURN
        \$cmd -C G_OUT -m comment --comment "Global_Ext_Out" -j RETURN 2>/dev/null || \$cmd -A G_OUT -m comment --comment "Global_Ext_Out" -j RETURN
    done
}

init_port_chain() {
    local port=\$1
    iptables -N "T_IN_\$port" 2>/dev/null
    iptables -N "T_OUT_\$port" 2>/dev/null
    
    # 将端口计费挂载到记账主链
    iptables -C TG_ACCT_IN -p tcp --dport "\$port" -j "T_IN_\$port" 2>/dev/null || iptables -A TG_ACCT_IN -p tcp --dport "\$port" -j "T_IN_\$port"
    iptables -C TG_ACCT_IN -p udp --dport "\$port" -j "T_IN_\$port" 2>/dev/null || iptables -A TG_ACCT_IN -p udp --dport "\$port" -j "T_IN_\$port"
    
    iptables -C TG_ACCT_OUT -p tcp --sport "\$port" -j "T_OUT_\$port" 2>/dev/null || iptables -A TG_ACCT_OUT -p tcp --sport "\$port" -j "T_OUT_\$port"
    iptables -C TG_ACCT_OUT -p udp --sport "\$port" -j "T_OUT_\$port" 2>/dev/null || iptables -A TG_ACCT_OUT -p udp --sport "\$port" -j "T_OUT_\$port"
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
    local v4_i=\$(iptables -L T_IN_\$p -v -n -x 2>/dev/null | awk '{sum+=\$2} END {printf "%.0f", sum}')
    local v4_o=\$(iptables -L T_OUT_\$p -v -n -x 2>/dev/null | awk '{sum+=\$2} END {printf "%.0f", sum}')
    echo \$((\${v4_i:-0} + \${v4_o:-0}))
}

auto_register_ports() {
    local active_ports=\$(ss -tuln | awk 'NR>1 {print \$5}' | awk -F: '{print \$NF}' | grep -E '^[0-9]+\$' | sort -nu)
    for p in \$active_ports; do init_port_chain "\$p"; done
    if [ -f "\$CONF_PORT" ]; then
        while read -r line; do
            [[ -z "\$line" || "\$line" =~ ^#.*\$ ]] && continue
            local conf_p=\$(echo "\$line" | cut -d: -f1)
            if echo "\$conf_p" | grep -qE '^[0-9]+\$'; then init_port_chain "\$conf_p"; fi
        done < "\$CONF_PORT"
    fi
}

NOW=\$(date +%s)
setup_foundation
setup_global_accounting
auto_register_ports

if [ -f "\$CONF_GLOBAL" ]; then
    source "\$CONF_GLOBAL"
    if [ "\$GLOBAL_LIMIT_GB" -gt 0 ]; then
        gb_bytes=\$(echo "\$GLOBAL_LIMIT_GB * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        cur_bytes=\$(get_global_bytes)
        lock_file="\$LOCK_DIR/global.lock"
        
        if [ "\$cur_bytes" -ge "\$gb_bytes" ]; then
            if [ ! -f "\$lock_file" ]; then
                touch "\$lock_file"
                # 在阻断层执行拦截
                iptables -I TG_BLOCK 1 -i "\$MAIN_IFACE" -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP
                iptables -I TG_BLOCK 1 -i "\$MAIN_IFACE" -p udp -m comment --comment "GLOBAL_BLOCK" -j DROP
                log "CRITICAL: Global traffic limit reached! External access blocked."
            fi
        else
            if [ -f "\$lock_file" ]; then
                rm -f "\$lock_file"
                while iptables -D TG_BLOCK -i "\$MAIN_IFACE" -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; do :; done
                while iptables -D TG_BLOCK -i "\$MAIN_IFACE" -p udp -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; do :; done
                log "INFO: Global traffic lock released."
            fi
        fi
    fi
fi

if [ -f "\$CONF_PORT" ]; then
    while read -r line; do
        [[ -z "\$line" || "\$line" =~ ^#.*\$ ]] && continue
        IFS=':' read -r port limit_gb raw_time <<< "\$line"
        if ! echo "\$port" | grep -qE '^[0-9]+\$'; then continue; fi

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
                while iptables -D TG_BLOCK -p tcp --dport "\$port" -j DROP 2>/dev/null; do :; done
                while iptables -D TG_BLOCK -p udp --dport "\$port" -j DROP 2>/dev/null; do :; done
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
                iptables -I TG_BLOCK 1 -p tcp --dport "\$port" -j DROP
                iptables -I TG_BLOCK 1 -p udp --dport "\$port" -j DROP
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
        bash "$INSTALL_PATH" >/dev/null 2>&1
        
        v4_in=$(iptables -L G_IN -v -n -x 2>/dev/null | grep "Global_Ext_In" | awk '{print $2}')
        v4_out=$(iptables -L G_OUT -v -n -x 2>/dev/null | grep "Global_Ext_Out" | awk '{print $2}')
        g_bytes=$((${v4_in:-0} + ${v4_out:-0}))
        
        if [ "$g_bytes" -gt 1073741824 ]; then
            g_used=$(awk -v b="$g_bytes" 'BEGIN {printf "%.2f", b/1073741824}')
            g_unit="GB"
        else
            g_used=$(awk -v b="$g_bytes" 'BEGIN {printf "%.2f", b/1048576}')
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
    SEP="+----------+----------------+----------------+----------+--------------+"
    echo "$SEP"
    printf "| %-8s | %-14s | %-14s | %-8s | %-12s |\n" " PORT" " USED" " LIMIT" " USAGE" " STATUS"
    echo "$SEP"
    
    active_chains=$(iptables -S TG_ACCT_IN 2>/dev/null | grep -E ' -j T_IN_[0-9]+$' | awk -F'_' '{print $3}' | sort -n | uniq)

    has_data=0
    port_total_bytes=0

    for port in $active_chains; do
        v4_i=$(iptables -L T_IN_$port -v -n -x 2>/dev/null | awk '{sum+=$2} END {printf "%.0f", sum}')
        v4_o=$(iptables -L T_OUT_$port -v -n -x 2>/dev/null | awk '{sum+=$2} END {printf "%.0f", sum}')
        bytes=$((${v4_i:-0} + ${v4_o:-0}))

        if [ "$bytes" -eq 0 ]; then continue; fi
        has_data=1
        port_total_bytes=$((port_total_bytes + bytes))

        if [ "$bytes" -gt 1073741824 ]; then
            used_h=$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}')
            unit="GB"
        else
            used_h=$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1048576}')
            unit="MB"
        fi

        limit_gb="0"
        if [ -f "$CONFIG_PORT" ]; then
            conf_line=$(grep -E "^${port}:" "$CONFIG_PORT" | head -n 1)
            if [ -n "$conf_line" ]; then limit_gb=$(echo "$conf_line" | cut -d: -f2); fi
        fi

        limit_bytes=$(echo "$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        if [ "$limit_bytes" -gt 0 ]; then 
            percent=$(awk -v b="$bytes" -v l="$limit_bytes" 'BEGIN {printf "%.1f", (b*100)/l}')
            limit_txt="${limit_gb} GB"
        else 
            percent="-"
            limit_txt="Unlimited"
        fi

        if [ -f "$LOCK_DIR/port_$port.lock" ]; then
            s_txt="BLOCKED"
            color_code="${RED}"
        elif [ "$limit_bytes" -gt 0 ]; then
            s_txt="Active"
            color_code="${YELLOW}"
        else
            s_txt="Stats Only"
            color_code="${GREEN}"
        fi
        
        printf "| %-8s | %-14s | %-14s | %-8s | %b%-12s%b |\n" \
            " $port" " $used_h $unit" " $limit_txt" " $percent%" "$color_code" " $s_txt" "${RESET}"
        echo "$SEP"
    done

    misc_bytes=$((g_bytes - port_total_bytes))
    if [ "$misc_bytes" -gt 104857 ]; then
        if [ "$misc_bytes" -gt 1073741824 ]; then
            misc_h=$(awk -v b="$misc_bytes" 'BEGIN {printf "%.2f", b/1073741824}')
            m_unit="GB"
        else
            misc_h=$(awk -v b="$misc_bytes" 'BEGIN {printf "%.2f", b/1048576}')
            m_unit="MB"
        fi
        printf "| %-8s | %-14s | %-14s | %-8s | %b%-12s%b |\n" \
            " System" " $misc_h $m_unit" " Unlimited" " -%" "${WHITE}" " Background" "${RESET}"
        echo "$SEP"
        has_data=1
    fi

    if [ "$has_data" -eq 0 ]; then
        printf "| %-68s |\n" " 系统暂无产生实质流量的活跃端口"
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
    
    mkdir -p /root/.cache
    echo "* * * * * root bash $INSTALL_PATH >/dev/null 2>&1" > /etc/cron.d/traffic_guard
    chmod 644 /etc/cron.d/traffic_guard
    systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1
    
    bash "$INSTALL_PATH"
    echo -e "${GREEN}守护进程与底层核心架构安装/重载成功！${RESET}"
}

service_uninstall() {
    rm -f /etc/cron.d/traffic_guard
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab - 2>/dev/null
    
    rm -f "$INSTALL_PATH" "$CONFIG_PORT" "$CONFIG_GLOBAL" "$LOG_FILE"
    rm -rf "$LOCK_DIR"
    
    # 彻底拆除所有架构链
    for cmd in iptables ip6tables; do
        \$cmd -D INPUT -j TG_ACCT_IN 2>/dev/null
        \$cmd -D INPUT -j TG_BLOCK 2>/dev/null
        \$cmd -D INPUT -j TG_SAFE 2>/dev/null
        \$cmd -D OUTPUT -j TG_ACCT_OUT 2>/dev/null
        
        # 清空链内容并删除
        for chain in TG_ACCT_IN TG_ACCT_OUT TG_BLOCK TG_SAFE G_IN G_OUT; do
            \$cmd -F \$chain 2>/dev/null && \$cmd -X \$chain 2>/dev/null
        done
        
        # 清理所有端口动态链
        local chains=\$(\$cmd -S 2>/dev/null | grep -E '^-N T_(IN|OUT)_[0-9]+' | awk '{print \$2}')
        for chain in \$chains; do
            \$cmd -F \$chain 2>/dev/null && \$cmd -X \$chain 2>/dev/null
        done
    done
    
    echo -e "${GREEN}卸载与清理完成！系统防火墙已恢复原样。${RESET}"
}

# ================== 主菜单 ==================
while true; do
    clear
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "${CYAN}             VPS 流量监控与全网管家 5.0                     ${RESET}"
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

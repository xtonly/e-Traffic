#!/bin/bash
# ========================================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v5.5 (Persistent Edition)
# 终极修复：引入持久化状态账本解决重启/宕机丢数据问题，兼容 UFW/Docker
# ========================================================================

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
CONFIG_MODE="/etc/traffic_guard_mode.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
DATA_DIR="/var/lib/traffic_guard" # 【新增】流量持久化账本目录
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
CONF_MODE="$CONFIG_MODE"
LOG_FILE="$LOG_FILE"
LOCK_DIR="$LOCK_DIR"
DATA_DIR="$DATA_DIR"
SAFE_SSH_PORT="$SSH_PORT"
SELF_IP="$MY_IP"
MAIN_IFACE="$DEFAULT_IFACE"

mkdir -p "\$LOCK_DIR" "\$DATA_DIR"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"; }

T_MODE=1
[ -f "\$CONF_MODE" ] && source "\$CONF_MODE"

calc_bytes() {
    local in_b=\$1
    local out_b=\$2
    if [ "\$T_MODE" == "2" ]; then
        echo "\$out_b"
    elif [ "\$T_MODE" == "3" ]; then
        if [ "\$in_b" -gt "\$out_b" ]; then echo "\$in_b"; else echo "\$out_b"; fi
    else
        echo \$((\$in_b + \$out_b))
    fi
}

# --- 【新增】持久化状态处理引擎 ---
handle_persistence() {
    local id=\$1
    local cur_in=\$2
    local cur_out=\$3
    local file="\$DATA_DIR/\${id}.dat"

    [ ! -f "\$file" ] && echo "0 0 0 0" > "\$file"
    # p_in/p_out: 持久化的总额; last_in/last_out: 上次内存中的记录
    read p_in p_out last_in last_out < "\$file"

    # 如果当前 iptables 计数小于上次记录，说明经历了重启，旧数据被冲刷，需加入持久化底账
    if [ "\$cur_in" -lt "\${last_in:-0}" ]; then p_in=\$((p_in + last_in)); fi
    if [ "\$cur_out" -lt "\${last_out:-0}" ]; then p_out=\$((p_out + last_out)); fi

    # 更新状态：把当前的内存值作为下一次比对的 "last_in/out"
    echo "\$p_in \$p_out \$cur_in \$cur_out" > "\$file"

    local final_in=\$((p_in + cur_in))
    local final_out=\$((p_out + cur_out))
    echo "\$final_in \$final_out"
}
# ----------------------------------

setup_foundation() {
    for cmd in iptables ip6tables; do
        \$cmd -t mangle -N TG_ACCT_IN 2>/dev/null
        \$cmd -t mangle -N TG_ACCT_OUT 2>/dev/null
        if ! \$cmd -t mangle -C PREROUTING -j TG_ACCT_IN 2>/dev/null; then \$cmd -t mangle -I PREROUTING 1 -j TG_ACCT_IN; fi
        if ! \$cmd -t mangle -C POSTROUTING -j TG_ACCT_OUT 2>/dev/null; then \$cmd -t mangle -I POSTROUTING 1 -j TG_ACCT_OUT; fi

        \$cmd -t filter -N TG_BLOCK 2>/dev/null
        \$cmd -t filter -N TG_SAFE 2>/dev/null
        if ! \$cmd -t filter -C INPUT -j TG_SAFE 2>/dev/null; then \$cmd -t filter -I INPUT 1 -j TG_SAFE; fi
        if ! \$cmd -t filter -C INPUT -j TG_BLOCK 2>/dev/null; then \$cmd -t filter -I INPUT 2 -j TG_BLOCK; fi
        if ! \$cmd -t filter -C FORWARD -j TG_SAFE 2>/dev/null; then \$cmd -t filter -I FORWARD 1 -j TG_SAFE; fi
        if ! \$cmd -t filter -C FORWARD -j TG_BLOCK 2>/dev/null; then \$cmd -t filter -I FORWARD 2 -j TG_BLOCK; fi

        if ! \$cmd -t filter -C TG_SAFE -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            \$cmd -t filter -A TG_SAFE -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        fi
        if ! \$cmd -t filter -C TG_SAFE -i lo -j ACCEPT 2>/dev/null; then
            \$cmd -t filter -A TG_SAFE -i lo -j ACCEPT 2>/dev/null
        fi
    done
    
    if [ ! -z "\$SELF_IP" ]; then
        if ! iptables -t filter -C TG_SAFE -s "\$SELF_IP" -j ACCEPT 2>/dev/null; then
            iptables -t filter -A TG_SAFE -s "\$SELF_IP" -j ACCEPT 2>/dev/null
        fi
    fi
}

setup_global_accounting() {
    for cmd in iptables ip6tables; do
        if \$cmd -t mangle -N G_IN 2>/dev/null; then
            \$cmd -t mangle -A TG_ACCT_IN -j G_IN
            for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10; do
                \$cmd -t mangle -A G_IN -s \$net -j RETURN
            done
            \$cmd -t mangle -A G_IN -m comment --comment "Global_Ext_In" -j RETURN
        fi
        
        if \$cmd -t mangle -N G_OUT 2>/dev/null; then
            \$cmd -t mangle -A TG_ACCT_OUT -j G_OUT
            for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10; do
                \$cmd -t mangle -A G_OUT -d \$net -j RETURN
            done
            \$cmd -t mangle -A G_OUT -m comment --comment "Global_Ext_Out" -j RETURN
        fi
    done
}

init_port_chain() {
    local port=\$1
    for cmd in iptables ip6tables; do
        if \$cmd -t mangle -N "T_IN_\$port" 2>/dev/null; then
            \$cmd -t mangle -A "T_IN_\$port" -j RETURN
            \$cmd -t mangle -A TG_ACCT_IN -p tcp --dport "\$port" -j "T_IN_\$port"
            \$cmd -t mangle -A TG_ACCT_IN -p udp --dport "\$port" -j "T_IN_\$port"
        fi
        
        if \$cmd -t mangle -N "T_OUT_\$port" 2>/dev/null; then
            \$cmd -t mangle -A "T_OUT_\$port" -j RETURN
            \$cmd -t mangle -A TG_ACCT_OUT -p tcp --sport "\$port" -j "T_OUT_\$port"
            \$cmd -t mangle -A TG_ACCT_OUT -p udp --sport "\$port" -j "T_OUT_\$port"
        fi
    done
}

get_global_bytes() {
    local v4_in=\$(iptables -t mangle -L G_IN -v -n -x 2>/dev/null | awk '/Global_Ext_In/ {sum+=\$2} END {printf "%.0f", sum}')
    local v4_out=\$(iptables -t mangle -L G_OUT -v -n -x 2>/dev/null | awk '/Global_Ext_Out/ {sum+=\$2} END {printf "%.0f", sum}')
    local v6_in=\$(ip6tables -t mangle -L G_IN -v -n -x 2>/dev/null | awk '/Global_Ext_In/ {sum+=\$2} END {printf "%.0f", sum}')
    local v6_out=\$(ip6tables -t mangle -L G_OUT -v -n -x 2>/dev/null | awk '/Global_Ext_Out/ {sum+=\$2} END {printf "%.0f", sum}')
    
    local total_in=\$((\${v4_in:-0} + \${v6_in:-0}))
    local total_out=\$((\${v4_out:-0} + \${v6_out:-0}))
    
    local persisted=\$(handle_persistence "global" \$total_in \$total_out)
    local fin_in=\$(echo \$persisted | awk '{print \$1}')
    local fin_out=\$(echo \$persisted | awk '{print \$2}')
    
    calc_bytes \$fin_in \$fin_out
}

get_port_bytes() {
    local p=\$1
    local v4_i=\$(iptables -t mangle -L T_IN_\$p -v -n -x 2>/dev/null | awk 'NR>2 {sum+=\$2} END {printf "%.0f", sum}')
    local v4_o=\$(iptables -t mangle -L T_OUT_\$p -v -n -x 2>/dev/null | awk 'NR>2 {sum+=\$2} END {printf "%.0f", sum}')
    local v6_i=\$(ip6tables -t mangle -L T_IN_\$p -v -n -x 2>/dev/null | awk 'NR>2 {sum+=\$2} END {printf "%.0f", sum}')
    local v6_o=\$(ip6tables -t mangle -L T_OUT_\$p -v -n -x 2>/dev/null | awk 'NR>2 {sum+=\$2} END {printf "%.0f", sum}')
    
    local total_in=\$((\${v4_i:-0} + \${v6_i:-0}))
    local total_out=\$((\${v4_o:-0} + \${v6_o:-0}))
    
    local persisted=\$(handle_persistence "port_\$p" \$total_in \$total_out)
    local fin_in=\$(echo \$persisted | awk '{print \$1}')
    local fin_out=\$(echo \$persisted | awk '{print \$2}')
    
    calc_bytes \$fin_in \$fin_out
}

auto_register_ports() {
    local active_ports=\$(ss -tuln | awk 'NR>1 {print \$5}' | awk -F':' '{print \$NF}' | grep -E '^[0-9]+\$' | sort -nu)
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
                for cmd in iptables ip6tables; do
                    if ! \$cmd -t filter -C TG_BLOCK -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; then
                        \$cmd -t filter -I TG_BLOCK 1 -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP
                        \$cmd -t filter -I TG_BLOCK 1 -p udp -m comment --comment "GLOBAL_BLOCK" -j DROP
                    fi
                done
                log "CRITICAL: Global traffic limit reached! External access blocked."
            fi
        else
            if [ -f "\$lock_file" ]; then
                rm -f "\$lock_file"
                for cmd in iptables ip6tables; do
                    while \$cmd -t filter -D TG_BLOCK -p tcp ! --dport "\$SAFE_SSH_PORT" -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; do :; done
                    while \$cmd -t filter -D TG_BLOCK -p udp -m comment --comment "GLOBAL_BLOCK" -j DROP 2>/dev/null; do :; done
                done
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
                for cmd in iptables ip6tables; do
                    while \$cmd -t filter -D TG_BLOCK -p tcp --dport "\$port" -j DROP 2>/dev/null; do :; done
                    while \$cmd -t filter -D TG_BLOCK -p udp --dport "\$port" -j DROP 2>/dev/null; do :; done
                done
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
                for cmd in iptables ip6tables; do
                    if ! \$cmd -t filter -C TG_BLOCK -p tcp --dport "\$port" -j DROP 2>/dev/null; then
                        \$cmd -t filter -I TG_BLOCK 1 -p tcp --dport "\$port" -j DROP
                        \$cmd -t filter -I TG_BLOCK 1 -p udp --dport "\$port" -j DROP
                    fi
                done
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
    T_MODE=1
    [ -f "$CONFIG_MODE" ] && source "$CONFIG_MODE"
    case "$T_MODE" in
        1) mode_str="双向合计 (IN + OUT)" ;;
        2) mode_str="单向计出 (仅统计出站)" ;;
        3) mode_str="双向取大 (Max[IN, OUT])" ;;
    esac

    calc_bytes() {
        local in_b=$1
        local out_b=$2
        if [ "$T_MODE" == "2" ]; then echo "$out_b"; elif [ "$T_MODE" == "3" ]; then
            if [ "$in_b" -gt "$out_b" ]; then echo "$in_b"; else echo "$out_b"; fi
        else echo $(($in_b + $out_b)); fi
    }

    # --- 【新增】前端只读账本引擎，防止与守护进程抢占文件 ---
    read_persistence() {
        local id=$1
        local cur_in=$2
        local cur_out=$3
        local file="$DATA_DIR/${id}.dat"

        local p_in=0 p_out=0 last_in=0 last_out=0
        if [ -f "$file" ]; then read p_in p_out last_in last_out < "$file"; fi

        if [ "$cur_in" -lt "${last_in:-0}" ]; then p_in=$((p_in + last_in)); fi
        if [ "$cur_out" -lt "${last_out:-0}" ]; then p_out=$((p_out + last_out)); fi

        local final_in=$((p_in + cur_in))
        local final_out=$((p_out + cur_out))
        echo "$final_in $final_out"
    }
    # --------------------------------------------------------

    echo -e "${CYAN}================== [3] 全局与网卡流量 (已剔除内网数据) ==================${RESET}"
    if [ -f "$INSTALL_PATH" ]; then
        bash "$INSTALL_PATH" >/dev/null 2>&1
        
        v4_in=$(iptables -t mangle -L G_IN -v -n -x 2>/dev/null | awk '/Global_Ext_In/ {sum+=$2} END {printf "%.0f", sum}')
        v4_out=$(iptables -t mangle -L G_OUT -v -n -x 2>/dev/null | awk '/Global_Ext_Out/ {sum+=$2} END {printf "%.0f", sum}')
        v6_in=$(ip6tables -t mangle -L G_IN -v -n -x 2>/dev/null | awk '/Global_Ext_In/ {sum+=$2} END {printf "%.0f", sum}')
        v6_out=$(ip6tables -t mangle -L G_OUT -v -n -x 2>/dev/null | awk '/Global_Ext_Out/ {sum+=$2} END {printf "%.0f", sum}')
        
        total_in=$((${v4_in:-0} + ${v6_in:-0}))
        total_out=$((${v4_out:-0} + ${v6_out:-0}))
        
        # 融入持久化计算
        local persisted=$(read_persistence "global" $total_in $total_out)
        local fin_in=$(echo $persisted | awk '{print $1}')
        local fin_out=$(echo $persisted | awk '{print $2}')
        g_bytes=$(calc_bytes $fin_in $fin_out)
        
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
                if [ -f "$LOCK_DIR/global.lock" ]; then g_status="${RED}全网阻断中${RESET}"; fi
            fi
        fi
        
        echo -e " ${BLUE}主网卡  :${RESET} ${WHITE}${DEFAULT_IFACE}${RESET}    ${BLUE}计费模式:${RESET} ${YELLOW}${mode_str}${RESET}"
        echo -e " ${BLUE}总限额  :${RESET} ${WHITE}${g_limit}${RESET}    ${BLUE}外部已用:${RESET} ${YELLOW}${g_used} ${g_unit}${RESET}    ${BLUE}状态:${RESET} ${g_status}"
    else
        echo -e "${RED}未安装守护进程！请先启动服务。${RESET}"
    fi
    echo ""
    echo -e "${CYAN}=================== 端口级实时审计 (Mangle 底层穿透) ====================${RESET}"
    SEP="+----------+----------------+----------------+----------+--------------+"
    echo "$SEP"
    printf "| %-8s | %-14s | %-14s | %-8s | %-12s |\n" " PORT" " USED" " LIMIT" " USAGE" " STATUS"
    echo "$SEP"
    
    active_chains=$( (iptables -t mangle -S 2>/dev/null; ip6tables -t mangle -S 2>/dev/null) | grep -E '^-N T_IN_[0-9]+$' | awk -F'_' '{print $3}' | sort -n | uniq)

    has_data=0
    port_total_bytes=0

    for port in $active_chains; do
        v4_i=$(iptables -t mangle -L T_IN_$port -v -n -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {printf "%.0f", sum}')
        v4_o=$(iptables -t mangle -L T_OUT_$port -v -n -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {printf "%.0f", sum}')
        v6_i=$(ip6tables -t mangle -L T_IN_$port -v -n -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {printf "%.0f", sum}')
        v6_o=$(ip6tables -t mangle -L T_OUT_$port -v -n -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {printf "%.0f", sum}')
        
        p_in=$((${v4_i:-0} + ${v6_i:-0}))
        p_out=$((${v4_o:-0} + ${v6_o:-0}))
        
        # 融入持久化计算
        local p_persisted=$(read_persistence "port_$port" $p_in $p_out)
        local p_fin_in=$(echo $p_persisted | awk '{print $1}')
        local p_fin_out=$(echo $p_persisted | awk '{print $2}')
        bytes=$(calc_bytes $p_fin_in $p_fin_out)

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
    echo -e "${CYAN}==================== [1] 全局与计费模式配置 ====================${RESET}"
    echo -e "${YELLOW}说明：支持三大主流云厂商计费模式，自动同步应用于全局和端口统计${RESET}"
    echo -e "${MAGENTA}----------------------------------------------------------------${RESET}"
    
    echo -e "${BLUE}请选择服务器计费模式：${RESET}"
    echo " 1. 双向合计 (入站 + 出站，默认标准)"
    echo " 2. 单向计出 (仅统计出站流量，例如阿里云/AWS)"
    echo " 3. 双向取大 (入站与出站取最大值，例如部分专线)"
    read -p "请输入模式编号 [1-3, 默认 1]: " t_mode
    [[ ! "$t_mode" =~ ^[1-3]$ ]] && t_mode=1
    echo "T_MODE=$t_mode" > "$CONFIG_MODE"
    echo -e "${GREEN}计费模式已保存！${RESET}"
    
    echo -e "${MAGENTA}----------------------------------------------------------------${RESET}"
    read -p "请输入整机每月公网流量上限 (单位:GB, 输入0为不限制): " g_limit
    if [[ "$g_limit" =~ ^[0-9]+$ ]]; then
        echo "GLOBAL_LIMIT_GB=$g_limit" > "$CONFIG_GLOBAL"
        echo -e "${GREEN}全局额度配置已生效！${RESET}"
    else
        echo -e "${RED}输入无效，保留原配置。${RESET}"
    fi
}

menu_port_config() {
    clear
    echo -e "${CYAN}====================== [2] 独立端口控制规则 ======================${RESET}"
    echo -e "${YELLOW}格式示例: 8080:500:10m (端口8080 限额500G 超额封锁10分钟后解封)${RESET}"
    echo -e "${MAGENTA}------------------------------------------------------------------${RESET}"
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
    echo -e "${GREEN}守护进程与底层持久化引擎安装/重载成功！${RESET}"
}

service_uninstall() {
    rm -f /etc/cron.d/traffic_guard
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab - 2>/dev/null
    
    rm -f "$INSTALL_PATH" "$CONFIG_PORT" "$CONFIG_GLOBAL" "$CONFIG_MODE" "$LOG_FILE"
    rm -rf "$LOCK_DIR" "$DATA_DIR"
    
    for cmd in iptables ip6tables; do
        $cmd -t mangle -D PREROUTING -j TG_ACCT_IN 2>/dev/null
        $cmd -t mangle -D POSTROUTING -j TG_ACCT_OUT 2>/dev/null
        
        $cmd -t filter -D INPUT -j TG_BLOCK 2>/dev/null
        $cmd -t filter -D INPUT -j TG_SAFE 2>/dev/null
        $cmd -t filter -D FORWARD -j TG_BLOCK 2>/dev/null
        $cmd -t filter -D FORWARD -j TG_SAFE 2>/dev/null
        
        local m_chains=$($cmd -t mangle -S 2>/dev/null | grep -E '^-N (T_IN|T_OUT|G_IN|G_OUT|TG_ACCT_IN|TG_ACCT_OUT)' | awk '{print $2}')
        for chain in $m_chains; do $cmd -t mangle -F $chain 2>/dev/null; done
        for chain in $m_chains; do $cmd -t mangle -X $chain 2>/dev/null; done
        
        local f_chains=$($cmd -t filter -S 2>/dev/null | grep -E '^-N (TG_BLOCK|TG_SAFE)' | awk '{print $2}')
        for chain in $f_chains; do $cmd -t filter -F $chain 2>/dev/null; done
        for chain in $f_chains; do $cmd -t filter -X $chain 2>/dev/null; done
    done
    
    echo -e "${GREEN}卸载与清理完成！底层所有计费链与硬盘持久化文件已物理抹除，系统完全复原。${RESET}"
}

# ================== 主菜单 ==================
while true; do
    clear
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e "${CYAN}         VPS 流量监控与全网管家 5.5 (持久化版)                ${RESET}"
    echo -e "${MAGENTA}=========================================================${RESET}"
    echo -e " ${BLUE}系统环境 :${RESET} ${WHITE}${SYS_PRETTY_NAME}${RESET}"
    echo -e " ${BLUE}出海网卡 :${RESET} ${WHITE}${DEFAULT_IFACE} ${YELLOW}(原子级防丢数据机制)${RESET}"
    echo -e " ${BLUE}公网 IPv4:${RESET} ${GREEN}${PUBLIC_IPV4}${RESET}"
    echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
    echo -e "  ${YELLOW}1.${RESET} 全局流量管理 (设置计费模式与总上限)"
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

#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v1.1
# 更新日志：
# 1. 增加循环菜单，操作后自动返回，不再直接退出
# 2. 编辑器默认调整为 nano，并自动检查安装
# ==============================================================

# --- 全局路径配置 ---
INSTALL_PATH="/usr/local/bin/traffic_guard.sh"
CONFIG_PATH="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"

# --- 核心工具函数 ---

# 颜色输出
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# 暂停并按键继续
pause_and_return() {
    echo ""
    read -n 1 -s -r -p ">>> 按任意键返回主菜单..."
}

# 1. 检查并安装依赖 (bc, iptables, nano)
check_dependencies() {
    echo "正在检查系统环境..."
    if [ -f /etc/redhat-release ]; then
        CMD_INSTALL="yum install -y"
    else
        CMD_INSTALL="apt-get install -y"
    fi

    # 安装 bc
    if ! command -v bc &> /dev/null; then
        yellow "安装依赖: bc..."
        $CMD_INSTALL bc
    fi
    
    # 安装 iptables
    if ! command -v iptables &> /dev/null; then
        yellow "安装依赖: iptables..."
        $CMD_INSTALL iptables
    fi

    # 安装 nano (响应你的需求)
    if ! command -v nano &> /dev/null; then
        yellow "安装编辑器: nano..."
        $CMD_INSTALL nano
    fi

    green "环境检查通过！"
}

# 2. 生成核心监控脚本
create_monitor_script() {
    cat > "$INSTALL_PATH" << 'EOF'
#!/bin/bash
# --- VPS Traffic Guard Core ---
CONF_FILE="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
mkdir -p "$LOCK_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

clean_iptables() {
    local port=$1
    iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null
    
    iptables -D INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null
    iptables -D OUTPUT -p udp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null
    
    iptables -F "TRAFFIC_IN_$port" 2>/dev/null
    iptables -X "TRAFFIC_IN_$port" 2>/dev/null
    iptables -F "TRAFFIC_OUT_$port" 2>/dev/null
    iptables -X "TRAFFIC_OUT_$port" 2>/dev/null
}

init_chain() {
    local port=$1
    iptables -N "TRAFFIC_IN_$port" 2>/dev/null
    if ! iptables -C INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port"
        iptables -I INPUT -p udp --dport "$port" -j "TRAFFIC_IN_$port"
    fi
    iptables -N "TRAFFIC_OUT_$port" 2>/dev/null
    if ! iptables -C OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null; then
        iptables -I OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port"
        iptables -I OUTPUT -p udp --sport "$port" -j "TRAFFIC_OUT_$port"
    fi
}

get_bytes() {
    local port=$1
    local v_in=$(iptables -L INPUT -v -n -x | grep "TRAFFIC_IN_$port" | awk '{print $2}')
    local v_out=$(iptables -L OUTPUT -v -n -x | grep "TRAFFIC_OUT_$port" | awk '{print $2}')
    echo $((${v_in:-0} + ${v_out:-0}))
}

block_action() {
    local port=$1
    if ! iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$port" -j DROP
        iptables -I INPUT 1 -p udp --dport "$port" -j DROP
        iptables -I OUTPUT 1 -p tcp --sport "$port" -j DROP
        iptables -I OUTPUT 1 -p udp --sport "$port" -j DROP
        timeout 2 ss -K dport = :$port >/dev/null 2>&1
        log "ALERT: Port $port traffic limit exceeded. BLOCKED."
    fi
}

unblock_action() {
    local port=$1
    while iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null; do :; done
    clean_iptables "$port"
    init_chain "$port"
    log "INFO: Port $port restriction expired. UNBLOCKED and Counter RESET."
}

if [ "$1" == "cleanup" ]; then
    if [ -f "$CONF_FILE" ]; then
        while read -r line; do
            [[ "$line" =~ ^#.*$ ]] && continue
            [ -z "$line" ] && continue
            port=$(echo $line | awk -F: '{print $1}')
            clean_iptables "$port"
        done < "$CONF_FILE"
    fi
    rm -rf "$LOCK_DIR"
    exit 0
fi

NOW=$(date +%s)
if [ -f "$CONF_FILE" ]; then
    while read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        IFS=':' read -r port limit_gb block_hours <<< "$line"
        
        init_chain "$port"
        lock_file="$LOCK_DIR/$port.lock"
        
        if [ -f "$lock_file" ]; then
            block_time=$(cat "$lock_file")
            [ -z "$block_time" ] && block_time=$NOW && echo $NOW > "$lock_file"
            elapsed=$((NOW - block_time))
            unlock_sec=$((block_hours * 3600))
            if [ "$elapsed" -ge "$unlock_sec" ]; then
                unblock_action "$port"
                rm -f "$lock_file"
            else
                block_action "$port"
            fi
            continue
        fi
        
        total_bytes=$(get_bytes "$port")
        limit_bytes=$(echo "$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        
        if [ "$total_bytes" -ge "$limit_bytes" ]; then
            echo "$NOW" > "$lock_file"
            block_action "$port"
            log "Port $port reached limit (${limit_gb}GB). Blocking for ${block_hours}h."
        fi
    done < "$CONF_FILE"
fi
EOF
    chmod +x "$INSTALL_PATH"
}

# 3. 安装流程
install_monitor() {
    check_dependencies
    
    echo "-------------------------------------"
    yellow "请配置监控规则"
    echo "格式: 端口号:流量上限(GB):超标封锁时长(小时)"
    echo "示例: 8080:500:24 (8080端口，500G限制，超标封24小时)"
    echo "-------------------------------------"
    read -p "请输入规则 (默认为 80:100:24): " user_rule
    
    if [ -z "$user_rule" ]; then
        user_rule="80:100:24"
    fi
    
    echo "$user_rule" > "$CONFIG_PATH"
    green "配置已保存至 $CONFIG_PATH"
    
    create_monitor_script
    green "核心监控脚本已生成."
    
    if ! crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null; echo "* * * * * $INSTALL_PATH >/dev/null 2>&1") | crontab -
        green "定时任务 (Cron) 已添加，每分钟检测一次."
    else
        yellow "定时任务已存在，跳过."
    fi
    
    $INSTALL_PATH
    green "安装完成！脚本已开始在后台运行。"
    echo "你可以随时选择菜单 2 修改配置。"
}

# 4. 卸载流程
uninstall_monitor() {
    echo "正在卸载并清理..."
    if [ -f "$INSTALL_PATH" ]; then
        bash "$INSTALL_PATH" cleanup
        green "防火墙规则限制已解除。"
    else
        if [ -f "$CONFIG_PATH" ]; then
             while read -r line; do
                port=$(echo $line | awk -F: '{print $1}')
                iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
                iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
                iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null
             done < "$CONFIG_PATH"
        fi
    fi
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    rm -f "$INSTALL_PATH" "$CONFIG_PATH" "$LOG_FILE"
    rm -rf "$LOCK_DIR"
    green "卸载完成！所有限制已取消，系统已恢复干净。"
}

# --- 主菜单 (循环模式) ---
while true; do
    clear
    echo "=============================================="
    echo "    VPS 流量监控与限制管理 (One-Click Guard)"
    echo "=============================================="
    echo " 1. 安装监控 (Install)"
    echo " 2. 编辑规则 (Edit Config - Nano)"
    echo " 3. 查看日志 (View Log)"
    echo " 4. 彻底卸载 (Uninstall & Unblock)"
    echo " 0. 退出 (Exit)"
    echo "=============================================="
    read -p "请输入数字 [0-4]: " choice

    case "$choice" in
        1)
            install_monitor
            pause_and_return
            ;;
        2)
            if [ -f "$CONFIG_PATH" ]; then
                # 检查并使用 nano
                if command -v nano &> /dev/null; then
                    nano "$CONFIG_PATH"
                else
                    vi "$CONFIG_PATH"
                fi
                green "修改已保存，等待下一分钟生效。"
            else
                red "请先安装监控 (选项 1)！"
            fi
            pause_and_return
            ;;
        3)
            if [ -f "$LOG_FILE" ]; then
                echo "--- 最新 20 条日志 ---"
                tail -n 20 "$LOG_FILE"
            else
                echo "暂无日志。"
            fi
            pause_and_return
            ;;
        4)
            uninstall_monitor
            pause_and_return
            ;;
        0)
            echo "退出管理脚本。"
            exit 0
            ;;
        *)
            yellow "输入无效，请重新输入。"
            sleep 1
            ;;
    esac
done

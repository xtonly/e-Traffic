#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v2.0 Final
# 更新日志：
# 1. 新增 [查看实时流量状态] 仪表盘功能
# 2. 优化流量单位换算 (自动显示 MB/GB)
# 3. 保留 Nano 编辑器和循环菜单习惯
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

# 暂停并按键继续
pause_and_return() {
    echo ""
    read -n 1 -s -r -p ">>> 按任意键返回主菜单..."
}

# 1. 检查并安装依赖
check_dependencies() {
    # 这一步仅在安装时显式调用，平时静默
    if [ -f /etc/redhat-release ]; then CMD="yum install -y"; else CMD="apt-get install -y"; fi
    
    # 检查核心工具
    for pkg in bc iptables nano; do
        if ! command -v $pkg &> /dev/null; then
            echo -e "${YELLOW}正在安装依赖: $pkg ...${RES}"
            $CMD $pkg >/dev/null 2>&1
        fi
    done
}

# 2. 生成核心监控脚本 (后台运行部分)
create_monitor_script() {
    cat > "$INSTALL_PATH" << 'EOF'
#!/bin/bash
CONF_FILE="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
mkdir -p "$LOCK_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# 清理防火墙规则
clean_iptables() {
    local port=$1
    # 删除 DROP 规则
    iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null
    # 删除统计链引用
    iptables -D INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null
    iptables -D OUTPUT -p udp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null
    # 清空并删除链
    iptables -F "TRAFFIC_IN_$port" 2>/dev/null
    iptables -X "TRAFFIC_IN_$port" 2>/dev/null
    iptables -F "TRAFFIC_OUT_$port" 2>/dev/null
    iptables -X "TRAFFIC_OUT_$port" 2>/dev/null
}

# 初始化统计链
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

# 获取流量字节数
get_bytes() {
    local port=$1
    local v_in=$(iptables -L INPUT -v -n -x | grep "TRAFFIC_IN_$port" | awk '{print $2}')
    local v_out=$(iptables -L OUTPUT -v -n -x | grep "TRAFFIC_OUT_$port" | awk '{print $2}')
    echo $((${v_in:-0} + ${v_out:-0}))
}

# 封锁逻辑
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

# 解封逻辑
unblock_action() {
    local port=$1
    # 移除 DROP
    while iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null; do :; done
    # 重置计数器
    clean_iptables "$port"
    init_chain "$port"
    log "INFO: Port $port restriction expired. UNBLOCKED and Counter RESET."
}

# 清理模式
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

# 监控模式
NOW=$(date +%s)
if [ -f "$CONF_FILE" ]; then
    while read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        IFS=':' read -r port limit_gb block_hours <<< "$line"
        
        init_chain "$port"
        lock_file="$LOCK_DIR/$port.lock"
        
        # 检查封锁状态
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
        
        # 检查流量限制
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

# 3. 功能：显示实时状态仪表盘
show_status() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}未找到配置文件，请先安装监控！${RES}"
        return
    fi

    echo -e "${BOLD}正在获取实时数据，请稍候...${RES}"
    echo "-----------------------------------------------------------------------"
    printf "${BOLD}%-8s %-15s %-15s %-10s %-10s${RES}\n" "端口" "已用流量" "流量上限" "使用率" "当前状态"
    echo "-----------------------------------------------------------------------"

    while read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        IFS=':' read -r port limit_gb block_hours <<< "$line"

        # 获取 iptables 原始字节
        v_in=$(iptables -L INPUT -v -n -x 2>/dev/null | grep "TRAFFIC_IN_$port" | awk '{print $2}')
        v_out=$(iptables -L OUTPUT -v -n -x 2>/dev/null | grep "TRAFFIC_OUT_$port" | awk '{print $2}')
        bytes=$((${v_in:-0} + ${v_out:-0}))

        # 单位换算 (MB/GB)
        if [ "$bytes" -gt 1073741824 ]; then
            used_human=$(echo "scale=2; $bytes/1024/1024/1024" | bc)
            used_unit="GB"
        else
            used_human=$(echo "scale=2; $bytes/1024/1024" | bc)
            used_unit="MB"
        fi

        # 计算百分比
        limit_bytes=$(echo "$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        if [ "$limit_bytes" -gt 0 ]; then
            percent=$(echo "scale=2; ($bytes * 100) / $limit_bytes" | bc)
        else
            percent="0"
        fi

        # 状态判定
        status_text="${GREEN}正常${RES}"
        if [ -f "$LOCK_DIR/$port.lock" ]; then
            status_text="${RED}已封锁${RES}"
        fi
        
        # 打印行
        printf "%-8s %-15s %-15s %-10s %-10s\n" "$port" "$used_human $used_unit" "${limit_gb} GB" "$percent%" "$status_text"

    done < "$CONFIG_PATH"
    echo "-----------------------------------------------------------------------"
    echo -e "${BLUE}提示：数据来源于 iptables 实时计数器，每分钟自动判定一次。${RES}"
}

# 4. 安装流程
install_monitor() {
    check_dependencies
    echo "-------------------------------------"
    echo -e "${YELLOW}请配置监控规则${RES}"
    echo "格式: 端口号:流量上限(GB):超标封锁时长(小时)"
    echo "示例: 8080:500:24 (8080端口，500G限制，超标封24小时)"
    echo "-------------------------------------"
    read -p "请输入规则 (默认为 80:100:24): " user_rule
    [ -z "$user_rule" ] && user_rule="80:100:24"
    
    echo "$user_rule" > "$CONFIG_PATH"
    echo -e "${GREEN}配置已保存。${RES}"
    
    create_monitor_script
    echo -e "${GREEN}核心脚本已生成。${RES}"
    
    if ! crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null; echo "* * * * * $INSTALL_PATH >/dev/null 2>&1") | crontab -
        echo -e "${GREEN}定时任务已添加。${RES}"
    fi
    
    # 立即初始化链
    bash "$INSTALL_PATH"
    echo -e "${GREEN}安装完成！监控已启动。${RES}"
}

# 5. 卸载流程
uninstall_monitor() {
    echo "正在卸载..."
    if [ -f "$INSTALL_PATH" ]; then
        bash "$INSTALL_PATH" cleanup
    else
        # 备用清理
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
    echo -e "${GREEN}卸载完成！防火墙规则已恢复，任务已删除。${RES}"
}

# --- 主循环菜单 ---
while true; do
    clear
    echo -e "${BLUE}==============================================${RES}"
    echo -e "${BOLD}    VPS 流量监控管家 (Traffic Guard v2.0)${RES}"
    echo -e "${BLUE}==============================================${RES}"
    echo " 1. 安装/重置监控 (Install/Reset)"
    echo " 2. 编辑监控规则 (Edit Config - Nano)"
    echo -e "${YELLOW} 3. 查看实时流量状态 (Live Status Dashboard)${RES}"
    echo " 4. 查看操作日志 (View Logs)"
    echo " 5. 彻底卸载 (Uninstall)"
    echo " 0. 退出 (Exit)"
    echo -e "${BLUE}==============================================${RES}"
    read -p "请输入数字 [0-5]: " choice

    case "$choice" in
        1) install_monitor; pause_and_return ;;
        2) 
            if [ -f "$CONFIG_PATH" ]; then
                nano "$CONFIG_PATH"
                echo -e "${GREEN}修改已保存，请等待一分钟后自动更新规则。${RES}"
            else
                echo -e "${RED}请先执行安装！${RES}"
            fi
            pause_and_return 
            ;;
        3) show_status; pause_and_return ;;
        4) 
            if [ -f "$LOG_FILE" ]; then
                echo "--- 最近 20 条系统日志 ---"
                tail -n 20 "$LOG_FILE"
            else
                echo "暂无日志。"
            fi
            pause_and_return 
            ;;
        5) uninstall_monitor; pause_and_return ;;
        0) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done

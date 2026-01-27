#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager)
# 功能：安装监控、配置规则、自动封锁/解封、一键彻底卸载
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

# 1. 检查并安装依赖 (bc, iptables)
check_dependencies() {
    echo "正在检查系统环境..."
    if [ -f /etc/redhat-release ]; then
        CMD_INSTALL="yum install -y"
    else
        CMD_INSTALL="apt-get install -y"
    fi

    if ! command -v bc &> /dev/null; then
        yellow "未检测到 bc 计算工具，正在安装..."
        $CMD_INSTALL bc
    fi
    
    if ! command -v iptables &> /dev/null; then
        yellow "未检测到 iptables，正在安装..."
        $CMD_INSTALL iptables
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

# 清理指定端口的防火墙规则 (用于卸载或重置)
clean_iptables() {
    local port=$1
    # 删除封锁规则
    iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null
    
    # 删除统计规则和链
    iptables -D INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null
    iptables -D OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null
    iptables -D OUTPUT -p udp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null
    
    iptables -F "TRAFFIC_IN_$port" 2>/dev/null
    iptables -X "TRAFFIC_IN_$port" 2>/dev/null
    iptables -F "TRAFFIC_OUT_$port" 2>/dev/null
    iptables -X "TRAFFIC_OUT_$port" 2>/dev/null
}

# 初始化统计链
init_chain() {
    local port=$1
    # 入站
    iptables -N "TRAFFIC_IN_$port" 2>/dev/null
    if ! iptables -C INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port" 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j "TRAFFIC_IN_$port"
        iptables -I INPUT -p udp --dport "$port" -j "TRAFFIC_IN_$port"
    fi
    # 出站
    iptables -N "TRAFFIC_OUT_$port" 2>/dev/null
    if ! iptables -C OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port" 2>/dev/null; then
        iptables -I OUTPUT -p tcp --sport "$port" -j "TRAFFIC_OUT_$port"
        iptables -I OUTPUT -p udp --sport "$port" -j "TRAFFIC_OUT_$port"
    fi
}

# 获取流量 (Bytes)
get_bytes() {
    local port=$1
    local v_in=$(iptables -L INPUT -v -n -x | grep "TRAFFIC_IN_$port" | awk '{print $2}')
    local v_out=$(iptables -L OUTPUT -v -n -x | grep "TRAFFIC_OUT_$port" | awk '{print $2}')
    echo $((${v_in:-0} + ${v_out:-0}))
}

# 执行封锁
block_action() {
    local port=$1
    if ! iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$port" -j DROP
        iptables -I INPUT 1 -p udp --dport "$port" -j DROP
        iptables -I OUTPUT 1 -p tcp --sport "$port" -j DROP
        iptables -I OUTPUT 1 -p udp --sport "$port" -j DROP
        # 尝试切断现有连接
        timeout 2 ss -K dport = :$port >/dev/null 2>&1
        log "ALERT: Port $port traffic limit exceeded. BLOCKED."
    fi
}

# 执行解封
unblock_action() {
    local port=$1
    # 移除封锁规则
    while iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p udp --sport "$port" -j DROP 2>/dev/null; do :; done
    
    # 彻底重置统计链（归零）
    clean_iptables "$port"
    init_chain "$port"
    
    log "INFO: Port $port restriction expired. UNBLOCKED and Counter RESET."
}

# --- MODE: CLEANUP (Used by uninstaller) ---
if [ "$1" == "cleanup" ]; then
    if [ -f "$CONF_FILE" ]; then
        while read -r line; do
            [[ "$line" =~ ^#.*$ ]] && continue
            [ -z "$line" ] && continue
            port=$(echo $line | awk -F: '{print $1}')
            clean_iptables "$port"
            echo "已清理端口 $port 的规则."
        done < "$CONF_FILE"
    fi
    rm -rf "$LOCK_DIR"
    exit 0
fi

# --- MODE: MONITOR (Cron job) ---
NOW=$(date +%s)
if [ -f "$CONF_FILE" ]; then
    while read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        
        # 解析配置: 端口:流量GB:封锁小时
        IFS=':' read -r port limit_gb block_hours <<< "$line"
        
        # 初始化
        init_chain "$port"
        
        lock_file="$LOCK_DIR/$port.lock"
        
        # 检查是否在封锁期
        if [ -f "$lock_file" ]; then
            block_time=$(cat "$lock_file")
            # 防止空文件报错
            if [ -z "$block_time" ]; then block_time=$NOW; echo $NOW > "$lock_file"; fi
            
            elapsed=$((NOW - block_time))
            unlock_sec=$((block_hours * 3600))
            
            if [ "$elapsed" -ge "$unlock_sec" ]; then
                unblock_action "$port"
                rm -f "$lock_file"
            else
                block_action "$port" # 维持封锁
            fi
            continue
        fi
        
        # 检查流量
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
    echo "例如输入: 8080:500:24 (表示8080端口，500G流量限制，超标封24小时)"
    echo "-------------------------------------"
    read -p "请输入规则 (默认为 80:100:24): " user_rule
    
    if [ -z "$user_rule" ]; then
        user_rule="80:100:24"
    fi
    
    # 写入配置文件
    echo "$user_rule" > "$CONFIG_PATH"
    green "配置已保存至 $CONFIG_PATH"
    
    # 创建核心脚本
    create_monitor_script
    green "核心监控脚本已生成."
    
    # 添加定时任务 (每分钟执行)
    if ! crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null; echo "* * * * * $INSTALL_PATH >/dev/null 2>&1") | crontab -
        green "定时任务 (Cron) 已添加，每分钟检测一次."
    else
        yellow "定时任务已存在，跳过."
    fi
    
    # 立即运行一次进行初始化
    $INSTALL_PATH
    green "安装完成！脚本已开始在后台运行。"
    echo "你可以随时编辑 $CONFIG_PATH 来增加更多端口 (每行一个规则)。"
}

# 4. 卸载流程
uninstall_monitor() {
    echo "正在卸载并清理..."
    
    # 1. 调用脚本内部清理功能，移除 iptables 规则
    if [ -f "$INSTALL_PATH" ]; then
        bash "$INSTALL_PATH" cleanup
        green "防火墙规则限制已解除。"
    else
        yellow "监控脚本文件不存在，尝试手动清理可能残留的规则..."
        # 备用清理方案：如果脚本没了，尝试读取配置清理
        if [ -f "$CONFIG_PATH" ]; then
             while read -r line; do
                port=$(echo $line | awk -F: '{print $1}')
                iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
                iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
                iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null
             done < "$CONFIG_PATH"
        fi
    fi
    
    # 2. 移除定时任务
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    green "定时任务已移除。"
    
    # 3. 删除文件
    rm -f "$INSTALL_PATH"
    rm -f "$CONFIG_PATH"
    rm -rf "$LOCK_DIR"
    rm -f "$LOG_FILE"
    
    green "卸载完成！所有限制已取消，系统已恢复干净。"
}

# --- 主菜单 ---
clear
echo "=============================================="
echo "    VPS 流量监控与限制管理 (One-Click Guard)"
echo "=============================================="
echo " 1. 安装监控 (Install)"
echo " 2. 编辑规则 (Edit Config)"
echo " 3. 查看日志 (View Log)"
echo " 4. 彻底卸载 (Uninstall & Unblock)"
echo " 0. 退出 (Exit)"
echo "=============================================="
read -p "请输入数字 [0-4]: " choice

case "$choice" in
    1)
        install_monitor
        ;;
    2)
        if [ -f "$CONFIG_PATH" ]; then
            vi "$CONFIG_PATH"
            green "修改已保存，等待下一分钟生效。"
        else
            red "请先安装监控！"
        fi
        ;;
    3)
        if [ -f "$LOG_FILE" ]; then
            tail -n 20 "$LOG_FILE"
        else
            echo "暂无日志。"
        fi
        ;;
    4)
        uninstall_monitor
        ;;
    0)
        exit 0
        ;;
    *)
        echo "无效输入"
        ;;
esac

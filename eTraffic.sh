#!/bin/bash
# ==============================================================
# VPS 流量自动管理系统 (Traffic Monitor Manager) v2.6 Security-Fix
# 紧急修复：
# 1. 增加“数字指纹校验”，防止因配置文件空行导致的“全端口误封”
# 2. 增加 Windows 换行符自动清洗 (tr -d '\r')
# 3. 封锁函数增加“空值熔断”机制，变量为空时拒绝执行 iptables
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
    if [ -f /etc/redhat-release ]; then CMD="yum install -y"; else CMD="apt-get install -y"; fi
    for pkg in bc iptables nano; do
        if ! command -v $pkg &> /dev/null; then
            echo -e "${YELLOW}正在安装依赖: $pkg ...${RES}"
            $CMD $pkg >/dev/null 2>&1
        fi
    done
}

# 2. 生成核心监控脚本
create_monitor_script() {
    cat > "$INSTALL_PATH" << 'EOF'
#!/bin/bash
CONF_FILE="/etc/traffic_guard.conf"
LOG_FILE="/var/log/traffic_guard.log"
LOCK_DIR="/tmp/traffic_guard_locks"
mkdir -p "$LOCK_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

clean_iptables() {
    local port=$1
    # 安全检查：如果端口不是数字，直接退出，防止误删
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then return; fi
    
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
    # 安全检查
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then return; fi

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
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then echo 0; return; fi
    
    # 使用 printf "%.0f" 强制转换为纯整数，防止科学计数法报错
    local v_in=$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
    local v_out=$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
    echo $((${v_in:-0} + ${v_out:-0}))
}

block_action() {
    local port=$1
    # 熔断机制：如果端口为空或非数字，绝对不执行封禁
    if [ -z "$port" ]; then return; fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then return; fi

    if ! iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
        # 仅针对特定端口封禁，绝不封禁 ALL
        iptables -I INPUT 1 -p tcp --dport "$port" -j DROP
        iptables -I INPUT 1 -p udp --dport "$port" -j DROP
        iptables -I OUTPUT 1 -p tcp --sport "$port" -j DROP
        iptables -I OUTPUT 1 -p udp --sport "$port" -j DROP
        
        # 杀掉对应连接
        timeout 2 ss -K dport = :$port >/dev/null 2>&1
        log "ALERT: Port $port traffic limit exceeded. BLOCKED."
    fi
}

unblock_action() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then return; fi

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
            # 兼容性清洗
            line=$(echo "$line" | tr -d '\r')
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
        # 1. 剔除 Windows 换行符
        line=$(echo "$line" | tr -d '\r')
        
        # 2. 跳过注释和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        
        IFS=':' read -r port limit_gb block_hours <<< "$line"
        
        # 3. 核心安全检查：如果端口不是数字，直接跳过本行
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then continue; fi

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

# 3. 功能：仪表盘 (同步安全修复)
show_status() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}未找到配置文件，请先安装监控！${RES}"
        return
    fi

    echo -e "${BOLD}正在获取实时数据...${RES}"
    
    SEP="+----------+----------------+----------------+----------+------------+"
    echo "$SEP"
    printf "| %-8s | %-14s | %-14s | %-8s | %-10s |\n" " PORT" " USED" " LIMIT" " USAGE" " STATUS"
    echo "$SEP"

    while read -r line; do
        # 这里的读取逻辑必须与后台脚本一致，否则显示会不准
        line=$(echo "$line" | tr -d '\r')
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        
        IFS=':' read -r port limit_gb block_hours <<< "$line"
        
        # 忽略无效端口
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then continue; fi

        v_in=$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_IN_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
        v_out=$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v t="TRAFFIC_OUT_$port" '$3 == t {sum+=$2} END {printf "%.0f", sum}')
        bytes=$((${v_in:-0} + ${v_out:-0}))

        if [ "$bytes" -gt 1073741824 ]; then
            used_human=$(echo "scale=2; $bytes/1024/1024/1024" | bc)
            used_unit="GB"
        else
            used_human=$(echo "scale=2; $bytes/1024/1024" | bc)
            used_unit="MB"
        fi

        limit_bytes=$(echo "$limit_gb * 1024 * 1024 * 1024" | bc | cut -d. -f1)
        if [ "$limit_bytes" -gt 0 ]; then
            percent=$(echo "scale=1; ($bytes * 100) / $limit_bytes" | bc)
        else
            percent="0"
        fi

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

# 4. 安装流程
install_monitor() {
    check_dependencies
    
    echo "--------------------------------------------------------"
    echo -e "${YELLOW}开始配置监控规则 (支持多端口录入)${RES}"
    echo "输入格式: 端口 流量上限(GB) 封锁时长(小时)"
    echo "使用空格分隔，例如: 8080 500 24"
    echo "--------------------------------------------------------"
    
    > "$CONFIG_PATH"
    
    while true; do
        echo -e "${BLUE}>> 请输入规则 (直接回车表示录入结束):${RES}"
        read -p "> " input_rule
        if [ -z "$input_rule" ]; then break; fi
        
        # 即使输入时有多余空格或TAB，也在此处清洗
        clean_rule=$(echo "$input_rule" | tr -s ' ' ':')
        
        # 简单格式校验
        if [[ $(echo "$clean_rule" | grep -o ":" | wc -l) -lt 2 ]]; then
             echo -e "${RED}格式错误！请确保输入了三个参数 (端口 流量 时间)${RES}"
             continue
        fi
        echo "$clean_rule" >> "$CONFIG_PATH"
        echo -e "${GREEN}已添加规则: $clean_rule${RES}"
    done
    
    if [ ! -s "$CONFIG_PATH" ]; then
        echo "80:100:24" > "$CONFIG_PATH"
        echo -e "${YELLOW}未检测到输入，已使用默认规则: 80:100:24${RES}"
    fi
    
    create_monitor_script
    
    if ! crontab -l 2>/dev/null | grep -q "$INSTALL_PATH"; then
        (crontab -l 2>/dev/null; echo "* * * * * $INSTALL_PATH >/dev/null 2>&1") | crontab -
        echo -e "${GREEN}定时任务已添加。${RES}"
    fi
    
    bash "$INSTALL_PATH"
    echo -e "${GREEN}安装完成！监控已启动。${RES}"
}

# 5. 卸载流程
uninstall_monitor() {
    echo "正在卸载..."
    if [ -f "$INSTALL_PATH" ]; then
        bash "$INSTALL_PATH" cleanup
    else
        # 备用清理：防止脚本文件丢失无法卸载
        if [ -f "$CONFIG_PATH" ]; then
             while read -r line; do
                line=$(echo "$line" | tr -d '\r')
                port=$(echo $line | awk -F: '{print $1}')
                if [[ "$port" =~ ^[0-9]+$ ]]; then
                    iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
                    iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
                    iptables -D OUTPUT -p tcp --sport "$port" -j DROP 2>/dev/null
                fi
             done < "$CONFIG_PATH"
        fi
    fi
    crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | crontab -
    rm -f "$INSTALL_PATH" "$CONFIG_PATH" "$LOG_FILE"
    rm -rf "$LOCK_DIR"
    echo -e "${GREEN}卸载完成！${RES}"
}

# --- 主循环菜单 ---
while true; do
    clear
    echo -e "${BLUE}==============================================${RES}"
    echo -e "${BOLD}    VPS 流量监控管家 (Traffic Guard v2.6)${RES}"
    echo -e "${BLUE}==============================================${RES}"
    echo " 1. 安装/重置监控 (Install - Multi Input)"
    echo " 2. 编辑监控规则 (Nano)"
    echo -e "${YELLOW} 3. 查看实时流量状态 (Status Dashboard)${RES}"
    echo " 4. 查看操作日志 (Logs)"
    echo " 5. 彻底卸载 (Uninstall)"
    echo " 0. 退出 (Exit)"
    echo -e "${BLUE}==============================================${RES}"
    read -p "请输入数字 [0-5]: " choice

    case "$choice" in
        1) install_monitor; pause_and_return ;;
        2) 
            if [ -f "$CONFIG_PATH" ]; then
                nano "$CONFIG_PATH"
                echo -e "${GREEN}修改已保存，等待更新。${RES}"
            else
                echo -e "${RED}请先执行安装！${RES}"
            fi
            pause_and_return 
            ;;
        3) show_status; pause_and_return ;;
        4) 
            if [ -f "$LOG_FILE" ]; then tail -n 20 "$LOG_FILE"; else echo "暂无日志。"; fi
            pause_and_return 
            ;;
        5) uninstall_monitor; pause_and_return ;;
        0) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done

#!/bin/bash

# ==============================================================================
# 四合一代理管理脚本 (Four-in-one Proxy Manager)
# 优化版本 - 性能提升 - 本地版本号获取 - 依赖前置 - GitHub镜像加速
# ==============================================================================

# 全局颜色定义
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# 全局变量：控制命令行模式
CLI_MODE=0

# 调试模式
DEBUG=${DEBUG:-0}

# 全局工具函数
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_RED}[错误] 请使用 root 权限运行此脚本 (sudo -i)${C_RESET}"
        exit 1
    fi
}

pause_key() {
    # 命令行模式跳过暂停
    if [[ "$CLI_MODE" -eq 1 ]]; then return; fi
    echo
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

debug_log() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${C_CYAN}[DEBUG] $1${C_RESET}"
    fi
}

# ==============================================================================
# 基础依赖安装函数
# ==============================================================================
install_dependencies() {
    if ! command -v curl &>/dev/null || ! command -v unzip &>/dev/null || ! command -v openssl &>/dev/null; then
        echo -e "${C_BLUE}[*] 安装基础依赖...${C_RESET}"
        if command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y curl unzip wget tar openssl >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y curl unzip wget tar openssl >/dev/null 2>&1
        fi
        echo -e "${C_GREEN}[✔] 依赖安装完成${C_RESET}"
    fi
}

# ==============================================================================
# 时间同步和时区设置函数
# ==============================================================================
setup_ntp_sync() {
    echo -e "${C_BLUE}[*] 检查系统时间同步...${C_RESET}"
    
    # 尝试方案1：安装 systemd-timesyncd
    if ! systemctl is-active --quiet systemd-timesyncd; then
        echo "安装 systemd-timesyncd..."
        if command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y systemd-timesyncd >/dev/null 2>&1
        fi
        systemctl start systemd-timesyncd 2>/dev/null
        systemctl enable systemd-timesyncd 2>/dev/null
        sleep 2
    fi
    
    # 如果 systemd-timesyncd 还是不工作，用 ntpdate 强制同步一次
    if ! timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
        if ! command -v ntpdate &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                apt-get install -y ntpdate >/dev/null 2>&1
            fi
        fi
        ntpdate -u ntp.ubuntu.com 2>/dev/null || ntpdate -u pool.ntp.org 2>/dev/null
    fi
    
    # 设置时区为上海
    echo "设置时区为上海..."
    timedatectl set-timezone Asia/Shanghai
    
    echo -e "${C_GREEN}[✔] 时间同步完成${C_RESET}"
    timedatectl status | grep "Local time" || true
}

# ==============================================================================
# 统一公共函数 - 网络请求优化
# ==============================================================================

# 带重试的网络请求函数
get_with_retry() {
    local url=$1
    local max_attempts=3
    local attempt=1
    local timeout=4
    
    debug_log "请求URL: $url"
    
    while [ $attempt -le $max_attempts ]; do
        result=$(curl -4s --max-time $timeout "$url" 2>/dev/null)
        if [ -n "$result" ]; then
            debug_log "请求成功 (尝试 $attempt)"
            echo "$result"
            return 0
        fi
        debug_log "请求失败，重试 $attempt/$max_attempts"
        attempt=$((attempt + 1))
    done
    return 1
}

# 统一的IPv4获取函数
get_public_ip() {
    local ip
    ip=$(get_with_retry "https://api-ipv4.ip.sb/ip") && echo "$ip" && return 0
    ip=$(get_with_retry "https://api.ipify.org") && echo "$ip" && return 0
    echo ""
}

# IPv6获取函数
get_public_ipv6() {
    local ipv6
    ipv6=$(curl -6s --max-time 4 https://api.ipify.org 2>/dev/null)
    [ -n "$ipv6" ] && echo "$ipv6" || echo ""
}

# 获取本地Xray版本号
get_xray_version() {
    local xray_binary_path="/usr/local/bin/xray"
    
    if [[ -f "$xray_binary_path" ]]; then
        # 优先从本地获取 - 快速且准确
        local version
        version=$("$xray_binary_path" -version 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    echo "Unknown"
}

# ==============================================================================
# 统一 Xray 核心安装函数 (带 GitHub 代理镜像加速)
# ==============================================================================

install_xray_core() {
    local xray_binary_path="/usr/local/bin/xray"
    local proxy_prefix="https://gcode.hostcentral.cc/"
    
    # 已安装则不重复安装核心
    if [[ -f "$xray_binary_path" ]]; then
        debug_log "Xray核心已存在，跳过安装"
        return 0
    fi
    
    # 通过代理下载官方安装脚本
    local xray_install_script_url="${proxy_prefix}https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
    local content
    content=$(curl -sL --max-time 15 "$xray_install_script_url" 2>/dev/null)
    
    if [[ -z "$content" || ! "$content" =~ "install-release" ]]; then
        echo -e "${C_RED}[✖] 无法通过加速镜像下载 Xray 安装脚本，请检查网络！${C_RESET}"
        return 1
    fi
    
    echo -e "${C_BLUE}[*] 开始下载并安装 Xray 核心 (使用加速镜像)...${C_RESET}"
    
    # 利用字符串替换，把脚本内部的 github.com 链接全部换成带代理前缀的链接
    content="${content//https:\/\/github.com/${proxy_prefix}https:\/\/github.com}"
    content="${content//https:\/\/raw.githubusercontent.com/${proxy_prefix}https:\/\/raw.githubusercontent.com}"
    
    # 执行安装核心，暴露出输出信息方便排错
    echo "$content" | bash -s -- install
    
    # 执行安装 Geo 数据
    echo "$content" | bash -s -- install-geodata
    
    # 增加严格校验：到底装进去了没有
    if [[ ! -f "$xray_binary_path" ]]; then
        echo -e "${C_RED}[✖] Xray 核心安装失败！请检查上方报错日志。${C_RESET}"
        return 1
    fi
    
    return 0
}

# ==============================================================================
# 模块 0: VMess+TCP - 函数定义（独立服务）
# ==============================================================================

m0_log_error() { echo -e "${C_RED}[✖] $1${C_RESET}"; }
m0_log_success() { echo -e "${C_GREEN}[✔] $1${C_RESET}"; }

m0_get_public_ip() {
    get_public_ip
}

m0_restart_xray_vmess_tcp() {
    mkdir -p /etc/systemd/system
    cat <<'EOF' >/etc/systemd/system/xray-vmesstcp.service
[Unit]
Description=Xray VMess-TCP Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/vmesstcp.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray-vmesstcp
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-vmesstcp >/dev/null 2>&1
    systemctl restart xray-vmesstcp
    sleep 2 # 等待服务启动
    systemctl is-active --quiet xray-vmesstcp
}

m0_install_vmess_tcp() {
    local xray_config_path="/usr/local/etc/xray/vmesstcp.json"

    # --- 默认配置 ---
    local port=26200
    local uuid="03c50ab2-80bf-40f2-947c-46b9e8f7b603"
    # ----------------

    # 检测是否已安装
    if [[ -f "$xray_config_path" ]] && systemctl is-active --quiet xray-vmesstcp 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 VMess+TCP 已安装，跳过安装步骤。${C_RESET}"
        local ip
        ip=$(m0_get_public_ip)
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
		echo ""
        echo -e "${C_GREEN}=== VMess+TCP 节点链接 ===${C_RESET}"
        local json_str="{\"v\":\"2\",\"ps\":\"VMess-TCP\",\"add\":\"${ip}\",\"port\":${port},\"id\":\"${uuid}\",\"aid\":0,\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}"
        local link="vmess://$(echo -n "$json_str" | base64 -w 0)"
        echo "$link"
        echo ""
        return 0
    fi
    
    # 安装 Xray 核心
    if ! install_xray_core; then
        return 1
    fi
    
    # 显示版本号
    echo "Xray 核心版本号: $(get_xray_version)"

    echo "正在配置 VMess+TCP..."
    mkdir -p "$(dirname "$xray_config_path")"
    cat > "$xray_config_path" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "::",
    "port": $port,
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "$uuid", "alterId": 0}]
    },
    "streamSettings": {
      "network": "tcp"
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 644 "$xray_config_path"

    if m0_restart_xray_vmess_tcp; then
        local ip
        ip=$(m0_get_public_ip)
        local json_str="{\"v\":\"2\",\"ps\":\"VMess-TCP\",\"add\":\"${ip}\",\"port\":${port},\"id\":\"${uuid}\",\"aid\":0,\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}"
        local link="vmess://$(echo -n "$json_str" | base64 -w 0)"
        mkdir -p /root/four-in-one
        m0_log_success "VMess+TCP 安装完成！"
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
		echo ""
        echo -e "${C_GREEN}=== VMess+TCP 节点链接 ===${C_RESET}"
        echo "$link"
        echo ""
        echo "$link" > /root/four-in-one/xray_vmess_tcp_link.txt
    else
        m0_log_error "启动失败，请检查日志 (journalctl -u xray-vmesstcp)"
    fi
}

m0_view_info() {
    if [ -f /root/four-in-one/xray_vmess_tcp_link.txt ]; then
        cat /root/four-in-one/xray_vmess_tcp_link.txt
    else
        m0_log_error "未找到 VMess+TCP 链接，请先安装。"
    fi
}

module_vmess_tcp_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== VMess+TCP ===${C_RESET}"
        if systemctl is-active --quiet xray-vmesstcp; then
            echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
            echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装VMess+TCP"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "5. 查看日志"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m0_install_vmess_tcp; pause_key ;;
            2) m0_view_info; pause_key ;;
            3) m0_restart_xray_vmess_tcp; m0_log_success "已重启"; pause_key ;;
            4) m0_uninstall_vmess_tcp; pause_key ;;
            5) journalctl -u xray-vmesstcp -n 20 --no-pager; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

m0_uninstall_vmess_tcp() {
    echo "正在卸载 VMess+TCP..."
    systemctl stop xray-vmesstcp 2>/dev/null
    systemctl disable xray-vmesstcp 2>/dev/null
    rm -f /etc/systemd/system/xray-vmesstcp.service
    rm -f /usr/local/etc/xray/vmesstcp.json
    systemctl daemon-reload
    m0_log_success "卸载完成"
}

# ==============================================================================
# 模块 1: Socks5 - 函数定义 - 优化版
# ==============================================================================

m1_install_xray() {
    local CONFIG_DIR="/etc/xrayL"
    local SERVICE_FILE="/etc/systemd/system/xray-socks5.service"
    local CONFIG_PATH="/usr/local/etc/xray/socks5.json"
    
    # --- 默认配置 ---
    local START_PORT=20264
    local USER="abai"
    local PASS="abai569"
    # ----------------
    
    # === 检测是否已安装 ===
    local ALREADY_INSTALLED=0
    if [[ -f "$SERVICE_FILE" ]]; then
        echo -e "${C_YELLOW}检测到 Socks5 已安装，跳过安装步骤。${C_RESET}"
        ALREADY_INSTALLED=1
    else
        # 新安装：安装 Xray 核心
        if ! install_xray_core; then
            echo -e "${C_RED}[✖] 核心安装失败${C_RESET}"
            return 1
        fi

        cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=Xray Socks5 Multi-IP Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/socks5.json
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xray-socks5.service >/dev/null 2>&1
        
        # 显示安装信息（仅新安装）
        echo "正在配置 Socks5..."
		
    fi
    # ====================

    # 重新获取IP列表
    local IPV4_LIST=()
    local IPV6_LIST=()

    debug_log "开始检测IPv4地址..."
    while read ip; do
        [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168|127\.) ]] && continue
        if curl --interface "$ip" -s4 --max-time 3 ip.sb 2>/dev/null | grep -q "$ip"; then
            IPV4_LIST+=("$ip")
            debug_log "检测到IPv4: $ip"
        fi
    done < <(ip -4 addr show scope global | awk '{print $2}' | cut -d/ -f1)

    # IPv4 NAT/Cloud
    debug_log "检测公网IPv4..."
    local PUB_IPV4
    PUB_IPV4=$(curl -s4 --max-time 3 ip.sb 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$PUB_IPV4" ] && IPV4_LIST+=("$PUB_IPV4") && debug_log "检测到公网IPv4: $PUB_IPV4"

    # IPv6
    debug_log "开始检测IPv6地址..."
    while read ip; do
        [[ "$ip" =~ ^(fd|fe80) ]] && continue
        if curl --interface "$ip" -s6 --max-time 3 ip.sb 2>/dev/null | grep -q ':'; then
            IPV6_LIST+=("$ip")
            debug_log "检测到IPv6: $ip"
        fi
    done < <(ip -6 addr show scope global | awk '{print $2}' | cut -d/ -f1)

    # 去重
    IPV4_LIST=($(printf "%s\n" "${IPV4_LIST[@]}" | sort -u))
    IPV6_LIST=($(printf "%s\n" "${IPV6_LIST[@]}" | sort -u))

    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    # 生成 Xray JSON 配置
    local inbounds="[]"
    local index=0
    local all_ips=("${IPV4_LIST[@]}" "${IPV6_LIST[@]}")

    for ip in "${all_ips[@]}"; do
        local PORT=$((START_PORT + index))
        local listen_addr="$ip"
        [[ "$ip" =~ ":" ]] && listen_addr="[$ip]"
        
        if [ $index -eq 0 ]; then
            inbounds="[{\"listen\": \"$listen_addr\", \"port\": $PORT, \"protocol\": \"socks\", \"settings\": {\"auth\": \"password\", \"accounts\": [{\"user\": \"$USER\", \"pass\": \"$PASS\"}]}}]"
        else
            inbounds="${inbounds%]},{\"listen\": \"$listen_addr\", \"port\": $PORT, \"protocol\": \"socks\", \"settings\": {\"auth\": \"password\", \"accounts\": [{\"user\": \"$USER\", \"pass\": \"$PASS\"}]}}]"
        fi
        index=$((index + 1))
    done

    cat > "$CONFIG_PATH" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": $inbounds,
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 644 "$CONFIG_PATH"
    
    systemctl restart xray-socks5.service >/dev/null 2>&1
    sleep 2 # 等待服务重启
    
    # 仅在新安装时显示“安装完成”
    if [[ "$ALREADY_INSTALLED" -eq 0 ]]; then
        echo -e "${C_GREEN}[✔] Socks5 安装完成！${C_RESET}"
    fi
    
    echo -e "${C_YELLOW}使用默认配置：${C_RESET}"
    echo "起始端口：$START_PORT 用户：$USER 密码：$PASS"
    
    if [ ${#all_ips[@]} -gt 0 ]; then
        echo -e "\n${C_GREEN}=== Socks5 节点链接 ===${C_RESET}"
        local idx=0
        for ip in "${all_ips[@]}"; do
            local PORT=$((START_PORT + idx))
            idx=$((idx + 1))
            if [[ "$ip" =~ ":" ]]; then
                printf "socks5://%s:%s@[%s]:%s\n" "$USER" "$PASS" "$ip" "$PORT"
            else
                printf "socks5://%s:%s@%s:%s\n" "$USER" "$PASS" "$ip" "$PORT"
            fi
        done
        echo ""
    fi
}

m1_uninstall_xray() {
    echo "开始卸载 Socks5..."
    systemctl stop xray-socks5.service 2>/dev/null
    systemctl disable xray-socks5.service 2>/dev/null
    rm -f "/etc/systemd/system/xray-socks5.service"
    systemctl daemon-reload
    rm -f "/usr/local/etc/xray/socks5.json"
    rm -rf "/etc/xrayL"
    echo "Socks5 已卸载完成"
}

module_socks5_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Socks5 ===${C_RESET}"
        echo "1. 安装Socks5"
        echo "2. 重置配置"
        echo "3. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1|2)
                m1_install_xray
                pause_key
                ;;
            3)
                m1_uninstall_xray
                pause_key
                ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 模块 2: VMess+WS - 函数定义（独立服务）
# ==============================================================================

m2_log_error() { echo -e "${C_RED}[✖] $1${C_RESET}"; }
m2_log_success() { echo -e "${C_GREEN}[✔] $1${C_RESET}"; }

m2_get_public_ip() {
    get_public_ip
}

m2_restart_xray_vmess_ws() {
    mkdir -p /etc/systemd/system
    cat <<'EOF' >/etc/systemd/system/xray-vmessws.service
[Unit]
Description=Xray VMess-WS Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/vmessws.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray-vmessws
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-vmessws >/dev/null 2>&1
    systemctl restart xray-vmessws
    sleep 2 # 等待服务启动
    systemctl is-active --quiet xray-vmessws
}

m2_install_xray() {
    local xray_config_path="/usr/local/etc/xray/vmessws.json"
    
    # --- 默认配置 ---
    local port=26201
    local uuid="03c50ab2-80bf-40f2-947c-46b9e8f7b603"
    local ws_path="/vmessws"
    # ----------------

    # 检测是否已安装
    if [[ -f "$xray_config_path" ]] && systemctl is-active --quiet xray-vmessws 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 VMess+WS 已安装，跳过安装步骤。${C_RESET}"
        local ip
        ip=$(m2_get_public_ip)
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
		echo ""
        echo -e "${C_GREEN}=== VMess+WS 节点链接 ===${C_RESET}"
        local json_str="{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${ip}\",\"port\":${port},\"id\":\"${uuid}\",\"aid\":0,\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${ws_path}\",\"tls\":\"\"}"
        local link="vmess://$(echo -n "$json_str" | base64 -w 0)"
        echo "$link"
        echo ""
        return 0
    fi
    
    # 安装 Xray 核心
    if ! install_xray_core; then
        return 1
    fi

    echo "正在配置 VMess+WS..."
    mkdir -p "$(dirname "$xray_config_path")"
    cat > "$xray_config_path" <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vmess",
        "settings": {
            "clients": [{"id": "$uuid", "alterId": 0}]
        },
        "streamSettings": { 
            "network": "ws",
            "wsSettings": {
                "path": "$ws_path"
            }
        }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF
    chmod 644 "$xray_config_path"
    
    if m2_restart_xray_vmess_ws; then
        local ip
        ip=$(m2_get_public_ip)
        local json_str="{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${ip}\",\"port\":${port},\"id\":\"${uuid}\",\"aid\":0,\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${ws_path}\",\"tls\":\"\"}"
        local link="vmess://$(echo -n "$json_str" | base64 -w 0)"
        m2_log_success "VMess+WS 安装完成！"
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
        echo -e "\n${C_GREEN}=== VMess+WS 节点链接 ===${C_RESET}"
        echo "$link"
        echo ""
        mkdir -p /root/four-in-one
        echo "$link" > /root/four-in-one/xray_vmess_ws_link.txt
    else
        m2_log_error "启动失败，请检查日志 (journalctl -u xray-vmessws)"
    fi
}

m2_uninstall_xray() {
    echo "正在卸载 VMess+WS..."
    systemctl stop xray-vmessws 2>/dev/null
    systemctl disable xray-vmessws 2>/dev/null
    rm -f /etc/systemd/system/xray-vmessws.service
    rm -f /usr/local/etc/xray/vmessws.json
    systemctl daemon-reload
    m2_log_success "卸载完成"
}

m2_view_info() {
    if [ -f /root/four-in-one/xray_vmess_ws_link.txt ]; then
        echo -e "${C_GREEN}上次生成的链接:${C_RESET}"
        cat /root/four-in-one/xray_vmess_ws_link.txt
    else
        m2_log_error "未找到链接文件，请重新安装或检查配置。"
    fi
}

module_vmess_ws_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== VMess+WS ===${C_RESET}"
        if systemctl is-active --quiet xray-vmessws; then
             echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
             echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装VMess+WS"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "5. 查看日志"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m2_install_xray; pause_key ;;
            2) m2_view_info; pause_key ;;
            3) m2_restart_xray_vmess_ws; m2_log_success "已重启"; pause_key ;;
            4) m2_uninstall_xray; pause_key ;;
            5) journalctl -u xray-vmessws -n 20 --no-pager; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 模块 3: Shadowsocks-2022 - 函数定义
# ==============================================================================

m3_install_ss() {
    local CONFIG_PATH="/usr/local/etc/xray/ss2022.json"
    local SERVICE_FILE="/etc/systemd/system/xray-ss2022.service"
    
    # === 检测是否已安装 ===
    if [[ -f "$CONFIG_PATH" ]] && systemctl is-active --quiet xray-ss2022 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 SS-2022 已安装，跳过安装步骤。${C_RESET}"
        m3_view_config
        return 0
    fi
    # ====================

    # --- 默认配置 ---
    local port=26202
    local password="gZl9lxHUUZiI5gakkq3pDA=="
    local method="2022-blake3-aes-128-gcm"
    # ----------------

    # 安装 Xray 核心
    if ! install_xray_core; then
        return 1
    fi
    
    echo "正在配置 SS-2022..."
    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 写入配置
    cat <<EOF > "$CONFIG_PATH"
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "shadowsocks",
        "settings": {
            "method": "$method",
            "password": "$password"
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 644 "$CONFIG_PATH"

    # 服务文件
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Xray Shadowsocks-2022 Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config $CONFIG_PATH
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-ss2022 >/dev/null 2>&1
    
    # 启动服务并检查
    systemctl restart xray-ss2022 >/dev/null 2>&1
    sleep 2 # 等待服务启动
    
    if systemctl is-active --quiet xray-ss2022; then
        debug_log "SS-2022 服务启动成功"
        echo -e "${C_GREEN}[✔] SS-2022 安装完成！${C_RESET}"
    else
        echo -e "${C_RED}[✖] SS-2022 服务启动失败，请检查日志${C_RESET}"
        return 1
    fi

    m3_view_config
}

m3_view_config() {
    local CONFIG_PATH="/usr/local/etc/xray/ss2022.json"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${C_RED}[错误] 未找到配置文件${C_RESET}"
        return
    fi
    
    local port
    port=$(grep '"port"' "$CONFIG_PATH" | tr -cd '0-9')
    local password
    password=$(grep '"password"' "$CONFIG_PATH" | cut -d'"' -f4)
    local method
    method=$(grep '"method"' "$CONFIG_PATH" | cut -d'"' -f4)
    
    local ip
    ip=$(get_public_ip)
    
    local link_str="${method}:${password}"
    local base64_str
    base64_str=$(echo -n "$link_str" | base64 -w 0)
    local link="ss://${base64_str}@${ip}:${port}#SS-2022"
    
    echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
    echo -e "${C_YELLOW}默认密码: $password${C_RESET}"
    echo -e "\n${C_GREEN}=== SS-2022 节点链接 ===${C_RESET}"
    echo "$link"
    echo ""
}

m3_uninstall_ss() {
    echo "卸载 SS-2022..."
    systemctl stop xray-ss2022 2>/dev/null
    systemctl disable xray-ss2022 2>/dev/null
    rm -f "/etc/systemd/system/xray-ss2022.service"
    systemctl daemon-reload
    rm -f "/usr/local/etc/xray/ss2022.json"
    echo -e "${C_GREEN}[成功] 已卸载${C_RESET}"
}

module_ssrust_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Shadowsocks-2022 ===${C_RESET}"
        if systemctl is-active --quiet xray-ss2022; then
             echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
             echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装SS-2022"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m3_install_ss; pause_key ;;
            2) m3_view_config; pause_key ;;
            3) systemctl restart xray-ss2022; echo -e "${C_GREEN}已重启${C_RESET}"; pause_key ;;
            4) m3_uninstall_ss; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 一键安装所有服务
# ==============================================================================
install_all_services() {
    clear
    echo -e "${C_YELLOW}>>> 开始安装服务...${C_RESET}"

    m0_install_vmess_tcp
    m2_install_xray
    m3_install_ss
    m1_install_xray

    echo -e "${C_GREEN}>>> 服务全部安装${C_RESET}"
    pause_key
}

# ==============================================================================
# 卸载所有服务逻辑
# ==============================================================================
uninstall_all() {
    echo -e "${C_RED}警告: 即将卸载所有模块 (VMess+TCP, VMess+WS, SS-2022, Socks5)!${C_RESET}"
    
    # 命令行模式跳过确认
    if [[ "$CLI_MODE" -eq 0 ]]; then
        read -p "确定继续吗? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            echo "操作取消。"
            return
        fi
    fi

    # 暴力停止所有可能的服务
    systemctl stop xray-vmesstcp xray-vmessws xray-socks5 xray-ss2022 2>/dev/null
    systemctl disable xray-vmesstcp xray-vmessws xray-socks5 xray-ss2022 2>/dev/null
    
    rm -f /etc/systemd/system/xray-vmesstcp.service
    rm -f /etc/systemd/system/xray-vmessws.service
    rm -f /etc/systemd/system/xray-socks5.service
    rm -f /etc/systemd/system/xray-ss2022.service
    systemctl daemon-reload
    
    # 直接手动删除Xray核心，最稳妥快速
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    
    rm -rf /etc/xrayL
    rm -rf /root/four-in-one
    
    echo -e "${C_GREEN}所有组件已清理完毕。${C_RESET}"
}

# ==============================================================================
# 主逻辑入口 (初始化流)
# ==============================================================================

# 1. 检查是否为 Root 用户
check_root

# 2. 命令行参数解析 (优先拦截卸载命令，跳过时间同步和依赖安装)
if [[ -n "$1" ]]; then
    case "$1" in
        --1)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m0_install_vmess_tcp
            exit 0
            ;;
        --2)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m2_install_xray
            exit 0
            ;;
        --3)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m3_install_ss
            exit 0
            ;;
        --4)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m1_install_xray
            exit 0
            ;;
        --8)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            install_all_services
            exit 0
            ;;
        --9)
            CLI_MODE=1
            uninstall_all
            exit 0
            ;;
    esac
fi

# 3. 如果无参数运行，则安装依赖并同步时间
install_dependencies
setup_ntp_sync

# 4. 进入交互式主菜单
while true; do
    clear
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "${C_CYAN}   四合一代理脚本 (Four-in-one Script)   ${C_RESET}"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "1. ${C_YELLOW}VMess+TCP${C_RESET}"
    echo -e "2. ${C_YELLOW}VMess+WS${C_RESET}"
    echo -e "3. ${C_YELLOW}SS-2022${C_RESET}"
    echo -e "4. ${C_YELLOW}Socks5${C_RESET}"
    echo -e "----------------------------------------------"
    echo -e "8. ${C_GREEN}安装所有服务${C_RESET}"
    echo -e "9. ${C_RED}卸载所有服务${C_RESET}"
    echo -e "0. 退出脚本"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    read -p "请输入选项: " main_choice

    case $main_choice in
        1) module_vmess_tcp_menu ;;
        2) module_vmess_ws_menu ;;
        3) module_ssrust_menu ;;
        4) module_socks5_menu ;;
        8) install_all_services ;;
        9) uninstall_all; pause_key ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause_key ;;
    esac
done

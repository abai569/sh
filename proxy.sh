#!/bin/bash

# ==============================================================================
# 阿白的一键代理装脚本-自用
# 六合一 - VMess/VLESS/SS-2022/AnyTLS/Hysteria2/Socks5
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

# 硬编码 REALITY 密钥对 (固定不变)
REALITY_PRIVATE_KEY="CCDiV4Yky7biXLdPm55KOFKTMTmOasE14IAP6f6CC04"
REALITY_PUBLIC_KEY="t8xSeYQnpY74kT4_e_1-nezXz2UOpANDxYxbZJtOKhY"

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
    local proxy_prefix="https://ghfast.top/"
    
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
    local START_PORT=26208
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
# 模块 2: VLESS+REALITY - 函数定义（独立服务）
# ==============================================================================

m2_log_error() { echo -e "${C_RED}[✖] $1${C_RESET}"; }
m2_log_success() { echo -e "${C_GREEN}[✔] $1${C_RESET}"; }

m2_get_public_ip() {
    get_public_ip
}

m2_restart_xray_vless_reality() {
    mkdir -p /etc/systemd/system
    cat <<'EOF' >/etc/systemd/system/xray-vlessreality.service
[Unit]
Description=Xray VLESS-REALITY Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/vlessreality.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray-vlessreality
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-vlessreality >/dev/null 2>&1
    systemctl restart xray-vlessreality
    sleep 2 # 等待服务启动
    systemctl is-active --quiet xray-vlessreality
}

m2_install_xray() {
    local xray_config_path="/usr/local/etc/xray/vlessreality.json"

    # --- 默认配置 ---
    local port=26201
    local uuid="03c50ab2-80bf-40f2-947c-46b9e8f7b603"
    local dest="tesla.com:443"
    local server_names='["tesla.com"]'
    local short_id="5188"
    local private_key="$REALITY_PRIVATE_KEY"
    local public_key="$REALITY_PUBLIC_KEY"
    # ----------------

    # 检测是否已安装
    if [[ -f "$xray_config_path" ]] && systemctl is-active --quiet xray-vlessreality 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 VLESS+REALITY 已安装，跳过安装步骤。${C_RESET}"
        local ip
        ip=$(m2_get_public_ip)
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
        echo ""
        echo -e "${C_GREEN}=== VLESS+REALITY 节点链接 ===${C_RESET}"
        local link="vless://${uuid}@${ip}:${port}?security=reality&flow=xtls-rprx-vision&pbk=${public_key}&sni=tesla.com&sid=${short_id}&fp=chrome&type=tcp#VLESS-REALITY"
        echo "$link"
        echo ""
        return 0
    fi

    # 安装 Xray 核心
    if ! install_xray_core; then
        return 1
    fi

    echo "正在配置 VLESS+REALITY..."
    mkdir -p "$(dirname "$xray_config_path")"
    cat > "$xray_config_path" <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "$dest",
                "xver": 0,
                "serverNames": $server_names,
                "privateKey": "$private_key",
                "shortIds": ["$short_id"],
                "publicKey": "$public_key",
                "fingerprint": "chrome"
            }
        }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF
    chmod 644 "$xray_config_path"

    if m2_restart_xray_vless_reality; then
        local ip
        ip=$(m2_get_public_ip)
        local link="vless://${uuid}@${ip}:${port}?security=reality&flow=xtls-rprx-vision&pbk=${public_key}&sni=tesla.com&sid=${short_id}&fp=chrome&type=tcp#VLESS-REALITY"
        m2_log_success "VLESS+REALITY 安装完成！"
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
        echo -e "\n${C_GREEN}=== VLESS+REALITY 节点链接 ===${C_RESET}"
        echo "$link"
        echo ""
        mkdir -p /root/four-in-one
        echo "$link" > /root/four-in-one/xray_vless_reality_link.txt
    else
        m2_log_error "启动失败，请检查日志 (journalctl -u xray-vlessreality)"
    fi
}

m2_uninstall_xray() {
    echo "正在卸载 VLESS+REALITY..."
    systemctl stop xray-vlessreality 2>/dev/null
    systemctl disable xray-vlessreality 2>/dev/null
    rm -f /etc/systemd/system/xray-vlessreality.service
    rm -f /usr/local/etc/xray/vlessreality.json
    systemctl daemon-reload
    m2_log_success "卸载完成"
}

m2_view_info() {
    if [ -f /root/four-in-one/xray_vless_reality_link.txt ]; then
        echo -e "${C_GREEN}上次生成的链接:${C_RESET}"
        cat /root/four-in-one/xray_vless_reality_link.txt
    else
        m2_log_error "未找到链接文件，请重新安装或检查配置。"
    fi
}

module_vmess_ws_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== VLESS+REALITY ===${C_RESET}"
        if systemctl is-active --quiet xray-vlessreality; then
             echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
             echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装VLESS+REALITY"
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
            3) m2_restart_xray_vless_reality; m2_log_success "已重启"; pause_key ;;
            4) m2_uninstall_xray; pause_key ;;
            5) journalctl -u xray-vlessreality -n 20 --no-pager; pause_key ;;
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
# 模块 4: AnyTLS - 函数定义
# ==============================================================================

m4_install_anytls() {
    local CONFIG_DIR="/etc/AnyTLS"
    local SERVER_FILE="${CONFIG_DIR}/server"
    local CONFIG_FILE="${CONFIG_DIR}/config.yaml"
    local SERVICE_FILE="/etc/systemd/system/anytls.service"

    # --- 默认配置 ---
    local PORT=20203
    local PASSWORD="AnyTLS569"
    # ----------------

    # 检测是否已安装
    if [[ -f "$SERVICE_FILE" ]] && systemctl is-active --quiet anytls 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 AnyTLS 已安装，跳过安装步骤。${C_RESET}"
        local ip
        ip=$(get_public_ip)
        echo -e "${C_GREEN}=== AnyTLS 节点链接 ===${C_RESET}"
        echo "anytls://${PASSWORD}@${ip}:${PORT}/?insecure=1#AnyTLS"
        echo ""
        return 0
    fi

    echo -e "${C_BLUE}[*] 开始安装 AnyTLS...${C_RESET}"

    # 检测系统架构
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${C_RED}[✖] 不支持的架构: $ARCH${C_RESET}"; return 1 ;;
    esac

    # 获取最新版本
    local LATEST
    LATEST=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST" ]]; then
        echo -e "${C_RED}[✖] 无法获取 AnyTLS 最新版本号${C_RESET}"
        return 1
    fi

    echo -e "${C_BLUE}[*] AnyTLS 版本: ${LATEST}, 架构: ${ARCH}${C_RESET}"

    # 创建目录
    mkdir -p "$CONFIG_DIR"

    # 下载并安装
    local DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"
    local TMP_DIR="/tmp/anytls_install_$$"
    mkdir -p "$TMP_DIR"

    echo -e "${C_BLUE}[*] 下载 AnyTLS...${C_RESET}"
    if ! curl -L -o "${TMP_DIR}/anytls.zip" "$DOWNLOAD_URL" 2>/dev/null; then
        echo -e "${C_RED}[✖] 下载失败${C_RESET}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    unzip -o "${TMP_DIR}/anytls.zip" -d "$TMP_DIR" >/dev/null 2>&1
    mv "${TMP_DIR}/anytls-server" "$SERVER_FILE"
    chmod +x "$SERVER_FILE"
    rm -rf "$TMP_DIR"

    # 写入配置
    cat > "$CONFIG_FILE" <<EOF
listen: :${PORT}
auth:
  type: password
  password: ${PASSWORD}
EOF

    # 创建 systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart="${SERVER_FILE}" -l 0.0.0.0:${PORT} -p "${PASSWORD}"
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable anytls >/dev/null 2>&1
    systemctl restart anytls
    sleep 2

    if systemctl is-active --quiet anytls; then
        local ip
        ip=$(get_public_ip)
        echo -e "${C_GREEN}[✔] AnyTLS 安装完成！${C_RESET}"
        echo -e "${C_YELLOW}端口: ${PORT}, 密码: ${PASSWORD}${C_RESET}"
        echo -e "\n${C_GREEN}=== AnyTLS 节点链接 ===${C_RESET}"
        echo "anytls://${PASSWORD}@${ip}:${PORT}/?insecure=1#AnyTLS"
        echo ""
        mkdir -p /root/four-in-one
        echo "anytls://${PASSWORD}@${ip}:${PORT}/?insecure=1#AnyTLS" > /root/four-in-one/anytls_link.txt
    else
        echo -e "${C_RED}[✖] AnyTLS 启动失败，请检查日志${C_RESET}"
        return 1
    fi
}

m4_uninstall_anytls() {
    echo "正在卸载 AnyTLS..."
    systemctl stop anytls 2>/dev/null
    systemctl disable anytls 2>/dev/null
    rm -f /etc/systemd/system/anytls.service
    rm -rf /etc/AnyTLS
    rm -f /root/four-in-one/anytls_link.txt
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] AnyTLS 已卸载${C_RESET}"
}

m4_view_info() {
    if [ -f /root/four-in-one/anytls_link.txt ]; then
        cat /root/four-in-one/anytls_link.txt
    else
        echo -e "${C_RED}[✖] 未找到 AnyTLS 链接，请先安装。${C_RESET}"
    fi
}

module_anytls_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== AnyTLS ===${C_RESET}"
        if systemctl is-active --quiet anytls 2>/dev/null; then
            echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
            echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装 AnyTLS"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m4_install_anytls; pause_key ;;
            2) m4_view_info; pause_key ;;
            3) systemctl restart anytls; echo -e "${C_GREEN}已重启${C_RESET}"; pause_key ;;
            4) m4_uninstall_anytls; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 模块 5: Hysteria2 - 函数定义 (调用官方脚本)
# ==============================================================================

m5_install_hysteria2() {
    echo -e "${C_BLUE}[*] 即将调用 Hysteria2 官方安装脚本...${C_RESET}"
    echo -e "${C_YELLOW}请按照官方脚本提示完成安装（端口、密码、证书等）${C_RESET}"
    echo ""
    bash <(curl -fsSL https://get.hy2.sh/)
}

m5_uninstall_hysteria2() {
    echo "正在卸载 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null
    systemctl stop hysteria-server 2>/dev/null
    systemctl disable hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service
    rm -rf /etc/hysteria
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] Hysteria2 已卸载${C_RESET}"
}

m5_view_info() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo -e "${C_GREEN}Hysteria2 服务运行中${C_RESET}"
        echo -e "${C_YELLOW}查看配置: cat /etc/hysteria/config.yaml${C_RESET}"
    else
        echo -e "${C_RED}[✖] Hysteria2 未运行或未安装${C_RESET}"
    fi
}

module_hysteria2_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Hysteria2 ===${C_RESET}"
        if systemctl is-active --quiet hysteria-server 2>/dev/null; then
            echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
            echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装 Hysteria2 (官方脚本)"
        echo "2. 查看状态"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m5_install_hysteria2; pause_key ;;
            2) m5_view_info; pause_key ;;
            3) systemctl restart hysteria-server; echo -e "${C_GREEN}已重启${C_RESET}"; pause_key ;;
            4) m5_uninstall_hysteria2; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 独立卸载函数 (命令行模式)
# ==============================================================================

un_vmess_tcp() {
    echo "正在卸载 VMess+TCP..."
    systemctl stop xray-vmesstcp 2>/dev/null
    systemctl disable xray-vmesstcp 2>/dev/null
    rm -f /etc/systemd/system/xray-vmesstcp.service
    rm -f /usr/local/etc/xray/vmesstcp.json
    rm -f /root/four-in-one/xray_vmess_tcp_link.txt
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] VMess+TCP 已卸载${C_RESET}"
}

un_vless_reality() {
    echo "正在卸载 VLESS+REALITY..."
    systemctl stop xray-vlessreality 2>/dev/null
    systemctl disable xray-vlessreality 2>/dev/null
    rm -f /etc/systemd/system/xray-vlessreality.service
    rm -f /usr/local/etc/xray/vlessreality.json
    rm -f /root/four-in-one/xray_vless_reality_link.txt
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] VLESS+REALITY 已卸载${C_RESET}"
}

un_ss2022() {
    echo "正在卸载 SS-2022..."
    systemctl stop xray-ss2022 2>/dev/null
    systemctl disable xray-ss2022 2>/dev/null
    rm -f /etc/systemd/system/xray-ss2022.service
    rm -f /usr/local/etc/xray/ss2022.json
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] SS-2022 已卸载${C_RESET}"
}

un_socks5() {
    echo "正在卸载 Socks5..."
    systemctl stop xray-socks5.service 2>/dev/null
    systemctl disable xray-socks5.service 2>/dev/null
    rm -f /etc/systemd/system/xray-socks5.service
    rm -f /usr/local/etc/xray/socks5.json
    rm -rf /etc/xrayL
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] Socks5 已卸载${C_RESET}"
}

un_anytls() {
    echo "正在卸载 AnyTLS..."
    systemctl stop anytls 2>/dev/null
    systemctl disable anytls 2>/dev/null
    rm -f /etc/systemd/system/anytls.service
    rm -rf /etc/AnyTLS
    rm -f /root/four-in-one/anytls_link.txt
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] AnyTLS 已卸载${C_RESET}"
}

un_hysteria2() {
    echo "正在卸载 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null
    systemctl stop hysteria-server 2>/dev/null
    systemctl disable hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service
    rm -rf /etc/hysteria
    systemctl daemon-reload
    echo -e "${C_GREEN}[✔] Hysteria2 已卸载${C_RESET}"
}

# ==============================================================================
# 查看所有链接+状态 (命令行模式)
# ==============================================================================

view_all_links() {
    local ip
    ip=$(get_public_ip)

    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "${C_CYAN}   阿白的一键代理 - 服务状态与链接   ${C_RESET}"
    echo -e "${C_GREEN}==============================================${C_RESET}"

    # VMess+TCP
    echo -e "\n${C_YELLOW}[1] VMess+TCP${C_RESET}"
    if systemctl is-active --quiet xray-vmesstcp 2>/dev/null; then
        echo -e "状态: ${C_GREEN}运行中${C_RESET}"
    else
        echo -e "状态: ${C_RED}未运行${C_RESET}"
    fi
    if [ -f /root/four-in-one/xray_vmess_tcp_link.txt ]; then
        cat /root/four-in-one/xray_vmess_tcp_link.txt
    else
        echo "链接: 未安装"
    fi

    # VLESS+REALITY
    echo -e "\n${C_YELLOW}[2] VLESS+REALITY${C_RESET}"
    if systemctl is-active --quiet xray-vlessreality 2>/dev/null; then
        echo -e "状态: ${C_GREEN}运行中${C_RESET}"
    else
        echo -e "状态: ${C_RED}未运行${C_RESET}"
    fi
    if [ -f /root/four-in-one/xray_vless_reality_link.txt ]; then
        cat /root/four-in-one/xray_vless_reality_link.txt
    else
        echo "链接: 未安装"
    fi

    # SS-2022
    echo -e "\n${C_YELLOW}[3] SS-2022${C_RESET}"
    if systemctl is-active --quiet xray-ss2022 2>/dev/null; then
        echo -e "状态: ${C_GREEN}运行中${C_RESET}"
    else
        echo -e "状态: ${C_RED}未运行${C_RESET}"
    fi
    local ss_config="/usr/local/etc/xray/ss2022.json"
    if [ -f "$ss_config" ]; then
        local ss_port ss_password ss_method ss_link
        ss_port=$(grep '"port"' "$ss_config" | tr -cd '0-9')
        ss_password=$(grep '"password"' "$ss_config" | cut -d'"' -f4)
        ss_method=$(grep '"method"' "$ss_config" | cut -d'"' -f4)
        ss_link="ss://$(echo -n "${ss_method}:${ss_password}" | base64 -w 0)@${ip}:${ss_port}#SS-2022"
        echo "$ss_link"
    else
        echo "链接: 未安装"
    fi

    # AnyTLS
    echo -e "\n${C_YELLOW}[4] AnyTLS${C_RESET}"
    if systemctl is-active --quiet anytls 2>/dev/null; then
        echo -e "状态: ${C_GREEN}运行中${C_RESET}"
    else
        echo -e "状态: ${C_RED}未运行${C_RESET}"
    fi
    if [ -f /root/four-in-one/anytls_link.txt ]; then
        cat /root/four-in-one/anytls_link.txt
    else
        echo "链接: 未安装"
    fi

    # Hysteria2
    echo -e "\n${C_YELLOW}[5] Hysteria2${C_RESET}"
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo -e "状态: ${C_GREEN}运行中${C_RESET}"
    else
        echo -e "状态: ${C_RED}未运行${C_RESET}"
    fi
    if [ -f /etc/hysteria/config.yaml ]; then
        echo -e "配置: /etc/hysteria/config.yaml"
        echo -e "${C_YELLOW}查看链接: cat /etc/hysteria/config.yaml${C_RESET}"
    else
        echo "链接: 未安装"
    fi

    # Socks5
    echo -e "\n${C_YELLOW}[6] Socks5${C_RESET}"
    if systemctl is-active --quiet xray-socks5 2>/dev/null; then
        echo -e "状态: ${C_GREEN}运行中${C_RESET}"
    else
        echo -e "状态: ${C_RED}未运行${C_RESET}"
    fi
    local socks5_config="/usr/local/etc/xray/socks5.json"
    if [ -f "$socks5_config" ]; then
        local socks5_user socks5_pass
        socks5_user=$(grep -o '"user": *"[^"]*"' "$socks5_config" | head -1 | cut -d'"' -f4)
        socks5_pass=$(grep -o '"pass": *"[^"]*"' "$socks5_config" | head -1 | cut -d'"' -f4)
        [ -z "$socks5_user" ] && socks5_user="abai"
        [ -z "$socks5_pass" ] && socks5_pass="abai569"
        local idx=0
        while read -r sip; do
            [[ "$sip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168|127\.) ]] && continue
            if curl --interface "$sip" -s4 --max-time 3 ip.sb 2>/dev/null | grep -q "$sip"; then
                printf "socks5://%s:%s@%s:%s\n" "$socks5_user" "$socks5_pass" "$sip" "$((26208+idx))"
                idx=$((idx+1))
            fi
        done < <(ip -4 addr show scope global | awk '{print $2}' | cut -d/ -f1)
        local pub_ipv4
        pub_ipv4=$(curl -s4 --max-time 3 ip.sb 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        if [ -n "$pub_ipv4" ]; then
            printf "socks5://%s:%s@%s:%s\n" "$socks5_user" "$socks5_pass" "$pub_ipv4" "$((26208+idx))"
        fi
        while read -r sip6; do
            [[ "$sip6" =~ ^(fd|fe80) ]] && continue
            if curl --interface "$sip6" -s6 --max-time 3 ip.sb 2>/dev/null | grep -q ':'; then
                printf "socks5://%s:%s@[%s]:%s\n" "$socks5_user" "$socks5_pass" "$sip6" "$((26208+idx))"
                idx=$((idx+1))
            fi
        done < <(ip -6 addr show scope global | awk '{print $2}' | cut -d/ -f1)
    else
        echo "链接: 未安装"
    fi

    echo -e "\n${C_GREEN}==============================================${C_RESET}"
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
    m4_install_anytls
    m1_install_xray

    echo -e "${C_GREEN}>>> 服务全部安装完成${C_RESET}"
    echo -e "${C_YELLOW}>>> Hysteria2 请通过菜单选项5手动安装（官方交互式脚本）${C_RESET}"
    pause_key
}

# ==============================================================================
# 卸载所有服务逻辑
# ==============================================================================
uninstall_all() {
    echo -e "${C_RED}警告: 即将卸载所有模块 (VMess+TCP, VLESS+REALITY, SS-2022, AnyTLS, Hysteria2, Socks5)!${C_RESET}"
    
    # 命令行模式跳过确认
    if [[ "$CLI_MODE" -eq 0 ]]; then
        read -p "确定继续吗? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            echo "操作取消。"
            return
        fi
    fi

    # 暴力停止所有可能的服务
    systemctl stop xray-vmesstcp xray-vlessreality xray-socks5 xray-ss2022 anytls hysteria-server 2>/dev/null
    systemctl disable xray-vmesstcp xray-vlessreality xray-socks5 xray-ss2022 anytls hysteria-server 2>/dev/null
    
    rm -f /etc/systemd/system/xray-vmesstcp.service
    rm -f /etc/systemd/system/xray-vlessreality.service
    rm -f /etc/systemd/system/xray-socks5.service
    rm -f /etc/systemd/system/xray-ss2022.service
    rm -f /etc/systemd/system/anytls.service
    rm -f /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
    
    # 删除Xray核心
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    
    # 删除AnyTLS
    rm -rf /etc/AnyTLS
    
    # 删除Hysteria2
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null
    rm -rf /etc/hysteria
    
    rm -rf /etc/xrayL
    rm -rf /root/four-in-one
    
    echo -e "${C_GREEN}所有组件已清理完毕。${C_RESET}"
}

# ==============================================================================
# 主逻辑入口 (初始化流)
# ==============================================================================

# 1. 检查是否为 Root 用户
check_root

# 2. 命令行参数解析 (去除首尾空格，兼容有无空格)
if [[ -n "$1" ]]; then
    ARG="${1#"${1%%[![:space:]]*}"}"
    ARG="${ARG%"${ARG##*[![:space:]]}"}"
    case "$ARG" in
        in1)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m0_install_vmess_tcp
            exit 0
            ;;
        in2)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m2_install_xray
            exit 0
            ;;
        in3)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m3_install_ss
            exit 0
            ;;
        in4)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m4_install_anytls
            exit 0
            ;;
        in5)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m5_install_hysteria2
            exit 0
            ;;
        in6)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            m1_install_xray
            exit 0
            ;;
        inall)
            CLI_MODE=1
            install_dependencies
            setup_ntp_sync
            install_all_services
            exit 0
            ;;
        un1)
            CLI_MODE=1
            un_vmess_tcp
            exit 0
            ;;
        un2)
            CLI_MODE=1
            un_vless_reality
            exit 0
            ;;
        un3)
            CLI_MODE=1
            un_ss2022
            exit 0
            ;;
        un4)
            CLI_MODE=1
            un_anytls
            exit 0
            ;;
        un5)
            CLI_MODE=1
            un_hysteria2
            exit 0
            ;;
        un6)
            CLI_MODE=1
            un_socks5
            exit 0
            ;;
        unall)
            CLI_MODE=1
            uninstall_all
            exit 0
            ;;
        10)
            CLI_MODE=1
            install_dependencies
            view_all_links
            exit 0
            ;;
        *)
            echo "无效选项: $ARG"
            exit 1
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
    echo -e "${C_CYAN}   阿白的一键代理装脚本-自用   ${C_RESET}"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "1. ${C_YELLOW}VMess+TCP${C_RESET}"
    echo -e "2. ${C_YELLOW}VLESS+REALITY${C_RESET}"
    echo -e "3. ${C_YELLOW}SS-2022${C_RESET}"
    echo -e "4. ${C_YELLOW}AnyTLS${C_RESET}"
    echo -e "5. ${C_YELLOW}Hysteria2${C_RESET}"
    echo -e "6. ${C_YELLOW}Socks5${C_RESET}"
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
        4) module_anytls_menu ;;
        5) module_hysteria2_menu ;;
        6) module_socks5_menu ;;
        8) install_all_services ;;
        9) uninstall_all; pause_key ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause_key ;;
    esac
done

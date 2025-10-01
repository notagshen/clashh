#!/bin/bash

# --- 默认配置 ---
DEFAULT_START_PORT=9001
DEFAULT_SOCKS_USERNAME="tcst"
DEFAULT_SOCKS_PASSWORD="229310"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

IP_ADDRESSES=($(hostname -I))

# --- 功能：配置策略路由 ---
# 描述：为除第一个IP外的其他所有IP配置独立的路由表，实现多IP出口
setup_policy_routing() {
    echo "--- 正在配置策略路由以支持多IP出口 ---"
    
    # 检查IP数量，如果只有一个或没有，则无需配置
    if [ ${#IP_ADDRESSES[@]} -le 1 ]; then
        echo "仅发现一个IP地址，无需配置策略路由。"
        return
    fi

    # 遍历除第一个IP外的所有其他IP
    for ((i = 1; i < ${#IP_ADDRESSES[@]}; i++)); do
        IP=${IP_ADDRESSES[i]}
        # 根据IP地址动态查找对应的网络接口名 (例如: ens5)
        INTERFACE=$(ip -o addr show | grep "inet $IP" | awk '{print $2}')
        # 根据接口名和IP计算网关 (通常是子网的.1地址，这是一个通用假设)
        GATEWAY=$(echo $IP | awk -F. '{print $1"."$2"."$3".1"}')
        # 为路由表创建一个唯一的ID和名称
        TABLE_ID=$((100 + i))
        TABLE_NAME="T$((i + 1))"

        echo "正在为 IP: $IP (接口: $INTERFACE) 设置路由，网关: $GATEWAY, 路由表: $TABLE_NAME (ID: $TABLE_ID)"

        # 1. 创建路由表别名 (如果 /etc/iproute2/rt_tables 中不存在)
        if ! grep -q "$TABLE_NAME" /etc/iproute2/rt_tables; then
            echo "添加路由表别名 '$TABLE_NAME' 到 /etc/iproute2/rt_tables"
            echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
        fi

        # 2. 添加默认路由到新表 (如果该表为空)
        if [ -z "$(ip route show table $TABLE_NAME)" ]; then
            echo "正在为路由表 '$TABLE_NAME' 添加默认路由..."
            ip route add default via $GATEWAY dev $INTERFACE table $TABLE_NAME
        else
            echo "路由表 '$TABLE_NAME' 的路由已存在，跳过添加。"
        fi

        # 3. 添加路由规则 (如果规则不存在)
        if ! ip rule list | grep -q "from $IP lookup $TABLE_NAME"; then
            echo "正在为源地址 '$IP' 添加路由规则..."
            ip rule add from $IP table $TABLE_NAME
        else
            echo "源地址 '$IP' 的路由规则已存在，跳过添加。"
        fi
    done

    # 刷新路由缓存使配置生效
    echo "正在刷新路由缓存..."
    ip route flush cache
    echo "--- 策略路由配置完成 ---"
    echo ""
}


# --- 功能：安装依赖项 ---
install_dependencies() {
    echo "正在检查并安装 curl, wget, unzip, iptables 等依赖项..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y wget unzip iptables curl
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip iptables-services curl
    else
        echo "错误：不支持的包管理器。请手动安装 wget, unzip, iptables, curl。" >&2
        exit 1
    fi
    echo "依赖项已准备就绪。"
}

# --- 功能：安装Xray ---
install_xray() {
    install_dependencies
    echo "正在安装 Xray..."
    wget -O Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    rm -f Xray-linux-64.zip geoip.dat geosite.dat LICENSE README.md
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.toml
Restart=on-failure
User=root
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xrayL.service
    systemctl start xrayL.service
    echo "Xray 安装并启动成功。"
}

# --- 功能：配置Xray并开放端口 ---
config_xray() {
    config_type=$1
    
    # *** 关键步骤：在生成Xray配置前，先设置好操作系统的策略路由 ***
    setup_policy_routing

    echo "正在生成 Xray 配置文件..."
    mkdir -p /etc/xrayL
    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        echo "类型无效！仅支持 'socks' 和 'vmess'。"
        exit 1
    fi

    START_PORT=$DEFAULT_START_PORT
    config_content=""

    if [ "$config_type" == "socks" ]; then
        SOCKS_USERNAME=$DEFAULT_SOCKS_USERNAME
        SOCKS_PASSWORD=$DEFAULT_SOCKS_PASSWORD
    elif [ "$config_type" == "vmess" ]; then
        UUID=$DEFAULT_UUID
        WS_PATH=$DEFAULT_WS_PATH
    fi

    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        config_content+="[[inbounds]]\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="listen = \"0.0.0.0\"\n" 
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n"
        config_content+="[inbounds.settings]\n"
        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"$SOCKS_USERNAME\"\n"
            config_content+="pass = \"$SOCKS_PASSWORD\"\n"
        elif [ "$config_type" == "vmess" ]; then
            config_content+="[[inbounds.settings.clients]]\n"
            config_content+="id = \"$UUID\"\n"
            config_content+="[inbounds.streamSettings]\n"
            config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"
            config_content+="path = \"$WS_PATH\"\n\n"
        fi
        
        config_content+="[[outbounds]]\n"
        config_content+="sendThrough = \"${IP_ADDRESSES[i]}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n\n"
        
        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"tag_$((i + 1))\"\n"
        config_content+="outboundTag = \"tag_$((i + 1))\"\n\n\n"
    done

    echo -e "$config_content" > /etc/xrayL/config.toml
    echo "配置文件写入 /etc/xrayL/config.toml 成功。"
    echo "正在重启 Xray 服务..."
    systemctl restart xrayL.service
    sleep 2 # 等待服务重启
    systemctl --no-pager status xrayL.service

    # 开放防火墙端口
    echo "正在开放防火墙端口..."
    for ((port = START_PORT; port <= START_PORT + i - 1; port++)); do
        if iptables -I INPUT -p tcp --dport $port -j ACCEPT && \
           iptables -I INPUT -p udp --dport $port -j ACCEPT; then
            echo "成功开放端口 $port (TCP/UDP)。"
        else
            echo "开放端口 $port 失败。"
        fi
    done

    echo -e "\n============== 配置概要 =============="
    echo "协议类型: $config_type"
    echo "起始端口: $START_PORT"
    echo "结束端口: $(($START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    if [ "$config_type" == "socks" ]; then
        echo "SOCKS 用户名: $SOCKS_USERNAME"
        echo "SOCKS 密码: $SOCKS_PASSWORD"
    elif [ "$config_type" == "vmess" ]; then
        echo "UUID: $UUID"
        echo "WebSocket 路径: $WS_PATH"
    fi
    echo "======================================"
    echo ""
    
    # 增加出口IP测试，方便验证
    echo "========== 开始测试出口IP =========="
    for ip in "${IP_ADDRESSES[@]}"; do
        echo -n "测试来源 $ip 的公网出口IP -> "
        # 使用curl的--interface选项强制从指定IP发包，设置5秒超时
        public_ip=$(curl --interface $ip --connect-timeout 5 ifconfig.me 2>/dev/null)
        if [ -n "$public_ip" ]; then
            echo "$public_ip"
        else
            echo "测试失败 (可能网络不通或超时)"
        fi
    done
    echo "======================================"
}

# --- 主函数 ---
main() {
    if [ "$EUID" -ne 0 ]; then
      echo "错误：此脚本必须以 root 身份运行。" >&2
      exit 1
    fi
    
    # 确保依赖已安装
    if ! command -v curl &>/dev/null; then
        install_dependencies
    fi

    if [ ! -x "$(command -v xrayL)" ]; then
        install_xray
    fi

    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "请选择配置类型 (socks/vmess): " config_type
    fi

    case "$config_type" in
        vmess|socks)
            config_xray "$config_type"
            ;;
        *)
            echo "输入类型无效，将使用默认的 SOCKS 进行配置。"
            config_xray "socks"
            ;;
    esac
}

# --- 脚本入口 ---
main "$@"

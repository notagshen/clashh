#!/bin/bash

# --- 默认配置 ---
DEFAULT_START_PORT=9001
DEFAULT_SOCKS_USERNAME="tcst"
DEFAULT_SOCKS_PASSWORD="229310"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

# --- 关键修正：使用更可靠的方式获取IP地址 ---
IP_ADDRESSES=($(hostname -I))
if [ ${#IP_ADDRESSES[@]} -eq 0 ]; then
    echo "Warning: 'hostname -I' returned no IPs. Trying to fetch public IP..."
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [ -n "$PUBLIC_IP" ]; then
        IP_ADDRESSES=($PUBLIC_IP)
        echo "Successfully fetched public IP: $PUBLIC_IP"
    else
        echo "Error: Failed to get any IP address. Cannot generate config." >&2
        exit 1
    fi
fi

# --- 新增功能：自动配置策略路由 ---
setup_policy_routing() {
    # 仅当IP地址数量大于1时才需要配置
    if [ ${#IP_ADDRESSES[@]} -le 1 ]; then
        echo "Single IP detected, no policy routing needed."
        return
    fi
    
    echo "Multiple IPs detected. Setting up policy routing..."
    
    # 获取主网络接口和默认网关
    # -o 选项让grep只输出匹配的部分
    INTERFACE=$(ip route | grep default | awk '{print $5}')
    GATEWAY=$(ip route | grep default | awk '{print $3}')
    
    if [ -z "$INTERFACE" ] || [ -z "$GATEWAY" ]; then
        echo "Error: Could not determine default interface or gateway. Skipping policy routing."
        return
    fi

    echo "Default Gateway: $GATEWAY on Interface: $INTERFACE"
    
    # 从第二个IP开始，为每个IP创建路由规则（第一个IP使用默认路由）
    for ((i = 1; i < ${#IP_ADDRESSES[@]}; i++)); do
        IP=${IP_ADDRESSES[i]}
        TABLE_ID=$((100 + i)) # 创建一个唯一的路由表ID，如101, 102...
        
        echo "Configuring routing for IP: $IP using table T$TABLE_ID"
        
        # 1. 添加规则：如果数据包的源地址是这个IP，就去查 Txx 号路由表
        #    `ip rule del` 用于防止重复添加规则导致出错
        ip rule del from $IP table $TABLE_ID &>/dev/null
        ip rule add from $IP table $TABLE_ID
        
        # 2. 在 Txx 号路由表中，添加默认路由，让它和主路由表一样通过网关出去
        #    这会告诉系统如何发送来自这个IP的数据包
        ip route replace default via $GATEWAY dev $INTERFACE table $TABLE_ID
    done
    
    echo "Policy routing setup complete."
    # 刷新路由缓存使配置生效
    ip route flush cache
}


# --- 依赖安装函数 (不变) ---
install_dependencies() {
    echo "Checking and installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y wget unzip iptables curl iproute2
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip iptables-services curl iproute2
    else
        echo "Error: Unsupported package manager." >&2; exit 1
    fi
    echo "Dependencies are ready."
}

# --- Xray安装函数 (不变) ---
install_xray() {
    install_dependencies
    echo "Installing Xray..."
    wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip -o Xray-linux-64.zip # -o 覆盖
    rm -f Xray-linux-64.zip* geoip.dat geosite.dat LICENSE README.md
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL
    cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.toml
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xrayL.service
    systemctl start xrayL.service
    echo "Xray installed successfully."
}

# --- Xray配置函数 (不变) ---
config_xray() {
    config_type=$1
    mkdir -p /etc/xrayL
    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        echo "Invalid type! Only 'socks' and 'vmess' are supported."; exit 1
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
    
    # 核心配置生成逻辑完全不变
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        config_content+="[[inbounds]]\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n"
        config_content+="[inbounds.settings]\n"
        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="ip = \"${IP_ADDRESSES[i]}\"\n"
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
    
    echo "Restarting xrayL service..."
    systemctl reset-failed xrayL.service
    systemctl restart xrayL.service
    sleep 2
    systemctl --no-pager status xrayL.service

    for ((port = START_PORT; port <= START_PORT + ${#IP_ADDRESSES[@]} - 1; port++)); do
        if iptables -I INPUT -p tcp --dport $port -j ACCEPT && \
           iptables -I INPUT -p udp --dport $port -j ACCEPT; then
            echo "Successfully opened port $port."
        else
            echo "Failed to open port $port."
        fi
    done

    echo ""
    echo "生成 $config_type 配置完成"
    echo "Start port: $START_PORT"
    echo "End port: $((START_PORT + ${#IP_ADDRESSES[@]} - 1))"
    if [ "$config_type" == "socks" ]; then
        echo "SOCKS Username: $SOCKS_USERNAME"
        echo "SOCKS Password: $SOCKS_PASSWORD"
    elif [ "$config_type" == "vmess" ]; then
        echo "UUID: $UUID"
        echo "WS Path: $WS_PATH"
    fi
    echo "IPs configured: ${IP_ADDRESSES[*]}"
    echo ""
}

# --- 主逻辑函数 (只增加了一行调用) ---
main() {
    if [ "$EUID" -ne 0 ]; then
      echo "Error: This script must be run as root." >&2; exit 1
    fi
     
    # 在所有操作之前，先设置好网络路由
    setup_policy_routing
    
    if [ ! -x "$(command -v xrayL)" ]; then
        install_xray
    fi

    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "Select configuration type (socks/vmess): " config_type
    fi

    case "$config_type" in
        vmess) config_xray "vmess";;
        socks) config_xray "socks";;
        *) echo "Invalid type. Using default SOCKS." && config_xray "socks";;
    esac
}

main "$@"

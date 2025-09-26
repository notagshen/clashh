#!/bin/bash

# --- 默认配置 ---
DEFAULT_START_PORT=9001
DEFAULT_SOCKS_USERNAME="tcst"
DEFAULT_SOCKS_PASSWORD="229310"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

# --- 核心修正：不再使用 hostname -I，直接且仅使用公网IP ---
# 这样可以确保只为能访问互联网的公网IP创建代理
echo "Fetching the public IP address..."
PUBLIC_IP=$(curl -s ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
    echo "Error: Failed to fetch the public IP address. Cannot generate config." >&2
    exit 1
fi
IP_ADDRESSES=($PUBLIC_IP)
echo "Using public IP: ${IP_ADDRESSES[0]}"
# --- 修正结束 ---


# --- 函数部分 (无需任何改动) ---

install_dependencies() {
    echo "Checking and installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y wget unzip iptables curl
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip iptables-services curl
    else
        echo "Error: Unsupported package manager." >&2
        exit 1
    fi
    echo "Dependencies are ready."
}

install_xray() {
    install_dependencies
    echo "Installing Xray..."
    wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip -o Xray-linux-64.zip
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

config_xray() {
    config_type=$1
    mkdir -p /etc/xrayL
    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        echo "Invalid type! Only 'socks' and 'vmess' are supported."
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
    
    # 因为现在 IP_ADDRESSES 数组里只有唯一的公网IP，这个循环只会执行一次
    # 这就完美地解决了为内网IP创建无效代理的问题
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

    # i 的值现在最大只会是 1 (因为只有一个IP)
    for ((port = START_PORT; port <= START_PORT + i - 1; port++)); do
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
    # End port现在只会是 START_PORT
    echo "End port: $(($START_PORT + $i - 1))"
    if [ "$config_type" == "socks" ]; then
        echo "SOCKS Username: $SOCKS_USERNAME"
        echo "SOCKS Password: $SOCKS_PASSWORD"
    elif [ "$config_type" == "vmess" ]; then
        echo "UUID: $UUID"
        echo "WS Path: $WS_PATH"
    fi
    echo ""
}

main() {
    if [ "$EUID" -ne 0 ]; then
      echo "Error: This script must be run as root." >&2
      exit 1
    fi
    
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

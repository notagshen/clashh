#!/bin/bash

# --- 默认配置 ---
DEFAULT_START_PORT=9001
DEFAULT_SOCKS_USERNAME="tcst"
DEFAULT_SOCKS_PASSWORD="229310"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

# --- GCP专用：通过元数据服务器获取所有公网IP ---
get_gcp_public_ips() {
    local ips=()
    # 查找所有非回环的、活跃的网络接口名 (如 ens4, ens5)
    local interfaces=$(ip -o link show | awk -F': ' '$3 !~ /lo/ && $2 !~ /@/ {print $2}')
    
    echo "Detected network interfaces: $interfaces"
    
    for iface in $interfaces; do
        # 查询每个接口的外部IP
        local public_ip=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/$(ip -o link show $iface | awk '{print $1}' | tr -d ':')/access-configs/0/external-ip")
        
        # 检查是否成功获取IP
        if [[ -n "$public_ip" && "$public_ip" != "Could not find access config 0 for network interface"* ]]; then
            # 检查IP是否已在数组中，防止重复
            if ! [[ " ${ips[@]} " =~ " ${public_ip} " ]]; then
                ips+=("$public_ip")
            fi
        fi
    done
    
    echo "${ips[@]}"
}

IP_ADDRESSES=($(get_gcp_public_ips))
if [ ${#IP_ADDRESSES[@]} -eq 0 ]; then
    echo "Error: Could not retrieve any public IPs from GCP Metadata Server." >&2
    echo "This script might not be running on a GCP instance or the instance lacks external IPs." >&2
    exit 1
fi
echo "Found Public IPs via GCP Metadata: ${IP_ADDRESSES[*]}"
# --- GCP专用代码结束 ---


# --- 函数部分 (安装、配置等函数保持不变) ---

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
User=root
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
    
    # 循环遍历所有找到的公网IP
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        public_ip="${IP_ADDRESSES[i]}"
        
        # 绑定监听地址到 0.0.0.0，允许从任何地址进入
        listen_ip="0.0.0.0"

        config_content+="[[inbounds]]\n"
        config_content+="listen = \"$listen_ip\"\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n"
        config_content+="[inbounds.settings]\n"
        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            # 注意：socks的ip字段是用来验证客户端来源IP的，这里我们不需要，所以留空或注释掉
            # config_content+="ip = \"127.0.0.1\"\n" 
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
        config_content+="sendThrough = \"$public_ip\"\n"
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

    # 为所有需要的端口打开iptables防火墙
    end_port=$(($START_PORT + ${#IP_ADDRESSES[@]} - 1))
    for ((port = START_PORT; port <= end_port; port++)); do
        if ! iptables -C INPUT -p tcp --dport $port -j ACCEPT &> /dev/null; then
            iptables -I INPUT -p tcp --dport $port -j ACCEPT
            echo "Opened TCP port $port."
        fi
        if ! iptables -C INPUT -p udp --dport $port -j ACCEPT &> /dev/null; then
            iptables -I INPUT -p udp --dport $port -j ACCEPT
            echo "Opened UDP port $port."
        fi
    done

    echo ""
    echo "生成 $config_type 配置完成"
    echo "Start port: $START_PORT"
    echo "End port: $end_port"
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

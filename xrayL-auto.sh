#!/bin/bash

# ==============================================================================
# --- 请在这里手动配置您的公网IP地址 ---
# 用空格隔开多个IP地址
IP_ADDRESSES=("34.92.7.16" "34.150.17.79")
# ==============================================================================

# --- 默认配置 ---
DEFAULT_START_PORT=9001
DEFAULT_SOCKS_USERNAME="tcst"
DEFAULT_SOCKS_PASSWORD="229310"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

# --- 检查IP是否已配置 ---
if [ ${#IP_ADDRESSES[@]} -eq 0 ] || [[ "${IP_ADDRESSES[1]}" == "请在这里填入您的第二个公网IP" ]]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "!! 错误：请先编辑此脚本，在 IP_ADDRESSES 变量中填入您的公网IP地址！" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    exit 1
fi
echo "Using manually configured Public IPs: ${IP_ADDRESSES[*]}"


# --- 函数部分 (安装、配置等函数) ---

install_dependencies() {
    echo "Checking and installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y wget unzip iptables curl
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip iptables-services curl
    else
        echo "Error: Unsupported package manager." >&2; exit 1
    fi; echo "Dependencies are ready."
}

install_xray() {
    install_dependencies
    echo "Installing Xray..."
    wget -qO xray.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip -o xray.zip
    rm -f xray.zip geoip.dat geosite.dat LICENSE README.md
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
        echo "Invalid type! Only 'socks' and 'vmess' are supported."; exit 1
    fi

    START_PORT=$DEFAULT_START_PORT; config_content=""
    if [ "$config_type" == "socks" ]; then
        SOCKS_USERNAME=$DEFAULT_SOCKS_USERNAME; SOCKS_PASSWORD=$DEFAULT_SOCKS_PASSWORD
    elif [ "$config_type" == "vmess" ]; then
        UUID=$DEFAULT_UUID; WS_PATH=$DEFAULT_WS_PATH
    fi
    
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        public_ip="${IP_ADDRESSES[i]}"
        listen_ip="0.0.0.0"
        config_content+="[[inbounds]]\n"
        config_content+="listen = \"$listen_ip\"\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n"
        config_content+="[inbounds.settings]\n"
        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"; config_content+="udp = true\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"$SOCKS_USERNAME\"\n"; config_content+="pass = \"$SOCKS_PASSWORD\"\n"
        elif [ "$config_type" == "vmess" ]; then
            config_content+="[[inbounds.settings.clients]]\n"; config_content+="id = \"$UUID\"\n"
            config_content+="[inbounds.streamSettings]\n"; config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"; config_content+="path = \"$WS_PATH\"\n\n"
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

    end_port=$(($START_PORT + ${#IP_ADDRESSES[@]} - 1))
    if [ ${#IP_ADDRESSES[@]} -gt 0 ]; then
      for ((port = START_PORT; port <= end_port; port++)); do
          if ! iptables -C INPUT -p tcp --dport $port -j ACCEPT &> /dev/null; then
              iptables -I INPUT -p tcp --dport $port -j ACCEPT; echo "Opened TCP port $port."
          fi
          if ! iptables -C INPUT -p udp --dport $port -j ACCEPT &> /dev/null; then
              iptables -I INPUT -p udp --dport $port -j ACCEPT; echo "Opened UDP port $port."
          fi
      done
    fi

    echo ""
    echo "生成 $config_type 配置完成"
    echo "Start port: $START_PORT"
    echo "End port: $end_port"
    if [ "$config_type" == "socks" ]; then
        echo "SOCKS Username: $SOCKS_USERNAME"; echo "SOCKS Password: $SOCKS_PASSWORD"
    elif [ "$config_type" == "vmess" ]; then
        echo "UUID: $UUID"; echo "WS Path: $WS_PATH"
    fi
    echo ""
}

main() {
    if [ "$EUID" -ne 0 ]; then
      echo "Error: This script must be run as root." >&2; exit 1
    fi
    if [ ! -x "$(command -v xrayL)" ]; then install_xray; fi
    if [ $# -eq 1 ]; then config_type="$1"
    else read -p "Select configuration type (socks/vmess): " config_type; fi
    case "$config_type" in
        vmess) config_xray "vmess";;
        socks) config_xray "socks";;
        *) echo "Invalid type. Using default SOCKS." && config_xray "socks";;
    esac
}

main "$@"

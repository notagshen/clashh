#!/bin/bash

# --- 默认配置 (与您原来的一致) ---
DEFAULT_START_PORT=9001
DEFAULT_SOCKS_USERNAME="tcst"
DEFAULT_SOCKS_PASSWORD="229310"
DEFAULT_WS_PATH="/ws"
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

IP_ADDRESSES=($(hostname -I))

# --- 修正部分：健壮的依赖安装 ---
# 功能：检测操作系统并安装所有必需的依赖包
install_dependencies() {
    echo "Checking and installing dependencies..."
    if command -v apt-get &>/dev/null; then
        # 适用于 Debian/Ubuntu
        apt-get update -qq
        apt-get install -y wget unzip iptables curl
    elif command -v yum &>/dev/null; then
        # 适用于 CentOS/RHEL
        yum install -y wget unzip iptables-services curl
    else
        echo "Error: Unsupported package manager. Please install wget, unzip, iptables manually." >&2
        exit 1
    fi
    echo "Dependencies are ready."
}


# --- 基本保持不变：安装Xray ---
install_xray() {
    # 修正：首先调用函数确保依赖已安装
    install_dependencies
    
    echo "Installing Xray..."
    # 原有的`apt || yum`命令已被上面的函数替代
    
    wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    
    # 清理下载和解压后的多余文件
    rm -f Xray-linux-64.zip Xray-linux-64.zip.* geoip.dat geosite.dat LICENSE README.md
    
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL

    # 服务文件 (与您原来的一致)
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

# --- 未做任何修改：您的原始配置逻辑 ---
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
    systemctl restart xrayL.service
    sleep 2 # 等待服务启动
    systemctl --no-pager status xrayL.service

    # Open ports (确保iptables命令现在可用)
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

# --- 未做任何修改：您的主函数 ---
main() {
    # 修正：增加 root 权限检查
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
        vmess)
            config_xray "vmess"
            ;;
        socks)
            config_xray "socks"
            ;;
        *)
            echo "Invalid type selected. Using default SOCKS configuration."
            config_xray "socks"
            ;;
    esac
}

main "$@"

# ================== ServerStatus-Rust 交互式一键部署脚本 ==================
# 1. 询问节点名称
echo -e "\n\033[36m========================================\033[0m"
read -p "👉 请输入当前机器的节点名称 (需与主控端配置一致，如 dmit, aliyun 等): " NODE
if [ -z "$NODE" ]; then
    echo -e "\033[31m❌ 节点名称不能为空，脚本已退出！\033[0m"
    exit 1
fi
echo -e "\033[36m========================================\033[0m\n"

# 2. 正式开始自动化部署
bash << EOF
# 自动安装 vnstat 和依赖
if command -v apt >/dev/null 2>&1; then apt update && apt install -y vnstat unzip curl wget; fi
if command -v yum >/dev/null 2>&1; then yum install -y epel-release vnstat unzip curl wget; fi
systemctl enable --now vnstat

# 智能识别 CPU 架构
ARCH=\$(uname -m)
if [ "\$ARCH" = "aarch64" ] || [ "\$ARCH" = "arm64" ]; then TARGET="aarch64"; else TARGET="x86_64"; fi
URL="https://github.com/zdz/ServerStatus-Rust/releases/latest/download/client-\${TARGET}-unknown-linux-musl.zip"

# 下载并解压核心程序
mkdir -p /opt/ServerStatus/client
curl -sL -o /tmp/client.zip "\$URL"
unzip -qo /tmp/client.zip -d /opt/ServerStatus/client/
chmod +x /opt/ServerStatus/client/stat_client

# 写入带流量统计(-n)和高速通道(HTTPS)的完美配置
cat << UNIT > /etc/systemd/system/stat_client.service
[Unit]
Description=ServerStatus-Rust Client
After=network.target

[Service]
User=root
Group=root
Environment="RUST_BACKTRACE=1"
WorkingDirectory=/opt/ServerStatus
ExecStart=/opt/ServerStatus/client/stat_client -a "https://app.arest.cc/report" -u ${NODE} -p Duan2000 -n
ExecReload=/bin/kill -HUP \\\$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

# 重启并点亮面板
systemctl daemon-reload
systemctl enable --now stat_client
echo -e "\n\033[32m✅ 节点 [${NODE}] 探针已部署完成，请刷新网页面板查看！\033[0m"
EOF

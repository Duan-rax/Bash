#!/bin/bash
# ==============================================================================
# vps-init-slim.sh — 纯净 Debian VPS 装机后精简脚本
#
# 适用场景：全新安装/DD 完成后的 Debian 12/13，不涉及更换内核，
#           只做系统层面的空间精简、日志限制、网络调优、磁盘看门狗。
#
# 幂等设计：可重复执行，已存在的配置会被覆盖为脚本内的版本，不会重复追加。
#
# 用法：
#   bash vps-init-slim.sh          # 执行全部步骤
#   bash vps-init-slim.sh status   # 只看当前磁盘占用，不做任何改动
# ==============================================================================

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "请用 root 运行: sudo bash $0 $*" >&2
    exit 1
fi

log()  { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[SKIP]\033[0m $*"; }
info() { echo -e "\033[1;36m[..]\033[0m $*"; }

show_status() {
    echo "===== 磁盘占用 ====="
    df -h /
    echo
    echo "===== 目录占用排行 ====="
    du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -12
}

if [[ "${1:-}" == "status" ]]; then
    show_status
    exit 0
fi

# ------------------------------------------------------------------------
info "1/8 换阿里云内网源（走内网，不计公网流量；非阿里云环境自动跳过）"
if curl -s -m 2 -o /dev/null -w '%{http_code}' http://100.100.100.200/latest/meta-data/ 2>/dev/null | grep -q 200; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-trixie}"
    cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
    cat > /etc/apt/sources.list <<EOF
deb http://mirrors.cloud.aliyuncs.com/debian ${CODENAME} main contrib non-free non-free-firmware
deb http://mirrors.cloud.aliyuncs.com/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb http://mirrors.cloud.aliyuncs.com/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
    rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null
    log "已切换为阿里云内网源（$CODENAME）"
else
    warn "未检测到阿里云元数据服务，跳过换源（非阿里云环境或元数据不可达）"
fi

# ------------------------------------------------------------------------
info "2/8 配置 apt 精简（不装推荐/建议包、不下多语言、不留 deb 缓存）"
cat > /etc/apt/apt.conf.d/99-slim <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
APT::Keep-Downloaded-Packages "false";
Binary::apt::APT::Keep-Downloaded-Packages "false";
APT::Periodic::AutocleanInterval "7";
EOF
log "已写入 /etc/apt/apt.conf.d/99-slim"

# ------------------------------------------------------------------------
info "3/8 配置 dpkg 排除文档/手册（对之后安装的包生效）"
cat > /etc/dpkg/dpkg.cfg.d/01-nodoc <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
EOF
log "已写入 /etc/dpkg/dpkg.cfg.d/01-nodoc"

info "   清理系统已存在的文档/手册/多语言文件"
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/lintian 2>/dev/null
find /usr/share/doc -mindepth 1 -maxdepth 1 -type d \
    -exec sh -c 'find "$1" -type f ! -name "copyright" -delete' _ {} \; 2>/dev/null
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
    ! -name 'en*' ! -name 'zh_CN' ! -name 'C*' -exec rm -rf {} + 2>/dev/null
log "文档/手册/多语言清理完成"

# ------------------------------------------------------------------------
info "4/8 限制 journald 日志体积（默认会无限增长吃满盘）"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-size.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=48M
SystemMaxFileSize=8M
RuntimeMaxUse=16M
MaxRetentionSec=7day
ForwardToSyslog=no
EOF
systemctl restart systemd-journald 2>/dev/null
journalctl --vacuum-size=48M >/dev/null 2>&1
log "journald 已限制为 48M / 7 天"

# ------------------------------------------------------------------------
info "5/8 logrotate 收紧（3 份轮转 + 压缩）"
if [[ -f /etc/logrotate.conf ]]; then
    sed -i -e 's/^rotate .*/rotate 3/' -e 's/^weekly/daily/' /etc/logrotate.conf
    grep -q '^compress' /etc/logrotate.conf || echo 'compress' >> /etc/logrotate.conf
    log "logrotate 已收紧"
else
    warn "未找到 logrotate.conf，跳过"
fi

# ------------------------------------------------------------------------
info "6/8 网络参数调优（仅 BBR + fq，最小改动，若内核已支持 BBR）"
AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
if echo "$AVAIL_CC" | grep -qw bbr; then
    cat > /etc/sysctl.d/99-net.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1
    log "已启用 BBR + fq"
else
    warn "当前内核不支持 BBR（可用: ${AVAIL_CC:-未知}），跳过网络调优。装完自定义内核后可再跑一次本脚本。"
fi

# ------------------------------------------------------------------------
info "7/8 部署磁盘看门狗（使用率超 80% 自动清理日志/缓存）"
cat > /usr/local/bin/disk_guard.sh <<'EOF'
#!/bin/bash
THRESHOLD=80
USE=$(df -P / | awk 'NR==2{print $5}' | tr -d '%')
[ "$USE" -lt "$THRESHOLD" ] && exit 0
journalctl --vacuum-size=32M >/dev/null 2>&1
apt-get clean
find /var/log -type f -name '*.gz' -delete
find /var/log -type f -regextype posix-extended -regex '.*\.[0-9]+$' -delete
find /tmp /var/tmp -type f -atime +3 -delete 2>/dev/null
NEW=$(df -P / | awk 'NR==2{print $5}')
logger -t disk_guard "cleanup triggered: ${USE}% -> ${NEW}"
EOF
chmod +x /usr/local/bin/disk_guard.sh

if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/disk-guard.service <<'EOF'
[Unit]
Description=Disk usage guard
[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk_guard.sh
EOF
    cat > /etc/systemd/system/disk-guard.timer <<'EOF'
[Unit]
Description=Run disk guard hourly
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now disk-guard.timer >/dev/null 2>&1
    log "已启用 systemd timer（每小时检查一次）"
else
    (crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/disk_guard.sh") | crontab -
    log "已加入 crontab（每小时检查一次）"
fi

# ------------------------------------------------------------------------
info "8/8 apt 更新 + 清理缓存"
apt-get update -qq
apt-get autoremove --purge -y -qq 2>/dev/null
apt-get clean
log "apt 缓存已清理"

# ------------------------------------------------------------------------
echo
log "全部完成。"
echo
info "当前磁盘状态："
df -h /

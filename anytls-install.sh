#!/usr/bin/env bash
#
# AnyTLS (sing-box) 交互式安装脚本  ——  Debian 11/12/13
#
#   bash anytls-install.sh              交互安装
#   bash anytls-install.sh uninstall    卸载
#
# 支持环境变量预设实现非交互安装，例如：
#   DOMAIN=a.example.com EMAIL=me@x.com PORT=443 CERT_MODE=1 \
#   NONINTERACTIVE=1 bash anytls-install.sh
#
set -Eeuo pipefail

CONF_DIR=/etc/sing-box
CERT_DIR="$CONF_DIR/cert"
CONF_FILE="$CONF_DIR/config.json"
INFO_FILE="$CONF_DIR/anytls-info.txt"
LINK_FILE="$CONF_DIR/anytls-link.txt"
ACME="$HOME/.acme.sh/acme.sh"

# 环境变量预设（留空则交互询问）
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
PORT=${PORT:-}
PASSWORD=${PASSWORD:-}
NODE_NAME=${NODE_NAME:-}
CERT_MODE=${CERT_MODE:-}          # 1=HTTP-01  2=Cloudflare DNS-01  3=已有证书
CF_TOKEN=${CF_Token:-}
CERT_FILE=${CERT_FILE:-}
KEY_FILE=${KEY_FILE:-}
ENABLE_BBR=${ENABLE_BBR:-}
NONINTERACTIVE=${NONINTERACTIVE:-0}

STOPPED_SVC=""

# ---------------------------------------------------------------- 输出
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; D=$'\e[2m'; BD=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; D=""; BD=""; N=""
fi
info() { echo "${B}[*]${N} $*"; }
ok()   { echo "${G}[✓]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[✗]${N} $*" >&2; exit 1; }
hr()   { echo "${D}────────────────────────────────────────────────────────${N}"; }

cleanup() {
  if [[ -n "$STOPPED_SVC" ]]; then
    info "恢复此前暂停的服务：$STOPPED_SVC"
    systemctl start "$STOPPED_SVC" 2>/dev/null || true
    STOPPED_SVC=""
  fi
}
trap cleanup EXIT
on_err() {
  # 命令替换在子 shell 中执行，会让 trap 触发两次，这里只保留第一条
  [[ -n "${_ERR_REPORTED:-}" ]] && exit 1
  export _ERR_REPORTED=1
  die "脚本在第 $1 行执行失败，上面是最后的输出。"
}
trap 'on_err $LINENO' ERR

# 允许 curl | bash 形式下仍能交互
[[ -t 0 ]] || { [[ -e /dev/tty ]] && exec < /dev/tty; } || true

# ---------------------------------------------------------------- 工具函数
urlencode() {
  local s=$1 out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

confirm() { # confirm <提示> <默认y|n>
  local prompt=$1 def=${2:-y} ans
  [[ "$NONINTERACTIVE" == "1" ]] && { [[ "$def" == "y" ]]; return; }
  local hint="[Y/n]"; [[ "$def" == "n" ]] && hint="[y/N]"
  read -r -p "    $prompt $hint " ans || true
  ans=${ans:-$def}
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

port_holder() { # 返回占用某端口的进程名，空闲时返回空字符串
  # 注意：端口空闲时 grep 无匹配会返回 1，配合 pipefail 会误判为致命错误，
  # 故整条管道以 || true 兜底。
  { ss -lntpH "sport = :$1" 2>/dev/null || true; } \
    | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null | head -n1 || true
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
  echo
  warn "即将卸载 sing-box 与相关配置。"
  confirm "确认继续？" n || { echo "已取消。"; exit 0; }
  systemctl disable --now sing-box 2>/dev/null || true
  apt-get purge -y sing-box 2>/dev/null || true
  rm -f /usr/local/bin/anytls
  if confirm "同时删除 $CONF_DIR（含证书与配置）？" n; then
    rm -rf "$CONF_DIR"
  fi
  if [[ -x "$ACME" ]] && confirm "同时卸载 acme.sh 及其自动续期任务？" n; then
    "$ACME" --uninstall >/dev/null 2>&1 || true
    rm -rf "$HOME/.acme.sh"
  fi
  ok "卸载完成。"
  exit 0
}
[[ "${1:-}" == "uninstall" ]] && do_uninstall

# ---------------------------------------------------------------- 环境检查
[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo -i 之后再执行）。"
[[ -f /etc/debian_version ]] || warn "非 Debian 系发行版，脚本可能不适用，继续风险自负。"
command -v systemctl >/dev/null || die "系统没有 systemd，脚本不支持。"

clear
echo
echo "${BD}  AnyTLS · sing-box 安装脚本${N}"
echo "${D}  Debian / 真实证书 / 自动续期${N}"
hr

info "安装基础依赖…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl socat jq dnsutils iproute2 qrencode >/dev/null
ok "依赖就绪"

# 取本机公网 IP
SERVER_IP4=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
SERVER_IP6=$(curl -fsS6 --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
[[ -n "$SERVER_IP4$SERVER_IP6" ]] || warn "无法获取本机公网 IP，将跳过解析校验。"

hr
echo "${BD}  第 1 步 · 基本信息${N}"
echo

# ---------------------------------------------------------------- 域名
while :; do
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "    域名（已解析到本机，Cloudflare 需灰云）: " DOMAIN || true
  fi
  DOMAIN=${DOMAIN// /}
  if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?)+$ ]]; then
    warn "域名格式不正确，请重新输入。"; DOMAIN=""; continue
  fi
  # 解析校验
  RES4=$(dig +short A    "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1 || true)
  RES6=$(dig +short AAAA "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1 || true)
  if [[ -z "$RES4$RES6" ]]; then
    warn "$DOMAIN 没有解析到任何 A/AAAA 记录。"
    confirm "仍要继续？" n || { DOMAIN=""; continue; }
  elif [[ -n "$SERVER_IP4$SERVER_IP6" && "$RES4" != "$SERVER_IP4" && "$RES6" != "$SERVER_IP6" ]]; then
    warn "解析结果（${RES4:-$RES6}）与本机 IP（${SERVER_IP4:-$SERVER_IP6}）不一致。"
    warn "常见原因：Cloudflare 开着橙云代理，或解析尚未生效。"
    confirm "仍要继续？" n || { DOMAIN=""; continue; }
  else
    ok "解析校验通过 → ${RES4:-$RES6}"
  fi
  break
done

# ---------------------------------------------------------------- 邮箱
while :; do
  if [[ -z "$EMAIL" ]]; then
    read -r -p "    邮箱（证书到期提醒，回车随机生成）: " EMAIL || true
  fi
  if [[ -z "$EMAIL" ]]; then
    EMAIL="$(openssl rand -hex 6)@${DOMAIN#*.}"
    info "使用随机邮箱：$EMAIL"
    break
  fi
  [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
  warn "邮箱格式不正确。"; EMAIL=""
done

# ---------------------------------------------------------------- 端口
while :; do
  if [[ -z "$PORT" ]]; then
    read -r -p "    监听端口 [默认 443]: " PORT || true
    PORT=${PORT:-443}
  fi
  if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    warn "端口须为 1-65535。"; PORT=""; continue
  fi
  HOLDER=$(port_holder "$PORT")
  if [[ -n "$HOLDER" && "$HOLDER" != "sing-box" ]]; then
    warn "端口 $PORT 已被 ${BD}$HOLDER${N} 占用。"
    echo "    ${D}若要与它共存，可让 nginx stream 按 SNI 分流，把 AnyTLS 放到内网端口。${N}"
    confirm "换一个端口？" y && { PORT=""; continue; }
  fi
  break
done

# ---------------------------------------------------------------- 密码
if [[ -z "$PASSWORD" ]]; then
  read -r -p "    密码（回车自动生成）: " PASSWORD || true
fi
if [[ -z "$PASSWORD" ]]; then
  # 生成 URL 安全字符集，避免分享链接被特殊字符截断
  PASSWORD=$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=')
  info "已生成密码：${BD}$PASSWORD${N}"
fi

# ---------------------------------------------------------------- 节点名
if [[ -z "$NODE_NAME" ]]; then
  read -r -p "    节点名称 [默认 $DOMAIN]: " NODE_NAME || true
  NODE_NAME=${NODE_NAME:-$DOMAIN}
fi

# ---------------------------------------------------------------- 证书方式
hr
echo "${BD}  第 2 步 · 证书方式${N}"
echo
echo "    1) HTTP-01  —— acme.sh standalone，需要 80 端口临时可用（推荐）"
echo "    2) DNS-01   —— Cloudflare API Token，80 被封或被占时用这个"
echo "    3) 已有证书 —— 手动指定 fullchain / key 路径"
echo
while :; do
  if [[ -z "$CERT_MODE" ]]; then
    read -r -p "    选择 [默认 1]: " CERT_MODE || true
    CERT_MODE=${CERT_MODE:-1}
  fi
  [[ "$CERT_MODE" =~ ^[123]$ ]] && break
  warn "请输入 1、2 或 3。"; CERT_MODE=""
done

if [[ "$CERT_MODE" == "2" && -z "$CF_TOKEN" ]]; then
  read -r -s -p "    Cloudflare API Token（Zone:DNS:Edit 权限）: " CF_TOKEN || true
  echo
  [[ -n "$CF_TOKEN" ]] || die "未提供 Token。"
fi

if [[ "$CERT_MODE" == "3" ]]; then
  [[ -n "$CERT_FILE" ]] || read -r -p "    证书 fullchain 路径: " CERT_FILE || true
  [[ -n "$KEY_FILE"  ]] || read -r -p "    私钥 key 路径: " KEY_FILE || true
  [[ -s "$CERT_FILE" ]] || die "证书文件不存在或为空：$CERT_FILE"
  [[ -s "$KEY_FILE"  ]] || die "私钥文件不存在或为空：$KEY_FILE"
else
  CERT_FILE="$CERT_DIR/cert.pem"
  KEY_FILE="$CERT_DIR/private.key"
fi

if [[ "$CERT_MODE" == "1" && "$PORT" == "80" ]]; then
  die "监听端口选了 80，会与 HTTP-01 验证冲突。请改端口或改用 DNS-01。"
fi

# ---------------------------------------------------------------- BBR
if [[ -z "$ENABLE_BBR" ]]; then
  if confirm "是否开启 BBR + fq 拥塞控制？" y; then ENABLE_BBR=1; else ENABLE_BBR=0; fi
fi

# ---------------------------------------------------------------- 确认
hr
echo "${BD}  确认配置${N}"
echo
printf "    %-12s %s\n" "域名"     "$DOMAIN"
printf "    %-12s %s\n" "邮箱"     "$EMAIL"
printf "    %-12s %s\n" "端口"     "$PORT"
printf "    %-12s %s\n" "密码"     "$PASSWORD"
printf "    %-12s %s\n" "节点名"   "$NODE_NAME"
printf "    %-12s %s\n" "证书"     "$([[ $CERT_MODE == 1 ]] && echo HTTP-01 || { [[ $CERT_MODE == 2 ]] && echo 'DNS-01 (Cloudflare)' || echo '已有证书'; })"
printf "    %-12s %s\n" "BBR"      "$([[ $ENABLE_BBR == 1 ]] && echo 开启 || echo 跳过)"
echo
confirm "开始安装？" y || { echo "已取消。"; exit 0; }

# ---------------------------------------------------------------- 安装 sing-box
hr
if command -v sing-box >/dev/null; then
  ok "sing-box 已安装：$(sing-box version | head -n1)"
else
  info "配置 sing-box 官方 apt 源…"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
    > /etc/apt/sources.list.d/sagernet.list
  apt-get update -qq
  apt-get install -y -qq sing-box
  ok "sing-box 安装完成：$(sing-box version | head -n1)"
fi

SB_VER=$(sing-box version 2>/dev/null | head -n1 | grep -oP '\d+\.\d+' | head -n1 || true)
if [[ -n "$SB_VER" ]] && awk "BEGIN{exit !($SB_VER < 1.12)}"; then
  die "sing-box 版本过低（$SB_VER），AnyTLS 需要 1.12 及以上。"
fi

# ---------------------------------------------------------------- 防火墙
info "放行端口…"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  [[ "$CERT_MODE" == "1" ]] && ufw allow 80/tcp >/dev/null 2>&1 || true
  ok "已写入 ufw 规则"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 || true
  [[ "$CERT_MODE" == "1" ]] && firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "已写入 firewalld 规则"
else
  warn "未检测到活动的本机防火墙。别忘了在云厂商安全组放行 TCP $PORT。"
fi

# ---------------------------------------------------------------- 申请证书
if [[ "$CERT_MODE" != "3" ]]; then
  install -d -m 755 "$CERT_DIR"

  if [[ ! -x "$ACME" ]]; then
    info "安装 acme.sh…"
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
    [[ -x "$ACME" ]] || die "acme.sh 安装失败。"
  fi
  "$ACME" --set-default-ca --server letsencrypt >/dev/null

  if [[ "$CERT_MODE" == "1" ]]; then
    HOLDER80=$(port_holder 80)
    if [[ -n "$HOLDER80" ]]; then
      for svc in nginx caddy apache2 haproxy lighttpd; do
        if systemctl is-active --quiet "$svc"; then
          info "暂停 $svc 以释放 80 端口…"
          systemctl stop "$svc"; STOPPED_SVC="$svc"; break
        fi
      done
      [[ -n "$STOPPED_SVC" ]] || die "80 端口被 $HOLDER80 占用且无法自动处理，请改用 DNS-01。"
    fi
    info "申请证书（HTTP-01）…"
    "$ACME" --issue -d "$DOMAIN" --standalone --httpport 80 -k ec-256 \
      || die "证书申请失败。检查 80 端口是否可从公网访问、域名解析是否正确。"
    cleanup
  else
    info "申请证书（Cloudflare DNS-01）…"
    CF_Token="$CF_TOKEN" "$ACME" --issue -d "$DOMAIN" --dns dns_cf -k ec-256 \
      || die "证书申请失败。检查 API Token 权限（Zone:Read + DNS:Edit）。"
  fi

  info "安装证书并挂上自动续期钩子…"
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$CERT_FILE" \
    --key-file       "$KEY_FILE" \
    --reloadcmd      "systemctl restart sing-box" >/dev/null
  chmod 600 "$KEY_FILE"
  ok "证书就绪（到期前会自动续期并重启服务）"
fi

CERT_END=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知")

# ---------------------------------------------------------------- 写配置
info "生成 $CONF_FILE …"
install -d -m 755 "$CONF_DIR"
[[ -f "$CONF_FILE" ]] && cp -a "$CONF_FILE" "$CONF_FILE.bak.$(date +%s)"

jq -n \
  --arg pw   "$PASSWORD" \
  --arg sni  "$DOMAIN" \
  --arg cert "$CERT_FILE" \
  --arg key  "$KEY_FILE" \
  --argjson port "$PORT" \
  '{
     log: { level: "info", timestamp: true },
     inbounds: [{
       type: "anytls",
       tag: "anytls-in",
       listen: "::",
       listen_port: $port,
       users: [{ name: "user", password: $pw }],
       tls: {
         enabled: true,
         server_name: $sni,
         certificate_path: $cert,
         key_path: $key
       }
     }],
     outbounds: [{ type: "direct", tag: "direct" }]
   }' > "$CONF_FILE"
chmod 600 "$CONF_FILE"

sing-box check -c "$CONF_FILE" || die "配置文件校验未通过。"
ok "配置校验通过"

# ---------------------------------------------------------------- BBR
if [[ "$ENABLE_BBR" == "1" ]]; then
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbr" ]]; then
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
  fi
  ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"
fi

# ---------------------------------------------------------------- 启动
info "启动服务…"
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
if ! systemctl is-active --quiet sing-box; then
  journalctl -u sing-box -n 30 --no-pager || true
  die "sing-box 启动失败，日志见上。"
fi
ss -lntH "sport = :$PORT" | grep -q . || warn "服务已启动但未监听 $PORT，请检查日志。"
ok "sing-box 运行中，监听 :$PORT"

# ---------------------------------------------------------------- 输出
PW_ENC=$(urlencode "$PASSWORD")
NAME_ENC=$(urlencode "$NODE_NAME")
LINK="anytls://${PW_ENC}@${DOMAIN}:${PORT}/?sni=${DOMAIN}&insecure=0#${NAME_ENC}"
echo "$LINK" > "$LINK_FILE"; chmod 600 "$LINK_FILE"

cat > "$INFO_FILE" <<EOF
════════════════════════════════════════════════════════
  AnyTLS 节点信息
════════════════════════════════════════════════════════
  地址        : $DOMAIN
  端口        : $PORT
  密码        : $PASSWORD
  SNI         : $DOMAIN
  协议        : anytls
  证书到期    : $CERT_END
  安装时间    : $(date '+%F %T %Z')

── 分享链接 ────────────────────────────────────────────
$LINK

── Mihomo / Clash Meta ─────────────────────────────────
proxies:
  - name: "$NODE_NAME"
    type: anytls
    server: $DOMAIN
    port: $PORT
    password: "$PASSWORD"
    sni: $DOMAIN
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30s
    idle-session-timeout: 30s
    min-idle-session: 0

── sing-box 客户端 outbound ────────────────────────────
$(jq -n --arg n "$NODE_NAME" --arg s "$DOMAIN" --arg pw "$PASSWORD" --argjson p "$PORT" \
  '{type:"anytls",tag:$n,server:$s,server_port:$p,password:$pw,
    tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:"chrome"}}}')

── 提示 ────────────────────────────────────────────────
  · 客户端只开 UDP 转发；连接复用(mux)、TCP Fast Open 必须关闭
  · 证书由 acme.sh 自动续期并重启 sing-box，无需手动干预
  · 管理命令： anytls {info|qr|log|restart|update|uninstall}
════════════════════════════════════════════════════════
EOF
chmod 600 "$INFO_FILE"

# ---------------------------------------------------------------- 管理命令
cat > /usr/local/bin/anytls <<EOF
#!/usr/bin/env bash
set -euo pipefail
INSTALLER="\$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
case "\${1:-info}" in
  info)      cat $INFO_FILE ;;
  link)      cat $LINK_FILE ;;
  qr)        qrencode -t ANSIUTF8 < $LINK_FILE ;;
  log)       journalctl -u sing-box -n 100 --no-pager -f ;;
  restart)   systemctl restart sing-box && systemctl --no-pager status sing-box ;;
  status)    systemctl --no-pager status sing-box ;;
  update)    apt-get update -qq && apt-get install -y --only-upgrade sing-box && systemctl restart sing-box && sing-box version ;;
  renew)     "$ACME" --renew -d "$DOMAIN" --ecc --force ;;
  uninstall) systemctl disable --now sing-box 2>/dev/null || true
             apt-get purge -y sing-box 2>/dev/null || true
             rm -rf $CONF_DIR /usr/local/bin/anytls
             echo "已卸载（acme.sh 保留，如需删除：\$HOME/.acme.sh/acme.sh --uninstall）" ;;
  *)         echo "用法: anytls {info|link|qr|log|status|restart|update|renew|uninstall}" ;;
esac
EOF
chmod +x /usr/local/bin/anytls

clear
cat "$INFO_FILE"
echo
echo "  ${BD}二维码${N}"
qrencode -t ANSIUTF8 < "$LINK_FILE" || true
echo
ok "全部完成。随时用 ${BD}anytls info${N} 重新查看，${BD}anytls qr${N} 显示二维码。"

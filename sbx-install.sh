#!/usr/bin/env bash
#
# AnyTLS + Hysteria2 二合一安装脚本（sing-box 内核）—— Debian 11/12/13
#
#   bash sbx-install.sh              交互安装 / 二次进入管理菜单
#   bash sbx-install.sh uninstall    卸载
#
# 支持环境变量预设实现非交互安装，例如：
#   DOMAIN=a.example.com EMAIL=me@x.com PROTOS=both \
#   ANYTLS_PORT=443 HY2_PORT=443 CERT_MODE=1 NONINTERACTIVE=1 bash sbx-install.sh
#
set -Eeuo pipefail

CONF_DIR=/etc/sing-box
CERT_DIR="$CONF_DIR/cert"
CONF_FILE="$CONF_DIR/config.json"
STATE_FILE="$CONF_DIR/sbx.conf"
INFO_FILE="$CONF_DIR/sbx-info.txt"
LINK_FILE="$CONF_DIR/sbx-links.txt"
SELF_COPY="$CONF_DIR/sbx-install.sh"
ACME="$HOME/.acme.sh/acme.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

# ---------------------------------------------------------------- 环境变量预设
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
PROTOS=${PROTOS:-}                 # both | anytls | hy2
NODE_PREFIX=${NODE_PREFIX:-}
ANYTLS_PORT=${ANYTLS_PORT:-}
ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-}
HY2_PORT=${HY2_PORT:-}
HY2_PASSWORD=${HY2_PASSWORD:-}
HY2_CC=${HY2_CC:-}                 # brutal | limit | bbr  流控方式
HY2_UP=${HY2_UP:-}                 # limit 模式：服务端→客户端 Mbps（你的下载）
HY2_DOWN=${HY2_DOWN:-}             # limit 模式：客户端→服务端 Mbps（你的上传）
HY2_OBFS=${HY2_OBFS:-}             # 留空 = 不启用 salamander 混淆
HY2_MASQ=${HY2_MASQ:-}             # 留空 = 不伪装，形如 https://bing.com
CERT_MODE=${CERT_MODE:-}           # 1=HTTP-01  2=Cloudflare DNS-01  3=已有证书
CF_Token=${CF_Token:-${CF_TOKEN:-}}   # 两种写法都认
CERT_FILE=${CERT_FILE:-}
KEY_FILE=${KEY_FILE:-}
ENABLE_TUNE=${ENABLE_TUNE:-}       # BBR + UDP 缓冲区
NONINTERACTIVE=${NONINTERACTIVE:-0}

ANYTLS_ENABLE=0
HY2_ENABLE=0
STOPPED_SVC=""
ACME_NOCRON=0

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

# 命令替换在子 shell 中执行会让 ERR trap 触发两次，只在主 shell 里报错
on_err() {
  [[ "$BASHPID" == "$$" ]] || exit 1
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

genpw() { openssl rand -base64 24 | tr '+/' '-_' | tr -d '='; }

confirm() {   # confirm <提示> <默认y|n>
  local prompt=$1 def=${2:-y} ans
  [[ "$NONINTERACTIVE" == "1" ]] && { [[ "$def" == "y" ]]; return; }
  local hint="[Y/n]"; [[ "$def" == "n" ]] && hint="[y/N]"
  read -r -p "  $prompt $hint " ans || true
  ans=${ans:-$def}
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ver_ge <A> <B>：A >= B 时返回 0。用 sort -V，避免 1.9 > 1.12 的浮点误判
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# port_holder <tcp|udp> <端口>：返回占用进程名，空闲返回空
port_holder() {
  local flag="-lntpH"; [[ "$1" == "udp" ]] && flag="-lnupH"
  { ss $flag "sport = :$2" 2>/dev/null || true; } \
    | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null | head -n1 || true
}

# sing-box 1.12 起 systemd unit 用非 root 的 sing-box 用户运行，
# 配置与私钥必须让该用户可读，否则 217/USER 或 permission denied
sb_service_user() {
  local u
  u=$(systemctl show -p User --value sing-box 2>/dev/null || true)
  echo "${u:-root}"
}

fix_perms() {
  local u g f
  u=$(sb_service_user)
  g=$(id -gn "$u" 2>/dev/null || echo "$u")
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    chown "root:$g" "$f" 2>/dev/null || true
    chmod 640 "$f"
  done
}

save_state() {
  install -d -m 755 "$CONF_DIR"
  cat > "$STATE_FILE" <<EOF
DOMAIN='$DOMAIN'
EMAIL='$EMAIL'
CERT_MODE='$CERT_MODE'
CERT_FILE='$CERT_FILE'
KEY_FILE='$KEY_FILE'
NODE_PREFIX='$NODE_PREFIX'
ANYTLS_ENABLE='$ANYTLS_ENABLE'
ANYTLS_PORT='$ANYTLS_PORT'
ANYTLS_PASSWORD='$ANYTLS_PASSWORD'
HY2_ENABLE='$HY2_ENABLE'
HY2_PORT='$HY2_PORT'
HY2_PASSWORD='$HY2_PASSWORD'
HY2_CC='$HY2_CC'
HY2_UP='$HY2_UP'
HY2_DOWN='$HY2_DOWN'
HY2_OBFS='$HY2_OBFS'
HY2_MASQ='$HY2_MASQ'
EOF
  chmod 600 "$STATE_FILE"
}

load_state() { [[ -f "$STATE_FILE" ]] && . "$STATE_FILE"; return 0; }

tune_kernel() {
  cat > /etc/sysctl.d/99-sbx.conf <<'SYSCTLEOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Hysteria2 / QUIC：默认 212KB 的收发缓冲会成为吞吐瓶颈
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
SYSCTLEOF
  sysctl --system >/dev/null 2>&1 || true
  ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)　UDP 缓冲：$(sysctl -n net.core.rmem_max)"
}

# ---------------------------------------------------------------- 交互子流程
ask_port() {   # ask_port <tcp|udp> <协议名> <默认端口> <变量名>
  local proto=$1 label=$2 def=$3 var=$4 cur=${!4} holder
  while :; do
    if [[ -z "$cur" ]]; then
      read -r -p "  $label 监听端口（$proto）[默认 $def]: " cur || true
      cur=${cur:-$def}
    fi
    if [[ ! "$cur" =~ ^[0-9]+$ ]] || (( cur < 1 || cur > 65535 )); then
      warn "端口须为 1-65535。"; cur=""; [[ "$NONINTERACTIVE" == "1" ]] && die "端口非法。"; continue
    fi
    holder=$(port_holder "$proto" "$cur")
    if [[ -n "$holder" && "$holder" != "sing-box" ]]; then
      warn "$proto 端口 $cur 已被 ${BD}$holder${N} 占用。"
      confirm "换一个端口？" y && { cur=""; continue; }
    fi
    break
  done
  printf -v "$var" '%s' "$cur"
}

ask_bw() {   # ask_bw <提示> <默认值> <变量名>
  local prompt=$1 def=$2 var=$3 cur=${!3}
  while :; do
    if [[ -z "$cur" ]]; then
      read -r -p "  $prompt [默认 $def]: " cur || true
      cur=${cur:-$def}
    fi
    [[ "$cur" =~ ^[0-9]+$ ]] && (( cur > 0 )) && break
    warn "请填纯数字（单位 Mbps）。"; cur=""
    [[ "$NONINTERACTIVE" == "1" ]] && die "带宽取值非法。"
  done
  printf -v "$var" '%s' "$cur"
}

ask_anytls() {
  ask_port tcp "AnyTLS" 443 ANYTLS_PORT
  if [[ -z "$ANYTLS_PASSWORD" ]]; then
    read -r -p "  AnyTLS 密码（回车自动生成）: " ANYTLS_PASSWORD || true
    [[ -n "$ANYTLS_PASSWORD" ]] || { ANYTLS_PASSWORD=$(genpw); info "已生成：${BD}$ANYTLS_PASSWORD${N}"; }
  fi
}

ask_hy2() {
  ask_port udp "Hysteria2" 443 HY2_PORT
  if [[ -z "$HY2_PASSWORD" ]]; then
    read -r -p "  Hysteria2 密码（回车自动生成）: " HY2_PASSWORD || true
    [[ -n "$HY2_PASSWORD" ]] || { HY2_PASSWORD=$(genpw); info "已生成：${BD}$HY2_PASSWORD${N}"; }
  fi
  if [[ -z "$HY2_CC" ]]; then
    echo
    echo "  ${BD}流控方式${N}"
    echo "  1) Brutal              ${D}恒速发送、丢包不退让，专治 QoS 主动丢包。固定线路首选${N}"
    echo "  2) Brutal + 服务端封顶 ${D}同上，但服务端限速，防止客户端填虚打爆机器 / 烧流量${N}"
    echo "  3) 强制 BBR            ${D}忽略客户端声明。移动网络或按流量计费时选这个${N}"
    echo
    read -r -p "  选择 [默认 1]: " CC || true
    case "${CC:-1}" in 1) HY2_CC=brutal ;; 2) HY2_CC=limit ;; 3) HY2_CC=bbr ;; *) HY2_CC=brutal ;; esac
  fi
  if [[ "$HY2_CC" != "bbr" ]]; then
    echo
    if [[ "$HY2_CC" == "brutal" ]]; then
      echo "  ${D}填你实测的可用带宽，脚本会写进客户端配置。宁可少填不要多填——${N}"
      echo "  ${D}虚报会让服务端恒速空发，丢包加冗余，有效吞吐反而低于 BBR。${N}"
      echo "  ${D}没测过就先用 iperf3 跑一遍，再取实测值的 80~90%。${N}"
    else
      echo "  ${D}服务端硬上限，客户端声明超过这个数会被压回来。${N}"
    fi
    ask_bw "你的下载带宽 Mbps（服务端 up）" 200 HY2_UP
    ask_bw "你的上传带宽 Mbps（服务端 down）" 50  HY2_DOWN
  fi
  if [[ -z "$HY2_OBFS" ]] && confirm "启用 salamander 混淆？（对抗 QUIC 特征识别，客户端需同步配置）" n; then
    HY2_OBFS=$(genpw); info "混淆密码：${BD}$HY2_OBFS${N}"
  fi
  if [[ -z "$HY2_MASQ" ]] && confirm "启用 masquerade 伪装（非法请求反代到真站）？" y; then
    read -r -p "  伪装目标 [默认 https://bing.com]: " HY2_MASQ || true
    HY2_MASQ=${HY2_MASQ:-https://bing.com}
  fi
}

fw_allow() {   # fw_allow <端口> <tcp|udp>
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "$1/$2" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$1/$2" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  return 0
}

# ---------------------------------------------------------------- 生成配置
build_config() {
  local inb='[]'

  if [[ "$ANYTLS_ENABLE" == "1" ]]; then
    inb=$(jq -n --argjson cur "$inb" \
      --arg pw "$ANYTLS_PASSWORD" --arg sni "$DOMAIN" \
      --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --argjson port "$ANYTLS_PORT" '
      $cur + [{
        type: "anytls",
        tag: "anytls-in",
        listen: "::",
        listen_port: $port,
        users: [{ name: "user", password: $pw }],
        tls: { enabled: true, server_name: $sni,
               certificate_path: $cert, key_path: $key }
      }]')
  fi

  if [[ "$HY2_ENABLE" == "1" ]]; then
    inb=$(jq -n --argjson cur "$inb" \
      --arg pw "$HY2_PASSWORD" --arg sni "$DOMAIN" \
      --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --argjson port "$HY2_PORT" \
      --arg obfs "$HY2_OBFS" --arg masq "$HY2_MASQ" \
      --arg cc "$HY2_CC" --arg up "${HY2_UP:-0}" --arg down "${HY2_DOWN:-0}" '
      $cur + [
        ({
          type: "hysteria2",
          tag: "hy2-in",
          listen: "::",
          listen_port: $port,
          users: [{ name: "user", password: $pw }],
          tls: { enabled: true, server_name: $sni, alpn: ["h3"],
                 certificate_path: $cert, key_path: $key }
        })
        # brutal: 什么都不写，速率完全由客户端声明决定
        # limit : 服务端设上限，客户端声明值会被压到这个数以内
        # bbr   : 忽略客户端声明，服务端一律走 BBR
        + (if $cc == "bbr" then { ignore_client_bandwidth: true }
           elif $cc == "limit" then { up_mbps: ($up|tonumber), down_mbps: ($down|tonumber) }
           else {} end)
        + (if $obfs != "" then { obfs: { type: "salamander", password: $obfs } } else {} end)
        + (if $masq != "" then { masquerade: $masq } else {} end)
      ]')
  fi

  [[ "$(jq 'length' <<<"$inb")" != "0" ]] || die "没有启用任何协议，拒绝写出空配置。"

  local tmp; tmp=$(mktemp)
  jq -n --argjson inb "$inb" '{
    log: { level: "info", timestamp: true },
    inbounds: $inb,
    outbounds: [{ type: "direct", tag: "direct" }]
  }' > "$tmp"

  if ! sing-box check -c "$tmp" 2>&1; then
    rm -f "$tmp"
    die "配置校验未通过，已放弃写入（原配置保持不变）。"
  fi

  [[ -f "$CONF_FILE" ]] && cp -a "$CONF_FILE" "$CONF_FILE.bak.$(date +%s)"
  install -d -m 755 "$CONF_DIR"
  cat "$tmp" > "$CONF_FILE"
  rm -f "$tmp"
  fix_perms "$CONF_FILE"
  chmod 755 "$CONF_DIR"
  [[ -d "$CERT_DIR" ]] && chmod 755 "$CERT_DIR"
  ok "配置已写入并通过校验"
}

restart_sb() {
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 30 --no-pager || true
    die "sing-box 启动失败，日志见上。"
  fi
  [[ "$ANYTLS_ENABLE" == "1" ]] && { ss -lntH "sport = :$ANYTLS_PORT" | grep -q . \
    || warn "AnyTLS 未监听 TCP $ANYTLS_PORT，请查日志。"; }
  [[ "$HY2_ENABLE" == "1" ]] && { ss -lnuH "sport = :$HY2_PORT" | grep -q . \
    || warn "Hysteria2 未监听 UDP $HY2_PORT，请查日志。"; }
  ok "sing-box 运行中"
}

# ---------------------------------------------------------------- 生成分享信息
build_info() {
  local cert_end
  cert_end=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知")
  : > "$LINK_FILE"; chmod 600 "$LINK_FILE"

  {
    echo "════════════════════════════════════════════════════════"
    echo "  sing-box 节点信息    （生成于 $(date '+%F %T %Z')）"
    echo "════════════════════════════════════════════════════════"
    echo "  域名      : $DOMAIN"
    echo "  证书到期  : $cert_end"
    echo
  } > "$INFO_FILE"

  if [[ "$ANYTLS_ENABLE" == "1" ]]; then
    local name="$NODE_PREFIX AnyTLS" link
    link="anytls://$(urlencode "$ANYTLS_PASSWORD")@${DOMAIN}:${ANYTLS_PORT}/?sni=${DOMAIN}&insecure=0#$(urlencode "$name")"
    echo "anytls|$link" >> "$LINK_FILE"
    cat >> "$INFO_FILE" <<EOF
── AnyTLS ──────────────────────────────────────────────
  端口(TCP) : $ANYTLS_PORT
  密码      : $ANYTLS_PASSWORD

  $link

  proxies:
    - name: "$name"
      type: anytls
      server: $DOMAIN
      port: $ANYTLS_PORT
      password: "$ANYTLS_PASSWORD"
      sni: $DOMAIN
      client-fingerprint: chrome
      udp: true
      skip-cert-verify: false
      idle-session-check-interval: 30s
      idle-session-timeout: 30s
      min-idle-session: 0

  sing-box outbound:
$(jq -n --arg n "$name" --arg s "$DOMAIN" --arg pw "$ANYTLS_PASSWORD" --argjson p "$ANYTLS_PORT" \
   '{type:"anytls",tag:$n,server:$s,server_port:$p,password:$pw,
     tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:"chrome"}}}' | sed 's/^/    /')

EOF
  fi

  if [[ "$HY2_ENABLE" == "1" ]]; then
    local name="$NODE_PREFIX Hy2" link obfs_q="" obfs_yaml=""
    if [[ -n "$HY2_OBFS" ]]; then
      obfs_q="&obfs=salamander&obfs-password=$(urlencode "$HY2_OBFS")"
      obfs_yaml=$'\n      obfs: salamander\n      obfs-password: "'"$HY2_OBFS"'"'
    fi
    link="hysteria2://$(urlencode "$HY2_PASSWORD")@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&alpn=h3&insecure=0${obfs_q}#$(urlencode "$name")"
    echo "hy2|$link" >> "$LINK_FILE"
    local cc_desc yaml_bw="" bw_tip=""
    case "$HY2_CC" in
      brutal) cc_desc="Brutal（速率由客户端声明，服务端不限速）"
              yaml_bw=$'\n      up: "'"${HY2_DOWN:-50}"$' Mbps"\n      down: "'"${HY2_UP:-200}"$' Mbps"'
              bw_tip="  · 上面的 up/down 是安装时填的实测值（下载 ${HY2_UP} / 上传 ${HY2_DOWN} Mbps）
  · 数字虚报会自伤：服务端按声明值恒速发，多出来的全丢在路上，
    Brutal 还会加冗余，有效吞吐反而低于 BBR。改带宽用 sbx menu
  · 删掉 up/down 的客户端会自动退回 BBR" ;;
      limit)  cc_desc="Brutal，服务端封顶 上行 ${HY2_UP} / 下行 ${HY2_DOWN} Mbps"
              yaml_bw=$'\n      up: "'"$HY2_DOWN"$' Mbps"\n      down: "'"$HY2_UP"$' Mbps"'
              bw_tip="  · 客户端声明值超过服务端上限会被压回上限，不会打爆机器
  · 服务端上行 ${HY2_UP} Mbps＝你的下载，下行 ${HY2_DOWN} Mbps＝你的上传" ;;
      *)      cc_desc="强制 BBR（ignore_client_bandwidth）"
              bw_tip="  · 服务端忽略客户端声明的带宽，客户端填不填 up/down 都不生效" ;;
    esac
    cat >> "$INFO_FILE" <<EOF
── Hysteria2 ───────────────────────────────────────────
  端口(UDP) : $HY2_PORT
  密码      : $HY2_PASSWORD
  流控      : $cc_desc
  混淆      : ${HY2_OBFS:-未启用}
  伪装站点  : ${HY2_MASQ:-未启用}

  $link

  proxies:
    - name: "$name"
      type: hysteria2
      server: $DOMAIN
      port: $HY2_PORT
      password: "$HY2_PASSWORD"
      sni: $DOMAIN
      alpn:
        - h3
      skip-cert-verify: false$obfs_yaml$yaml_bw

  带宽说明:
$bw_tip

  sing-box outbound:
$(jq -n --arg n "$name" --arg s "$DOMAIN" --arg pw "$HY2_PASSWORD" --argjson p "$HY2_PORT" --arg o "$HY2_OBFS" \
   '{type:"hysteria2",tag:$n,server:$s,server_port:$p,password:$pw,
     tls:{enabled:true,server_name:$s,alpn:["h3"]}}
    + (if $o != "" then {obfs:{type:"salamander",password:$o}} else {} end)' | sed 's/^/    /')

EOF
  fi

  cat >> "$INFO_FILE" <<'EOF'
── 提示 ────────────────────────────────────────────────
  · AnyTLS 客户端：连接复用(mux)、TCP Fast Open 必须关闭
  · Hysteria2 走 UDP，云厂商安全组别忘了放行对应 UDP 端口
  · 服务端已设 ignore_client_bandwidth，统一使用 BBR，
    客户端填不填带宽都不会启用 Brutal
  · 证书每日自动检查、到期自动续期并重启 sing-box
  · 管理命令： sbx {info|link|qr|log|cert|status|restart|update|menu|uninstall}
════════════════════════════════════════════════════════
EOF
  chmod 600 "$INFO_FILE"
}

# ---------------------------------------------------------------- 管理命令
write_cli() {
  cat > /usr/local/bin/sbx <<'CLIEOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_DIR=/etc/sing-box
INFO_FILE="$CONF_DIR/sbx-info.txt"
LINK_FILE="$CONF_DIR/sbx-links.txt"
CERT_FILE="$CONF_DIR/cert/cert.pem"
INSTALLER="$CONF_DIR/sbx-install.sh"
[[ -f "$CONF_DIR/sbx.conf" ]] && . "$CONF_DIR/sbx.conf"

case "${1:-info}" in
  info)    cat "$INFO_FILE" ;;
  link)    cut -d'|' -f2- "$LINK_FILE" ;;
  qr)
    which=${2:-all}
    while IFS='|' read -r tag link; do
      [[ "$which" == "all" || "$which" == "$tag" ]] || continue
      echo; echo "  [$tag]"
      qrencode -t ANSIUTF8 <<<"$link"
    done < "$LINK_FILE" ;;
  log)     journalctl -u sing-box -n 100 --no-pager -f ;;
  cert)
    echo "到期时间: $(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)"
    if systemctl list-unit-files acme-renew.timer >/dev/null 2>&1; then
      systemctl list-timers acme-renew.timer --no-pager 2>/dev/null || true
    fi
    crontab -l 2>/dev/null | grep acme || true ;;
  renew)   "$HOME/.acme.sh/acme.sh" --renew -d "$DOMAIN" --ecc --force ;;
  status)  systemctl --no-pager status sing-box ;;
  restart) systemctl restart sing-box && systemctl --no-pager status sing-box ;;
  update)  apt-get update -qq && apt-get install -y --only-upgrade sing-box \
             && systemctl restart sing-box && sing-box version ;;
  menu|add|del|reconfig)
    [[ -x "$INSTALLER" ]] || { echo "找不到 $INSTALLER，请重新下载安装脚本运行。"; exit 1; }
    exec bash "$INSTALLER" ;;
  uninstall)
    [[ -x "$INSTALLER" ]] && exec bash "$INSTALLER" uninstall
    echo "找不到安装脚本，请手动卸载。"; exit 1 ;;
  *) echo "用法: sbx {info|link|qr [anytls|hy2]|log|cert|renew|status|restart|update|menu|uninstall}" ;;
esac
CLIEOF
  chmod +x /usr/local/bin/sbx
  [[ -n "$SELF" && -f "$SELF" ]] && install -m 700 "$SELF" "$SELF_COPY"
  return 0
}

# ---------------------------------------------------------------- 迁移旧版 anytls 安装
# 老脚本（anytls-install.sh）只写了 config.json / anytls-info.txt / /usr/local/bin/anytls，
# 没有状态文件。这里把参数从现有 config.json 里读回来，生成 sbx.conf，实现无缝接管。
migrate_legacy() {
  [[ -f "$STATE_FILE" ]] && return 0
  [[ -f "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0

  local a h
  a=$(jq -c '.inbounds[]? | select(.type=="anytls")'    "$CONF_FILE" 2>/dev/null | head -n1 || true)
  h=$(jq -c '.inbounds[]? | select(.type=="hysteria2")' "$CONF_FILE" 2>/dev/null | head -n1 || true)
  [[ -n "$a$h" ]] || return 0

  hr
  info "检测到未被本脚本管理的 sing-box 配置，尝试接管…"

  if [[ -n "$a" ]]; then
    ANYTLS_ENABLE=1
    ANYTLS_PORT=$(jq -r '.listen_port' <<<"$a")
    ANYTLS_PASSWORD=$(jq -r '.users[0].password' <<<"$a")
    DOMAIN=$(jq -r '.tls.server_name // empty' <<<"$a")
    CERT_FILE=$(jq -r '.tls.certificate_path // empty' <<<"$a")
    KEY_FILE=$(jq -r '.tls.key_path // empty' <<<"$a")
    ok "读到 AnyTLS：TCP $ANYTLS_PORT ／ $DOMAIN"
  fi
  if [[ -n "$h" ]]; then
    HY2_ENABLE=1
    HY2_PORT=$(jq -r '.listen_port' <<<"$h")
    HY2_PASSWORD=$(jq -r '.users[0].password' <<<"$h")
    HY2_OBFS=$(jq -r '.obfs.password // empty' <<<"$h")
    HY2_MASQ=$(jq -r 'if (.masquerade|type)=="string" then .masquerade else "" end' <<<"$h")
    if [[ "$(jq -r '.ignore_client_bandwidth // false' <<<"$h")" == "true" ]]; then HY2_CC=bbr
    elif [[ "$(jq -r '.up_mbps // 0' <<<"$h")" != "0" ]]; then
      HY2_CC=limit; HY2_UP=$(jq -r '.up_mbps' <<<"$h"); HY2_DOWN=$(jq -r '.down_mbps // 0' <<<"$h")
    else HY2_CC=brutal; fi
    [[ -z "$DOMAIN" ]] && DOMAIN=$(jq -r '.tls.server_name // empty' <<<"$h")
    [[ -z "$CERT_FILE" ]] && { CERT_FILE=$(jq -r '.tls.certificate_path // empty' <<<"$h")
                               KEY_FILE=$(jq -r '.tls.key_path // empty' <<<"$h"); }
    ok "读到 Hysteria2：UDP $HY2_PORT"
  fi

  [[ -n "$DOMAIN" && -s "$CERT_FILE" && -s "$KEY_FILE" ]] \
    || { warn "现有配置里缺域名或证书路径，无法自动接管，将走全新安装流程。"; return 0; }

  NODE_PREFIX="$DOMAIN"
  # 证书已由老脚本的 acme.sh 管着（reloadcmd 就是 restart sing-box），这里不再重新签发
  CERT_MODE=3
  EMAIL=""
  save_state
  ok "已生成 $STATE_FILE，原配置与证书原样保留。"

  if [[ -f /usr/local/bin/anytls ]] && confirm "移除旧的 anytls 管理命令（功能已并入 sbx）？" y; then
    rm -f /usr/local/bin/anytls
  fi
  return 0
}
# ---------------------------------------------------------------- 卸载
do_uninstall() {
  echo
  warn "即将卸载 sing-box 与相关配置。"
  confirm "确认继续？" n || { echo "已取消。"; exit 0; }
  systemctl disable --now sing-box 2>/dev/null || true
  systemctl disable --now acme-renew.timer 2>/dev/null || true
  rm -f /etc/systemd/system/acme-renew.service /etc/systemd/system/acme-renew.timer
  systemctl daemon-reload 2>/dev/null || true
  apt-get purge -y sing-box 2>/dev/null || true
  rm -f /usr/local/bin/sbx
  if confirm "同时删除 $CONF_DIR（含证书与配置）？" n; then rm -rf "$CONF_DIR"; fi
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

# ---------------------------------------------------------------- 已安装 → 管理菜单
if [[ ! -f "$STATE_FILE" && -f "$CONF_FILE" && "$NONINTERACTIVE" != "1" ]]; then
  command -v jq >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq jq >/dev/null 2>&1 || true; }
  migrate_legacy
  [[ -f "$STATE_FILE" ]] && write_cli
fi

if [[ -f "$STATE_FILE" && "$NONINTERACTIVE" != "1" ]]; then
  load_state
  clear
  echo
  echo "${BD}  已检测到现有安装${N}"
  echo "${D}  域名 $DOMAIN ｜ AnyTLS $([[ $ANYTLS_ENABLE == 1 ]] && echo "TCP $ANYTLS_PORT" || echo 未启用)"\
       "｜ Hysteria2 $([[ $HY2_ENABLE == 1 ]] && echo "UDP $HY2_PORT" || echo 未启用)${N}"
  hr
  echo "  1) 查看节点信息"
  echo "  2) 启用 / 停用 AnyTLS"
  echo "  3) 启用 / 停用 Hysteria2"
  echo "  4) 重置密码（两个协议都重新生成）"
  echo "  5) 全新安装（覆盖现有配置）"
  echo "  6) 卸载"
  echo "  0) 退出"
  echo
  read -r -p "  选择 [默认 0]: " MENU || true
  case "${MENU:-0}" in
    1) cat "$INFO_FILE"; exit 0 ;;
    2) if [[ "$ANYTLS_ENABLE" == "1" ]]; then
         ANYTLS_ENABLE=0
       else
         ANYTLS_ENABLE=1; echo; ask_anytls; fw_allow "$ANYTLS_PORT" tcp
       fi
       [[ "$ANYTLS_ENABLE$HY2_ENABLE" == "00" ]] && die "不能同时停用两个协议，请直接卸载。"
       build_config; save_state; build_info; restart_sb
       [[ "$ANYTLS_ENABLE" == "1" ]] && { echo; cat "$INFO_FILE"; }
       ok "AnyTLS 现在 $([[ $ANYTLS_ENABLE == 1 ]] && echo 启用 || echo 停用)"
       exit 0 ;;
    3) if [[ "$HY2_ENABLE" == "1" ]]; then
         HY2_ENABLE=0
       else
         HY2_ENABLE=1; echo; ask_hy2; fw_allow "$HY2_PORT" udp
         warn "云厂商安全组需要放行 UDP $HY2_PORT，脚本改不了。"
         if [[ "$(sysctl -n net.core.rmem_max)" -lt 8388608 ]] \
            && confirm "当前 UDP 缓冲区偏小会限制 Hy2 吞吐，现在调大并开启 BBR？" y; then
           tune_kernel
         fi
       fi
       [[ "$ANYTLS_ENABLE$HY2_ENABLE" == "00" ]] && die "不能同时停用两个协议，请直接卸载。"
       build_config; save_state; build_info; restart_sb
       [[ "$HY2_ENABLE" == "1" ]] && { echo; cat "$INFO_FILE"; }
       ok "Hysteria2 现在 $([[ $HY2_ENABLE == 1 ]] && echo 启用 || echo 停用)"
       exit 0 ;;
    4) ANYTLS_PASSWORD=$(genpw); HY2_PASSWORD=$(genpw)
       [[ -n "$HY2_OBFS" ]] && HY2_OBFS=$(genpw)
       build_config; save_state; build_info; restart_sb
       cat "$INFO_FILE"; exit 0 ;;
    5) warn "将进入全新安装流程。"; ANYTLS_ENABLE=0; HY2_ENABLE=0 ;;
    6) do_uninstall ;;
    *) exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- 依赖
clear
echo
echo "${BD}  AnyTLS + Hysteria2 · sing-box 安装脚本${N}"
echo "${D}  Debian ／ 真实证书 ／ 自动续期${N}"
hr
info "检查并安装依赖…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || die "apt-get update 失败，请检查网络或软件源。"

DEPS=(
  "curl:curl" "ca-certificates:" "openssl:openssl" "socat:socat"
  "jq:jq" "dnsutils:dig" "iproute2:ss" "qrencode:qrencode" "cron:crontab"
)
dep_ok() { if [[ -z "$2" ]]; then dpkg -s "$1" >/dev/null 2>&1; else command -v "$2" >/dev/null 2>&1; fi; }

MISSING=()
for item in "${DEPS[@]}"; do dep_ok "${item%%:*}" "${item#*:}" || MISSING+=("${item%%:*}"); done
if (( ${#MISSING[@]} > 0 )); then
  info "缺失组件：${MISSING[*]}，开始安装…"
  apt-get install -y "${MISSING[@]}" || warn "部分依赖安装返回非零，下面逐项复核。"
fi

FATAL=()
for item in "${DEPS[@]}"; do
  pkg=${item%%:*}; cmd=${item#*:}
  dep_ok "$pkg" "$cmd" && continue
  if [[ "$pkg" == "cron" ]]; then
    ACME_NOCRON=1; warn "cron 安装失败，证书续期将降级为 systemd timer（功能等价）。"
  else
    FATAL+=("$pkg${cmd:+ (缺少 $cmd)}")
  fi
done
(( ${#FATAL[@]} > 0 )) && die "以下依赖无法安装：${FATAL[*]}"

if (( ACME_NOCRON == 0 )); then
  systemctl enable --now cron >/dev/null 2>&1 || true
  systemctl is-active --quiet cron || { ACME_NOCRON=1; warn "cron 未运行，证书续期改用 systemd timer。"; }
fi
ok "依赖就绪"

SERVER_IP4=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
SERVER_IP6=$(curl -fsS6 --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
[[ -n "$SERVER_IP4$SERVER_IP6" ]] || warn "无法获取本机公网 IP，将跳过解析校验。"

# ---------------------------------------------------------------- 第 1 步 协议
hr
echo "${BD}  第 1 步 · 选择协议${N}"
echo
echo "  1) AnyTLS + Hysteria2   ${D}（推荐，TCP/UDP 双保险）${N}"
echo "  2) 仅 AnyTLS"
echo "  3) 仅 Hysteria2"
echo
while :; do
  if [[ -z "$PROTOS" ]]; then
    read -r -p "  选择 [默认 1]: " P || true
    case "${P:-1}" in 1) PROTOS=both ;; 2) PROTOS=anytls ;; 3) PROTOS=hy2 ;; *) PROTOS="" ;; esac
  fi
  case "$PROTOS" in
    both)   ANYTLS_ENABLE=1; HY2_ENABLE=1; break ;;
    anytls) ANYTLS_ENABLE=1; HY2_ENABLE=0; break ;;
    hy2)    ANYTLS_ENABLE=0; HY2_ENABLE=1; break ;;
    *) warn "请输入 1、2 或 3。"; PROTOS=""
       [[ "$NONINTERACTIVE" == "1" ]] && die "PROTOS 取值非法（both|anytls|hy2）。" ;;
  esac
done

# ---------------------------------------------------------------- 第 2 步 基本信息
hr
echo "${BD}  第 2 步 · 基本信息${N}"
echo

while :; do
  [[ -n "$DOMAIN" ]] || read -r -p "  域名（已解析到本机，Cloudflare 需灰云）: " DOMAIN || true
  DOMAIN=${DOMAIN// /}
  if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?)+$ ]]; then
    warn "域名格式不正确，请重新输入。"; DOMAIN=""
    [[ "$NONINTERACTIVE" == "1" ]] && die "DOMAIN 非法。"
    continue
  fi
  RES4=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1 || true)
  RES6=$(dig +short AAAA "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1 || true)
  if [[ -z "$RES4$RES6" ]]; then
    warn "$DOMAIN 没有解析到任何 A/AAAA 记录。"
    confirm "仍要继续？" n || { DOMAIN=""; continue; }
  elif [[ -n "$SERVER_IP4$SERVER_IP6" && "$RES4" != "$SERVER_IP4" && "$RES6" != "$SERVER_IP6" ]]; then
    warn "解析结果（${RES4:-$RES6}）与本机 IP（${SERVER_IP4:-$SERVER_IP6}）不一致。"
    warn "常见原因：Cloudflare 开着橙云代理（Hysteria2 走 UDP，橙云必然不通），或解析未生效。"
    confirm "仍要继续？" n || { DOMAIN=""; continue; }
  else
    ok "解析校验通过 → ${RES4:-$RES6}"
  fi
  break
done

while :; do
  [[ -n "$EMAIL" ]] || read -r -p "  邮箱（证书到期提醒，回车随机生成）: " EMAIL || true
  if [[ -z "$EMAIL" ]]; then
    EMAIL="$(openssl rand -hex 6)@${DOMAIN#*.}"; info "使用随机邮箱：$EMAIL"; break
  fi
  [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
  warn "邮箱格式不正确。"; EMAIL=""
  [[ "$NONINTERACTIVE" == "1" ]] && die "EMAIL 非法。"
done

[[ -n "$NODE_PREFIX" ]] || { read -r -p "  节点名前缀 [默认 $DOMAIN]: " NODE_PREFIX || true; NODE_PREFIX=${NODE_PREFIX:-$DOMAIN}; }

# ---------------------------------------------------------------- 第 3 步 端口密码
hr
echo "${BD}  第 3 步 · 端口与密码${N}"
echo "${D}  AnyTLS 占 TCP、Hysteria2 占 UDP，端口号相同也不冲突${N}"
echo

if [[ "$ANYTLS_ENABLE" == "1" ]]; then ask_anytls; fi
if [[ "$HY2_ENABLE" == "1" ]]; then ask_hy2; fi

# ---------------------------------------------------------------- 第 4 步 证书
hr
echo "${BD}  第 4 步 · 证书方式${N}"
echo
echo "  1) HTTP-01  ${D}acme.sh standalone，需要 80 端口临时可用（推荐）${N}"
echo "  2) DNS-01   ${D}Cloudflare API Token，80 被封或被占时用这个${N}"
echo "  3) 已有证书 ${D}手动指定 fullchain / key 路径${N}"
echo
while :; do
  [[ -n "$CERT_MODE" ]] || { read -r -p "  选择 [默认 1]: " CERT_MODE || true; CERT_MODE=${CERT_MODE:-1}; }
  [[ "$CERT_MODE" =~ ^[123]$ ]] && break
  warn "请输入 1、2 或 3。"; CERT_MODE=""
  [[ "$NONINTERACTIVE" == "1" ]] && die "CERT_MODE 非法。"
done

if [[ "$CERT_MODE" == "2" && -z "$CF_Token" ]]; then
  read -r -s -p "  Cloudflare API Token（Zone:Read + DNS:Edit）: " CF_Token || true; echo
  [[ -n "$CF_Token" ]] || die "未提供 Token。"
fi

if [[ "$CERT_MODE" == "3" ]]; then
  [[ -n "$CERT_FILE" ]] || read -r -p "  证书 fullchain 路径: " CERT_FILE || true
  [[ -n "$KEY_FILE"  ]] || read -r -p "  私钥 key 路径: " KEY_FILE || true
  [[ -s "$CERT_FILE" ]] || die "证书文件不存在或为空：$CERT_FILE"
  [[ -s "$KEY_FILE"  ]] || die "私钥文件不存在或为空：$KEY_FILE"
else
  CERT_FILE="$CERT_DIR/cert.pem"
  KEY_FILE="$CERT_DIR/private.key"
fi

if [[ "$CERT_MODE" == "1" && "$ANYTLS_ENABLE" == "1" && "$ANYTLS_PORT" == "80" ]]; then
  die "AnyTLS 选了 80 端口，会与 HTTP-01 验证冲突。请改端口或改用 DNS-01。"
fi

# ---------------------------------------------------------------- 第 5 步 内核调优
if [[ -z "$ENABLE_TUNE" ]]; then
  if confirm "开启 BBR + fq，并放大 UDP 缓冲区（Hysteria2 跑满带宽的必要条件）？" y; then ENABLE_TUNE=1; else ENABLE_TUNE=0; fi
fi

# ---------------------------------------------------------------- 确认
hr
echo "${BD}  确认配置${N}"
echo
printf "  %-12s %s\n" "域名" "$DOMAIN"
printf "  %-12s %s\n" "邮箱" "$EMAIL"
[[ "$ANYTLS_ENABLE" == "1" ]] && printf "  %-12s %s\n" "AnyTLS" "TCP $ANYTLS_PORT ／ $ANYTLS_PASSWORD"
[[ "$HY2_ENABLE" == "1" ]]    && printf "  %-12s %s\n" "Hysteria2" "UDP $HY2_PORT ／ $HY2_PASSWORD${HY2_OBFS:+ ／ obfs 已开}"
[[ "$HY2_ENABLE" == "1" ]]    && printf "  %-12s %s\n" "流控" "$([[ $HY2_CC == brutal ]] && echo 'Brutal（客户端声明）' || { [[ $HY2_CC == limit ]] && echo "Brutal 封顶 ${HY2_UP}/${HY2_DOWN} Mbps" || echo '强制 BBR'; })"
printf "  %-12s %s\n" "证书" "$([[ $CERT_MODE == 1 ]] && echo HTTP-01 || { [[ $CERT_MODE == 2 ]] && echo 'DNS-01 (Cloudflare)' || echo '已有证书'; })"
printf "  %-12s %s\n" "内核调优" "$([[ $ENABLE_TUNE == 1 ]] && echo 开启 || echo 跳过)"
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

SB_VER=$(sing-box version 2>/dev/null | head -n1 | grep -oP '\d+(\.\d+)+' | head -n1 || true)
if [[ -n "$SB_VER" ]] && ! ver_ge "$SB_VER" "1.12.0"; then
  die "sing-box 版本过低（$SB_VER），AnyTLS 需要 1.12 及以上。"
fi

# ---------------------------------------------------------------- 防火墙
info "放行端口…"
[[ "$ANYTLS_ENABLE" == "1" ]] && fw_allow "$ANYTLS_PORT" tcp
[[ "$HY2_ENABLE" == "1" ]]    && fw_allow "$HY2_PORT" udp
[[ "$CERT_MODE" == "1" ]]     && fw_allow 80 tcp
warn "别忘了在云厂商安全组放行：$([[ $ANYTLS_ENABLE == 1 ]] && echo "TCP $ANYTLS_PORT ")$([[ $HY2_ENABLE == 1 ]] && echo "UDP $HY2_PORT")"

# ---------------------------------------------------------------- 证书
if [[ "$CERT_MODE" != "3" ]]; then
  install -d -m 755 "$CERT_DIR"
  if ! ( [[ -x "$ACME" ]] && "$ACME" --version >/dev/null 2>&1 ); then
    info "安装 acme.sh…"
    rm -rf "$HOME/.acme.sh"
    curl -fsSL https://get.acme.sh -o /tmp/get-acme.sh || die "无法下载 acme.sh 安装脚本。"
    if [[ "$ACME_NOCRON" == "1" ]]; then
      sh /tmp/get-acme.sh --nocron email="$EMAIL" || true
    else
      sh /tmp/get-acme.sh email="$EMAIL" || true
    fi
    rm -f /tmp/get-acme.sh
    [[ -x "$ACME" ]] || die "acme.sh 安装失败，原因见上方 acme.sh 的输出。"
  fi
  "$ACME" --set-default-ca --server letsencrypt >/dev/null

  # 同域名已有 30 天以上有效期的证书就别再签了，免得撞 Let's Encrypt 速率限制
  if [[ -s "$CERT_FILE" ]] && openssl x509 -in "$CERT_FILE" -noout -checkend 2592000 >/dev/null 2>&1 \
     && openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -qF "$DOMAIN"; then
    ok "检测到 $DOMAIN 的有效证书，跳过签发，仅刷新续期钩子。"
    SKIP_ISSUE=1
  else
    SKIP_ISSUE=0
  fi

  if [[ "$SKIP_ISSUE" == "1" ]]; then
    :
  elif [[ "$CERT_MODE" == "1" ]]; then
    HOLDER80=$(port_holder tcp 80)
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
    CF_Token="$CF_Token" "$ACME" --issue -d "$DOMAIN" --dns dns_cf -k ec-256 \
      || die "证书申请失败。检查 API Token 权限（Zone:Read + DNS:Edit）。"
  fi

  info "安装证书并挂上自动续期钩子…"
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE" \
    --reloadcmd "systemctl restart sing-box" >/dev/null 2>&1 \
    || warn "install-cert 未成功（证书可能不是 acme.sh 签的），沿用现有证书文件。"
  fix_perms "$CERT_FILE" "$KEY_FILE"

  if [[ "$ACME_NOCRON" == "1" ]]; then
    info "配置证书自动续期 timer…"
    cat > /etc/systemd/system/acme-renew.service <<EOF
[Unit]
Description=Renew ACME certificates (acme.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ACME --cron --home $HOME/.acme.sh
EOF
    cat > /etc/systemd/system/acme-renew.timer <<'EOF'
[Unit]
Description=Daily ACME certificate renewal

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now acme-renew.timer >/dev/null 2>&1 || warn "acme-renew.timer 启用失败，请手动检查。"
    ok "证书就绪（acme-renew.timer 每日检查）"
  else
    ok "证书就绪（acme.sh crontab 每日检查）"
  fi
else
  fix_perms "$CERT_FILE" "$KEY_FILE"
fi

# ---------------------------------------------------------------- 内核调优
[[ "$ENABLE_TUNE" == "1" ]] && tune_kernel

# ---------------------------------------------------------------- 写配置并启动
info "生成 $CONF_FILE …"
build_config
save_state
build_info
write_cli
info "启动服务…"
restart_sb

clear
cat "$INFO_FILE"
echo
echo "  ${BD}二维码${N}"
while IFS='|' read -r tag link; do
  echo; echo "  [$tag]"
  qrencode -t ANSIUTF8 <<<"$link" || true
done < "$LINK_FILE"
echo
ok "全部完成。${BD}sbx info${N} 查看信息，${BD}sbx qr hy2${N} 单独出码，${BD}sbx menu${N} 增删协议。"

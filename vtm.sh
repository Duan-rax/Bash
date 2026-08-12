#!/usr/bin/env bash
# =============================================================================
#  vtm — VPS Traffic Monitor
#  流量监控 · 超额自动停用服务(不关机) · 新周期自动恢复
#
#  一键安装 / 交互菜单:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Duan-rax/Bash/main/vtm.sh)
#
#  非交互 (给 cron 用):
#    vtm check | status | restore | limit | history | doctor | update
# =============================================================================
set -uo pipefail

VERSION="4.1"
REPO_RAW="https://raw.githubusercontent.com/Duan-rax/Bash/main"
BIN_PATH="/usr/local/bin/vtm"
CONF_FILE="${VTM_CONF:-/etc/vtm.conf}"
STATE_DIR="/var/lib/vtm"
STATE_FILE="$STATE_DIR/state"
HIST_FILE="$STATE_DIR/history.csv"
LOG_FILE="/var/log/vtm.log"
LOCK_FILE="/var/lock/vtm.lock"
CRON_FILE="/etc/cron.d/vtm"

# ------------------------------- 默认配置 ------------------------------------
# 这些只是初值，真正的配置存在 $CONF_FILE，用菜单里的「配置向导」生成
IFACE="auto"
EXCLUDE_IFACE_RE='^(lo|docker.*|veth.*|br-.*|virbr.*|wg[0-9]*|CloudflareWARP|wgcf.*|warp.*|zt.*|tun[0-9]*|tap[0-9]*|sit[0-9]*|ip6tnl.*|ifb[0-9]*|dummy[0-9]*|gre.*|erspan.*|teql[0-9]*|nlmon[0-9]*)$'
DATA_SOURCE="auto"
COUNT_MODE="TX"
LIMIT="1000"
LIMIT_UNIT="GB"
LIMIT_MARGIN_PCT=10
RESET_DAY=1
RESET_HOUR=0
WARN_PERCENTS="50,80,90,95"
LIMIT_ACTIONS="notify,service"
SERVICES=""
SERVICE_STOP_MODE="disable"
DOCKERS=""
CUSTOM_LIMIT_CMD=""
CUSTOM_RESTORE_CMD=""
KEEP_SSH_PORT="22"
SHUTDOWN_DELAY_MIN=1
AUTO_RESTORE=1
TG_BOT_TOKEN=""
TG_CHAT_ID=""
CHECK_INTERVAL_MIN=5
HOSTNAME_TAG="$(hostname 2>/dev/null || echo vps)"
DRY_RUN="${DRY_RUN:-0}"
LOG_KEEP_LINES=2000

CONF_KEYS=(IFACE DATA_SOURCE COUNT_MODE LIMIT LIMIT_UNIT LIMIT_MARGIN_PCT
           RESET_DAY RESET_HOUR WARN_PERCENTS LIMIT_ACTIONS SERVICES
           SERVICE_STOP_MODE DOCKERS CUSTOM_LIMIT_CMD CUSTOM_RESTORE_CMD
           KEEP_SSH_PORT SHUTDOWN_DELAY_MIN AUTO_RESTORE TG_BOT_TOKEN
           TG_CHAT_ID CHECK_INTERVAL_MIN HOSTNAME_TAG EXCLUDE_IFACE_RE)

[[ -f "$CONF_FILE" ]] && . "$CONF_FILE"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null

# ------------------------------- 输出 ----------------------------------------
if [[ -t 1 ]]; then
  C0=$'\e[0m'; CB=$'\e[1m'; CD=$'\e[2m'
  CR=$'\e[31m'; CG=$'\e[32m'; CY=$'\e[33m'; CC=$'\e[36m'
else
  C0=""; CB=""; CD=""; CR=""; CG=""; CY=""; CC=""
fi
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
run() { if (( DRY_RUN )); then log "DRY-RUN: $*"; return 0; fi; "$@" >>"$LOG_FILE" 2>&1; }
die() { log "ERROR: $*"; exit 1; }
ok()   { echo "${CG}✓${C0} $*"; }
warn() { echo "${CY}!${C0} $*"; }
err()  { echo "${CR}✗${C0} $*"; }

# ------------------------------- 依赖 ----------------------------------------
PM=""; PM_INSTALL=""; PM_UPDATE=""
detect_pm() {
  if   command -v apt-get >/dev/null 2>&1; then PM=apt;    PM_UPDATE="apt-get update -qq"; PM_INSTALL="apt-get install -y -qq"
  elif command -v dnf     >/dev/null 2>&1; then PM=dnf;    PM_UPDATE="";                   PM_INSTALL="dnf install -y -q"
  elif command -v yum     >/dev/null 2>&1; then PM=yum;    PM_UPDATE="";                   PM_INSTALL="yum install -y -q"
  elif command -v apk     >/dev/null 2>&1; then PM=apk;    PM_UPDATE="apk update -q";      PM_INSTALL="apk add --no-cache -q"
  elif command -v pacman  >/dev/null 2>&1; then PM=pacman; PM_UPDATE="";                   PM_INSTALL="pacman -S --noconfirm --needed"
  elif command -v zypper  >/dev/null 2>&1; then PM=zypper; PM_UPDATE="";                   PM_INSTALL="zypper -q install -y"
  else PM=""; fi
}
# 依赖表: 命令|包名(apt/dnf/yum)|包名(apk)|包名(pacman)|是否必需
dep_pkg() {   # $1=命令名 -> 当前发行版的包名
  case "$1" in
    curl)    echo curl ;;
    awk)     [[ $PM == apk ]] && echo gawk || echo gawk ;;
    ip)      case "$PM" in apt|apk) echo iproute2 ;; pacman) echo iproute2 ;; *) echo iproute ;; esac ;;
    flock)   echo util-linux ;;
    vnstat)  echo vnstat ;;
    python3) [[ $PM == pacman ]] && echo python || echo python3 ;;
    *)       echo "$1" ;;
  esac
}
missing_deps() {   # 回显 "必需: a b | 可选: c d"
  local req="" opt="" c
  for c in curl awk ip flock; do command -v "$c" >/dev/null 2>&1 || req+="$c "; done
  for c in vnstat python3;    do command -v "$c" >/dev/null 2>&1 || opt+="$c "; done
  echo "${req% }|${opt% }"
}
pkg_install() {
  [[ -z "$PM" ]] && { err "无法识别包管理器，请手动安装: $*"; return 1; }
  local pkgs=() c
  for c in "$@"; do pkgs+=("$(dep_pkg "$c")"); done
  echo "  ${CD}执行: $PM_INSTALL ${pkgs[*]}${C0}"
  [[ -n "$PM_UPDATE" ]] && $PM_UPDATE >/dev/null 2>&1
  # shellcheck disable=SC2086
  if $PM_INSTALL "${pkgs[@]}" >>"$LOG_FILE" 2>&1; then ok "已安装: ${pkgs[*]}"; return 0
  else err "安装失败，详见 $LOG_FILE"; return 1; fi
}
post_install_vnstat() {
  command -v vnstat >/dev/null 2>&1 || return
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now vnstat >>"$LOG_FILE" 2>&1 || systemctl enable --now vnstatd >>"$LOG_FILE" 2>&1
  else
    rc-update add vnstatd default >/dev/null 2>&1; rc-service vnstatd start >/dev/null 2>&1
  fi
  fix_vnstat_quiet
  warn "vnstat 刚装好，数据库从现在才开始记录，本计费周期之前的流量它不知道"
  warn "所以本周期内 vtm 会低估用量，下个周期起才准确 —— 期间建议把安全余量调大些"
}
fix_vnstat_quiet() {
  [[ -f /etc/vnstat.conf ]] || return
  if grep -qiE '^\s*;?\s*DailyDays' /etc/vnstat.conf; then
    sed -i -E 's/^\s*;?\s*DailyDays.*/DailyDays 62/I' /etc/vnstat.conf
  else echo "DailyDays 62" >> /etc/vnstat.conf; fi
  systemctl restart vnstat 2>/dev/null || systemctl restart vnstatd 2>/dev/null || service vnstat restart 2>/dev/null
}
ensure_deps() {   # $1=auto(不问直接装必需项) | ask(交互询问)
  detect_pm
  local m req opt
  m="$(missing_deps)"; req="${m%%|*}"; opt="${m##*|}"
  [[ -z "$req$opt" ]] && return 0
  echo
  [[ -n "$req" ]] && err "缺少必需依赖: $req"
  [[ -n "$opt" ]] && warn "缺少可选依赖: $opt  ${CD}(vnstat+python3 能让统计跨重启不丢数，强烈建议装)${C0}"
  if [[ -n "$PM" ]]; then echo "  ${CD}检测到包管理器: $PM${C0}"; else err "未识别包管理器，请手动安装"; return 1; fi
  local want=""
  if [[ "$1" == auto ]]; then
    want="$req"
  else
    [[ -n "$req" ]] && ask_yn "安装必需依赖 ($req)？" y && want="$req"
    [[ -n "$opt" ]] && ask_yn "安装可选依赖 ($opt)？" y && want="$want $opt"
  fi
  want="$(echo "$want" | xargs)"
  [[ -z "$want" ]] && return 0
  # shellcheck disable=SC2086
  pkg_install $want || return 1
  [[ " $want " == *" vnstat "* ]] && post_install_vnstat
  return 0
}

# ------------------------------- 自举 ----------------------------------------
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
bootstrap() {
  # 通过 bash <(curl ...) 运行时没有真实文件路径，先落盘再 exec
  if [[ ! -f "$SELF" || "$SELF" == /dev/fd/* || "$SELF" == /proc/* || "$SELF" == pipe:* ]]; then
    echo "${CC}正在安装 vtm 到 $BIN_PATH ...${C0}"
    curl -fsSL "$REPO_RAW/vtm.sh" -o "$BIN_PATH.tmp" || die "下载失败，检查网络或仓库地址"
    bash -n "$BIN_PATH.tmp" || die "下载的脚本语法异常"
    mv "$BIN_PATH.tmp" "$BIN_PATH"; chmod 755 "$BIN_PATH"
    ok "已安装：$BIN_PATH"
    exec "$BIN_PATH" "$@"
  fi
}

# ------------------------------- 单位 ----------------------------------------
to_bytes() {
  awk -v v="$1" -v u="$2" 'BEGIN{
    u=toupper(u)
    m["B"]=1;m["KB"]=1000;m["MB"]=1000^2;m["GB"]=1000^3;m["TB"]=1000^4
    m["KIB"]=1024;m["MIB"]=1024^2;m["GIB"]=1024^3;m["TIB"]=1024^4
    if(!(u in m)) exit 1
    printf "%.0f", v*m[u]
  }'
}
human() {
  awk -v b="$1" 'BEGIN{
    s[0]="B";s[1]="KiB";s[2]="MiB";s[3]="GiB";s[4]="TiB";i=0
    while(b>=1024&&i<4){b/=1024;i++}
    printf "%.2f %s", b, s[i]
  }'
}

# ------------------------------- 网卡 ----------------------------------------
default_iface() {
  local i
  i=$(ip -4 route show default 2>/dev/null | awk '/default/{for(k=1;k<=NF;k++)if($k=="dev"){print $(k+1);exit}}')
  [[ -z "$i" ]] && i=$(ip -6 route show default 2>/dev/null | awk '/default/{for(k=1;k<=NF;k++)if($k=="dev"){print $(k+1);exit}}')
  echo "$i"
}
all_ifaces() {
  sed 's/:/ /' /proc/net/dev | awk 'NR>2{print $1}' | while read -r n; do
    [[ "$n" =~ $EXCLUDE_IFACE_RE ]] || echo "$n"
  done
}
vnstat_ifaces() {
  vnstat --json 2>/dev/null | grep -o '"name":"[^"]*"' | sed 's/.*:"//;s/"$//' | while read -r n; do
    [[ "$n" =~ $EXCLUDE_IFACE_RE ]] || echo "$n"
  done
}
resolve_ifaces() {
  local list out="" n
  case "$IFACE" in
    auto)   list="$(default_iface)"; [[ -z "$list" ]] && list="$(all_ifaces)" ;;
    all)    list="$(all_ifaces)" ;;
    vnstat) list="$(vnstat_ifaces)"; [[ -z "$list" ]] && list="$(all_ifaces)" ;;
    *)      list="$IFACE" ;;
  esac
  for n in $list; do [[ -d "/sys/class/net/$n" ]] && out+="$n "; done
  echo "${out% }"
}

# ------------------------------- 周期 ----------------------------------------
_cycle_start_for_month() {
  local ym="$1" dim dd
  dim=$(date -d "${ym}-01 +1 month -1 day" +%-d)
  dd=$RESET_DAY; (( dd > dim )) && dd=$dim
  printf '%s-%02d' "$ym" "$dd"
}
current_cycle_id() {
  (( RESET_DAY == 0 )) && { echo "forever"; return; }
  local s ts
  s=$(_cycle_start_for_month "$(date +%Y-%m)")
  ts=$(date -d "$s $(printf '%02d' "$RESET_HOUR"):00:00" +%s)
  if (( $(date +%s) >= ts )); then echo "$s"
  else _cycle_start_for_month "$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)"; fi
}
next_cycle_desc() {
  (( RESET_DAY == 0 )) && { echo "不重置"; return; }
  local cur ym
  cur=$(current_cycle_id); ym=$(date -d "${cur%-*}-01 +1 month" +%Y-%m)
  echo "$(_cycle_start_for_month "$ym") $(printf '%02d' "$RESET_HOUR"):00"
}

# ------------------------------- 状态 ----------------------------------------
CYCLE=""; NOTIFIED=""; LIMITED=0; DYNKEYS=""
ACC_RX=0; ACC_TX=0; IFACES=""; SRC=""
load_state() { [[ -f "$STATE_FILE" ]] && . "$STATE_FILE"; : ; }
save_state() {
  { echo "CYCLE=\"$CYCLE\""; echo "NOTIFIED=\"$NOTIFIED\""
    echo "LIMITED=$LIMITED"; echo "DYNKEYS=\"$DYNKEYS\""
    local k v
    for k in $DYNKEYS; do
      for v in "L_${k}_RX" "L_${k}_TX" "A_${k}_RX" "A_${k}_TX"; do echo "$v=${!v:-0}"; done
    done
  } > "$STATE_FILE"
}
sanitize() { echo "$1" | tr -c 'A-Za-z0-9' '_'; }

# ------------------------------- 采集 ----------------------------------------
have_vnstat() {
  command -v vnstat >/dev/null 2>&1 || return 1
  vnstat --version 2>/dev/null | grep -qE 'vnStat 2\.' || return 1
  command -v python3 >/dev/null 2>&1 || return 1
}
vnstat_usage() {
  local json; json=$(vnstat --json d 2>/dev/null) || return 1
  [[ -z "$json" ]] && return 1
  printf '%s' "$json" | python3 -c '
import sys, json, datetime
try: data = json.load(sys.stdin)
except Exception: sys.exit(1)
want = set(sys.argv[1].split())
y, m, d = map(int, sys.argv[2].split("-"))
start = datetime.date(y, m, d)
rx = tx = 0; short = []
for i in data.get("interfaces", []):
    name = i.get("name")
    if want and name not in want: continue
    days = i.get("traffic", {}).get("day", [])
    if not days: continue
    oldest = None
    for e in days:
        dt = e["date"]
        cur = datetime.date(dt["year"], dt["month"], dt.get("day", 1))
        if oldest is None or cur < oldest: oldest = cur
        if cur >= start:
            rx += e.get("rx", 0); tx += e.get("tx", 0)
    if oldest is not None and oldest > start: short.append(name)
print(rx, tx, ("SHORT:" + ",".join(short)) if short else "OK")
' "$1" "$2"
}
proc_usage() {
  local n rx tx line key lrx ltx arx atx d
  ACC_RX=0; ACC_TX=0
  for n in $1; do
    line=$(sed 's/:/ /' /proc/net/dev | awk -v i="$n" '$1==i{print $2" "$10}')
    [[ -z "$line" ]] && continue
    read -r rx tx <<<"$line"
    key=$(sanitize "$n")
    [[ " $DYNKEYS " == *" $key "* ]] || DYNKEYS+=" $key"
    eval "lrx=\${L_${key}_RX:-0}; ltx=\${L_${key}_TX:-0}"
    eval "arx=\${A_${key}_RX:-0}; atx=\${A_${key}_TX:-0}"
    if (( rx >= lrx )); then d=$(( rx - lrx )); else d=$rx; log "网卡 $n RX 计数器已重置"; fi
    arx=$(( arx + d ))
    if (( tx >= ltx )); then d=$(( tx - ltx )); else d=$tx; log "网卡 $n TX 计数器已重置"; fi
    atx=$(( atx + d ))
    eval "L_${key}_RX=$rx; L_${key}_TX=$tx; A_${key}_RX=$arx; A_${key}_TX=$atx"
    ACC_RX=$(( ACC_RX + arx )); ACC_TX=$(( ACC_TX + atx ))
  done
  DYNKEYS="${DYNKEYS# }"
}
proc_reset_accum() { local k; for k in $DYNKEYS; do eval "A_${k}_RX=0; A_${k}_TX=0"; done; }

collect() {
  IFACES="$(resolve_ifaces)"
  [[ -z "$IFACES" ]] && die "找不到可用网卡 (IFACE=$IFACE)"
  local cs="$CYCLE"
  [[ "$CYCLE" == "forever" || "$RESET_DAY" == "0" || -z "$CYCLE" ]] && cs="1970-01-01"
  local use=0
  case "$DATA_SOURCE" in
    vnstat) use=1 ;; proc) use=0 ;; auto) have_vnstat && use=1 ;;
  esac
  if (( use )); then
    local out rx tx flag
    out=$(vnstat_usage "$IFACES" "$cs")
    if [[ -n "$out" ]]; then
      read -r rx tx flag <<<"$out"
      ACC_RX=$rx; ACC_TX=$tx; SRC="vnstat"
      [[ "$flag" == SHORT:* ]] && log "WARN: vnstat 保留期未覆盖整个周期 (${flag#SHORT:})，建议菜单里执行『修复 vnstat 保留期』"
      return
    fi
    log "WARN: vnstat 取数失败，回退 /proc/net/dev"
  fi
  SRC="proc"; proc_usage "$IFACES"
}
used_bytes() {
  case "${COUNT_MODE^^}" in
    TX) echo "$ACC_TX" ;; RX) echo "$ACC_RX" ;;
    TOTAL) echo $(( ACC_RX + ACC_TX )) ;;
    MAX) (( ACC_TX > ACC_RX )) && echo "$ACC_TX" || echo "$ACC_RX" ;;
    *) die "COUNT_MODE 非法: $COUNT_MODE" ;;
  esac
}
effective_total() {
  local raw; raw=$(to_bytes "$LIMIT" "$LIMIT_UNIT") || die "LIMIT/LIMIT_UNIT 配置错误"
  awk -v t="$raw" -v m="$LIMIT_MARGIN_PCT" 'BEGIN{printf "%.0f", t*(100-m)/100}'
}
pct_of() { awk -v u="$1" -v t="$2" 'BEGIN{if(t<=0)print 0;else printf "%.1f",u*100/t}'; }

# ------------------------------- 通知 ----------------------------------------
notify() {
  log "NOTIFY: ${1//$'\n'/ | }"
  [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
  curl -s -m 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1
}

# ------------------------------- 动作 ----------------------------------------
unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }
stop_service() {
  local s="$1"
  if command -v systemctl >/dev/null 2>&1 && unit_exists "$s"; then
    run systemctl stop "$s"
    case "$SERVICE_STOP_MODE" in
      disable) run systemctl disable "$s" ;;
      mask)    run systemctl mask --now "$s" ;;
    esac
    log "已停用服务 $s ($SERVICE_STOP_MODE)"
  elif [[ -x "/etc/init.d/$s" ]]; then
    run "/etc/init.d/$s" stop
    [[ "$SERVICE_STOP_MODE" != "stop" ]] && command -v update-rc.d >/dev/null 2>&1 && run update-rc.d "$s" disable
    log "已停用服务 $s (init.d)"
  else log "WARN: 未找到服务 $s"; fi
}
start_service() {
  local s="$1"
  if command -v systemctl >/dev/null 2>&1 && unit_exists "$s"; then
    run systemctl unmask "$s"; run systemctl enable "$s"; run systemctl start "$s"
    log "已恢复服务 $s"
  elif [[ -x "/etc/init.d/$s" ]]; then
    command -v update-rc.d >/dev/null 2>&1 && run update-rc.d "$s" enable
    run "/etc/init.d/$s" start; log "已恢复服务 $s (init.d)"
  fi
}
do_services()   { local s; for s in $SERVICES; do stop_service  "$s"; done; }
undo_services() { local s; for s in $SERVICES; do start_service "$s"; done; }
do_dockers()    { local c; for c in $DOCKERS; do run docker stop  "$c" && log "docker stop $c";  done; }
undo_dockers()  { local c; for c in $DOCKERS; do run docker start "$c" && log "docker start $c"; done; }

do_block() {
  command -v iptables >/dev/null 2>&1 || { log "WARN: 无 iptables"; return; }
  (( DRY_RUN )) && { log "DRY-RUN: 封锁出站"; return; }
  iptables -N VTM_OUT 2>/dev/null; iptables -F VTM_OUT
  iptables -A VTM_OUT -o lo -j RETURN
  local p n
  for p in ${KEEP_SSH_PORT//,/ }; do
    iptables -A VTM_OUT -p tcp --sport "$p" -j RETURN
    iptables -A VTM_OUT -p tcp --dport "$p" -j RETURN
  done
  for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16; do
    iptables -A VTM_OUT -d "$n" -j RETURN
  done
  iptables -A VTM_OUT -j DROP
  iptables -C OUTPUT -j VTM_OUT 2>/dev/null || iptables -I OUTPUT 1 -j VTM_OUT
  log "iptables: 已封锁出站 (放行 SSH $KEEP_SSH_PORT)"
}
undo_block() {
  command -v iptables >/dev/null 2>&1 || return
  (( DRY_RUN )) && { log "DRY-RUN: 解除封锁"; return; }
  while iptables -C OUTPUT -j VTM_OUT 2>/dev/null; do iptables -D OUTPUT -j VTM_OUT; done
  iptables -F VTM_OUT 2>/dev/null; iptables -X VTM_OUT 2>/dev/null
  log "iptables: 已解除封锁"
}
do_shutdown() {
  log "执行关机 (延迟 ${SHUTDOWN_DELAY_MIN} 分钟)"; (( DRY_RUN )) && return; sync
  if (( SHUTDOWN_DELAY_MIN > 0 )); then
    shutdown -h "+${SHUTDOWN_DELAY_MIN}" "流量超额" 2>/dev/null || { sleep $((SHUTDOWN_DELAY_MIN*60)); poweroff; }
  else shutdown -h now "流量超额" 2>/dev/null || poweroff; fi
}
apply_limit_actions() {
  local used="$1" total="$2" pct="$3" a
  local msg="🚨 [$HOSTNAME_TAG] 流量超额
计数: $COUNT_MODE   网卡: $IFACES   来源: $SRC
已用: $(human "$used") / $(human "$total")  (${pct}%)
出站: $(human "$ACC_TX")   入站: $(human "$ACC_RX")
处置: $LIMIT_ACTIONS
服务: ${SERVICES:-无} ($SERVICE_STOP_MODE)
下次重置: $(next_cycle_desc)"
  for a in ${LIMIT_ACTIONS//,/ }; do
    case "$a" in
      notify) notify "$msg" ;; service) do_services ;; docker) do_dockers ;;
      block) do_block ;;
      custom) [[ -n "$CUSTOM_LIMIT_CMD" ]] && { log "custom: $CUSTOM_LIMIT_CMD"; (( DRY_RUN )) || bash -c "$CUSTOM_LIMIT_CMD" >>"$LOG_FILE" 2>&1; } ;;
      shutdown) do_shutdown ;; none|"") ;;
      *) log "WARN: 未知动作 $a" ;;
    esac
  done
}
restore_all() {
  local a
  for a in ${LIMIT_ACTIONS//,/ }; do
    case "$a" in
      service) undo_services ;; docker) undo_dockers ;; block) undo_block ;;
      custom) [[ -n "$CUSTOM_RESTORE_CMD" ]] && { log "restore: $CUSTOM_RESTORE_CMD"; (( DRY_RUN )) || bash -c "$CUSTOM_RESTORE_CMD" >>"$LOG_FILE" 2>&1; } ;;
    esac
  done
  LIMITED=0
}

# ------------------------------- 主检查 --------------------------------------
do_check() {
  load_state
  local cyc; cyc="$(current_cycle_id)"
  if [[ -n "$CYCLE" && "$CYCLE" != "$cyc" ]]; then
    collect
    [[ -f "$HIST_FILE" ]] || echo "cycle,mode,rx_bytes,tx_bytes,billed_bytes,limit_bytes,limited" > "$HIST_FILE"
    echo "$CYCLE,$COUNT_MODE,$ACC_RX,$ACC_TX,$(used_bytes),$(effective_total),$LIMITED" >> "$HIST_FILE"
    log "周期切换: $CYCLE -> $cyc (已归档)"
    NOTIFIED=""; proc_reset_accum; ACC_RX=0; ACC_TX=0
    if (( AUTO_RESTORE )) && (( LIMITED )); then
      restore_all
      notify "✅ [$HOSTNAME_TAG] 新计费周期 $cyc 开始，流量清零，服务已恢复。"
    fi
  fi
  CYCLE="$cyc"
  collect
  local total used pct w
  total=$(effective_total); used=$(used_bytes); pct=$(pct_of "$used" "$total")
  for w in ${WARN_PERCENTS//,/ }; do
    [[ -z "$w" ]] && continue
    if awk -v p="$pct" -v x="$w" 'BEGIN{exit !(p>=x)}' && [[ ",$NOTIFIED," != *",$w,"* ]]; then
      NOTIFIED="${NOTIFIED:+$NOTIFIED,}$w"
      notify "⚠️ [$HOSTNAME_TAG] 流量已用 ${pct}% (阈值 ${w}%)
计数: $COUNT_MODE   网卡: $IFACES   来源: $SRC
已用: $(human "$used") / $(human "$total")
出站: $(human "$ACC_TX")   入站: $(human "$ACC_RX")
下次重置: $(next_cycle_desc)"
    fi
  done
  if awk -v u="$used" -v t="$total" 'BEGIN{exit !(u>=t)}'; then
    if (( LIMITED == 0 )); then
      log "超额: $(human "$used") >= $(human "$total")，执行 $LIMIT_ACTIONS"
      LIMITED=1; save_state
      apply_limit_actions "$used" "$total" "$pct"
    else log "仍处于超额状态 ($(human "$used")/$(human "$total"))"; fi
  fi
  save_state
  log "OK src=$SRC if=[$IFACES] mode=$COUNT_MODE used=$(human "$used")/$(human "$total") (${pct}%) tx=$(human "$ACC_TX") rx=$(human "$ACC_RX") limited=$LIMITED"
  if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > LOG_KEEP_LINES*2 )); then
    tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

do_status() {
  load_state
  [[ -z "$CYCLE" ]] && CYCLE="$(current_cycle_id)"
  collect
  local raw total used pct bar i n
  raw=$(to_bytes "$LIMIT" "$LIMIT_UNIT"); total=$(effective_total)
  used=$(used_bytes); pct=$(pct_of "$used" "$total")
  n=$(awk -v p="$pct" 'BEGIN{n=int(p/5); if(n>20)n=20; if(n<0)n=0; print n}')
  bar=""; i=0
  while (( i<20 )); do (( i<n )) && bar+="█" || bar+="░"; ((i++)); done
  local col=$CG
  awk -v p="$pct" 'BEGIN{exit !(p>=80)}' && col=$CY
  awk -v p="$pct" 'BEGIN{exit !(p>=100)}' && col=$CR
  echo
  echo "  ${CB}vtm v$VERSION${C0}  ${CD}$HOSTNAME_TAG${C0}"
  echo "  ${CD}──────────────────────────────────────────${C0}"
  printf "  数据来源  %s\n" "$SRC"
  printf "  网卡      %s\n" "$IFACES"
  printf "  计数方式  %s  %s\n" "$COUNT_MODE" "${CD}$(mode_desc)${C0}"
  printf "  计费周期  %s   下次重置 %s\n" "$CYCLE" "$(next_cycle_desc)"
  echo "  ${CD}──────────────────────────────────────────${C0}"
  printf "  出站 TX   %s\n" "$(human "$ACC_TX")"
  printf "  入站 RX   %s\n" "$(human "$ACC_RX")"
  printf "  合计      %s\n" "$(human $((ACC_RX+ACC_TX)))"
  echo "  ${CD}──────────────────────────────────────────${C0}"
  printf "  配额      %s   ${CD}安全余量 %s%%${C0}\n" "$(human "$raw")" "$LIMIT_MARGIN_PCT"
  printf "  触发阈值  %s\n" "$(human "$total")"
  printf "  已用      ${col}%s${C0}\n" "$(human "$used")"
  printf "  ${col}[%s] %s%%${C0}\n" "$bar" "$pct"
  printf "  受限状态  %s\n" "$( ((LIMITED)) && echo "${CR}是${C0}" || echo "${CG}否${C0}" )"
  if [[ -n "$SERVICES" ]]; then
    echo "  ${CD}──────────────────────────────────────────${C0}"
    echo "  服务 (active / enabled):"
    local s a e
    for s in $SERVICES; do
      if command -v systemctl >/dev/null 2>&1 && unit_exists "$s"; then
        a=$(systemctl is-active "$s" 2>/dev/null); e=$(systemctl is-enabled "$s" 2>/dev/null)
        [[ "$a" == active ]] && a="${CG}$a${C0}" || a="${CR}$a${C0}"
        printf "    %-20s %s / %s\n" "$s" "$a" "$e"
      else
        printf "    %-20s ${CY}未找到 unit${C0}\n" "$s"
      fi
    done
  fi
  echo
}
mode_desc() {
  case "${COUNT_MODE^^}" in
    TX) echo "(只计出站)" ;; RX) echo "(只计入站)" ;;
    TOTAL) echo "(出站+入站)" ;; MAX) echo "(取较大者)" ;;
  esac
}

do_doctor() {
  detect_pm
  echo
  echo "  ${CB}环境自检${C0}"
  echo "  ${CD}──────────────────────────────────────────${C0}"
  local m req opt
  m="$(missing_deps)"; req="${m%%|*}"; opt="${m##*|}"
  if [[ -z "$req" ]]; then ok "必需依赖齐全 (curl awk ip flock)"
  else err "缺少必需依赖: $req   ${CD}菜单第 15 项可自动安装${C0}"; fi
  [[ -n "$opt" ]] && warn "缺少可选依赖: $opt"
  printf "  包管理器      %s\n" "${PM:-未识别}"
  printf "  默认路由网卡  %s\n" "$(default_iface)"
  printf "  解析出的网卡  %s\n" "$(resolve_ifaces)"
  if have_vnstat; then
    ok "vnstat 可用 ($(vnstat --version 2>/dev/null | head -1 | awk '{print $1,$2}'))"
    printf "  vnstat 监控   %s\n" "$(vnstat_ifaces | tr '\n' ' ')"
    local dd; dd=$(grep -iE '^\s*DailyDays' /etc/vnstat.conf 2>/dev/null | awk '{print $2}')
    if [[ -z "$dd" ]]; then warn "DailyDays 未设置 (默认 30)，31 天的月份会漏 1 天"
    elif (( dd < 62 )); then warn "DailyDays=$dd 偏小，建议 62"
    else ok "DailyDays=$dd"; fi
  else
    warn "vnstat 不可用，将使用 /proc/net/dev（重启期间可能丢少量计数）"
    echo "     ${CD}菜单第 15 项可自动安装 vnstat + python3${C0}"
  fi
  printf "  当前周期      %s   下次重置 %s\n" "$(current_cycle_id)" "$(next_cycle_desc)"
  printf "  配额          %s   阈值 %s\n" "$(human "$(to_bytes "$LIMIT" "$LIMIT_UNIT")")" "$(human "$(effective_total)")"
  local s
  for s in $SERVICES; do
    if command -v systemctl >/dev/null 2>&1 && unit_exists "$s"; then ok "服务 $s 存在"
    else err "服务 $s 未找到 unit"; fi
  done
  [[ -f "$CRON_FILE" ]] && ok "定时任务已安装 (每 ${CHECK_INTERVAL_MIN} 分钟)" || warn "定时任务未安装"
  [[ -f "$CONF_FILE" ]] && ok "配置文件 $CONF_FILE" || warn "尚未生成配置文件，请先跑配置向导"
  echo
}

do_history() {
  if [[ ! -f "$HIST_FILE" ]]; then echo "暂无历史记录（第一个计费周期结束后才会产生）"; return; fi
  echo
  printf "  %-12s %-6s %12s %12s %12s %8s\n" 周期 计数 入站 出站 计费用量 是否超额
  echo "  ${CD}──────────────────────────────────────────────────────────────${C0}"
  tail -n +2 "$HIST_FILE" | while IFS=, read -r c m rx tx bill lim lm; do
    printf "  %-12s %-6s %12s %12s %12s %8s\n" "$c" "$m" "$(human "$rx")" "$(human "$tx")" "$(human "$bill")" "$( [[ "$lm" == 1 ]] && echo 是 || echo 否 )"
  done
  echo
}

install_cron() {
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/$CHECK_INTERVAL_MIN * * * * root $BIN_PATH check >/dev/null 2>&1
@reboot root sleep 90 && $BIN_PATH check >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"
  ok "定时任务已安装：每 $CHECK_INTERVAL_MIN 分钟检查一次"
}

do_update() {
  echo "从 $REPO_RAW 拉取最新版本 ..."
  local tmp; tmp=$(mktemp)
  if ! curl -fsSL "$REPO_RAW/vtm.sh" -o "$tmp"; then err "下载失败"; rm -f "$tmp"; return 1; fi
  if ! bash -n "$tmp"; then err "新版本语法检查未通过，已放弃"; rm -f "$tmp"; return 1; fi
  local new; new=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
  if [[ "$new" == "$VERSION" ]]; then ok "已是最新版本 ($VERSION)"; rm -f "$tmp"; return 0; fi
  install -m 755 "$tmp" "$BIN_PATH"; rm -f "$tmp"
  ok "已更新：$VERSION → $new  (配置文件未改动)"
}

do_uninstall() {
  echo "${CY}将要删除：${C0}"
  echo "  $BIN_PATH"
  echo "  $CRON_FILE"
  echo "  $STATE_DIR  (含历史记录)"
  echo "  $CONF_FILE"
  echo "  $LOG_FILE"
  read -rp "确认卸载？(输入 yes) " a
  [[ "$a" != "yes" ]] && { echo "已取消"; return; }
  load_state
  if (( LIMITED )); then echo "检测到服务处于受限状态，先恢复 ..."; restore_all; fi
  rm -f "$CRON_FILE" "$CONF_FILE" "$LOG_FILE"; rm -rf "$STATE_DIR"; rm -f "$BIN_PATH"
  ok "已卸载"
  exit 0
}

fix_vnstat() {
  command -v vnstat >/dev/null 2>&1 || { err "未安装 vnstat"; return; }
  if grep -qiE '^\s*;?\s*DailyDays' /etc/vnstat.conf 2>/dev/null; then
    sed -i -E 's/^\s*;?\s*DailyDays.*/DailyDays 62/I' /etc/vnstat.conf
  else
    echo "DailyDays 62" >> /etc/vnstat.conf
  fi
  systemctl restart vnstat 2>/dev/null || service vnstat restart 2>/dev/null
  ok "DailyDays 已设为 62，vnstat 已重启"
  grep -iE '^\s*DailyDays' /etc/vnstat.conf
}

# ============================= 交互部分 ======================================
need_tty() { [[ -t 0 ]] || die "当前不是交互终端。请用: bash <(curl -fsSL $REPO_RAW/vtm.sh)"; }
ask() {  # $1=提示 $2=默认值  -> 回显到 stdout
  local p="$1" d="${2:-}" v
  if [[ -n "$d" ]]; then read -rp "  $p [${CC}$d${C0}]: " v; else read -rp "  $p: " v; fi
  echo "${v:-$d}"
}
ask_yn() {  # $1=提示 $2=y/n默认
  local p="$1" d="${2:-y}" v
  read -rp "  $p ($( [[ $d == y ]] && echo 'Y/n' || echo 'y/N' )): " v
  v="${v:-$d}"; [[ "${v,,}" == y* ]]
}
ask_choice() {  # $1=提示  之后为 "值|说明" 列表 -> 回显选中的值
  local p="$1"; shift
  local -a vals=() descs=()
  local it
  for it in "$@"; do vals+=("${it%%|*}"); descs+=("${it#*|}"); done
  echo "  $p" >&2
  local i
  for i in "${!vals[@]}"; do printf "    ${CB}%d)${C0} %-8s %s\n" "$((i+1))" "${vals[$i]}" "${CD}${descs[$i]}${C0}" >&2; done
  local n
  while :; do
    read -rp "  选择 [1-${#vals[@]}] (默认 1): " n
    n="${n:-1}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#vals[@]} )) && break
    echo "  ${CR}输入无效${C0}" >&2
  done
  echo "${vals[$((n-1))]}"
}

detect_services() {   # 列出常见代理/下载服务里实际存在的 unit
  local cands=(xray sing-box hysteria hysteria2 v2ray trojan trojan-go tuic
               shadowsocks-libev ss-server snell-server naiveproxy brook gost realm
               aria2 aria2c qbittorrent-nox transmission-daemon rclone emby-server jellyfin)
  local s out=""
  for s in "${cands[@]}"; do
    command -v systemctl >/dev/null 2>&1 && systemctl cat "$s" >/dev/null 2>&1 && out+="$s "
  done
  echo "${out% }"
}

pick_services() {
  local found; found="$(detect_services)"
  if [[ -z "$found" ]]; then
    echo "  ${CY}未自动识别到常见服务${C0}" >&2
    ask "手动输入服务名（空格分隔，可留空）" "$SERVICES"
    return
  fi
  local -a arr=($found) sel=()
  local i
  for i in "${!arr[@]}"; do
    if [[ " $SERVICES " == *" ${arr[$i]} "* ]]; then sel[$i]=1; else sel[$i]=0; fi
  done
  while :; do
    echo >&2
    echo "  ${CB}选择超额时要停用的服务${C0}  ${CD}(输入序号切换，回车确认)${C0}" >&2
    for i in "${!arr[@]}"; do
      printf "    ${CB}%2d)${C0} [%s] %s\n" "$((i+1))" "$( [[ ${sel[$i]} == 1 ]] && echo "${CG}x${C0}" || echo ' ' )" "${arr[$i]}" >&2
    done
    printf "    ${CB} m)${C0} 手动输入其它服务名\n" >&2
    local n
    read -rp "  > " n
    [[ -z "$n" ]] && break
    if [[ "$n" == m ]]; then
      local extra; read -rp "  额外服务名(空格分隔): " extra
      local e
      for e in $extra; do arr+=("$e"); sel+=(1); done
      continue
    fi
    local x
    for x in $n; do
      [[ "$x" =~ ^[0-9]+$ ]] || continue
      (( x>=1 && x<=${#arr[@]} )) || continue
      sel[$((x-1))]=$(( 1 - sel[$((x-1))] ))
    done
  done
  local out=""
  for i in "${!arr[@]}"; do [[ ${sel[$i]} == 1 ]] && out+="${arr[$i]} "; done
  echo "${out% }"
}

save_conf() {
  local k v
  { echo "# vtm 配置文件  —— 由配置向导生成，可手工编辑后重跑 vtm check"
    echo "# 生成时间: $(date '+%F %T')"
    for k in "${CONF_KEYS[@]}"; do
      v="${!k}"
      printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}"
    done
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  ok "配置已保存到 $CONF_FILE"
}

wizard() {
  need_tty
  echo
  echo "  ${CB}════ vtm 配置向导 ════${C0}"

  # 0 依赖
  ensure_deps ask

  echo

  # 1 网卡
  local di; di="$(default_iface)"
  echo "  ${CB}[1/8] 网卡${C0}"
  [[ -n "$di" ]] && echo "  ${CD}检测到默认路由网卡: $di${C0}"
  IFACE=$(ask_choice "统计哪块网卡的流量？" \
    "auto|默认路由网卡 (推荐${di:+，当前为 $di})" \
    "all|所有物理网卡合计" \
    "vnstat|vnstat 正在监控的网卡" \
    "manual|手动指定")
  [[ "$IFACE" == manual ]] && IFACE=$(ask "网卡名（空格分隔多个）" "$di")
  echo

  # 2 计数方式
  echo "  ${CB}[2/8] 计费方式${C0}"
  COUNT_MODE=$(ask_choice "你的服务商按什么计费？" \
    "TX|只计出站 — AWS / GCP / Oracle / Azure" \
    "TOTAL|出站+入站 — Vultr / DO / 搬瓦工 / RackNerd" \
    "RX|只计入站（少见）" \
    "MAX|取出站入站较大者（少见）")
  echo

  # 3 配额
  echo "  ${CB}[3/8] 配额${C0}"
  LIMIT=$(ask "每月配额数值" "$LIMIT")
  LIMIT_UNIT=$(ask_choice "单位" \
    "GB|1000 进制，商家标称通常是这个" \
    "GiB|1024 进制" "TB|1000 进制" "TiB|1024 进制")
  echo "  ${CD}安全余量: guest 内的统计和商家账单会有几个百分点出入，留点余量更稳${C0}"
  LIMIT_MARGIN_PCT=$(ask "安全余量 %（0-50）" "$LIMIT_MARGIN_PCT")
  echo "  → 实际触发阈值 ${CC}$(human "$(effective_total)")${C0}"
  echo

  # 4 周期
  echo "  ${CB}[4/8] 计费周期${C0}"
  RESET_DAY=$(ask "每月几号重置（1-31，0=永不重置）" "$RESET_DAY")
  RESET_HOUR=$(ask "重置的小时（0-23，按服务器本地时区）" "$RESET_HOUR")
  echo "  → 当前周期 ${CC}$(current_cycle_id)${C0}，下次重置 ${CC}$(next_cycle_desc)${C0}"
  echo

  # 5 服务
  echo "  ${CB}[5/8] 超额时停用哪些服务${C0}"
  SERVICES=$(pick_services)
  echo "  已选: ${CC}${SERVICES:-（无）}${C0}"
  SERVICE_STOP_MODE=$(ask_choice "停用方式" \
    "disable|stop + disable，重启后也不会自己起来（推荐）" \
    "stop|只 stop，重启可能自动恢复" \
    "mask|stop + mask，最彻底")
  if command -v docker >/dev/null 2>&1; then
    DOCKERS=$(ask "另外要停止的 docker 容器（空格分隔，可留空）" "$DOCKERS")
  fi
  echo

  # 6 动作
  echo "  ${CB}[6/8] 超额处置${C0}"
  local acts="notify"
  [[ -n "$SERVICES$DOCKERS" ]] && acts="notify,service"
  [[ -n "$DOCKERS" ]] && acts="$acts,docker"
  if ask_yn "超额后是否额外用 iptables 封锁出站（SSH 仍可登录）？" n; then
    acts="$acts,block"
    KEEP_SSH_PORT=$(ask "需要放行的 SSH 端口（逗号分隔）" "$KEEP_SSH_PORT")
  fi
  if ask_yn "超额后关机？${CR}需要登服务商后台才能开回来${C0}" n; then
    acts="$acts,shutdown"
  fi
  LIMIT_ACTIONS="$acts"
  echo "  → 处置顺序: ${CC}$LIMIT_ACTIONS${C0}"
  AUTO_RESTORE=$( ask_yn "新计费周期自动恢复服务？" y && echo 1 || echo 0 )
  echo

  # 7 通知
  echo "  ${CB}[7/8] Telegram 通知${C0}  ${CD}（留空跳过，只写日志）${C0}"
  TG_BOT_TOKEN=$(ask "Bot Token" "$TG_BOT_TOKEN")
  if [[ -n "$TG_BOT_TOKEN" ]]; then
    TG_CHAT_ID=$(ask "Chat ID" "$TG_CHAT_ID")
    WARN_PERCENTS=$(ask "分级告警百分比（逗号分隔）" "$WARN_PERCENTS")
  fi
  HOSTNAME_TAG=$(ask "通知里显示的机器名" "$HOSTNAME_TAG")
  echo

  # 8 定时
  echo "  ${CB}[8/8] 定时检查${C0}"
  CHECK_INTERVAL_MIN=$(ask "每隔几分钟检查一次" "$CHECK_INTERVAL_MIN")
  echo

  save_conf
  install_cron
  if have_vnstat; then
    local dd; dd=$(grep -iE '^\s*DailyDays' /etc/vnstat.conf 2>/dev/null | awk '{print $2}')
    if [[ ! "$dd" =~ ^[0-9]+$ ]] || (( dd < 62 )); then
      ask_yn "vnstat 日志保留期偏短（31 天的月份会漏 1 天），设为 62 天？" y && fix_vnstat
    fi
  fi
  if [[ -n "$TG_BOT_TOKEN$TG_CHAT_ID" ]] && ask_yn "发一条测试通知？" y; then
    notify "🔔 [$HOSTNAME_TAG] vtm 配置完成，监控已启动。"
  fi
  echo
  ok "配置完成"
  do_status
}

edit_one() {
  need_tty
  local -a keys=(IFACE COUNT_MODE LIMIT LIMIT_UNIT LIMIT_MARGIN_PCT RESET_DAY RESET_HOUR
                 SERVICES SERVICE_STOP_MODE DOCKERS LIMIT_ACTIONS WARN_PERCENTS
                 AUTO_RESTORE TG_BOT_TOKEN TG_CHAT_ID CHECK_INTERVAL_MIN
                 DATA_SOURCE KEEP_SSH_PORT CUSTOM_LIMIT_CMD CUSTOM_RESTORE_CMD HOSTNAME_TAG)
  local -a desc=("网卡 auto/all/vnstat/网卡名" "计数方式 TX/RX/TOTAL/MAX" "配额数值" "配额单位"
                 "安全余量 %" "每月重置日 0-31" "重置小时 0-23"
                 "停用的服务" "停用方式 stop/disable/mask" "停止的容器"
                 "超额动作 notify,service,docker,block,custom,shutdown" "告警百分比"
                 "新周期自动恢复 1/0" "TG Bot Token" "TG Chat ID" "检查间隔(分钟)"
                 "数据源 auto/vnstat/proc" "放行的 SSH 端口" "超额自定义命令" "恢复自定义命令" "通知显示的机器名")
  while :; do
    echo
    echo "  ${CB}修改配置项${C0}"
    local i
    for i in "${!keys[@]}"; do
      printf "    ${CB}%2d)${C0} %-20s ${CD}%-45s${C0} = ${CC}%s${C0}\n" \
        "$((i+1))" "${keys[$i]}" "${desc[$i]}" "${!keys[$i]}"
    done
    printf "    ${CB} 0)${C0} 返回\n"
    local n; read -rp "  > " n
    [[ -z "$n" || "$n" == 0 ]] && break
    [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#keys[@]} )) || { echo "  ${CR}无效${C0}"; continue; }
    local k="${keys[$((n-1))]}" v
    case "$k" in
      SERVICES)          v=$(pick_services) ;;
      COUNT_MODE)        v=$(ask_choice "计数方式" "TX|只计出站" "TOTAL|出站+入站" "RX|只计入站" "MAX|取较大者") ;;
      SERVICE_STOP_MODE) v=$(ask_choice "停用方式" "disable|stop+disable" "stop|只 stop" "mask|stop+mask") ;;
      DATA_SOURCE)       v=$(ask_choice "数据源" "auto|优先 vnstat" "vnstat|强制 vnstat" "proc|强制 /proc") ;;
      LIMIT_UNIT)        v=$(ask_choice "单位" "GB|1000进制" "GiB|1024进制" "TB|1000进制" "TiB|1024进制") ;;
      *)                 v=$(ask "$k" "${!k}") ;;
    esac
    printf -v "$k" '%s' "$v"
    save_conf
    [[ "$k" == CHECK_INTERVAL_MIN ]] && install_cron
    ok "$k = $v"
  done
}

menu() {
  need_tty
  while :; do
    load_state
    local hint=""
    if [[ -f "$CONF_FILE" ]]; then
      (( LIMITED )) && hint="${CR}● 服务受限中${C0}" || hint="${CG}● 正常${C0}"
      [[ -f "$CRON_FILE" ]] || hint="$hint  ${CY}(定时任务未安装)${C0}"
    else
      hint="${CY}● 尚未配置，请先选 1${C0}"
    fi
    echo
    echo "  ${CB}╭─ vtm  VPS 流量监控  v$VERSION ─────────────${C0}"
    echo "  ${CB}│${C0}  $hint"
    echo "  ${CB}╰────────────────────────────────────────${C0}"
    echo "    ${CB}1)${C0} 配置向导 ${CD}(首次使用 / 重新设置)${C0}"
    echo "    ${CB}2)${C0} 查看状态"
    echo "    ${CB}3)${C0} 修改单项配置"
    echo "    ${CB}4)${C0} 立即执行一次检查"
    echo "    ${CB}5)${C0} 恢复服务 / 解除限制"
    echo "    ${CB}6)${C0} 演练超额动作 ${CD}(DRY-RUN，不真执行)${C0}"
    echo "    ${CB}7)${C0} 历史周期用量"
    echo "    ${CB}8)${C0} 查看日志"
    echo "    ${CB}9)${C0} 环境自检"
    echo "   ${CB}10)${C0} 定时任务 安装 / 卸载"
    echo "   ${CB}11)${C0} 测试 Telegram 通知"
    echo "   ${CB}12)${C0} 修复 vnstat 保留期"
    echo "   ${CB}13)${C0} 更新脚本"
    echo "   ${CB}14)${C0} 卸载 vtm"
    echo "   ${CB}15)${C0} 检查并安装依赖 ${CD}(vnstat / python3 等)${C0}"
    echo "    ${CB}0)${C0} 退出"
    local c; read -rp "  > " c
    case "$c" in
      1) wizard ;;
      2) do_status ;;
      3) edit_one ;;
      4) do_check; ok "检查完成，详见日志" ;;
      5) load_state; restore_all; save_state; ok "已恢复服务并解除限制" ;;
      6) load_state; [[ -z "$CYCLE" ]] && CYCLE="$(current_cycle_id)"; collect
         echo "  ${CD}以下动作只打印不执行：${C0}"
         DRY_RUN=1 apply_limit_actions "$(used_bytes)" "$(effective_total)" "$(pct_of "$(used_bytes)" "$(effective_total)")"
         ok "演练结束" ;;
      7) do_history ;;
      8) [[ -f "$LOG_FILE" ]] && tail -n 40 "$LOG_FILE" || echo "暂无日志" ;;
      9) do_doctor ;;
      10) if [[ -f "$CRON_FILE" ]]; then
            ask_yn "定时任务已安装，是否卸载？" n && { rm -f "$CRON_FILE"; ok "已卸载定时任务"; }
          else install_cron; fi ;;
      11) if [[ -z "$TG_BOT_TOKEN$TG_CHAT_ID" ]]; then err "尚未配置 Telegram"
          else notify "🔔 [$HOSTNAME_TAG] vtm 测试通知"; ok "已发送"; fi ;;
      12) fix_vnstat ;;
      13) do_update ;;
      14) do_uninstall ;;
      15) ensure_deps ask; ok "依赖检查完成" ;;
      0|q|"") echo; exit 0 ;;
      *) err "无效选项" ;;
    esac
  done
}

# ------------------------------- 入口 ----------------------------------------
bootstrap "$@"
[[ $EUID -ne 0 ]] && die "需要 root 权限运行"

case "${1:-menu}" in
  menu|"")     menu ;;
  check)       exec 9>"$LOCK_FILE"; flock -n 9 || exit 0; do_check ;;
  status)      do_status ;;
  doctor)      do_doctor ;;
  history)     do_history ;;
  restore)     load_state; restore_all; save_state; ok "已恢复" ;;
  limit)       load_state; [[ -z "$CYCLE" ]] && CYCLE="$(current_cycle_id)"; collect
               LIMITED=1; save_state
               _u=$(used_bytes); _t=$(effective_total)
               apply_limit_actions "$_u" "$_t" "$(pct_of "$_u" "$_t")"; ok "已执行限制动作" ;;
  reset)       load_state; proc_reset_accum; NOTIFIED=""; LIMITED=0; save_state; ok "已清零告警与受限标记" ;;
  wizard)      wizard ;;
  deps)        ensure_deps "${2:-auto}" ;;
  update)      do_update ;;
  uninstall)   do_uninstall ;;
  version|-v)  echo "vtm $VERSION" ;;
  *)           sed -n '2,12p' "$SELF"; exit 1 ;;
esac

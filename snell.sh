#!/bin/sh
# shellcheck disable=SC3043 # local is supported by dash/ash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH
umask 077

APP="snell-server"
SNELL_DIR="/etc/snell"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF="/etc/snell/config.conf"
SNELL_VERSION="/etc/snell/ver.txt"
SNELL_MARKER="/etc/snell/.user-created"
SYSTEMD_UNIT="/etc/systemd/system/snell-server.service"
SYSTEMD_LINK="/etc/systemd/system/multi-user.target.wants/snell-server.service"
OPENRC_INIT="/etc/init.d/snell-server"
PID_FILE="/run/snell-server.pid"
LOG_FILE="/var/log/snell-server.log"
RELEASE_PAGE="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
DOWNLOAD_BASE="https://dl.nssurge.com/snell"

C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"; C_RESET="\033[0m"
rt_os=""; rt_arch=""; rt_backend=""; rt_artifacts=false; rt_installed=false; rt_config_valid=false; rt_running=false; rt_enabled=false; rt_version=""; rt_protocol=""; deps_ready=false
release_html=""; release_version=""; release_v5=""; release_v6=""; artifact_url=""; version_cmp=0
panel_major=""; panel_latest=""; panel_retry=0
cfg_listen=""; cfg_port=""; cfg_version=""; cfg_psk=""; cfg_ipv6=false; cfg_obfs=off; cfg_host=""; cfg_tfo=true; cfg_dns_pref=""; cfg_mode=""; cfg_egress=""
tx_dir=""; tx_cfg=""; tx_mode=""; tx_was_running=false; tx_was_enabled=false; tx_had_service=false; tx_had_version=false; tx_account_created=false

ui_clear(){ [ -z "${TERM:-}" ] || clear 2>/dev/null || true; }
ui_clear_line(){ [ -t 1 ] && printf '\r\033[K'; }
ui_ok(){ ui_clear_line; printf '%b✓%b %s\n' "$C_GREEN" "$C_RESET" "$1"; }
ui_warn(){ ui_clear_line; printf '%b!%b %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
ui_error(){ ui_clear_line; printf '%b✗%b %s\n' "$C_RED" "$C_RESET" "$1"; return 1; }
ui_read(){
    ui_clear_line
    [ -z "$1" ] || printf '> %s' "$1"
    [ -n "$1" ] || printf '> '
    IFS= read -r REPLY || { printf '\n'; exit 0; }
}
ui_pause(){ printf '\n'; ui_read "回车返回"; }
ui_confirm(){
    local prompt="$1" default="${2:-n}"
    ui_read "$prompt"; REPLY="${REPLY:-$default}"
    case "$REPLY" in [Yy]) return 0 ;; [Nn]) return 1 ;; *) ui_error "请输入 y 或 n"; return 1 ;; esac
}

ui_progress(){
    local percent="$1" label="$2" cols=80 width=20 filled empty bar max_label label_len
    if [ -t 1 ]; then
        cols="${COLUMNS:-}"
        [ -n "$cols" ] || cols=$(stty size 2>/dev/null | awk '{print $2}')
        [ -n "$cols" ] || cols=$(tput cols 2>/dev/null || printf '80')
        case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
        max_label=$(( (cols - 12) / 2 )); [ "$max_label" -lt 2 ] && max_label=2
        label=$(printf '%s' "$label" | awk -v n="$max_label" '{print substr($0,1,n)}')
        label_len=$(printf '%s' "$label" | wc -m)
        width=$((cols - label_len * 2 - 9))
        [ "$width" -lt 4 ] && width=4
        [ "$width" -gt 20 ] && width=20
    fi
    [ "$percent" -lt 0 ] && percent=0; [ "$percent" -gt 100 ] && percent=100
    if [ "$percent" -eq 100 ]; then
        ui_clear_line
        return 0
    fi
    filled=$((percent * width / 100)); empty=$((width - filled))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar="${bar}$(printf '%*s' "$empty" '' | tr ' ' '-')"
    if [ -t 1 ]; then
        printf '\r\033[K[%s] %3s%% %s' "$bar" "$percent" "$label"
    else
        printf '[%3s%%] %s\n' "$percent" "$2"
    fi
}


platform_init(){
    [ "$(id -u)" = 0 ] || { ui_error "需要 Root 权限，请使用 sudo -i"; exit 1; }
    if [ -f /etc/alpine-release ]; then rt_os=alpine
    elif [ -f /etc/debian_version ]; then rt_os=debian
    else ui_error "仅支持 Debian 与 Alpine"; exit 1
    fi

    case "$(uname -m)" in
        i386|i686) rt_arch=i386 ;;
        armv6l) rt_arch=armv7l; ui_warn "armv6 将尝试使用 armv7l 构建，不保证可运行" ;;
        armv7l|armv7*) rt_arch=armv7l ;;
        aarch64|armv8*) rt_arch=aarch64 ;;
        x86_64|amd64) rt_arch=amd64 ;;
        *) ui_error "不支持的架构：$(uname -m)"; exit 1 ;;
    esac

    if command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then rt_backend=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then rt_backend=openrc
    else ui_error "未找到可用的 systemd 或 OpenRC"; exit 1
    fi
}

ensure_dependencies(){
    [ "$deps_ready" = true ] && return 0
    ui_progress 8 "检查依赖"
    if [ "$rt_os" = alpine ]; then
        if ! apk add --no-cache curl unzip file tzdata gcompat upx iproute2 >/dev/null 2>&1; then
            if apk add --no-cache curl unzip file tzdata gcompat iproute2 >/dev/null 2>&1; then
                ui_warn "upx 不可用：不影响 v6；v5 安装/更新时需先 apk add upx"
            else
                ui_error "依赖安装失败"; return 1
            fi
        fi
        ui_progress 15 "依赖就绪"
        deps_ready=true
        return 0
    fi
    local packages=""
    command -v curl >/dev/null 2>&1 || packages="$packages curl"
    command -v unzip >/dev/null 2>&1 || packages="$packages unzip"
    command -v file >/dev/null 2>&1 || packages="$packages file"
    command -v ss >/dev/null 2>&1 || packages="$packages iproute2"
    [ -f /etc/ssl/certs/ca-certificates.crt ] || packages="$packages ca-certificates"
    if [ -n "$packages" ]; then
        # shellcheck disable=SC2086
        if ! apt-get update >/dev/null 2>&1 || ! apt-get install -y $packages >/dev/null 2>&1; then ui_error "依赖安装失败"; return 1; fi
    fi
    ui_progress 15 "依赖就绪"
    deps_ready=true
}

artifacts_exist(){
    [ -e "$SNELL_BIN" ] || [ -e "$SNELL_DIR" ] || [ -e "$SYSTEMD_UNIT" ] || [ -L "$SYSTEMD_UNIT" ] || \
    [ -e "$SYSTEMD_LINK" ] || [ -L "$SYSTEMD_LINK" ] || [ -e "$OPENRC_INIT" ]
}

installed_version(){
    local value
    value=$(sed 's/^v//' "$SNELL_VERSION" 2>/dev/null)
    printf '%s' "$value" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([A-Za-z]+[0-9]*)?$' || return 1
    printf '%s\n' "$value"
}

config_protocol(){
    awk -F= '
        /^[[:space:]]*\[/ { active=($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
        active && tolower($1) ~ /^[[:space:]]*version[[:space:]]*$/ { v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
    ' "$SNELL_CONF" 2>/dev/null
}

service_status(){
    rt_running=false
    case "$rt_backend" in
        systemd)
            [ -f "$SYSTEMD_UNIT" ] || return 1
            systemctl is-active snell-server.service >/dev/null 2>&1 && rt_running=true
            ;;
        openrc)
            [ -f "$OPENRC_INIT" ] || return 1
            rc-service snell-server status >/dev/null 2>&1 && rt_running=true
            ;;
    esac
    return 0
}

service_enabled(){
    rt_enabled=false
    case "$rt_backend" in
        systemd) systemctl is-enabled snell-server.service >/dev/null 2>&1 && rt_enabled=true ;;
        openrc) rc-update show default 2>/dev/null | grep -q '^[[:space:]]*snell-server[[:space:]]' && rt_enabled=true ;;
    esac
}

service_exists(){
    if [ "$rt_backend" = systemd ]; then [ -f "$SYSTEMD_UNIT" ]; else [ -f "$OPENRC_INIT" ]; fi
}

service_ctl(){
    case "$rt_backend" in
        systemd) systemctl "$1" snell-server.service >/dev/null 2>&1 ;;
        openrc) rc-service snell-server "$1" >/dev/null 2>&1 ;;
    esac
}

service_set_enabled(){
    case "$1:$rt_backend" in
        true:systemd) systemctl enable snell-server.service >/dev/null 2>&1 ;;
        false:systemd) systemctl disable snell-server.service >/dev/null 2>&1 ;;
        true:openrc) rc-update add snell-server default >/dev/null 2>&1 ;;
        false:openrc) rc-update del snell-server default >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

service_wait(){
    local i=0
    while [ "$i" -lt 10 ]; do
        sleep 1
        service_status && [ "$rt_running" = true ] && return 0
        i=$((i + 1))
    done
    return 1
}

service_log(){
    case "$rt_backend" in
        systemd) if command -v journalctl >/dev/null 2>&1; then journalctl -u snell-server -n 20 --no-pager; else systemctl status snell-server.service; fi ;;
        openrc) tail -n 20 "$LOG_FILE" 2>/dev/null || rc-service snell-server status ;;
    esac
}

service_pid(){
    case "$rt_backend" in
        systemd) systemctl show -p MainPID --value snell-server.service 2>/dev/null ;;
        openrc) cat "$PID_FILE" 2>/dev/null ;;
    esac
}

runtime_refresh(){
    rt_artifacts=false; rt_running=false; rt_enabled=false; rt_version=""; rt_protocol=""
    artifacts_exist && rt_artifacts=true
    if [ -x "$SNELL_BIN" ] && [ -f "$SNELL_CONF" ]; then
        rt_version=$(installed_version 2>/dev/null) || true
        rt_protocol=$(config_protocol)
        service_status || true
        service_enabled
    fi
}

state_refresh(){
    runtime_refresh
    rt_installed=false; rt_config_valid=false
    if [ -x "$SNELL_BIN" ] && [ -f "$SNELL_CONF" ] && config_load >/dev/null 2>&1; then
        rt_config_valid=true; rt_installed=true
    fi
}

require_installed(){
    state_refresh
    [ "$rt_installed" = true ] || { ui_error "请先安装 Snell Server"; return 1; }
    config_load || return 1
}

stop_orphans(){
    local proc pid cmd pids="" alive i=0
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        cmd=$(tr '\0' ' ' < "$proc" 2>/dev/null)
        case "$cmd" in
            *"$SNELL_BIN"*"$SNELL_CONF"*) pid=${proc#/proc/}; pid=${pid%/cmdline}; kill "$pid" 2>/dev/null && pids="$pids $pid" ;;
        esac
    done
    while [ "$i" -lt 5 ]; do
        alive=""
        for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
        [ -z "$alive" ] && return 0
        pids="$alive"; sleep 1; i=$((i + 1))
    done
    for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 1
    for pid in $pids; do kill -0 "$pid" 2>/dev/null && return 1; done
}

account_create(){
    local group_exists=false
    grep -q "^${APP}:" /etc/group && group_exists=true
    if id "$APP" >/dev/null 2>&1; then
        [ -f "$SNELL_MARKER" ] && [ "$(id -gn "$APP" 2>/dev/null)" = "$APP" ] && return 0
        ui_error "系统已存在非本脚本创建的 ${APP} 用户"
        return 1
    fi
    if [ "$group_exists" = true ] && [ ! -f "$SNELL_MARKER" ]; then ui_error "系统已存在非本脚本创建的 ${APP} 组"; return 1; fi

    if [ "$rt_os" = debian ]; then
        [ "$group_exists" = true ] || groupadd --system "$APP" >/dev/null 2>&1 || return 1
        useradd --system --gid "$APP" --no-create-home --shell /usr/sbin/nologin "$APP" >/dev/null 2>&1 || {
            [ "$group_exists" = true ] || groupdel "$APP" >/dev/null 2>&1
            return 1
        }
    else
        [ "$group_exists" = true ] || addgroup -S "$APP" >/dev/null 2>&1 || return 1
        adduser -S -D -H -s /sbin/nologin -G "$APP" "$APP" >/dev/null 2>&1 || {
            [ "$group_exists" = true ] || delgroup "$APP" >/dev/null 2>&1
            return 1
        }
    fi
    mkdir -p "$SNELL_DIR" || return 1
    chown "root:${APP}" "$SNELL_DIR" || return 1
    chmod 0750 "$SNELL_DIR" || return 1
    touch "$SNELL_MARKER" || { account_remove_force; return 1; }
}

account_remove_force(){
    if id "$APP" >/dev/null 2>&1; then
        if [ "$rt_os" = debian ]; then userdel "$APP" >/dev/null 2>&1 || return 1; else deluser "$APP" >/dev/null 2>&1 || return 1; fi
    fi
    if grep -q "^${APP}:" /etc/group; then
        if [ "$rt_os" = debian ]; then groupdel "$APP" >/dev/null 2>&1 || return 1; else delgroup "$APP" >/dev/null 2>&1 || return 1; fi
    fi
}

account_remove(){ [ -f "$SNELL_MARKER" ] || return 0; account_remove_force; }

service_install(){
    local tmp
    if [ "$rt_backend" = systemd ]; then
        tmp=$(mktemp "${SYSTEMD_UNIT}.new.XXXXXX") || return 1
        cat >"$tmp" <<'EOF'
[Unit]
Description=Snell Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snell-server
Group=snell-server
ExecStart=/usr/local/bin/snell-server -c /etc/snell/config.conf
Restart=on-failure
RestartSec=5s
LimitNOFILE=32767
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RemoveIPC=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
EOF
        if [ -n "$cfg_egress" ]; then
            printf 'AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN\nCapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN\n' >>"$tmp"
        fi
        cat >>"$tmp" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
        if ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$SYSTEMD_UNIT"; then rm -f "$tmp"; return 1; fi
        systemctl daemon-reload >/dev/null 2>&1 && systemctl enable snell-server.service >/dev/null 2>&1
        return
    fi

    tmp=$(mktemp "${OPENRC_INIT}.new.XXXXXX") || return 1
    cat >"$tmp" <<'EOF'
#!/sbin/openrc-run
name="snell-server"
description="Snell Server"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/config.conf"
command_user="snell-server:snell-server"
command_background=true
pidfile="/run/snell-server.pid"
output_log="/var/log/snell-server.log"
error_log="/var/log/snell-server.log"
EOF
    if [ -n "$cfg_egress" ]; then printf 'capabilities="^cap_net_raw,^cap_net_admin"\n' >>"$tmp"; fi
    cat >>"$tmp" <<'EOF'

start_pre() {
    checkpath --file --mode 0640 --owner snell-server:snell-server "$output_log"
}

depend() {
    need net
}
EOF
    if ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$OPENRC_INIT"; then rm -f "$tmp"; return 1; fi
    rc-update add snell-server default >/dev/null 2>&1
}

service_remove(){
    service_set_enabled false >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT" "$SYSTEMD_LINK" "$OPENRC_INIT"
    [ "$rt_backend" != systemd ] || systemctl daemon-reload >/dev/null 2>&1 || true
}

service_managed(){
    local managed=false
    case "$rt_backend" in
        systemd)
            if [ -f "$SYSTEMD_UNIT" ] && grep -qx 'User=snell-server' "$SYSTEMD_UNIT" && \
               grep -qx 'ExecStart=/usr/local/bin/snell-server -c /etc/snell/config.conf' "$SYSTEMD_UNIT" && \
               grep -qx 'NoNewPrivileges=true' "$SYSTEMD_UNIT"; then managed=true; fi
            if [ -n "$cfg_egress" ]; then grep -qx 'AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN' "$SYSTEMD_UNIT" || managed=false
            elif grep -q '^AmbientCapabilities=' "$SYSTEMD_UNIT" 2>/dev/null; then managed=false
            fi
            ;;
        openrc)
            if [ -f "$OPENRC_INIT" ] && grep -qx 'command="/usr/local/bin/snell-server"' "$OPENRC_INIT" && \
               grep -qx 'command_user="snell-server:snell-server"' "$OPENRC_INIT"; then managed=true; fi
            if [ -n "$cfg_egress" ]; then grep -qx 'capabilities="\^cap_net_raw,\^cap_net_admin"' "$OPENRC_INIT" || managed=false
            elif grep -q '^capabilities=' "$OPENRC_INIT" 2>/dev/null; then managed=false
            fi
            ;;
    esac
    [ "$managed" = true ]
}

installation_reconcile(){
    state_refresh
    [ "$rt_installed" = true ] || return 0
    [ "$rt_config_valid" = true ] || { ui_error "现有 Snell 配置无效，拒绝自动修改"; return 1; }
    local dir_ok=false
    [ "$(stat -c %U:%G:%a "$SNELL_DIR" 2>/dev/null)" = "root:${APP}:750" ] && dir_ok=true
    if [ "$dir_ok" = true ] && [ "$(stat -c %U:%G:%a "$SNELL_CONF" 2>/dev/null)" = "root:${APP}:640" ] && service_managed; then return 0; fi
    account_create || return 1
    transaction_apply reconcile
}

version_compare(){
    local a b base_a base_b suffix_a suffix_b label_a label_b num_a num_b first
    a=$(printf '%s' "$1" | sed 's/^v//'); b=$(printf '%s' "$2" | sed 's/^v//'); version_cmp=0
    [ "$a" = "$b" ] && return 0
    base_a=$(printf '%s' "$a" | sed 's/[A-Za-z].*$//'); base_b=$(printf '%s' "$b" | sed 's/[A-Za-z].*$//')
    suffix_a=${a#"$base_a"}; suffix_b=${b#"$base_b"}
    if [ "$base_a" != "$base_b" ]; then
        first=$(printf '%s\n' "$base_a" "$base_b" | sort -V | head -1)
        if [ "$first" = "$base_a" ]; then version_cmp=-1; else version_cmp=1; fi
        return 0
    fi
    [ -z "$suffix_a" ] && { version_cmp=1; return 0; }
    [ -z "$suffix_b" ] && { version_cmp=-1; return 0; }
    label_a=$(printf '%s' "$suffix_a" | sed 's/[0-9]*$//' | tr '[:upper:]' '[:lower:]')
    label_b=$(printf '%s' "$suffix_b" | sed 's/[0-9]*$//' | tr '[:upper:]' '[:lower:]')
    if [ "$label_a" != "$label_b" ]; then
        first=$(printf '%s\n' "$label_a" "$label_b" | LC_ALL=C sort | head -1)
        if [ "$first" = "$label_a" ]; then version_cmp=-1; else version_cmp=1; fi
        return 0
    fi
    case "$suffix_a" in *[0-9]) num_a=${suffix_a##*[!0-9]} ;; *) num_a=0 ;; esac
    case "$suffix_b" in *[0-9]) num_b=${suffix_b##*[!0-9]} ;; *) num_b=0 ;; esac
    [ "$num_a" -lt "$num_b" ] && version_cmp=-1
    [ "$num_a" -gt "$num_b" ] && version_cmp=1
    return 0
}

artifact_url_for(){
    local version="$1"
    [ "$rt_arch" = armv7l ] && [ "${version%%.*}" = 6 ] && return 1
    artifact_url="${DOWNLOAD_BASE}/snell-server-v${version}-linux-${rt_arch}.zip"
}

release_latest(){
    local major="$1" pattern candidates latest v
    case "$major" in
        5) [ -z "$release_v5" ] || { release_version="$release_v5"; return 0; }; pattern='snell-server-v5\.[0-9]+\.[0-9]+[A-Za-z]*[0-9]*-linux' ;;
        6) [ -z "$release_v6" ] || { release_version="$release_v6"; return 0; }; pattern='snell-server-v6\.[0-9]+\.[0-9]+[A-Za-z]*[0-9]*-linux' ;;
        *) return 1 ;;
    esac
    [ "$rt_arch" = armv7l ] && [ "$major" = 6 ] && return 1
    [ -n "$release_html" ] || release_html=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 10 "$RELEASE_PAGE" 2>/dev/null)
    [ -n "$release_html" ] || return 1
    candidates=$(printf '%s' "$release_html" | grep -oE "$pattern" | sed 's/snell-server-v//;s/-linux//' | sort -u)
    while [ -n "$candidates" ]; do
        latest=""
        for v in $candidates; do
            if [ -z "$latest" ]; then latest="$v"; else version_compare "$v" "$latest"; [ "$version_cmp" -gt 0 ] && latest="$v"; fi
        done
        [ -n "$latest" ] || return 1
        artifact_url_for "$latest" || return 1
        if curl -fsSIL --proto '=https' --tlsv1.2 --max-time 10 "$artifact_url" 2>/dev/null | grep -q '^HTTP/.* 200'; then
            release_version="$latest"
            if [ "$major" = 5 ]; then release_v5="$latest"; else release_v6="$latest"; fi
            return 0
        fi
        candidates=$(printf '%s\n' "$candidates" | grep -Fvx "$latest")
    done
    return 1
}

resolve_release(){
    ensure_dependencies || return 1
    ui_progress 18 "查询 Surge 官方版本"
    release_latest "$1" || { ui_error "无法从 Surge 官方发布页获取 v$1 可下载版本"; return 1; }
}

artifact_fetch(){
    local version="$1" target="$2" work archive extract entries size binary kind
    artifact_url_for "$version" || { ui_error "Surge 未提供 Snell v${version%%.*} 的 Linux ${rt_arch} 构建"; return 1; }
    work=$(dirname "$target"); archive="$work/package.zip"; extract="$work/unpack"
    rm -rf "$archive" "$extract"; mkdir -p "$extract" || return 1
    ui_progress 25 "下载 Snell v${version}"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 --max-time 60 --max-filesize 52428800 \
        -o "$archive" "$artifact_url" >/dev/null 2>&1; then
        return 1
    fi
    ui_progress 55 "校验下载包"
    entries=$(unzip -Z1 "$archive" 2>/dev/null)
    size=$(unzip -l "$archive" 2>/dev/null | awk '$4=="snell-server"{print $1;exit}')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$entries" = snell-server ] || { ui_error "下载包结构无效"; return 1; }
    if [ "$size" -le 0 ] || [ "$size" -gt 52428800 ]; then ui_error "下载包解压大小异常"; return 1; fi
    if ! unzip -oq "$archive" -d "$extract" >/dev/null 2>&1; then ui_error "Snell Server 解压失败"; return 1; fi
    ui_progress 65 "校验二进制"
    binary="$extract/snell-server"
    if [ ! -f "$binary" ] || [ -L "$binary" ]; then ui_error "下载包内容无效"; return 1; fi
    kind=$(file -b "$binary" 2>/dev/null)
    if [ "$rt_os" = alpine ]; then
        if printf '%s' "$kind" | grep -qi 'UPX'; then
            command -v upx >/dev/null 2>&1 || { ui_error "下载包为 UPX 压缩，请先安装 upx（apk add upx）"; return 1; }
            if ! upx -d -o "$extract/server.raw" "$binary" >/dev/null 2>&1 || ! mv -f "$extract/server.raw" "$binary"; then ui_error "Snell Server UPX 解包失败"; return 1; fi
            kind=$(file -b "$binary" 2>/dev/null)
        fi
    fi
    case "$rt_arch:$kind" in
        amd64:*ELF*x86-64*|i386:*ELF*80386*|aarch64:*ELF*aarch64*|armv7l:*ELF*ARM*) ;;
        *) ui_error "下载的二进制类型或架构不匹配"; return 1 ;;
    esac
    chown root:root "$binary" 2>/dev/null || true
    chmod 0755 "$binary" || return 1
    "$binary" -v >/dev/null 2>&1 || { ui_error "下载的二进制无法在当前系统运行"; return 1; }
    mv -f "$binary" "$target" || return 1
    rm -rf "$archive" "$extract"
    ui_progress 70 "制品验证完成"
}

config_reset(){
    cfg_version="${1:-5}"; cfg_port=8443; cfg_listen="[::]:8443"; cfg_psk=""; cfg_ipv6=false; cfg_obfs=off; cfg_host=""; cfg_tfo=true
    cfg_dns_pref=default; cfg_mode=default; cfg_egress=""
}

config_validate(){
    case "$cfg_version" in 5|6) ;; *) ui_error "协议版本无效"; return 1 ;; esac
    if [ -z "$cfg_listen" ] || ! printf '%s\n' "$cfg_listen" | awk -F, '
        { for (i=1; i<=NF; i++) { p=$i; bad=0; for(j=1;j<=length(p);j++){c=substr(p,j,1); if(c !~ /[A-Za-z0-9_.:,]/ && c!="[" && c!="]" && c!="-") bad=1} q=p; sub(/^.*:/, "", q); a=p; sub(/:[^:]*$/, "", a); if(bad || q !~ /^[0-9]+$/ || q + 0 < 1 || q + 0 > 65535 || (a ~ /:/ && a !~ /^\[.*\]$/)) exit 1 } }
    '; then ui_error "监听地址格式无效"; return 1; fi
    if [ ${#cfg_psk} -lt 16 ] || [ ${#cfg_psk} -gt 255 ]; then ui_error "密钥必须为 16-255 位"; return 1; fi
    case "$cfg_psk" in *[!A-Za-z0-9]*) ui_error "密钥仅允许字母和数字"; return 1 ;; esac
    case "$cfg_tfo" in true|false) ;; *) ui_error "TCP Fast Open 配置无效"; return 1 ;; esac
    if [ "$cfg_version" = 5 ]; then
        case "$cfg_ipv6" in true|false) ;; *) ui_error "目标 IPv6 配置无效"; return 1 ;; esac
        case "$cfg_obfs" in off|tls|http) ;; *) ui_error "OBFS 配置无效"; return 1 ;; esac
        if [ "$cfg_obfs" != off ]; then
            if [ -z "$cfg_host" ] || [ ${#cfg_host} -gt 253 ]; then ui_error "OBFS 域名无效"; return 1; fi
            case "$cfg_host" in .*|*..*|*.|-*|*.-*|*-.*|*-|*[!A-Za-z0-9.-]*) ui_error "OBFS 域名无效"; return 1 ;; esac
        fi
    else
        case "$cfg_dns_pref" in default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) ;; *) ui_error "目标地址 DNS IP 偏好无效"; return 1 ;; esac
        case "$cfg_mode" in default|unshaped|unsafe-raw) ;; *) ui_error "Snell v6 模式无效"; return 1 ;; esac
    fi
    if [ -n "$cfg_egress" ]; then
        [ ${#cfg_egress} -le 15 ] || { ui_error "出口网卡名称过长"; return 1; }
        case "$cfg_egress" in *[!A-Za-z0-9_.:-]*) ui_error "出口网卡名称无效"; return 1 ;; esac
    fi
}

config_load(){
    [ -f "$SNELL_CONF" ] || { ui_error "配置文件不存在"; return 1; }
    local parsed key value first
    config_reset 5
    cfg_listen=""; cfg_psk=""; cfg_version=""
    parsed=$(mktemp) || return 1
    chmod 0600 "$parsed" || { rm -f "$parsed"; return 1; }
    awk -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { active=($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
        !active || NF<2 { next }
        { key=$1; value=$0; sub(/^[^=]*=/,"",value); gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); gsub(/^[[:space:]]+|[[:space:]]+$/,"",value); print key "=" value }
    ' "$SNELL_CONF" >"$parsed" || { rm -f "$parsed"; return 1; }
    while IFS='=' read -r key value; do
        key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
        case "$key" in
            listen) cfg_listen="$value" ;;
            psk) cfg_psk="$value" ;;
            version) cfg_version="$value" ;;
            ipv6) cfg_ipv6="$value" ;;
            obfs) cfg_obfs="$value" ;;
            obfs-host) cfg_host="$value" ;;
            tfo) cfg_tfo="$value" ;;
            dns-ip-preference|ipv-preference) cfg_dns_pref="$value" ;;
            mode) cfg_mode="$value" ;;
            egress-interface) cfg_egress="$value" ;;
        esac
    done <"$parsed"
    rm -f "$parsed"
    first=${cfg_listen%%,*}; cfg_port=${first##*:}; cfg_port=${cfg_port%]}
    [ "$cfg_version" = 6 ] || { cfg_dns_pref="${cfg_dns_pref:-default}"; cfg_mode="${cfg_mode:-default}"; }
    config_validate
}

config_stage(){
    local target="$1" custom other
    config_validate || return 1
    {
        printf '[snell-server]\nlisten = %s\npsk = %s\ntfo = %s\n' "$cfg_listen" "$cfg_psk" "$cfg_tfo"
        if [ "$cfg_version" = 5 ]; then
            printf 'ipv6 = %s\nobfs = %s\n' "$cfg_ipv6" "$cfg_obfs"
            [ "$cfg_obfs" = off ] || printf 'obfs-host = %s\n' "$cfg_host"
        else
            printf 'dns-ip-preference = %s\nmode = %s\n' "$cfg_dns_pref" "$cfg_mode"
        fi
        [ -z "$cfg_egress" ] || printf 'egress-interface = %s\n' "$cfg_egress"
        printf 'version = %s\n' "$cfg_version"
    } >"$target" || return 1

    if [ -f "$SNELL_CONF" ]; then
        custom=$(awk -F= '
            /^[[:space:]]*\[/ { active=($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
            active && $0 ~ /^[[:space:]]*#[[:space:]]*psk([[:space:]=]|$)/ { next }
            active && $0 !~ /^[[:space:]#]*$/ { key=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); k=tolower(key); if(k !~ /^(listen|psk|version|ipv6|obfs|obfs-host|tfo|dns-ip-preference|ipv-preference|mode|egress-interface)$/) print }
        ' "$SNELL_CONF")
        other=$(awk '
            /^[[:space:]]*\[/ { active=($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); if(!active) print; next }
            !active { print }
        ' "$SNELL_CONF")
        if [ -n "$custom" ]; then printf '\n# Custom Snell Configs\n%s\n' "$custom" >>"$target"; fi
        if [ -n "$other" ]; then printf '\n%s\n' "$other" >>"$target"; fi
    fi
    chmod 0640 "$target" && chown "root:${APP}" "$target"
}

version_write(){
    local tmp
    tmp=$(mktemp "${SNELL_VERSION}.new.XXXXXX") || return 1
    if ! printf 'v%s\n' "$1" >"$tmp" || ! chmod 0644 "$tmp" || ! chown root:root "$tmp" || ! mv -f "$tmp" "$SNELL_VERSION"; then rm -f "$tmp"; return 1; fi
}

restore_atomic(){
    local source="$1" target="$2" mode="$3" owner="$4" tmp
    tmp=$(mktemp "${target}.restore.XXXXXX") || return 1
    if ! cp -p "$source" "$tmp" || ! chmod "$mode" "$tmp" || ! chown "$owner" "$tmp" || ! mv -f "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
}

service_restore(){
    local file mode
    if [ "$rt_backend" = systemd ]; then file="$SYSTEMD_UNIT"; mode=0644; else file="$OPENRC_INIT"; mode=0755; fi
    restore_atomic "$tx_dir/service" "$file" "$mode" root:root || return 1
    [ "$rt_backend" != systemd ] || systemctl daemon-reload >/dev/null 2>&1 || return 1
    service_set_enabled "$tx_was_enabled"
}

transaction_rollback(){
    local failed=false
    trap - HUP INT TERM
    service_ctl stop >/dev/null 2>&1 || true
    if [ "$tx_mode" = install ]; then
        stop_orphans >/dev/null 2>&1 || true
        service_remove
        rm -f "$SNELL_BIN" "$PID_FILE" "$LOG_FILE"
        if [ "$tx_account_created" = true ]; then
            if account_remove; then rm -rf "$SNELL_DIR"; else failed=true; fi
        else
            rm -f "$SNELL_CONF" "$SNELL_VERSION"
        fi
    else
        if [ "$tx_had_service" = true ]; then
            service_restore || failed=true
        else
            service_remove || failed=true
        fi
        restore_atomic "$tx_dir/config" "$SNELL_CONF" 0640 "root:${APP}" || failed=true
        if [ "$tx_mode" = binary ]; then
            restore_atomic "$tx_dir/server" "$SNELL_BIN" 0755 root:root || failed=true
            if [ "$tx_had_version" = true ]; then restore_atomic "$tx_dir/version" "$SNELL_VERSION" 0644 root:root || failed=true
            else rm -f "$SNELL_VERSION" || failed=true
            fi
        fi
        if [ "$tx_was_running" = true ] && [ "$failed" = false ]; then
            if ! service_ctl start || ! service_wait; then service_log; failed=true; fi
        fi
    fi
    rm -f "${tx_cfg:-}"
    if [ "$failed" = false ]; then
        rm -rf "$tx_dir"
        if [ "$tx_mode" = install ]; then ui_ok "已清理失败安装"; else ui_ok "已恢复旧状态"; fi
    else ui_error "自动回滚不完整，备份保留在：$tx_dir"
    fi
    [ "$failed" = false ]
}

transaction_stage_abort(){
    trap - HUP INT TERM
    rm -rf "$tx_dir"
    rm -f "${tx_cfg:-}"
    exit 130
}

transaction_apply(){
    local mode="$1" package_version="${2:-}" swap_bin=false
    tx_mode="$mode"; tx_was_running=false; tx_was_enabled=false; tx_had_service=false; tx_had_version=false; tx_account_created=false; tx_cfg=""
    case "$mode" in install|binary) swap_bin=true ;; esac
    case "$mode" in install) ui_progress 18 "准备安装事务" ;; binary) ui_progress 18 "准备更新事务" ;; config) ui_progress 20 "准备配置事务" ;; reconcile) ui_progress 20 "协调服务定义" ;; esac
    if [ "$mode" != config ]; then runtime_refresh; fi
    if [ "$mode" = install ]; then
        [ "$rt_artifacts" = false ] || { ui_error "检测到已安装文件或残留，请先卸载"; return 1; }
        ensure_dependencies || return 1
    elif [ "$mode" = reconcile ]; then
        [ "$rt_installed" = true ] || return 1
        tx_was_running="$rt_running"; tx_was_enabled="$rt_enabled"
        service_exists && tx_had_service=true
    else
        if [ ! -x "$SNELL_BIN" ] || [ ! -f "$SNELL_CONF" ]; then ui_error "Snell Server 未完整安装"; return 1; fi
        service_status || { ui_error "无法确认服务状态，操作已取消"; return 1; }
        tx_was_running="$rt_running"; tx_was_enabled="$rt_enabled"
        service_exists && tx_had_service=true
        [ "$mode" != binary ] || ensure_dependencies || return 1
    fi

    tx_dir=$(mktemp -d "$(dirname "$SNELL_BIN")/.snell-tx.XXXXXX") || return 1
    trap 'transaction_stage_abort' HUP INT TERM

    if [ "$mode" != config ] && [ "$mode" != reconcile ]; then
        artifact_fetch "$package_version" "$tx_dir/new" || { trap - HUP INT TERM; rm -rf "$tx_dir"; return 1; }
    fi

    if [ "$mode" = install ]; then
        account_create || { transaction_rollback; return 1; }
        tx_account_created=true
    else
        cp -p "$SNELL_CONF" "$tx_dir/config" || { trap - HUP INT TERM; rm -rf "$tx_dir"; return 1; }
        if [ "$tx_had_service" = true ]; then
            if [ "$rt_backend" = systemd ]; then cp -p "$SYSTEMD_UNIT" "$tx_dir/service"
            else cp -p "$OPENRC_INIT" "$tx_dir/service"
            fi || { trap - HUP INT TERM; rm -rf "$tx_dir"; return 1; }
        fi
        if [ "$mode" = binary ]; then
            cp -p "$SNELL_BIN" "$tx_dir/server" || { trap - HUP INT TERM; rm -rf "$tx_dir"; return 1; }
            if [ -f "$SNELL_VERSION" ]; then cp -p "$SNELL_VERSION" "$tx_dir/version" || { trap - HUP INT TERM; rm -rf "$tx_dir"; return 1; }; tx_had_version=true; fi
        fi
    fi

    mkdir -p "$SNELL_DIR" || { transaction_rollback; return 1; }
    chown "root:${APP}" "$SNELL_DIR" || { transaction_rollback; return 1; }
    chmod 0750 "$SNELL_DIR" || { transaction_rollback; return 1; }
    tx_cfg=$(mktemp "${SNELL_CONF}.new.XXXXXX") || { transaction_rollback; return 1; }
    config_stage "$tx_cfg" || { transaction_rollback; return 1; }
    trap 'transaction_rollback; exit 130' HUP INT TERM
    if [ "$mode" != install ] && [ "$tx_was_running" = true ]; then
        if ! service_ctl stop; then transaction_rollback; return 1; fi
    fi
    if ! service_install; then transaction_rollback; return 1; fi
    ui_progress 82 "提交服务定义"
    if [ "$mode" != install ] && [ "$tx_was_enabled" = false ]; then
        if ! service_set_enabled "$tx_was_enabled"; then transaction_rollback; return 1; fi
    fi
    if [ "$swap_bin" = true ] && ! mv -f "$tx_dir/new" "$SNELL_BIN"; then transaction_rollback; return 1; fi
    if ! mv -f "$tx_cfg" "$SNELL_CONF"; then transaction_rollback; return 1; fi
    tx_cfg=""
    if [ "$swap_bin" = true ] && ! version_write "$package_version"; then transaction_rollback; return 1; fi

    if [ "$mode" = install ] || [ "$tx_was_running" = true ]; then
        ui_progress 90 "启动服务"
        if ! service_ctl start || ! service_wait; then service_log; transaction_rollback; return 1; fi
    fi
    ui_progress 100 "完成"
    trap - HUP INT TERM
    rm -rf "$tx_dir"
    panel_major=""; panel_latest=""; panel_retry=0
    state_refresh
    return 0
}

ui_choose(){
    local title="$1" current="$2" default="$3" opt label=""
    shift 3; printf '\n%s\n' "$title"; printf '%s\n' "$@"
    if [ -n "$current" ]; then
        for opt in "$@"; do
            case "$opt" in " $current)"*) label="${opt#" $current) "}" ;; esac
        done
        if [ -n "$label" ]; then ui_read "选择（当前 ${label}）："
        else ui_read "选择（当前 ${current}）："
        fi
    else ui_read "选择（默认 ${default}）："
    fi
    REPLY="${REPLY:-${current:-$default}}"
}

ui_toggle(){
    local title="$1" current="$2" default="$3"
    while true; do
        ui_choose "$title" "$current" "$default" " 1) 开启" " 2) 关闭"
        case "$REPLY" in 1) return 0 ;; 2) return 1 ;; *) ui_error "仅支持 1 或 2" ;; esac
    done
}

edit_port(){
    local original="$cfg_port" value
    ui_warn "脚本不操作防火墙，请手动放行监听端口"
    while true; do
        ui_read "端口（当前 ${cfg_port:-8443}）："
        value="${REPLY:-${cfg_port:-8443}}"
        if ! printf '%s' "$value" | grep -qE '^[0-9]+$' || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then ui_error "端口无效"; continue; fi
        if [ "$value" != "$original" ] && ss -H -tuln 2>/dev/null | grep -qE "[:.]${value}[[:space:]]"; then ui_error "端口 ${value} 已被占用"; continue; fi
        cfg_port="$value"
        cfg_listen=$(printf '%s\n' "$cfg_listen" | awk -F, -v port="$value" '
            {
                out=""
                for (i=1; i<=NF; i++) {
                    p=$i
                    if (p ~ /:/) sub(/:[0-9]+$/, ":" port, p); else p=port
                    out = out (i>1 ? "," : "") p
                }
                print out
            }')
        return 0
    done
}

edit_psk(){
    local value
    while true; do
        ui_read "密钥（回车随机生成）："
        if [ -z "$REPLY" ]; then
            value=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        else value="$REPLY"
        fi
        if [ ${#value} -ge 16 ] && [ ${#value} -le 255 ]; then
            case "$value" in *[!A-Za-z0-9]*) ;; *) cfg_psk="$value"; return 0 ;; esac
        fi
        ui_error "密钥需 16-255 位，仅允许字母和数字"
    done
}

edit_ipv6(){
    local current=2; [ "$cfg_ipv6" = true ] && current=1
    if ui_toggle "目标域名 IPv6 解析" "$current" 2; then cfg_ipv6=true; else cfg_ipv6=false; fi
}

edit_tfo(){
    local current=1; [ "$cfg_tfo" = false ] && current=2
    if ui_toggle "TCP Fast Open" "$current" 1; then cfg_tfo=true; else cfg_tfo=false; fi
}

edit_host(){
    while true; do
        ui_read "OBFS 域名（当前 ${cfg_host:-www.wechat.com}）："
        [ -z "$REPLY" ] && REPLY="${cfg_host:-www.wechat.com}"
        cfg_host="$REPLY"
        config_validate >/dev/null 2>&1 && return 0
        ui_error "域名格式无效"
    done
}

edit_obfs(){
    local current=3
    [ "$cfg_obfs" = tls ] && current=1; [ "$cfg_obfs" = http ] && current=2
    while true; do
        ui_choose "OBFS" "$current" 3 " 1) TLS" " 2) HTTP" " 3) 关闭"
        case "$REPLY" in
            1) cfg_obfs=tls; edit_host; return ;;
            2) cfg_obfs=http; edit_host; return ;;
            3) cfg_obfs=off; cfg_host=""; return ;;
            *) ui_error "仅支持 1、2 或 3" ;;
        esac
    done
}

edit_dns_pref(){
    local current=1
    case "$cfg_dns_pref" in prefer-ipv4) current=2 ;; prefer-ipv6) current=3 ;; ipv4-only) current=4 ;; ipv6-only) current=5 ;; esac
    while true; do
        ui_choose "目标地址 DNS IP 偏好" "$current" 1 " 1) default" " 2) prefer-ipv4" " 3) prefer-ipv6" " 4) ipv4-only" " 5) ipv6-only"
        case "$REPLY" in 1) cfg_dns_pref=default; return ;; 2) cfg_dns_pref=prefer-ipv4; return ;; 3) cfg_dns_pref=prefer-ipv6; return ;; 4) cfg_dns_pref=ipv4-only; return ;; 5) cfg_dns_pref=ipv6-only; return ;; *) ui_error "仅支持 1-5" ;; esac
    done
}

edit_mode(){
    local current=1
    [ "$cfg_mode" = unshaped ] && current=2; [ "$cfg_mode" = unsafe-raw ] && current=3
    while true; do
        ui_choose "混淆模式" "$current" 1 " 1) default" " 2) unshaped" " 3) unsafe-raw"
        case "$REPLY" in 1) cfg_mode=default; return ;; 2) cfg_mode=unshaped; return ;; 3) cfg_mode=unsafe-raw; return ;; *) ui_error "仅支持 1-3" ;; esac
    done
}

edit_egress(){
    local cur="$cfg_egress"
    while true; do
        if [ -n "$cur" ]; then ui_read "出口网卡（当前 $cur，none 清除）："
        else ui_read "出口网卡（未设置，none 清除）："
        fi
        [ -z "$REPLY" ] && return 0
        case "$REPLY" in
            [Nn][Oo][Nn][Ee]|[Oo][Ff][Ff]) cfg_egress=""; return 0 ;;
        esac
        cfg_egress="$REPLY"
        config_validate >/dev/null 2>&1 && return 0
        ui_error "网卡名称无效（≤15 位，仅字母数字及 . _ : -）"
    done
}

edit_target_options(){
    if [ "$cfg_version" = 5 ]; then edit_obfs; edit_ipv6; else edit_dns_pref; edit_mode; fi
}

edit_version(){
    local old="$cfg_version" current=1
    [ "$cfg_version" = 6 ] && current=2
    ui_choose "协议版本" "$current" 1 " 1) v5" " 2) v6"
    case "$REPLY" in 1) cfg_version=5 ;; 2) cfg_version=6 ;; *) ui_error "仅支持 1 或 2"; return 1 ;; esac
    [ "$cfg_version" = "$old" ] && return 0
    ui_confirm "确认从 v${old} 切换到 v${cfg_version}？(y/N)：" n || { cfg_version="$old"; return 1; }
}

header_render(){
    local status installed major
    ui_clear; printf '\n'
    state_refresh
    printf '// snell-server\n'
    if [ "$rt_installed" != true ]; then
        [ "$rt_artifacts" = true ] && printf '安装不完整\n' || printf '未安装\n'
        return
    fi
    status=已停止; [ "$rt_running" = true ] && status=运行中
    installed="${rt_version:-$rt_protocol}"; [ -n "$installed" ] || installed="?"; major=${installed%%.*}
    if [ "$major" = 5 ] || [ "$major" = 6 ]; then
        if [ "$panel_major" != "$major" ]; then
            panel_latest=""
            now=$(date +%s 2>/dev/null || printf '0')
            if [ "$panel_retry" = 0 ] || [ "$now" -ge "$panel_retry" ]; then
                if release_latest "$major" >/dev/null 2>&1; then
                    panel_latest="$release_version"; panel_major="$major"
                else
                    panel_retry=$((now + 60))
                fi
            fi
        fi
    else panel_latest=""; panel_major="?"
    fi
    if [ -n "$panel_latest" ] && [ -n "$rt_version" ]; then
        version_compare "$rt_version" "$panel_latest"
        if [ "$version_cmp" -lt 0 ]; then
            printf 'v%s → v%s · %s\n' "$installed" "$panel_latest" "$status"
        else
            printf 'v%s · %s\n' "$installed" "$status"
        fi
    elif [ -n "$panel_latest" ]; then
        printf 'v%s · 最新 v%s · %s\n' "$installed" "$panel_latest" "$status"
    else
        printf 'v%s · %s\n' "$installed" "$status"
    fi
}

action_service(){
    local action="$1" stage success
    case "$action" in
        start) stage="启动服务"; success="Snell Server 已启动" ;;
        stop) stage="停止服务"; success="Snell Server 已停止" ;;
        restart) stage="重启服务"; success="Snell Server 已重启" ;;
        *) return 1 ;;
    esac
    ui_progress 10 "检查服务状态"
    state_refresh; [ "$rt_installed" = true ] || { ui_error "请先安装 Snell Server"; return 1; }
    if [ "$action" = start ] && [ "$rt_running" = true ]; then
        ui_progress 100 "服务已在运行"; ui_ok "Snell Server 已在运行"; return 0
    fi
    if [ "$action" = stop ] && [ "$rt_running" = false ]; then
        ui_progress 100 "服务未运行"; ui_warn "Snell Server 未运行"; return 0
    fi
    ui_progress 70 "$stage"
    if ! service_ctl "$action"; then ui_error "${stage}失败"; return 1; fi
    if [ "$action" != stop ] && ! service_wait; then ui_error "${stage}失败"; service_log; return 1; fi
    ui_progress 100 "完成"
    ui_ok "$success"
}

action_install(){
    local major
    state_refresh
    [ "$rt_artifacts" = false ] || { ui_error "检测到已安装文件或残留，请先卸载"; return 1; }
    printf '\n安装协议\n 1) v5（Surge 官方最新版本）\n 2) v6（Surge 官方最新版本）\n'
    ui_read "选择 [1/2]（默认 1）："
    case "${REPLY:-1}" in 1) major=5 ;; 2) major=6 ;; *) ui_error "仅支持 1 或 2"; return 1 ;; esac
    resolve_release "$major" || return 1
    ui_warn "即将安装 Snell v${release_version}（协议 v${major}）"
    ui_confirm "确认安装？(Y/n)：" y || { ui_ok "已取消安装"; return 0; }
    config_reset "$major"
    edit_port; edit_psk; edit_tfo; edit_egress; edit_target_options
    transaction_apply install "$release_version" || return 1
    ui_ok "Snell v${release_version} 安装完成"
    view_config
}

commit_config(){
    transaction_apply config || { config_load >/dev/null 2>&1 || true; return 1; }
    ui_ok "配置已应用"
}

switch_protocol(){
    local old="$cfg_version"
    edit_version || return 1
    [ "$cfg_version" != "$old" ] || return 0
    edit_target_options
    resolve_release "$cfg_version" || { cfg_version="$old"; return 1; }
    transaction_apply binary "$release_version" || { config_load >/dev/null 2>&1 || true; return 1; }
    ui_ok "已切换到 Snell v${cfg_version}（${release_version}）"
}

action_config(){
    local choice old
    require_installed || return 1
    while true; do
        config_load || return 1
        header_render
        printf '\n设置配置（协议 v%s）\n 1) 监听端口\n 2) 密钥\n' "$cfg_version"
        if [ "$cfg_version" = 5 ]; then printf ' 3) OBFS\n 4) OBFS 域名\n 5) 目标域名 IPv6 解析\n'; fi
        printf ' 6) TCP Fast Open\n 7) 出口网卡\n 8) 切换协议版本\n'
        if [ "$cfg_version" = 6 ]; then printf ' 9) 目标地址 DNS IP 偏好\n10) 混淆模式\n'; fi
        printf '11) 全部配置\n\n'
        ui_read "菜单项（回车返回）："; choice="$REPLY"; [ -n "$choice" ] || return 0
        case "$choice" in
            1) edit_port; commit_config ;;
            2) edit_psk; commit_config ;;
            3)
                if [ "$cfg_version" != 5 ]; then ui_error "当前协议不支持此项"
                else edit_obfs; commit_config
                fi
                ;;
            4)
                if [ "$cfg_version" != 5 ] || [ "$cfg_obfs" = off ]; then ui_error "请先启用 OBFS"
                else edit_host; commit_config
                fi
                ;;
            5)
                if [ "$cfg_version" != 5 ]; then ui_error "当前协议不支持此项"
                else edit_ipv6; commit_config
                fi
                ;;
            6) edit_tfo; commit_config ;;
            7) edit_egress; commit_config ;;
            8)
                old="$cfg_version"
                if switch_protocol && [ "$cfg_version" = "$old" ]; then ui_warn "协议版本未变更"; fi
                ;;
            9)
                if [ "$cfg_version" != 6 ]; then ui_error "当前协议不支持此项"
                else edit_dns_pref; commit_config
                fi
                ;;
            10)
                if [ "$cfg_version" != 6 ]; then ui_error "当前协议不支持此项"
                else edit_mode; commit_config
                fi
                ;;
            11)
                old="$cfg_version"; edit_version || continue
                edit_port; edit_psk; edit_tfo; edit_egress; edit_target_options
                if [ "$cfg_version" = "$old" ]; then
                    commit_config
                elif resolve_release "$cfg_version" && transaction_apply binary "$release_version"; then
                    ui_ok "全部配置已应用"
                else
                    config_load >/dev/null 2>&1 || true
                fi
                ;;
            *) ui_error "请输入 1-11" ;;
        esac
    done
}

action_update(){
    local latest old
    require_installed || return 1
    if [ "$cfg_version" = 5 ]; then
        old=5; cfg_version=6
        ui_warn "更新操作将从协议 v5 升级至 v6"
        ui_confirm "确认升级？(y/N)：" n || { cfg_version="$old"; return 0; }
        edit_target_options
        resolve_release 6 || { cfg_version="$old"; return 1; }
        transaction_apply binary "$release_version" || { config_load >/dev/null 2>&1 || true; return 1; }
        ui_ok "已升级到 Snell v${release_version}"
        return 0
    fi
    resolve_release 6 || return 1; latest="$release_version"
    if [ -n "$rt_version" ]; then
        version_compare "$rt_version" "$latest"
        [ "$version_cmp" -lt 0 ] || { ui_ok "当前已是最新可下载版本：v${rt_version}"; return 0; }
        ui_warn "发现更新：v${rt_version} → v${latest}"
    else
        ui_warn "无法识别已安装包版本，将重新安装 Surge 官方最新版本 v${latest}"
    fi
    ui_confirm "确认更新？(Y/n)：" y || return 0
    transaction_apply binary "$latest" && ui_ok "Snell Server 已更新到 v${latest}"
}

action_uninstall(){
    ui_progress 10 "检查安装状态"
    state_refresh; [ "$rt_artifacts" = true ] || { ui_progress 100 "未安装"; ui_warn "Snell Server 未安装"; return 0; }
    printf '\n将删除主程序、服务和 %s。\n' "$SNELL_DIR"
    ui_confirm "确认卸载？(y/N)：" n || { ui_ok "已取消卸载"; return 0; }
    [ "$rt_running" = false ] || service_ctl stop || { ui_error "无法停止服务"; return 1; }
    ui_progress 55 "清理服务与账户"
    stop_orphans || { ui_error "仍有 Snell 进程无法终止"; return 1; }
    service_remove
    account_remove || { ui_error "无法删除系统用户"; return 1; }
    rm -f "$SNELL_BIN" "$SNELL_CONF" "$SNELL_VERSION" "$PID_FILE" "$LOG_FILE"
    rm -rf "$SNELL_DIR"
    state_refresh
    [ "$rt_artifacts" = false ] || { ui_error "卸载后仍有残留"; return 1; }
    ui_progress 100 "完成"
    ui_ok "Snell Server 已卸载"
}

public_ipv4(){
    local source
    for source in https://ipinfo.io/ip https://api.ip.sb/ip https://members.3322.org/dyndns/getip; do
        public_v4=$(curl -fsSL4 --connect-timeout 2 --max-time 5 "$source" 2>/dev/null | sed -n '1{s/[[:space:]]//g;p;q;}')
        printf '%s\n' "$public_v4" | awk -F. 'NF==4{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1;exit 0}{exit 1}' && return 0
    done
    public_v4=""
}

public_ipv6(){
    local source
    for source in https://ifconfig.co https://ipv6.icanhazip.com https://api6.ipify.org; do
        public_v6=$(curl -fsSL6 --connect-timeout 2 --max-time 5 "$source" 2>/dev/null | sed -n '1{s/[[:space:]]//g;p;q;}')
        printf '%s\n' "$public_v6" | awk '
            length($0)<2||length($0)>39||$0~/[^0-9A-Fa-f:]/{exit 1}
            { c=index($0,"::")>0;t=$0;if(gsub(/::/,"",t)>1||$0~/:::/)exit 1;n=split($0,a,":");g=0;for(i=1;i<=n;i++)if(a[i]!=""){if(length(a[i])>4)exit 1;g++}if((c&&g>=8)||(!c&&g!=8))exit 1 }
        ' && return 0
    done
    public_v6=""
}

surge_line(){
    local address="$1" line
    line="$(uname -n) = snell, ${address}, ${cfg_port}, psk=${cfg_psk}, version=${cfg_version}"
    [ "$cfg_version" != 6 ] || line="${line}, mode=${cfg_mode}"
    [ "$cfg_version" != 5 ] || [ "$cfg_obfs" = off ] || line="${line}, obfs=${cfg_obfs}, obfs-host=${cfg_host}"
    printf '%s, reuse=true, tfo=%s\n' "$line" "$cfg_tfo"
}

view_config(){
    local tmp address tfo_text ipv6_text obfs_text
    ui_progress 10 "读取配置"
    require_installed || return 1
    ui_progress 35 "获取公网地址"
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$tmp"; exit 130' HUP INT TERM
    ( public_ipv4; printf '%s\n' "$public_v4" >"$tmp/v4" ) &
    ( public_ipv6; printf '%s\n' "$public_v6" >"$tmp/v6" ) &
    wait
    public_v4=$(cat "$tmp/v4" 2>/dev/null); public_v6=$(cat "$tmp/v6" 2>/dev/null)
    rm -rf "$tmp"; trap - HUP INT TERM
    ui_progress 75 "生成 Surge 配置"
    address="${public_v4:-${public_v6:+[$public_v6]}}"
    header_render
    tfo_text=关闭; [ "$cfg_tfo" = true ] && tfo_text=开启
    printf '\n配置\n文件      : %s\n端口      : %s\n密钥      : %s\n协议      : v%s\nTFO       : %s\n' "$SNELL_CONF" "$cfg_port" "$cfg_psk" "$cfg_version" "$tfo_text"
    if [ "$cfg_version" = 5 ]; then
        ipv6_text=关闭; [ "$cfg_ipv6" = true ] && ipv6_text=开启
        obfs_text=关闭; [ "$cfg_obfs" = tls ] && obfs_text=TLS; [ "$cfg_obfs" = http ] && obfs_text=HTTP
        printf 'OBFS      : %s\n目标 IPv6 : %s\n' "$obfs_text" "$ipv6_text"
        if [ "$cfg_obfs" != off ]; then printf '域名      : %s\n' "$cfg_host"; fi
    else
        printf '目标 DNS  : %s\n模式      : %s\n' "$cfg_dns_pref" "$cfg_mode"
    fi
    if [ -n "$cfg_egress" ]; then printf '出口网卡  : %s\n' "$cfg_egress"; fi
    printf '\nSurge 配置：\n'
    if [ -n "$address" ]; then surge_line "$address"; else ui_error "无法获取公网 IP"; fi
    ui_progress 100 "完成"
    ui_pause
}

view_status(){
    local pid started service_text log_command
    ui_progress 10 "读取服务状态"
    require_installed || return 1
    ui_progress 70 "整理状态信息"
    header_render
    service_text="已停止"; [ "$rt_running" = true ] && service_text="运行中"
    printf '\n状态\n安装版本  : v%s\n协议版本  : v%s\n监听端口  : %s\n服务状态  : %s\n' "${rt_version:-?}" "$cfg_version" "$cfg_port" "$service_text"
    if [ "$rt_running" = true ]; then
        pid=$(service_pid)
        case "$pid" in
            ''|0|*[!0-9]*) ;;
            *)
                printf '进程 PID  : %s\n' "$pid"
                started=$(ps -o lstart= -p "$pid" 2>/dev/null)
                if [ -n "$started" ]; then printf '启动时间  : %s\n' "$started"; fi
                ;;
        esac
        if ss -H -ltn 2>/dev/null | grep -qE "[:.]${cfg_port}[[:space:]]"; then printf 'TCP       : 正常\n'; else printf 'TCP       : 异常\n'; fi
        if ss -H -lun 2>/dev/null | grep -qE "[:.]${cfg_port}[[:space:]]"; then printf 'UDP       : 正常\n'; fi
    fi
    if [ "$rt_backend" = systemd ]; then log_command='journalctl -u snell-server -n 50'; else log_command="tail -50 $LOG_FILE"; fi
    printf '日志      : %s\n' "$log_command"
    ui_progress 100 "完成"
    ui_pause
}

main_menu(){
    while true; do
        header_render
        printf '\n 1) 安装服务    2) 启动服务\n 3) 停止服务    4) 重启服务\n 5) 设置配置    6) 查看配置\n 7) 查看状态    8) 更新服务\n 9) 卸载服务    0) 退出脚本\n\n'
        ui_read "请输入选项 [0-9]: "
        case "$REPLY" in
            0) ui_ok "已退出脚本"; exit 0 ;;
            1) action_install ;;
            2) action_service start ;;
            3) action_service stop ;;
            4) action_service restart ;;
            5) action_config ;;
            6) view_config ;;
            7) view_status ;;
            8) action_update ;;
            9) action_uninstall ;;
            *) ui_error "请输入 0-9" ;;
        esac
    done
}

main(){
    platform_init
    state_refresh
    installation_reconcile || exit 1
    main_menu
}

main "$@"

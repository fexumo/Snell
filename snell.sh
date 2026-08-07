#!/bin/sh
# shellcheck disable=SC3037,SC3043  # dash/ash support echo/local
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#==============================================
#	System Required: Debian/Alpine
#	Description: Snell Server manager
#	Author: Fexumo
#	WebSite: https://fexumo.org
#==============================================

snell_v5_version="5.0.1"
snell_v6_version="6.0.0rc2"
snell_dir="/etc/snell/"
snell_bin="/usr/local/bin/snell-server"
snell_conf="/etc/snell/config.conf"
snell_version_file="/etc/snell/ver.txt"
snell_user="snell-server"
snell_marker="/etc/snell/.user-created"

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m" && Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}✓${Font_color_suffix}"
Error="${Red_font_prefix}✗${Font_color_suffix}"
Tip="${Yellow_font_prefix}!${Font_color_suffix}"

clearScreen(){
    [ -z "${TERM:-}" ] && return 0
    clear 2>/dev/null || true
}

readInput(){
    if [ -n "$1" ]; then
        printf '> %s' "$1"
    else
        printf '> '
    fi
    IFS= read -r REPLY || exit 0
}

pauseMenu(){
    echo
    readInput "按回车返回主菜单"
}

# dash/ash echo: only -e interprets escapes
# shellcheck disable=SC3037
echo() {
    local opt_n="" opt_e=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) opt_n=1; shift ;;
            -e) opt_e=1; shift ;;
            *) break ;;
        esac
    done
    if [ -n "$opt_e" ]; then
        [ -n "$opt_n" ] && printf '%b' "$*" || printf '%b\n' "$*"
    else
        [ -n "$opt_n" ] && printf '%s' "$*" || printf '%s\n' "$*"
    fi
}

fail(){
    echo -e "${Error} $1"
    sleep 1
    return 1
}

ok(){
    echo -e "${Info} $1"
}

askConfirm(){
    local prompt="$1" default="${2:-n}"
    readInput "$prompt"
    REPLY="${REPLY:-$default}"
    case "$REPLY" in
        [Yy]) return 0 ;;
        [Nn]) return 1 ;;
        *) echo -e "${Error} 请输入 y 或 n"; sleep 1; return 1 ;;
    esac
}

# Runtime
checkRoot(){
    [ "$(id -u)" = 0 ] || { echo -e "${Error} 需要 ROOT 权限，请使用 sudo -i"; exit 1; }
}

checkSys(){
    if [ -f /etc/alpine-release ]; then
        release="alpine"
    elif [ -f /etc/debian_version ]; then
        release="debian"
    else
        echo -e "${Error} 不支持的系统！本脚本仅支持 Debian/Alpine。"
        exit 1
    fi
}

sysArch(){
    machine=$(uname -m)
    case "$machine" in
        i386|i686) arch="i386" ;;
        armv6l)
            arch="armv7l"
            echo -e "${Tip} 检测到 armv6 架构，官方无对应构建，将尝试 armv7l 版本（可能无法运行）"
            ;;
        armv7l|armv7*) arch="armv7l" ;;
        aarch64|armv8*) arch="aarch64" ;;
        x86_64|amd64) arch="amd64" ;;
        *) echo -e "${Error} 不支持的系统架构：${machine}"; return 1 ;;
    esac
}

installDependencies(){
    if [ "$release" = "alpine" ]; then
        apk add --no-cache curl unzip tzdata gcompat upx iproute2 >/dev/null 2>&1 || fail "依赖安装失败"
    elif [ "$release" = "debian" ]; then
        local packages=""
        command -v curl >/dev/null 2>&1 || packages="$packages curl"
        command -v unzip >/dev/null 2>&1 || packages="$packages unzip"
        command -v ss >/dev/null 2>&1 || packages="$packages iproute2"
        [ -f /etc/ssl/certs/ca-certificates.crt ] || packages="$packages ca-certificates"
        if [ -n "$packages" ]; then
            # shellcheck disable=SC2086  # controlled package list
            { apt-get update >/dev/null 2>&1 && apt-get install -y $packages >/dev/null 2>&1; } || fail "依赖安装失败"
        fi
    fi
}

hasSnellArtifacts(){
    [ -e "$snell_bin" ] || [ -e "$snell_dir" ] || \
    [ -e /etc/systemd/system/snell-server.service ] || [ -L /etc/systemd/system/snell-server.service ] || \
    [ -e /etc/systemd/system/multi-user.target.wants/snell-server.service ] || [ -L /etc/systemd/system/multi-user.target.wants/snell-server.service ] || \
    [ -e /etc/init.d/snell-server ]
}

checkInstalledStatus(){
    if [ ! -x "$snell_bin" ] || [ ! -f "$snell_conf" ]; then
        fail "Snell Server 未完整安装，请检查！"
        return 1
    fi
}

serviceBackend(){
    if [ -f /etc/systemd/system/snell-server.service ] && command -v systemctl >/dev/null 2>&1; then
        echo systemd
    elif [ -f /etc/init.d/snell-server ] && command -v rc-service >/dev/null 2>&1; then
        echo openrc
    elif [ "${release:-}" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
        echo openrc
    elif command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
        echo systemd
    else
        echo none
    fi
}

svc(){
    case "$(serviceBackend)" in
        systemd) systemctl "$1" snell-server >/dev/null 2>&1 ;;
        openrc) rc-service snell-server "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

checkStatus(){
    status="stopped"
    case "$(serviceBackend)" in
        systemd) systemctl is-active snell-server.service >/dev/null 2>&1 && status="running" ;;
        openrc) rc-service snell-server status >/dev/null 2>&1 && status="running" ;;
        *) return 1 ;;
    esac
}

showServiceLog(){
    case "$(serviceBackend)" in
        systemd) journalctl -u snell-server -n 20 --no-pager ;;
        openrc) tail -n 20 /var/log/snell-server.log 2>/dev/null || rc-service snell-server status ;;
    esac
}

waitServiceStart(){
    local i=0
    while [ "$i" -lt 10 ]; do
        sleep 1
        checkStatus
        [ "$status" = "running" ] && return 0
        i=$((i + 1))
    done
    return 1
}

stopOrphanedProcesses(){
    local proc pid cmd
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        cmd=$(tr '\0' ' ' < "$proc" 2>/dev/null)
        case "$cmd" in
            *"${snell_bin}"*"${snell_conf}"*)
                pid=${proc#/proc/}
                pid=${pid%/cmdline}
                kill "$pid" 2>/dev/null
                ;;
        esac
    done
}

removeServiceAccount(){
    if [ "$release" = "debian" ]; then
        userdel "$snell_user" >/dev/null 2>&1 || true
        groupdel "$snell_user" >/dev/null 2>&1 || true
    else
        deluser "$snell_user" >/dev/null 2>&1 || true
        delgroup "$snell_user" >/dev/null 2>&1 || true
    fi
}

removeServiceUser(){
    [ -f "$snell_marker" ] || return 0
    removeServiceAccount
}

setupServiceUser(){
    local group_exists=false
    grep -q "^${snell_user}:" /etc/group && group_exists=true

    if id "$snell_user" >/dev/null 2>&1; then
        if [ -f "$snell_marker" ] && id -gn "$snell_user" 2>/dev/null | grep -qx "$snell_user"; then
            return 0
        fi
        [ -f "$snell_marker" ] || fail "系统已存在非本脚本创建的 ${snell_user} 用户" || return 1
        removeServiceAccount
        group_exists=false
    elif [ "$group_exists" = true ] && [ ! -f "$snell_marker" ]; then
        fail "系统已存在非本脚本创建的 ${snell_user} 组"
        return 1
    fi

    if [ "$release" = "debian" ]; then
        [ "$group_exists" = true ] || groupadd --system "$snell_user" >/dev/null 2>&1 || return 1
        useradd --system --gid "$snell_user" --no-create-home --shell /usr/sbin/nologin "$snell_user" >/dev/null 2>&1 || {
            [ "$group_exists" = true ] || groupdel "$snell_user" >/dev/null 2>&1
            return 1
        }
    else
        [ "$group_exists" = true ] || addgroup -S "$snell_user" >/dev/null 2>&1 || return 1
        adduser -S -D -H -s /sbin/nologin -G "$snell_user" "$snell_user" >/dev/null 2>&1 || {
            [ "$group_exists" = true ] || delgroup "$snell_user" >/dev/null 2>&1
            return 1
        }
    fi
    mkdir -p "$snell_dir" || return 1
    touch "$snell_marker" || { removeServiceAccount; return 1; }
}

setupService(){
    if [ "$release" = "debian" ] && command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
        cat > /etc/systemd/system/snell-server.service <<'EOF'
[Unit]
Description=Snell Service
After=network.target
[Service]
LimitNOFILE=32767
Type=simple
User=snell-server
Group=snell-server
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/snell-server -c /etc/snell/config.conf
NoNewPrivileges=true
PrivateTmp=true
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
UMask=0077
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
EOF
        if ! systemctl daemon-reload >/dev/null 2>&1 || ! systemctl enable snell-server >/dev/null 2>&1; then
            fail "无法注册 systemd 服务"
            return 1
        fi
    elif [ "$release" = "alpine" ] && [ -d /etc/init.d ] && command -v rc-update >/dev/null 2>&1; then
        cat > /etc/init.d/snell-server <<'EOF'
#!/sbin/openrc-run
name="snell-server"
description="Snell Server"
pidfile="/run/${RC_SVCNAME}.pid"
logfile="/var/log/snell-server.log"

is_snell_pid() {
    local pid="$1"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/${pid}/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q 'snell-server'
}

start() {
    ebegin "Starting ${name}"
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
            eend 0 "already running"
            return 0
        fi
        rm -f "$pidfile"
    fi
    touch "$logfile"
    chown snell-server:snell-server "$logfile"
    setsid su snell-server -s /bin/sh -c 'exec /usr/local/bin/snell-server -c /etc/snell/config.conf' >>"$logfile" 2>&1 &
    pid=$!
    echo "$pid" > "$pidfile"
    sleep 1
    if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
        eend 0
    else
        rm -f "$pidfile"
        eend 1
        return 1
    fi
}

stop() {
    ebegin "Stopping ${name}"
    pid=""
    [ -f "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
        kill "$pid" 2>/dev/null
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
            sleep 1
            i=$((i + 1))
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
    eend 0
}

status() {
    pid=""
    [ -f "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
        ebegin "${name} is running (pid ${pid})"
        eend 0
        return 0
    fi
    ebegin "${name} is stopped"
    eend 1
}

depend() {
    need net
}
EOF
        if ! chmod +x /etc/init.d/snell-server || ! rc-update add snell-server default >/dev/null 2>&1; then
            fail "无法注册 OpenRC 服务"
            return 1
        fi
    else
        fail "未找到可用的服务管理器（systemd/OpenRC）"
    fi
}

cleanupFailedInstall(){
    case "$(serviceBackend)" in
        systemd) systemctl disable snell-server >/dev/null 2>&1 ;;
        openrc) rc-update del snell-server default >/dev/null 2>&1 ;;
    esac
    removeServiceUser
    rm -f "$snell_bin" /etc/systemd/system/snell-server.service /etc/systemd/system/multi-user.target.wants/snell-server.service /etc/init.d/snell-server
    rm -rf "$snell_dir"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
}

ensureServiceSecurity(){
    local was_running=false was_enabled=false
    [ -x "$snell_bin" ] && [ -f "$snell_conf" ] || return 0
    case "$(serviceBackend)" in
        systemd) systemctl is-enabled snell-server >/dev/null 2>&1 && was_enabled=true ;;
        openrc) rc-update show default 2>/dev/null | grep -q '^[[:space:]]*snell-server[[:space:]]' && was_enabled=true ;;
    esac
    if [ -f "$snell_marker" ] && id "$snell_user" >/dev/null 2>&1 && \
       [ "$(stat -c %U "$snell_conf" 2>/dev/null)" = "$snell_user" ]; then
        if [ "$release" = "debian" ] && grep -q "^User=${snell_user}$" /etc/systemd/system/snell-server.service 2>/dev/null && \
           grep -q '^NoNewPrivileges=true$' /etc/systemd/system/snell-server.service 2>/dev/null; then
            return 0
        fi
        if [ "$release" = "alpine" ] && grep -q "su ${snell_user}" /etc/init.d/snell-server 2>/dev/null; then
            return 0
        fi
    fi
    checkStatus
    [ "$status" = "running" ] && was_running=true
    setupServiceUser || return 1
    chown "${snell_user}:${snell_user}" "$snell_conf" || return 1
    chmod 600 "$snell_conf" || return 1
    setupService || return 1
    if [ "$was_enabled" != true ]; then
        case "$(serviceBackend)" in
            systemd) systemctl disable snell-server >/dev/null 2>&1 ;;
            openrc) rc-update del snell-server default >/dev/null 2>&1 ;;
        esac
    fi
    if [ "$was_running" = true ]; then
        svc restart || return 1
        waitServiceStart || return 1
    fi
}

# Version
compareVersions(){
    local version1="$1" version2="$2" base1 base2 suffix1 suffix2 num1 num2 first
    version1=$(printf '%s' "$version1" | sed 's/^v//')
    version2=$(printf '%s' "$version2" | sed 's/^v//')
    [ "$version1" = "$version2" ] && return 1
    base1=$(printf '%s' "$version1" | sed 's/[a-z].*//')
    base2=$(printf '%s' "$version2" | sed 's/[a-z].*//')
    case "$version1" in *[a-z]*) suffix1=${version1#"$base1"} ;; *) suffix1="" ;; esac
    case "$version2" in *[a-z]*) suffix2=${version2#"$base2"} ;; *) suffix2="" ;; esac
    if [ "$base1" = "$base2" ]; then
        [ -z "$suffix1" ] && [ -n "$suffix2" ] && return 0
        [ -n "$suffix1" ] && [ -z "$suffix2" ] && return 2
        num1=$(printf '%s' "$suffix1" | grep -oE '[0-9]+$'); num2=$(printf '%s' "$suffix2" | grep -oE '[0-9]+$')
        [ -z "$num1" ] && num1=0; [ -z "$num2" ] && num2=0
        [ "$num1" -lt "$num2" ] && return 2
        [ "$num1" -gt "$num2" ] && return 0
        [ "$suffix1" = "$suffix2" ] && return 1
        first=$(printf '%s\n' "$suffix1" "$suffix2" | LC_ALL=C sort | head -1)
        [ "$first" = "$suffix1" ] && return 2
        return 0
    fi
    printf '%s\n' "$base1" "$base2" | sort -V | head -1 | grep -q "^${base1}$" && return 2
    return 0
}

getSnellDownloadUrl(){
    sysArch || return 1
    snell_url="https://dl.nssurge.com/snell/snell-server-v${1}-linux-${arch}.zip"
}

validateVersionUrl(){
    getSnellDownloadUrl "$1" || return 1
    curl -fsSIL --proto '=https' --tlsv1.2 --max-time 10 "$snell_url" 2>/dev/null | grep -q '^HTTP/.* 200'
}

getLatestVersionFromWeb(){
    local version_type="$1" pattern latest
    if [ -z "$_snell_release_page" ]; then
        _snell_release_page=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 10 \
            "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" 2>/dev/null)
    fi
    [ -n "$_snell_release_page" ] || return 1
    case "$version_type" in
        v5) pattern='snell-server-v5\.[0-9]+\.[0-9]+[a-z]*[0-9]*-linux' ;;
        v6) pattern='snell-server-v6\.[0-9]+\.[0-9]+[a-z]*[0-9]*-linux' ;;
        *) return 1 ;;
    esac
    latest=""
    for v in $(printf '%s' "$_snell_release_page" | grep -oE "$pattern" | sed 's/snell-server-v//;s/-linux//' | sort -u); do
        if [ -z "$latest" ]; then
            latest="$v"
        elif compareVersions "$v" "$latest"; then
            latest="$v"
        fi
    done
    [ -n "$latest" ] && echo "$latest"
}

readInstalledVersion(){
    local recorded
    recorded=$(sed 's/^v//' "$snell_version_file" 2>/dev/null)
    printf '%s' "$recorded" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z]+[0-9]*)?$' || return 1
    echo "$recorded"
}

confVersion(){
    awk -F '=' '
        /^[[:space:]]*\[/ { in_snell = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
        in_snell && $1 ~ /^[[:space:]]*version[[:space:]]*$/ {
            v=$2; sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); print v; exit
        }
    ' "$snell_conf" 2>/dev/null
}

pickVersion(){
    local major="$1" builtin_ver web_ver
    case "$major" in
        5) builtin_ver=$snell_v5_version ;;
        6) builtin_ver=$snell_v6_version ;;
        *) return 1 ;;
    esac
    web_ver=$(getLatestVersionFromWeb "v${major}")
    if [ -n "$web_ver" ]; then
        compareVersions "$builtin_ver" "$web_ver"
        if [ $? -eq 2 ] && validateVersionUrl "$web_ver"; then
            echo "$web_ver"
            return 0
        fi
    fi
    echo "$builtin_ver"
}

installFromZip(){
    local version="$1" label="$2" url="$3" tmp_dir zip_file version_tmp
    tmp_dir=$(mktemp -d /tmp/snell-install.XXXXXX) || fail "无法创建临时目录" || return 1
    zip_file="${tmp_dir}/snell-server.zip"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 --max-time 60 -o "$zip_file" "$url" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        fail "Snell Server ${Yellow_font_prefix}${label}${Font_color_suffix} 下载失败！"
        return 1
    fi
    if ! unzip -oq "$zip_file" -d "$tmp_dir" >/dev/null 2>&1 || [ ! -f "${tmp_dir}/snell-server" ] || [ -L "${tmp_dir}/snell-server" ]; then
        rm -rf "$tmp_dir"
        fail "Snell Server ${Yellow_font_prefix}${label}${Font_color_suffix} 解压失败！"
        return 1
    fi
    chmod +x "${tmp_dir}/snell-server" || { rm -rf "$tmp_dir"; return 1; }
    if [ "$release" = "alpine" ] && command -v upx >/dev/null 2>&1 && strings "${tmp_dir}/snell-server" 2>/dev/null | grep -q "UPX!"; then
        if upx -d -o "${tmp_dir}/snell-server.unpacked" "${tmp_dir}/snell-server" >/dev/null 2>&1; then
            mv -f "${tmp_dir}/snell-server.unpacked" "${tmp_dir}/snell-server"
            chmod +x "${tmp_dir}/snell-server"
        else
            rm -rf "$tmp_dir"
            fail "Snell Server 解包失败"
            return 1
        fi
    fi
    mkdir -p "$snell_dir" || { rm -rf "$tmp_dir"; return 1; }
    version_tmp=$(mktemp "${snell_version_file}.tmp.XXXXXX") || { rm -rf "$tmp_dir"; return 1; }
    printf 'v%s\n' "$version" > "$version_tmp" || { rm -f "$version_tmp"; rm -rf "$tmp_dir"; return 1; }
    if ! mv -f "${tmp_dir}/snell-server" "$snell_bin"; then
        rm -f "$version_tmp"; rm -rf "$tmp_dir"; fail "无法安装 Snell Server 主程序"; return 1
    fi
    if ! mv -f "$version_tmp" "$snell_version_file"; then
        rm -f "$version_tmp"; rm -rf "$tmp_dir"; fail "无法记录 Snell Server 版本"; return 1
    fi
    rm -rf "$tmp_dir"
}

downloadSnell(){
    getSnellDownloadUrl "$1" || return 1
    installFromZip "$1" "$2" "$snell_url"
}

# Config
resetConfigState(){
    listen_val=""; port=""; ver=""; ipv6="false"; psk=""; obfs="off"; host=""; tfo="true"
    dns_ip_pref=""; mode=""; egress_interface=""
}

writeConfig(){
    mkdir -p "$snell_dir" || fail "无法创建 Snell 配置目录" || return 1
    local tmp_conf
    tmp_conf=$(mktemp "${snell_conf}.tmp.XXXXXX") || fail "无法创建临时配置文件" || return 1
    chmod 600 "$tmp_conf" || { rm -f "$tmp_conf"; fail "无法保护临时配置文件"; return 1; }
    {
        printf '%s\n' "[snell-server]"
        printf '%s\n' "listen = ${listen_val}"
        if [ "$ver" != "6" ]; then
            printf '%s\n' "ipv6 = ${ipv6}"
            printf '%s\n' "psk = ${psk}"
            printf '%s\n' "obfs = ${obfs}"
            [ "$obfs" != "off" ] && printf '%s\n' "obfs-host = ${host}"
        else
            printf '%s\n' "# ipv6 = ${ipv6}"
            printf '%s\n' "psk = ${psk}"
            printf '%s\n' "# obfs = ${obfs}"
            [ "$obfs" != "off" ] && printf '%s\n' "# obfs-host = ${host}"
        fi
        printf '%s\n' "tfo = ${tfo}"
        if [ "$ver" = "6" ]; then
            printf '%s\n' "dns-ip-preference = ${dns_ip_pref:-default}"
            printf '%s\n' "mode = ${mode:-default}"
        else
            [ -n "$dns_ip_pref" ] && printf '%s\n' "# dns-ip-preference = ${dns_ip_pref}"
            [ -n "$mode" ] && printf '%s\n' "# mode = ${mode}"
        fi
        [ -n "$egress_interface" ] && printf '%s\n' "egress-interface = ${egress_interface}"
        printf '%s\n' "version = ${ver}"
    } > "$tmp_conf" || { rm -f "$tmp_conf"; fail "无法生成 Snell 配置"; return 1; }

    if [ -f "$snell_conf" ]; then
        custom_configs=$(awk -F '=' '
            /^[[:space:]]*\[/ { in_snell = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); if (!in_snell) print $0; next }
            !in_snell { if ($0 !~ /^[[:space:]]*$/) print $0; next }
            /^[[:space:]]*#/ { next }
            {
                key=$1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
                if (key != "listen" && key != "ipv6" && key != "psk" && key != "obfs" && key != "obfs-host" && key != "tfo" && key != "dns-ip-preference" && key != "mode" && key != "version" && key != "egress-interface" && NF > 0 && $0 !~ /^[[:space:]]*$/) print $0
            }
        ' "$snell_conf")
        if [ -n "$custom_configs" ]; then
            printf '\n%s\n%s\n' "# Custom Configs" "$custom_configs" >> "$tmp_conf"
        fi
    fi
    mv -f "$tmp_conf" "$snell_conf" || { rm -f "$tmp_conf"; fail "无法替换 Snell 配置文件"; return 1; }
    chmod 600 "$snell_conf" || fail "无法设置配置文件权限" || return 1
    if id "$snell_user" >/dev/null 2>&1; then
        chown "${snell_user}:${snell_user}" "$snell_conf" || fail "无法设置配置文件属主" || return 1
    fi
}

readConfig(){
    [ -e "$snell_conf" ] || fail "Snell Server 配置文件不存在！" || return 1
    resetConfigState
    local conf_tmp key val
    conf_tmp=$(mktemp /tmp/snell_config_parse.XXXXXX) || fail "无法创建配置解析临时文件" || return 1
    chmod 600 "$conf_tmp" || { rm -f "$conf_tmp"; return 1; }
    awk -F '=' '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { in_snell = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
        !in_snell || NF < 2 { next }
        {
            key=$1; value=$0; sub(/^[^=]*=/, "", value)
            sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
            sub(/^[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
            print key "=" value
        }
    ' "$snell_conf" > "$conf_tmp" || { rm -f "$conf_tmp"; fail "无法解析 Snell 配置文件"; return 1; }
    while IFS='=' read -r key val; do
        case "$key" in
            listen) listen_val="$val"; port=$(printf '%s' "$val" | awk -F',' '{print $1}' | sed 's/.*://') ;;
            ipv6) ipv6="$val" ;;
            psk) psk="$val" ;;
            obfs) obfs="$val" ;;
            obfs-host) host="$val" ;;
            tfo) tfo="$val" ;;
            version) ver="$val" ;;
            dns-ip-preference) dns_ip_pref="$val" ;;
            mode) mode="$val" ;;
            egress-interface) egress_interface="$val" ;;
        esac
    done < "$conf_tmp"
    rm -f "$conf_tmp"
    [ -n "$listen_val" ] && [ -n "$port" ] && [ -n "$psk" ] || fail "Snell 配置缺少 listen 或 psk" || return 1
    case "$ver" in 5|6) ;; *) fail "Snell 配置中的 version 无效，仅支持 5 或 6"; return 1 ;; esac
    printf '%s' "$port" | grep -qE '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "Snell 配置中的监听端口无效" || return 1
    if [ "$ver" = "6" ]; then
        [ -n "$dns_ip_pref" ] || dns_ip_pref="default"
        [ -n "$mode" ] || mode="default"
    fi
    return 0
}

checkPskForV6(){
    [ ${#psk} -ge 16 ] && [ ${#psk} -le 255 ] && return 0
    echo -e "${Error} 当前密钥长度为 ${#psk}，不符合 Snell v6 要求（16-255 位）"
    echo " 1) 自动生成随机密钥"
    echo " 2) 手动输入新密钥"
    while true; do
        readInput "请选择 [1/2]（默认 1）: "
        case "${REPLY:-1}" in
            1) psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20); ok "已自动生成新密钥: ${Green_font_prefix}${psk}${Font_color_suffix}"; return 0 ;;
            2)
                while true; do
                    readInput "请输入新的密钥 [16-255 位]: "
                    [ ${#REPLY} -ge 16 ] && [ ${#REPLY} -le 255 ] && { psk=$REPLY; return 0; }
                    echo -e "${Error} 密钥长度必须在 16 到 255 位之间！"
                done
                ;;
            *) echo -e "${Error} 输入无效，仅支持 1 或 2" ;;
        esac
    done
}

showSettingResult(){
    echo; echo -e "$1"; echo
}

setPort(){
    local orig_port="$port" input_port
    echo -e "${Tip} 请手动放行防火墙端口（脚本不操作系统防火墙）"
    while true; do
        if [ -n "$port" ]; then
            readInput "请输入端口 [1-65535]（当前 ${port}，回车保留）："
        else
            readInput "请输入端口 [1-65535]（默认 8443）："
        fi
        input_port="${REPLY:-${port:-8443}}"
        if ! echo "$input_port" | grep -qE '^[0-9]+$' || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
            echo -e "${Error} 端口无效，请输入 1-65535 之间的数字"
            continue
        fi
        port=$input_port
        listen_val="::0:${port}"
        if [ "$port" != "$orig_port" ] && ss -tuln | grep -q ":$port "; then
            echo -e "${Error} 端口 $port 已被占用，请选择其他端口"
        else
            showSettingResult "端口 : ${Red_background_prefix} ${port} ${Font_color_suffix}"
            break
        fi
    done
}

chooseOption(){
    local title="$1" current="$2" default_opt="$3"
    shift 3
    echo; echo "$title"
    printf '%s\n' "$@"
    if [ -n "$current" ]; then
        readInput "选择（当前 ${current}，回车保留）："
    else
        readInput "选择（默认 ${default_opt}）："
    fi
    [ -z "$REPLY" ] && REPLY="${current:-$default_opt}"
}

setIpv6(){
    local current_opt=2
    [ "$ipv6" = "true" ] && current_opt=1
    while true; do
        chooseOption "IPv6 解析" "$current_opt" 2 " 1) 开启" " 2) 关闭"
        case "$REPLY" in
            1) ipv6=true; break ;;
            2) ipv6=false; break ;;
            *) echo -e "${Error} 输入无效，仅支持 1 或 2" ;;
        esac
    done
    showSettingResult "IPv6 解析 开启状态：${Red_background_prefix} ${ipv6} ${Font_color_suffix}"
}

setPSK(){
    echo "密钥设置（回车生成随机密钥；已有密钥回车保留）"
    if [ "$ver" = "6" ]; then
        echo -e "${Tip} Snell v6 密钥长度要求：16-255 位"
        while true; do
            if [ -n "$psk" ]; then
                readInput "请输入密钥（已有密钥，回车保留）："
            else
                readInput "请输入密钥（回车随机生成）："
            fi
            if [ -z "$REPLY" ] && [ -n "$psk" ]; then
                break
            elif [ -z "$REPLY" ]; then
                psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20); break
            elif [ ${#REPLY} -ge 16 ] && [ ${#REPLY} -le 255 ]; then
                psk=$REPLY; break
            else
                echo -e "${Error} 密钥长度必须在 16 到 255 位之间"
            fi
        done
    else
        if [ -n "$psk" ]; then
            readInput "请输入密钥（已有密钥，回车保留）："
        else
            readInput "请输入密钥（回车随机生成）："
        fi
        if [ -z "$REPLY" ] && [ -z "$psk" ]; then
            psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        elif [ -n "$REPLY" ]; then
            psk=$REPLY
        fi
    fi
    showSettingResult "密钥已设置"
}

setHost(){
    echo "请输入 Snell Server 域名，Snell v5 版本及以上如无特别需求可忽略。"
    while true; do
        if [ -n "$host" ]; then
            readInput "请输入域名（当前 ${host}，回车保留）："
        else
            readInput "请输入域名（默认 www.wechat.com）："
        fi
        if [ -z "$REPLY" ]; then
            host="${host:-www.wechat.com}"; break
        fi
        case "$REPLY" in
            *[!A-Za-z0-9.-]*) echo -e "${Error} 域名格式无效，请勿包含空格或特殊字符" ;;
            *) host="$REPLY"; break ;;
        esac
    done
    showSettingResult "域名 : ${Red_background_prefix} ${host} ${Font_color_suffix}"
}

setObfs(){
    local current_opt=3
    [ "$obfs" = "tls" ] && current_opt=1
    [ "$obfs" = "http" ] && current_opt=2
    while true; do
        chooseOption "OBFS 设置" "$current_opt" 3 " 1) TLS" " 2) HTTP" " 3) 关闭"
        case "$REPLY" in
            1) obfs=tls; setHost; break ;;
            2) obfs=http; setHost; break ;;
            3) obfs=off; host=""; break ;;
            *) echo -e "${Error} 输入无效，仅支持 1、2 或 3" ;;
        esac
    done
    if [ "$obfs" != "off" ]; then
        showSettingResult "OBFS 状态：${Red_background_prefix} ${obfs} ${Font_color_suffix}\nOBFS 域名：${Red_background_prefix} ${host} ${Font_color_suffix}"
    else
        showSettingResult "OBFS 状态：${Red_background_prefix} ${obfs} ${Font_color_suffix}"
    fi
}

setVer(){
    local current_opt=1
    [ "$ver" = "6" ] && current_opt=2
    if [ -n "$ver" ]; then
        readInput "协议版本 [1=v5 / 2=v6]（当前 ${current_opt}，回车保留）："
    else
        readInput "协议版本 [1=v5 / 2=v6]（默认 1）："
    fi
    case "${REPLY:-$current_opt}" in
        1) ver=5 ;;
        2) ver=6 ;;
        *) echo -e "${Error} 输入无效，仅支持 1 或 2"; return 1 ;;
    esac
    showSettingResult "Snell Server 协议版本：${Red_background_prefix} v${ver} ${Font_color_suffix}"
}

setTFO(){
    local current_opt=1
    [ "$tfo" = "false" ] && current_opt=2
    while true; do
        chooseOption "TCP Fast Open" "$current_opt" 1 " 1) 开启" " 2) 关闭"
        case "$REPLY" in
            1) tfo=true; break ;;
            2) tfo=false; break ;;
            *) echo -e "${Error} 输入无效，仅支持 1 或 2" ;;
        esac
    done
    showSettingResult "Snell TFO 开启状态：${Red_background_prefix} ${tfo} ${Font_color_suffix}"
}

setDNSIPPref(){
    local current_opt=1
    case "$dns_ip_pref" in prefer-ipv4) current_opt=2 ;; prefer-ipv6) current_opt=3 ;; ipv4-only) current_opt=4 ;; ipv6-only) current_opt=5 ;; esac
    while true; do
        chooseOption "DNS IP 偏好" "$current_opt" 1 " 1) default" " 2) prefer-ipv4" " 3) prefer-ipv6" " 4) ipv4-only" " 5) ipv6-only"
        case "$REPLY" in
            1) dns_ip_pref=default; break ;;
            2) dns_ip_pref=prefer-ipv4; break ;;
            3) dns_ip_pref=prefer-ipv6; break ;;
            4) dns_ip_pref="ipv4-only"; break ;;
            5) dns_ip_pref="ipv6-only"; break ;;
            *) echo -e "${Error} 输入无效，仅支持 1 到 5" ;;
        esac
    done
    showSettingResult "DNS IP 偏好 状态：${Red_background_prefix} ${dns_ip_pref} ${Font_color_suffix}"
}

setMode(){
    local current_opt=1
    [ "$mode" = "unshaped" ] && current_opt=2
    [ "$mode" = "unsafe-raw" ] && current_opt=3
    while true; do
        chooseOption "混淆模式" "$current_opt" 1 " 1) default" " 2) unshaped" " 3) unsafe-raw"
        case "$REPLY" in
            1) mode=default; break ;;
            2) mode=unshaped; break ;;
            3) mode=unsafe-raw; break ;;
            *) echo -e "${Error} 输入无效，仅支持 1、2 或 3" ;;
        esac
    done
    showSettingResult "混淆模式：${Red_background_prefix} ${mode} ${Font_color_suffix}"
}

collectVersionSettings(){
    if [ "$ver" = "6" ]; then
        setDNSIPPref; setMode; checkPskForV6
    else
        setObfs
    fi
}

# Workflow
captureServiceState(){
    service_was_running=false
    checkStatus
    [ "$status" = "running" ] && service_was_running=true
}

replaceServerBinary(){
    captureServiceState
    if [ "$service_was_running" = true ] && ! svc stop; then
        fail "无法停止当前服务"
        return 1
    fi
    downloadSnell "$1" "$2"
}

restoreServiceState(){
    if [ "$service_was_running" != true ]; then
        ok "$2"
        return 0
    fi
    if svc start && waitServiceStart; then
        ok "$1"
    else
        echo -e "${Error} 服务启动失败，以下为错误日志："
        showServiceLog
        return 1
    fi
}

applyBinaryChange(){
    local version="$1" label="$2" ok_msg="$3" stop_msg="$4"
    replaceServerBinary "$version" "$label" || {
        echo -e "${Error} 下载失败，已保持当前版本"
        restoreServiceState "已恢复当前版本服务" "服务保持停止状态"
        return 1
    }
    writeConfig || fail "配置写入失败" || return 1
    restoreServiceState "$ok_msg" "$stop_msg"
}

runWorkflow(){
    local action="$1" target="$2" current
    case "$action" in
        install)
            installDependencies || return 1
            setPort; setPSK
            if [ "$target" = "6" ]; then
                setTFO; setDNSIPPref; setMode
            else
                setObfs; setIpv6; setTFO
            fi
            if [ "$target" = "6" ]; then
                downloadSnell "$snell_v6_version" "Snell v6 官网源版" || { cleanupFailedInstall; return 1; }
            else
                downloadSnell "$snell_v5_version" "Snell v5 官网源版" || { cleanupFailedInstall; return 1; }
            fi
            if ! setupServiceUser || ! setupService || ! writeConfig; then
                cleanupFailedInstall
                fail "Snell Server 安装配置失败"
                return 1
            fi
            startSnell || return 1
            viewConfig
            ;;
        switch)
            current="$3"
            collectVersionSettings
            applyBinaryChange "$(pickVersion "$target")" "Snell v${target} 版本" "Snell Server 重启完毕！" "版本切换完成，服务保持停止状态" || {
                ver=$current
                writeConfig
                return 1
            }
            ;;
        update)
            applyBinaryChange "$target" "Snell v6 最新版本" "Snell Server 更新完成" "更新完成，服务保持停止状态"
            ;;
    esac
}

# Commands
simpleHeader(){
    clearScreen
    echo
    if [ -e "$snell_bin" ] && [ -e "$snell_conf" ]; then
        checkStatus
        header_ver=$(sed 's/^v//' "$snell_version_file" 2>/dev/null)
        [ -z "$header_ver" ] && header_ver=$(confVersion)
        printf 'server: v%s · %s\n' "$header_ver" "$status"
    else
        echo 'server: not installed'
    fi
}

startSnell(){
    checkInstalledStatus || return 1
    checkStatus
    [ "$status" = "running" ] && return 0
    if ! svc start || ! waitServiceStart; then
        fail "Snell Server 启动失败"
        echo -e "${Tip} 请检查配置文件、端口占用和防火墙规则"
        showServiceLog
        return 1
    fi
}

stopSnell(){
    checkInstalledStatus || return 1
    checkStatus
    [ "$status" = "running" ] || fail "Snell Server 没有运行，请检查！" || return 1
    svc stop || fail "Snell Server 停止命令失败" || return 1
    ok "Snell Server 已停止"
    sleep 1
}

restartSnell(){
    checkInstalledStatus || return 1
    if svc restart && waitServiceStart; then
        ok "Snell Server 已重启"
    else
        fail "Snell Server 重启后未运行"
        showServiceLog
    fi
    sleep 1
}

installSnell(){
    if hasSnellArtifacts; then
        echo -e "${Error} 检测到 Snell Server 已安装或存在残留文件！"
        echo -e "${Tip} 请先选择「卸载 Snell Server」清理后再安装"
        sleep 1
        return 1
    fi
    simpleHeader
    echo
    echo "安装版本"
    echo " 1) v5（${snell_v5_version}，稳定版）"
    echo " 2) v6（${snell_v6_version}，内置版）"
    readInput "选择 [1/2]（默认 1.v5）："
    case "${REPLY:-1}" in
        1) ver=5 ;;
        2) ver=6 ;;
        *) fail "输入无效，仅支持 1 或 2"; return 1 ;;
    esac
    echo -e "${Tip} 即将安装 Snell v${ver}（默认配置，安装后可用「设置配置」调整）"
    askConfirm "确认安装？(Y/n)（默认 y）: " y || { ok "已取消安装"; return 0; }
    runWorkflow install "$ver"
}

applyConfigChange(){
    simpleHeader
    "$1" || fail "配置项设置失败" || return 1
    writeConfig || return 1
    restartSnell
}

confirmVersionSwitch(){
    local current="$1"
    setVer || { ver=$current; return 1; }
    [ "$ver" = "$current" ] && return 0
    if [ "$ver" -gt "$current" ]; then
        echo -e "${Info} 协议版本将从 Snell v${current} 升级到 Snell v${ver}"
    else
        echo -e "${Info} 协议版本将从 Snell v${current} 降级到 Snell v${ver}"
    fi
    askConfirm "确认切换？（默认 n）: " n || { ok "已取消切换，保持原版本"; ver=$current; return 1; }
}

setConfig(){
    checkInstalledStatus || return 1
    local cver
    while true; do
        readConfig || break
        cver="$ver"
        simpleHeader
        echo
        echo "设置配置（当前 Snell v${cver}）"
        echo " 1) 设置监听端口"
        echo " 2) 设置密钥"
        if [ "$cver" != "6" ]; then
            echo " 3) 设置 OBFS"
            echo " 4) 设置 OBFS 域名"
            echo " 5) 设置 IPv6 解析"
        fi
        echo " 6) 设置 TCP Fast Open"
        echo " 7) 切换协议版本"
        if [ "$cver" = "6" ]; then
            echo " 8) 设置 DNS IP 偏好"
            echo " 9) 设置混淆模式"
        fi
        echo "10) 设置全部配置"
        echo
        readInput "按回车返回主菜单: "
        [ -z "$REPLY" ] && break
        case "$REPLY" in
            1) applyConfigChange setPort ;;
            2) applyConfigChange setPSK ;;
            3) applyConfigChange setObfs ;;
            4)
                [ "$obfs" != "off" ] || { echo -e "${Error} OBFS 当前为 off，无法设置 OBFS 域名。"; sleep 1; continue; }
                applyConfigChange setHost
                ;;
            5) applyConfigChange setIpv6 ;;
            6) applyConfigChange setTFO ;;
            7)
                confirmVersionSwitch "$cver" || { sleep 1; continue; }
                if [ "$ver" != "$cver" ]; then
                    runWorkflow switch "$ver" "$cver"
                else
                    writeConfig && restartSnell
                fi
                ;;
            8)
                [ "$cver" = "6" ] || { echo -e "${Error} 当前版本不是 Snell v6，不支持 DNS IP 偏好配置！"; sleep 1; continue; }
                applyConfigChange setDNSIPPref
                ;;
            9)
                [ "$cver" = "6" ] || { echo -e "${Error} 当前版本不是 Snell v6，不支持混淆模式配置！"; sleep 1; continue; }
                applyConfigChange setMode
                ;;
            10)
                confirmVersionSwitch "$cver"
                setPort; setPSK
                [ "$ver" != "6" ] && setIpv6
                setTFO
                if [ "$ver" != "$cver" ]; then
                    runWorkflow switch "$ver" "$cver"
                else
                    collectVersionSettings
                    writeConfig && restartSnell
                fi
                ;;
            *) echo -e "${Error} 请输入正确数字${Yellow_font_prefix}[1-10]${Font_color_suffix}"; sleep 1 ;;
        esac
    done
}

updateSnell(){
    checkInstalledStatus || return 1
    readConfig || return 1
    if [ "$ver" = "5" ]; then
        echo -e "${Tip} 即将从 Snell v5 升级到 v6，并保留端口与密钥"
        askConfirm "确认升级？(y/N)（默认 n）: " n || { ok "已取消升级"; return 0; }
        ver=6
        runWorkflow switch 6 5
        return
    fi

    local installed latest candidate script_ver web_ver
    installed=$(readInstalledVersion 2>/dev/null) || { echo -e "${Tip} 无法识别当前 Snell 版本，已跳过更新检查"; sleep 1; return 0; }
    latest="$installed"
    script_ver=$snell_v6_version
    web_ver=$(getLatestVersionFromWeb "v6")
    for candidate in "$script_ver" "$web_ver"; do
        [ -n "$candidate" ] || continue
        compareVersions "$latest" "$candidate"
        [ $? -eq 2 ] && validateVersionUrl "$candidate" && latest="$candidate"
    done
    if ! compareVersions "$installed" "$latest"; then
        :
    fi
    compareVersions "$installed" "$latest"
    if [ $? -ne 2 ]; then
        ok "当前已是最新版本：v${installed}"
        sleep 1
        return 0
    fi
    echo -e "${Tip} 发现更新：v${installed} → v${latest}"
    askConfirm "确认更新？(Y/n，默认 y)：" y || return 0
    runWorkflow update "$latest"
}

uninstallSnell(){
    hasSnellArtifacts || fail "Snell Server 没有安装！" || return 1
    local full_ver
    full_ver=$(sed 's/^v//' "$snell_version_file" 2>/dev/null)
    echo -e "${Error} 即将卸载 Snell Server："
    echo "  - 版本：${Yellow_font_prefix}v${full_ver:-?}${Font_color_suffix}"
    echo "  - 将移除：主程序、服务、配置文件（/etc/snell）"
    echo
    while true; do
        readInput "确认卸载？(y/N)（默认 n）: "
        case "${REPLY:-n}" in
            [Yy]) break ;;
            [Nn]) echo; echo "卸载已取消"; sleep 1; return 0 ;;
            *) echo -e "${Error} 请输入 y 或 n" ;;
        esac
    done
    ok "停止并禁用服务"
    checkStatus
    if [ "$status" = "running" ]; then
        svc stop || fail "无法停止 Snell Server，取消卸载" || return 1
    fi
    case "$(serviceBackend)" in
        systemd) systemctl disable snell-server 2>/dev/null ;;
        openrc) rc-update del snell-server default 2>/dev/null ;;
    esac
    stopOrphanedProcesses
    ok "移除主程序"; rm -rf "$snell_bin"
    ok "移除服务文件"
    rm -f /etc/systemd/system/snell-server.service /etc/init.d/snell-server
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    ok "移除系统用户"; removeServiceUser
    ok "移除配置文件及版本记录"; rm -rf /etc/snell
    ok "清理运行时文件"; rm -f /run/snell-server.pid /var/log/snell-server.log
    echo; echo -e "${Green_font_prefix}Snell Server 卸载完成！${Font_color_suffix}"; echo
    sleep 1
}

getIpv4(){
    for src in https://ipinfo.io/ip https://api.ip.sb/ip https://members.3322.org/dyndns/getip; do
        ipv4=$(curl -fsSL4 --connect-timeout 2 --max-time 5 "$src" 2>/dev/null)
        [ -n "$ipv4" ] && return 0
    done
    ipv4="IPv4_Error"
}

getIpv6(){
    ip6=$(curl -fsSL6 --connect-timeout 2 --max-time 5 https://ifconfig.co 2>/dev/null)
    [ -z "$ip6" ] && ip6="IPv6_Error"
}

printSurgeLine(){
    local addr="$1"
    if [ "$ver" = "6" ]; then
        if [ -n "$mode" ]; then
            echo "$(uname -n) = snell, ${addr}, ${port}, psk=${psk}, version=${ver}, mode=${mode}, reuse=true, tfo=${tfo}"
        else
            echo "$(uname -n) = snell, ${addr}, ${port}, psk=${psk}, version=${ver}, reuse=true, tfo=${tfo}"
        fi
    elif [ "$obfs" != "off" ]; then
        echo "$(uname -n) = snell, ${addr}, ${port}, psk=${psk}, version=${ver}, obfs=${obfs}, obfs-host=${host}, reuse=true, tfo=${tfo}"
    else
        echo "$(uname -n) = snell, ${addr}, ${port}, psk=${psk}, version=${ver}, reuse=true, tfo=${tfo}"
    fi
}

viewConfig(){
    checkInstalledStatus || return 1
    readConfig || return 1
    local ip_tmp_dir
    ip_tmp_dir=$(mktemp -d /tmp/snell-view.XXXXXX)
    if [ -n "$ip_tmp_dir" ]; then
        ( getIpv4; printf '%s\n' "$ipv4" > "${ip_tmp_dir}/ipv4" ) &
        ( getIpv6; printf '%s\n' "$ip6" > "${ip_tmp_dir}/ipv6" ) &
        wait
        ipv4=$(cat "${ip_tmp_dir}/ipv4" 2>/dev/null)
        ip6=$(cat "${ip_tmp_dir}/ipv6" 2>/dev/null)
        rm -rf "$ip_tmp_dir"
    else
        ipv4="IPv4_Error"; ip6="IPv6_Error"
    fi
    simpleHeader
    echo
    echo "配置"
    if [ "$ipv4" != "IPv4_Error" ]; then
        address="$ipv4"
    elif [ "$ip6" != "IPv6_Error" ]; then
        address="[$ip6]"
    else
        address="获取失败"
    fi
    echo "配置文件  : ${snell_conf}"
    echo "IPv4 地址 : ${address}"
    echo "端口      : ${port}"
    echo "密钥      : ${psk}"
    echo "版本      : v${ver}"
    echo "TFO       : ${tfo}"
    if [ "$ver" != "6" ]; then
        echo "OBFS      : ${obfs}"
        [ "$obfs" != "off" ] && [ -n "$host" ] && echo "域名      : ${host}"
        echo "IPv6      : ${ipv6}"
    else
        echo "DNS IP    : ${dns_ip_pref}"
        echo "模式      : ${mode}"
    fi
    [ -n "$egress_interface" ] && echo "出口网卡  : ${egress_interface}"
    echo
    echo "Surge 配置："
    if [ "$ipv4" != "IPv4_Error" ]; then
        printSurgeLine "$ipv4"
    elif [ "$ip6" != "IPv6_Error" ]; then
        printSurgeLine "[${ip6}]"
    else
        echo -e "${Error} 无法获取 IP 地址！"
    fi
    pauseMenu
}

viewStatus(){
    checkInstalledStatus || return 1
    readConfig || return 1
    simpleHeader
    echo
    echo "状态"
    local full_ver pid start_time
    full_ver=$(sed 's/^v//' "$snell_version_file" 2>/dev/null)
    [ -z "$full_ver" ] && full_ver=$(confVersion)
    echo "版本      : v${full_ver}"
    echo "配置文件  : ${snell_conf}"
    echo "监听端口  : ${port}"
    checkStatus
    if [ "$status" = "running" ]; then
        echo "服务状态  : 运行中"
        [ -f /run/snell-server.pid ] && pid=$(cat /run/snell-server.pid 2>/dev/null)
        [ -z "$pid" ] && pid=$(pgrep -f "snell-server -c" 2>/dev/null | head -1)
        [ -n "$pid" ] && echo "进程 PID  : ${pid}"
        start_time=$(ps -o lstart= -p "$pid" 2>/dev/null)
        [ -z "$start_time" ] && start_time=$(ps -o pid=,etime= 2>/dev/null | awk -v p="$pid" '$1==p{print $2}' | head -1)
        [ -n "$start_time" ] && echo "启动时间  : ${start_time}"
        if ss -tln | grep -q ":$port "; then echo "TCP   : 正常"; else echo "TCP   : 异常"; fi
        ss -uln | grep -q ":$port " && echo "UDP   : 正常"
    else
        echo "服务  : 未运行"
        ss -tuln | grep -q ":$port " && echo "端口  : 被其他程序占用"
    fi
    echo
    case "$(serviceBackend)" in
        systemd) echo "日志  : journalctl -u snell-server -n 50" ;;
        openrc) echo "日志  : tail -50 /var/log/snell-server.log" ;;
    esac
    pauseMenu
}

startMenu(){
    while true; do
        simpleHeader
        echo
        echo ' 1) 安装服务    2) 启动服务'
        echo ' 3) 停止服务    4) 重启服务'
        echo ' 5) 设置配置    6) 查看配置'
        echo ' 7) 查看状态    8) 更新服务'
        echo ' 9) 卸载服务    0) 退出脚本'
        echo
        readInput ""
        case "$REPLY" in
            0) echo -e "${Info} 已退出脚本，再见！"; exit 0 ;;
            1) installSnell ;;
            2) startSnell ;;
            3) stopSnell ;;
            4) restartSnell ;;
            5) setConfig ;;
            6) viewConfig ;;
            7) viewStatus ;;
            8)
                if [ -e "$snell_bin" ] && [ -e "$snell_conf" ]; then
                    updateSnell
                else
                    fail "请先安装 Snell Server"
                fi
                ;;
            9) uninstallSnell ;;
            *) echo -e "${Error} 输入无效，请输入 0-9 之间的数字"; sleep 1 ;;
        esac
    done
}

checkRoot
checkSys
sysArch || exit 1
ensureServiceSecurity || exit 1
startMenu

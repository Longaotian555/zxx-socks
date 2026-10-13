#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

SERVICE="my-socks5"
CONF="/etc/my-socks5.conf"
UNIT="/etc/systemd/system/${SERVICE}.service"
SELF="/usr/local/bin/s5"

trap 'printf "\n操作失败（第 %s 行），请查看上方报错。\n" "$LINENO" >&2' ERR

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    read -rp "$1 [y/N]： " answer || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

random_hex() {
    od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

random_account() {
    ACCOUNT="u$(random_hex 4)"
    PASSWORD="$(random_hex 16)"
}

random_port() {
    local candidate listeners i
    local previous="${PORT:-}"

    for ((i = 0; i < 100; i++)); do
        candidate="$(shuf -i 10000-65000 -n 1)"
        listeners="$(ss -H -lntu "sport = :$candidate")"

        if [[ "$candidate" != "$previous" && -z "$listeners" ]]; then
            PORT="$candidate"
            return 0
        fi
    done

    echo "未找到空闲端口，请稍后重试。" >&2
    return 1
}

load_config() {
    if [[ ! -f "$CONF" ]]; then
        echo "尚未安装，请先选择菜单 1。" >&2
        return 1
    fi

    PORT=""
    ACCOUNT=""
    PASSWORD=""

    source "$CONF" || return 1

    if [[ "$PORT" =~ ^[1-9][0-9]{3,4}$ ]] &&
       ((PORT >= 1024 && PORT <= 65535)) &&
       [[ "$ACCOUNT" =~ ^[A-Za-z0-9]+$ ]] &&
       [[ "$PASSWORD" =~ ^[A-Za-z0-9]+$ ]]; then
        return 0
    fi

    echo "配置文件内容无效，请检查 $CONF。" >&2
    return 1
}

public_ipv4() {
    local url ip

    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com"; do

        if ip="$(
            curl -4fsS \
                --noproxy '*' \
                --connect-timeout 3 \
                --max-time 5 \
                "$url" 2>/dev/null
        )"; then
            ip="$(printf '%s' "$ip" | tr -d '[:space:]')"

            if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    done

    return 1
}

show_info() {
    load_config || return 0

    local ip

    if ! ip="$(public_ipv4)"; then
        ip="你的VPS公网IPv4"
        echo "未能自动查询公网 IPv4，请在客户端手动填写。"
    fi

    printf '\n========== SOCKS5 连接信息 ==========\n'
    printf '服务器：%s\n' "$ip"
    printf '端口：%s\n' "$PORT"
    printf '账号：%s\n' "$ACCOUNT"
    printf '密码：%s\n' "$PASSWORD"
    printf '协议：SOCKS5\n'
    printf '状态：'
    systemctl is-active "$SERVICE" || true

    printf '\n参考链接：\n'
    printf 'socks5://%s:%s@%s:%s\n' \
        "$ACCOUNT" "$PASSWORD" "$ip" "$PORT"

    printf '\n客户端若无法导入链接，请手动填写以上信息。\n'
    printf '请在云安全组和服务器防火墙中放行 TCP %s。\n' "$PORT"
    printf '====================================\n\n'
}

apply_config() {
    [[ -x /usr/bin/microsocks ]] ||
        die "未找到 MicroSOCKS，请先选择菜单 1 安装依赖。"

    (
        umask 077

        printf 'PORT=%q\nACCOUNT=%q\nPASSWORD=%q\n' \
            "$PORT" "$ACCOUNT" "$PASSWORD" > "$CONF"

        cat > "$UNIT" <<EOF
[Unit]
Description=Personal SOCKS5 Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
ExecStart=/usr/bin/microsocks -i 0.0.0.0 -p ${PORT} -u ${ACCOUNT} -P ${PASSWORD}
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

        chmod 600 "$CONF" "$UNIT"
    )

    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
    systemctl restart "$SERVICE"

    sleep 1

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "服务启动失败，近期日志如下：" >&2
        journalctl -u "$SERVICE" -n 30 --no-pager || true
        return 1
    fi
}

check_connection() {
    load_config || return 1

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "代理服务没有运行，请选择菜单 9 启动服务。"
        return 1
    fi

    echo "正在检测本机 SOCKS5 认证、远程 DNS 和 HTTPS 出站连接..."
    printf '代理出口 IPv4：'

    if curl -4fsS \
        --noproxy "" \
        --connect-timeout 8 \
        --max-time 25 \
        --proxy "socks5h://127.0.0.1:$PORT" \
        --proxy-user "$ACCOUNT:$PASSWORD" \
        "https://api.ipify.org"; then

        printf '\n本机代理测试成功。\n'
        printf '外部客户端连接还需要放行 TCP %s。\n' "$PORT"
    else
        printf '\n本机检测未通过。\n'
        echo "请检查代理服务、服务器出网、DNS 或检测网站是否可访问。"
        echo "近期服务日志如下："
        journalctl -u "$SERVICE" -n 20 --no-pager || true
        return 1
    fi
}

install_proxy() {
    echo "正在安装依赖..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        microsocks \
        curl \
        ca-certificates \
        iproute2 \
        coreutils

    if [[ -f "$CONF" ]]; then
        load_config || return 1
        echo "发现已有配置，保留现有账号、密码和端口。"
    else
        PORT=""
        random_account
        random_port
    fi

    apply_config

    echo "SOCKS5 安装完成，已设置开机启动。"
    show_info
    check_connection || true
}

reset_account() {
    load_config || return 0

    confirm "更换后，客户端需要更新账号和密码，继续吗？" ||
        return 0

    random_account
    apply_config

    echo "账号和密码已更新。"
    show_info
}

reset_port() {
    load_config || return 0

    confirm "更换后，需要更新客户端端口并放行新端口，继续吗？" ||
        return 0

    local previous="$PORT"

    random_port
    apply_config

    printf '端口已从 %s 更换为 %s。\n' "$previous" "$PORT"
    show_info
}

manage_service() {
    load_config || return 0

    systemctl "$1" "$SERVICE"

    printf '当前服务状态：'
    systemctl is-active "$SERVICE" || true
}

show_status() {
    systemctl status "$SERVICE" --no-pager || true
}

show_logs() {
    journalctl -u "$SERVICE" -n 50 --no-pager || true
}

uninstall_proxy() {
    if [[ ! -f "$CONF" && ! -f "$UNIT" ]]; then
        echo "尚未安装代理服务。"
        return 0
    fi

    confirm "确认停止并卸载 SOCKS5 服务及配置？" ||
        return 0

    if [[ -f "$UNIT" ]]; then
        systemctl disable --now "$SERVICE"
    fi

    rm -f -- "$CONF" "$UNIT"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true

    echo "代理服务及配置已卸载。"
    echo "以后输入 s5，可以重新打开菜单安装。"
}

main() {
    [[ $EUID -eq 0 ]] ||
        die "请使用 root 运行；可以先执行 sudo -i。"

    command -v apt-get >/dev/null ||
        die "本脚本仅支持 Debian / Ubuntu。"

    command -v systemctl >/dev/null ||
        die "未找到 systemctl，需要使用 systemd 的系统。"

    [[ -d /run/systemd/system ]] ||
        die "当前系统没有运行 systemd。"

    exec </dev/tty ||
        die "无法读取终端，请在 VPS 的交互式 SSH 终端中执行。"

    local script_file="${BASH_SOURCE[0]:-}"

    [[ -n "$script_file" && -f "$script_file" ]] ||
        die "请先将脚本下载为本地文件，再使用 bash 执行。"

    if [[ "$script_file" -ef "$SELF" ]]; then
        chmod 700 "$SELF"
    else
        install -m 700 -- "$script_file" "$SELF"
    fi

    local choice

    while true; do
        cat <<'MENU'

========== 我的 SOCKS5 工具箱 ==========
1. 安装 / 修复 SOCKS5（保留已有配置）
2. 查看连接信息
3. 随机更换账号和密码
4. 随机更换端口
5. 检测本机代理连接
6. 查看服务状态
7. 重启代理
8. 停止代理
9. 启动代理
10. 卸载代理服务及配置
11. 查看近期日志
0. 退出
=======================================

MENU

        read -rp "请选择： " choice || return 0

        case "$choice" in
            1) install_proxy ;;
            2) show_info ;;
            3) reset_account ;;
            4) reset_port ;;
            5) check_connection || true ;;
            6) show_status ;;
            7) manage_service restart ;;
            8) manage_service stop ;;
            9) manage_service start ;;
            10) uninstall_proxy ;;
            11) show_logs ;;
            0) return 0 ;;
            *) echo "请输入菜单中的数字。" ;;
        esac
    done
}

main "$@"

#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

SERVICE="my-socks5"
CONF="/etc/my-socks5.conf"
ENVFILE="/etc/my-socks5.env"
UNIT="/etc/systemd/system/${SERVICE}.service"
SELF="/usr/local/bin/s5"

PORT=""
ACCOUNT=""
PASSWORD=""

trap 'printf "\n操作失败（第 %s 行），请查看上方报错。\n" "$LINENO" >&2' ERR

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    IFS= read -r -p "$1 [y/N]： " answer || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

valid_account() {
    local value="$1"

    [[ ${#value} -ge 1 &&
       ${#value} -le 255 &&
       "$value" =~ ^[A-Za-z0-9_.-]+$ ]]
}

valid_password() {
    local value="$1"

    [[ ${#value} -ge 1 &&
       ${#value} -le 255 &&
       ! "$value" =~ [^[:print:]] ]]
}

valid_port() {
    local value="$1"

    [[ "$value" =~ ^[1-9][0-9]{3,4}$ ]] &&
        ((value >= 1024 && value <= 65535))
}

random_hex() {
    od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

generate_credentials() {
    ACCOUNT="u$(random_hex 4)" || return 1
    PASSWORD="$(random_hex 16)" || return 1
}

port_is_free() {
    local listeners

    listeners="$(ss -H -ltn "sport = :$1")" || return 1
    [[ -z "$listeners" ]]
}

generate_port() {
    local candidate i

    for ((i = 0; i < 100; i++)); do
        candidate="$(shuf -i 10000-65000 -n 1)" || return 1

        if port_is_free "$candidate"; then
            PORT="$candidate"
            return 0
        fi
    done

    echo "未找到空闲 TCP 端口，请稍后重试。" >&2
    return 1
}

load_config() {
    if [[ ! -f "$CONF" ]]; then
        echo "尚未安装，请选择菜单 1。" >&2
        return 1
    fi

    PORT=""
    ACCOUNT=""
    PASSWORD=""

    if ! source "$CONF"; then
        echo "无法读取配置文件：$CONF" >&2
        return 1
    fi

    if valid_port "$PORT" &&
       valid_account "$ACCOUNT" &&
       valid_password "$PASSWORD"; then
        return 0
    fi

    echo "配置文件内容无效，请检查 $CONF。" >&2
    return 1
}

# 按 systemd EnvironmentFile 的双引号规则转义。
quote_environment() {
    local value="$1"
    local result="" char i

    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"

        case "$char" in
            '\'|'"'|'$'|'`')
                result+="\\$char"
                ;;
            *)
                result+="$char"
                ;;
        esac
    done

    printf '"%s"' "$result"
}

# 将账号和密码编码为可用于连接链接的形式。
urlencode() {
    local value="$1"
    local result="" char hex i

    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"

        case "$char" in
            [A-Za-z0-9._~-])
                result+="$char"
                ;;
            *)
                printf -v hex '%02X' "'$char"
                result+="%$hex"
                ;;
        esac
    done

    printf '%s' "$result"
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
        echo "公网 IPv4 查询失败，请在客户端手动填写。"
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
        "$(urlencode "$ACCOUNT")" \
        "$(urlencode "$PASSWORD")" \
        "$ip" "$PORT"

    printf '\n客户端无法导入链接时，请手动填写连接信息。\n'
    printf '请在云安全组和服务器防火墙中放行 TCP %s。\n' "$PORT"
    printf '====================================\n\n'
}

write_config() {
    (
        umask 077

        printf 'PORT=%q\nACCOUNT=%q\nPASSWORD=%q\n' \
            "$PORT" "$ACCOUNT" "$PASSWORD" > "$CONF" || exit 1

        {
            printf 'SOCKS_PORT="%s"\n' "$PORT" || exit 1
            printf 'SOCKS_ACCOUNT=%s\n' \
                "$(quote_environment "$ACCOUNT")" || exit 1
            printf 'SOCKS_PASSWORD=%s\n' \
                "$(quote_environment "$PASSWORD")" || exit 1
        } > "$ENVFILE" || exit 1

        cat > "$UNIT" <<'EOF' || exit 1
[Unit]
Description=Personal SOCKS5 Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
EnvironmentFile=/etc/my-socks5.env
ExecStart=/usr/bin/microsocks -i 0.0.0.0 -p ${SOCKS_PORT} -u ${SOCKS_ACCOUNT} -P ${SOCKS_PASSWORD}
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

        chmod 600 "$CONF" "$ENVFILE" || exit 1
        chmod 644 "$UNIT" || exit 1
    )
}

activate_service() {
    local listeners

    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE" >/dev/null || return 1
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" || return 1

    sleep 1

    listeners="$(ss -H -ltn "sport = :$PORT")" || return 1

    if ! systemctl is-active --quiet "$SERVICE" ||
       [[ -z "$listeners" ]]; then
        echo "服务未能正常启动，近期日志如下：" >&2
        journalctl -u "$SERVICE" -n 30 --no-pager || true
        return 1
    fi
}

apply_config() {
    if [[ ! -x /usr/bin/microsocks ]]; then
        echo "未找到 MicroSOCKS，请先选择菜单 1。" >&2
        return 1
    fi

    if ! valid_port "$PORT" ||
       ! valid_account "$ACCOUNT" ||
       ! valid_password "$PASSWORD"; then
        echo "账号、密码或端口格式无效。" >&2
        return 1
    fi

    write_config || return 1
    activate_service
}

change_config() {
    local old_port="$PORT"
    local old_account="$ACCOUNT"
    local old_password="$PASSWORD"

    PORT="$1"
    ACCOUNT="$2"
    PASSWORD="$3"

    if apply_config; then
        return 0
    fi

    echo "新配置应用失败，正在尝试恢复原配置..."

    PORT="$old_port"
    ACCOUNT="$old_account"
    PASSWORD="$old_password"

    if apply_config; then
        echo "原配置已恢复。"
    else
        echo "原配置恢复未完成，请查看服务状态和日志。" >&2
    fi

    return 1
}

check_connection() {
    load_config || return 1

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "代理没有运行，请选择菜单 10 启动服务。"
        return 1
    fi

    echo "正在检测 SOCKS5 认证、远程 DNS 和 HTTPS 出站连接..."
    printf '代理出口 IPv4：'

    if curl -4fsS \
        --noproxy "" \
        --connect-timeout 8 \
        --max-time 25 \
        --proxy "socks5h://127.0.0.1:$PORT" \
        --proxy-user "$ACCOUNT:$PASSWORD" \
        "https://api.ipify.org"; then

        printf '\n本机代理测试成功。\n'
        printf '外部连接还需要放行 TCP %s，并用客户端验证。\n' "$PORT"
    else
        printf '\n本机检测未通过。\n'
        echo "请检查服务状态、服务器出网、DNS 和检测网站。"
        echo "近期服务日志如下："
        journalctl -u "$SERVICE" -n 20 --no-pager || true
        return 1
    fi
}

install_proxy() {
    echo "正在安装依赖..."

    apt-get update || return 1

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        microsocks \
        curl \
        ca-certificates \
        iproute2 \
        coreutils || return 1

    if [[ -f "$CONF" ]]; then
        load_config || return 1
        echo "发现已有配置，保留现有账号、密码和端口。"
    else
        echo "首次安装，自动生成随机账号、密码和空闲端口。"
        generate_credentials || return 1
        generate_port || return 1
    fi

    apply_config || return 1

    echo "SOCKS5 安装完成，已设置开机启动。"
    show_info
    check_connection || true
}

custom_account() {
    load_config || return 0

    local value

    printf '当前账号：%s\n' "$ACCOUNT"
    echo "账号支持英文字母、数字、下划线、点和短横线，长度 1–255。"

    while true; do
        IFS= read -r -p "请输入新账号，直接回车取消： " value ||
            return 0

        [[ -n "$value" ]] || return 0

        if ! valid_account "$value"; then
            echo "账号格式不正确，请重新输入。"
            continue
        fi

        if [[ "$value" == "$ACCOUNT" ]]; then
            echo "账号没有变化。"
            return 0
        fi

        change_config "$PORT" "$value" "$PASSWORD" || return 1

        echo "账号已更新，请同步修改客户端账号。"
        show_info
        return 0
    done
}

custom_password() {
    load_config || return 0

    local value repeated

    echo "密码支持英文字母、数字、常用特殊符号和空格，长度 1–255。"
    echo "输入时隐藏内容，直接回车取消。"

    while true; do
        if ! IFS= read -r -s -p "请输入新密码： " value; then
            printf '\n'
            return 0
        fi
        printf '\n'

        [[ -n "$value" ]] || return 0

        if ! valid_password "$value"; then
            echo "密码格式不正确，请使用可打印的 ASCII 字符。"
            continue
        fi

        if ! IFS= read -r -s -p "请再次输入新密码： " repeated; then
            printf '\n'
            return 0
        fi
        printf '\n'

        if [[ "$value" != "$repeated" ]]; then
            echo "两次密码不一致，请重新输入。"
            continue
        fi

        if [[ "$value" == "$PASSWORD" ]]; then
            echo "密码没有变化。"
            return 0
        fi

        change_config "$PORT" "$ACCOUNT" "$value" || return 1

        echo "密码已更新，请同步修改客户端密码。"
        show_info
        return 0
    done
}

custom_port() {
    load_config || return 0

    local value previous="$PORT"

    if ! command -v ss >/dev/null; then
        echo "未找到端口检查工具，请先选择菜单 1。"
        return 1
    fi

    printf '当前端口：%s\n' "$PORT"
    echo "可设置范围：1024–65535，请输入不带前导零的整数。"

    while true; do
        IFS= read -r -p "请输入新端口，直接回车取消： " value ||
            return 0

        [[ -n "$value" ]] || return 0

        if ! valid_port "$value"; then
            echo "端口格式或范围不正确，请重新输入。"
            continue
        fi

        if [[ "$value" == "$PORT" ]]; then
            echo "端口没有变化。"
            return 0
        fi

        if ! port_is_free "$value"; then
            echo "该 TCP 端口已被占用，或端口检查失败，请换一个。"
            continue
        fi

        change_config "$value" "$ACCOUNT" "$PASSWORD" || return 1

        printf '端口已从 %s 更换为 %s。\n' "$previous" "$PORT"
        echo "请更新客户端端口，并在云安全组和防火墙中放行新端口。"
        show_info
        return 0
    done
}

manage_service() {
    load_config || return 0

    systemctl "$1" "$SERVICE" || return 1

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
    if [[ ! -f "$CONF" && ! -f "$UNIT" && ! -f "$ENVFILE" ]]; then
        echo "尚未安装代理服务。"
        return 0
    fi

    confirm "确认停止并卸载 SOCKS5 服务及配置？" || return 0

    if [[ -f "$UNIT" ]]; then
        systemctl disable --now "$SERVICE" || return 1
    fi

    rm -f -- "$CONF" "$ENVFILE" "$UNIT" || return 1
    systemctl daemon-reload || return 1
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true

    echo "代理服务及配置已卸载。"
    echo "管理脚本和软件包保留。再次运行 s5 会自动重新安装。"
}

main() {
    [[ $EUID -eq 0 ]] ||
        die "请使用 root 运行，可以先执行 sudo -i。"

    command -v apt-get >/dev/null ||
        die "本脚本适用于 Debian / Ubuntu。"

    command -v systemctl >/dev/null ||
        die "未找到 systemctl，需要使用 systemd 的系统。"

    [[ -d /run/systemd/system ]] ||
        die "当前系统没有运行 systemd。"

    if (($# > 1)); then
        die "用法：s5 或 bash socks5.sh --install"
    fi

    case "${1:-}" in
        ""|--install) ;;
        *) die "用法：s5 或 bash socks5.sh --install" ;;
    esac

    exec </dev/tty ||
        die "无法读取终端，请在交互式 SSH 终端中执行。"

    local script_file="${BASH_SOURCE[0]:-}"

    [[ -n "$script_file" && -f "$script_file" ]] ||
        die "请先下载为本地文件，再用 bash 执行。"

    install -d -m 755 /usr/local/bin

    if [[ "$script_file" -ef "$SELF" ]]; then
        chmod 700 "$SELF"
    else
        install -m 700 -- "$script_file" "$SELF"
    fi

    if [[ "${1:-}" == "--install" || ! -f "$CONF" ]]; then
        install_proxy ||
            die "安装未完成，请根据上方报错处理后重新运行。"
    fi

    local choice

    while true; do
        cat <<'MENU'

========== 我的 SOCKS5 工具箱 ==========
1. 安装 / 修复 SOCKS5（保留已有配置）
2. 查看连接信息
3. 自定义账号
4. 自定义密码
5. 自定义端口
6. 检测本机代理连接
7. 查看服务状态
8. 重启代理
9. 停止代理
10. 启动代理
11. 卸载代理服务及配置
12. 查看近期日志
0. 退出
=======================================

MENU

        IFS= read -r -p "请选择： " choice || return 0

        case "$choice" in
            1) install_proxy || true ;;
            2) show_info ;;
            3) custom_account || true ;;
            4) custom_password || true ;;
            5) custom_port || true ;;
            6) check_connection || true ;;
            7) show_status ;;
            8) manage_service restart || true ;;
            9) manage_service stop || true ;;
            10) manage_service start || true ;;
            11) uninstall_proxy || true ;;
            12) show_logs ;;
            0) return 0 ;;
            *) echo "请输入菜单中的数字。" ;;
        esac
    done
}

main "$@"

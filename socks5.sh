#!/usr/bin/env bash
set -euo pipefail

SERVICE="my-socks5"
CONF="/etc/my-socks5.conf"
UNIT="/etc/systemd/system/${SERVICE}.service"

[[ $EUID -eq 0 ]] || {
    echo "请用 root 运行，先执行 sudo -i"
    exit 1
}
command -v apt-get >/dev/null || {
    echo "本脚本仅适用于 Ubuntu/Debian"
    exit 1
}
[[ -d /run/systemd/system ]] || {
    echo "需要使用 systemd 的系统"
    exit 1
}
exec </dev/tty

load_config() {
    [[ -f "$CONF" ]] || {
        echo "请先安装"
        return 1
    }
    source "$CONF"
}

show_info() {
    load_config || return 0
    echo
    echo "服务器 IP：填写你的 VPS 公网 IP"
    echo "端口：$PORT"
    echo "账号：$ACCOUNT"
    echo "密码：$PASSWORD"
    echo "链接：socks5://$ACCOUNT:$PASSWORD@你的公网IP:$PORT"
    echo
}

deploy() {
    if [[ -f "$CONF" ]]; then
        read -rp "这会更换现有账号、密码和端口，继续？[y/N] " answer
        [[ "$answer" == "y" ]] || return 0
    fi

    apt-get update
    apt-get install -y microsocks openssl curl iproute2

    PORT=""
    for ((i=0; i<100; i++)); do
        candidate=$(shuf -i 10000-65000 -n 1)
        if [[ -z "$(ss -H -ltn "sport = :$candidate")" ]]; then
            PORT="$candidate"
            break
        fi
    done
    [[ -n "$PORT" ]] || {
        echo "未找到空闲端口"
        return 1
    }

    ACCOUNT="u$(openssl rand -hex 4)"
    PASSWORD="$(openssl rand -hex 12)"
    umask 077
    printf 'PORT=%q\nACCOUNT=%q\nPASSWORD=%q\n' \
        "$PORT" "$ACCOUNT" "$PASSWORD" > "$CONF"

    cat > "$UNIT" <<EOF
[Unit]
Description=Personal SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/microsocks -i 0.0.0.0 -p $PORT -u $ACCOUNT -P $PASSWORD
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    chmod 600 "$CONF" "$UNIT"
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"

    # 验证本

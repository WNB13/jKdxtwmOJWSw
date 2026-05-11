#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-443}"
METHOD="${METHOD:-chacha20-ietf-poly1305}"
PASSWORD="${PASSWORD:-}"
DEFAULT_TAG="my-ss-443-$(date '+%Y%m%d%H%M%S')"
TAG="${TAG:-${DEFAULT_TAG}}"
SERVER_IP="${SERVER_IP:-}"
ENABLE_UFW="${ENABLE_UFW:-auto}"
CONF_NAME="${CONF_NAME:-ss443}"
OUT_FILE="${OUT_FILE:-/root/ss_uri.txt}"

CONF_DIR="/etc/shadowsocks-libev"
CONF_FILE="${CONF_DIR}/config.json"
UNIT="shadowsocks-libev-local.service"
SERVICE_FILE="/etc/systemd/system/${UNIT}"
SS_SERVER_BIN=""

err() { printf '%s\n' "$*" >&2; }

require_arg() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "${value}" || "${value}" == --* ]]; then
    err "参数 ${flag} 缺少值"
    exit 1
  fi
}

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

url_encode() {
  local s="${1:-}"
  local out=""
  local i ch hex
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "${ch}" in
      [a-zA-Z0-9.~_-]) out+="${ch}" ;;
      *)
        printf -v hex '%02X' "'${ch}"
        out+="%${hex}"
        ;;
    esac
  done
  printf '%s' "${out}"
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash install_ss_443.sh [options]

Options:
  --password <PASS>            Shadowsocks password (default: auto generate)
  --port <PORT>                Server port (default: 443)
  --method <METHOD>            Cipher method (default: chacha20-ietf-poly1305)
  --tag <TAG>                  SS URI tag (default: my-ss-443)
  --server-ip <IP>             Override server IP shown in output (default: auto detect)
  --enable-ufw <auto|yes|no>   Manage UFW rules (default: auto)
  --conf-name <NAME>           Config name for @ instance service (default: ss443)
  --out-file <PATH>            Write result to file (default: /root/ss_uri.txt)
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) require_arg "$1" "${2:-}"; PASSWORD="${2}"; shift 2 ;;
    --port) require_arg "$1" "${2:-}"; PORT="${2}"; shift 2 ;;
    --method) require_arg "$1" "${2:-}"; METHOD="${2}"; shift 2 ;;
    --tag) require_arg "$1" "${2:-}"; TAG="${2}"; shift 2 ;;
    --server-ip) require_arg "$1" "${2:-}"; SERVER_IP="${2}"; shift 2 ;;
    --enable-ufw) require_arg "$1" "${2:-}"; ENABLE_UFW="${2}"; shift 2 ;;
    --conf-name) require_arg "$1" "${2:-}"; CONF_NAME="${2}"; shift 2 ;;
    --out-file) require_arg "$1" "${2:-}"; OUT_FILE="${2}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  err "请用 root 运行：sudo bash $0"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  err "未找到 systemctl（需要 systemd 环境）"
  exit 1
fi

if [[ -z "${PORT}" || ! "${PORT}" =~ ^[0-9]+$ || "${PORT}" -lt 1 || "${PORT}" -gt 65535 ]]; then
  err "PORT 无效：${PORT}"
  exit 1
fi

case "${ENABLE_UFW}" in
  auto|yes|no) ;;
  *) err "ENABLE_UFW 无效（auto|yes|no）：${ENABLE_UFW}"; exit 1 ;;
esac

if command -v ss >/dev/null 2>&1; then
  if ss -lunpt 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${PORT}$"; then
    err "端口 ${PORT} 已被占用，请释放端口或修改 PORT"
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y shadowsocks-libev openssl curl ca-certificates qrencode

mkdir -p "${CONF_DIR}"

if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr -d '=+/')"
fi

PASSWORD_JSON="$(json_escape "${PASSWORD}")"
METHOD_JSON="$(json_escape "${METHOD}")"

SS_SERVER_BIN="$(command -v ss-server || true)"
if [[ -z "${SS_SERVER_BIN}" ]]; then
  err "未找到 ss-server，可执行文件安装异常"
  err "请执行：command -v ss-server"
  exit 1
fi

cat > "${CONF_FILE}" <<EOF
{
  "server":"0.0.0.0",
  "server_port":${PORT},
  "password":"${PASSWORD_JSON}",
  "timeout":300,
  "method":"${METHOD_JSON}",
  "mode":"tcp_and_udp",
  "fast_open":false
}
EOF

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Local Shadowsocks-libev Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_SERVER_BIN} -c ${CONF_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable "${UNIT}"
systemctl restart "${UNIT}"
if ! systemctl is-active --quiet "${UNIT}"; then
  err "服务未处于 active 状态：${UNIT}"
  systemctl --no-pager --full status "${UNIT}" || true
  exit 1
fi

if command -v ufw >/dev/null 2>&1; then
  UFW_ACTIVE=false
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    UFW_ACTIVE=true
  fi
  if [[ "${ENABLE_UFW}" == "yes" || ( "${ENABLE_UFW}" == "auto" && "${UFW_ACTIVE}" == "true" ) ]]; then
    ufw allow "${PORT}/tcp" || true
    ufw allow "${PORT}/udp" || true
    ufw reload || true
  fi
fi

if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
fi
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="<你的服务器IP>"
fi

if base64 --help 2>/dev/null | grep -q -- '-w'; then
  ENC="$(printf '%s:%s' "${METHOD}" "${PASSWORD}" | base64 -w0)"
else
  ENC="$(printf '%s:%s' "${METHOD}" "${PASSWORD}" | base64 | tr -d '\n')"
fi

TAG_ENC="$(url_encode "${TAG}")"
SS_URI="ss://${ENC}@${SERVER_IP}:${PORT}#${TAG_ENC}"

cat > "${OUT_FILE}" <<EOF
server: ${SERVER_IP}
port: ${PORT}
method: ${METHOD}
password: ${PASSWORD}
ss_uri: ${SS_URI}
EOF

printf '\n'
systemctl --no-pager --full status "${UNIT}" | sed -n '1,30p' || true
printf '\n'
printf '端口监听：\n'
if command -v ss >/dev/null 2>&1; then
  ss -lunpt 2>/dev/null | grep -E ":${PORT}\b" || true
else
  err "未找到 ss 命令，跳过端口监听检查"
fi
printf '\n'
printf 'SS URI：\n%s\n' "${SS_URI}"
printf '\nClash 节点片段：\n'
cat <<EOF
- name: SS-${SERVER_IP}-${PORT}
  type: ss
  server: ${SERVER_IP}
  port: ${PORT}
  cipher: ${METHOD}
  password: ${PASSWORD}
  udp: true
EOF
printf '\n已保存到：%s\n' "${OUT_FILE}"
printf '\n二维码（可选）：\n'
qrencode -t ANSIUTF8 "${SS_URI}" || true

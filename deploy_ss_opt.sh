#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-443}"
METHOD="${METHOD:-chacha20-ietf-poly1305}"
PASSWORD="${PASSWORD:-}"
DEFAULT_TAG="node-ss-443-$(date '+%Y%m%d%H%M%S')"
TAG="${TAG:-${DEFAULT_TAG}}"
SERVER_IP="${SERVER_IP:-}"
ENABLE_UFW="${ENABLE_UFW:-auto}"
ENABLE_EGRESS_ROUTE="${ENABLE_EGRESS_ROUTE:-auto}"
EGRESS_PROBE_IP="${EGRESS_PROBE_IP:-1.1.1.1}"
CONF_NAME="${CONF_NAME:-ss443}"
OUT_FILE="${OUT_FILE:-/root/ss_uri.txt}"
YAML_DIR="${YAML_DIR:-/root/clash-yaml}"
YAML_HTTP_ENABLE="${YAML_HTTP_ENABLE:-no}"
YAML_HTTP_PORT="${YAML_HTTP_PORT:-18080}"
YAML_HTTP_HOST="${YAML_HTTP_HOST:-}"
YAML_HTTP_BIND="${YAML_HTTP_BIND:-127.0.0.1}"

CONF_DIR="/etc/shadowsocks-libev"
CONF_FILE="${CONF_DIR}/config.json"
UNIT="shadowsocks-libev-local.service"
SERVICE_FILE="/etc/systemd/system/${UNIT}"
TEMPLATE_UNIT="shadowsocks-libev-ss@.service"
TEMPLATE_SERVICE_FILE="/etc/systemd/system/${TEMPLATE_UNIT}"
YAML_HTTP_UNIT="clash-yaml-http.service"
YAML_HTTP_SERVICE_FILE="/etc/systemd/system/${YAML_HTTP_UNIT}"
EGRESS_ROUTE_UNIT="shadowsocks-libev-egress-route.service"
EGRESS_ROUTE_SERVICE_FILE="/etc/systemd/system/${EGRESS_ROUTE_UNIT}"
EGRESS_ROUTE_CONF="${CONF_DIR}/egress-routes.conf"
EGRESS_ROUTE_STATE="${CONF_DIR}/egress-routes.state"
EGRESS_ROUTE_SCRIPT="/usr/local/sbin/shadowsocks-libev-egress-route"
SS_SERVER_BIN=""
INSTANCES=()

err() { printf '%s\n' "$*" >&2; }

log_failure() {
  local unit="$1"
  err "========================================"
  err "服务失败日志：${unit}"
  systemctl --no-pager --full status "${unit}" 2>/dev/null || true
  journalctl -u "${unit}" --no-pager -n 50 2>/dev/null || true
  err "========================================"
}

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
  本地执行:
    sudo bash deploy_ss_opt.sh [options]

Options:
  --password <PASS>              Shadowsocks password (single instance)
  --port <PORT>                  Default server port (default: 443)
  --method <METHOD>              Cipher method (default: chacha20-ietf-poly1305)
  --tag <TAG>                    SS URI tag for single instance
  --server-ip <IP>               Override single-instance output IP
  --enable-ufw <auto|yes|no>     Manage UFW rules (default: auto)
  --enable-egress-route <auto|yes|no>
                                  Install source-based policy routes for multi-instance egress (default: auto)
  --egress-probe-ip <IP>         Destination used to detect gateway/dev (default: 1.1.1.1)
  --conf-name <NAME>             Instance prefix (default: ss443)
  --out-file <PATH>              Write result to file (default: /root/ss_uri.txt)
  --yaml-dir <PATH>              Clash YAML output dir (default: /root/clash-yaml)
  --yaml-http-enable <yes|no>     Start YAML HTTP service (default: no)
  --yaml-http-port <PORT>        YAML HTTP port (default: 18080)
  --yaml-http-host <HOST>        Host shown in YAML HTTP URLs (default: auto)
  --yaml-http-bind <ADDR>        YAML HTTP bind address (default: 127.0.0.1)
  --instance <SPEC>              Multi-instance mode (repeatable). SPEC format:
                                  LISTEN_IP|PORT|TAG|PASSWORD|EGRESS_IP

Notes:
  EGRESS_IP is optional. If omitted, it defaults to LISTEN_IP.
  LISTEN_IP and EGRESS_IP must already be assigned on this host.

Examples:
  sudo bash deploy_ss_opt.sh

  sudo bash /root/deploy_ss_opt.sh \
    --method chacha20-ietf-poly1305 \
    --yaml-http-enable yes \
    --yaml-http-bind 0.0.0.0 \
    --yaml-http-host 1.2.3.4 \
    --instance '72.249.207.28|443|us-node01-01|password|72.249.207.28' \
    --instance '23.144.132.62|443|us-node01-02|password|23.144.132.62'

  sudo bash /root/deploy_ss_opt.sh \
    --instance '72.249.207.28|443|us-node01-01|password|72.249.207.28' \
    --instance '23.144.132.62|443|us-node01-02|password|23.144.132.62'
EOF
}

is_ipv4() {
  local ip="${1:-}"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
  [[ "${o1}" -le 255 && "${o2}" -le 255 && "${o3}" -le 255 && "${o4}" -le 255 ]]
}

is_private_ipv4() {
  local ip="${1:-}"
  local o1 o2 o3 o4
  is_ipv4 "${ip}" || return 1
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"

  [[ "${o1}" -eq 10 ]] && return 0
  [[ "${o1}" -eq 127 ]] && return 0
  [[ "${o1}" -eq 169 && "${o2}" -eq 254 ]] && return 0
  [[ "${o1}" -eq 172 && "${o2}" -ge 16 && "${o2}" -le 31 ]] && return 0
  [[ "${o1}" -eq 192 && "${o2}" -eq 168 ]] && return 0
  [[ "${o1}" -eq 100 && "${o2}" -ge 64 && "${o2}" -le 127 ]] && return 0
  [[ "${o1}" -eq 0 ]] && return 0
  [[ "${o1}" -ge 224 ]] && return 0
  return 1
}

first_public_ipv4() {
  local ip
  for ip in "$@"; do
    if is_ipv4 "${ip}" && ! is_private_ipv4 "${ip}"; then
      printf '%s' "${ip}"
      return 0
    fi
  done
  return 1
}

is_local_ip() {
  local ip="$1"
  ip -o -4 addr show | awk -v wanted="${ip}" '
    {
      split($4, addr, "/")
      if (addr[1] == wanted) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

sanitize_name() {
  local s="${1:-}"
  s="${s//./_}"
  s="${s//:/_}"
  s="${s//\//_}"
  s="${s// /_}"
  printf '%s' "${s}"
}

sanitize_yaml_name() {
  local s="${1:-}"
  s="${s//:/_}"
  s="${s//\//_}"
  s="${s// /_}"
  [[ -n "${s}" ]] || s="node"
  printf '%s' "${s}"
}

gen_password() {
  openssl rand -base64 24 | tr -d '\n' | tr -d '=+/'
}

read_existing_password() {
  local conf_path="$1"
  [[ -f "${conf_path}" ]] || return 1
  sed -n 's/^[[:space:]]*"password"[[:space:]]*:[[:space:]]*"\(.*\)",[[:space:]]*$/\1/p' "${conf_path}" | head -n 1
}

route_field() {
  local line="$1"
  local key="$2"
  local -a parts
  local i
  read -r -a parts <<<"${line}"
  for ((i = 0; i < ${#parts[@]} - 1; i++)); do
    if [[ "${parts[$i]}" == "${key}" ]]; then
      printf '%s' "${parts[$((i + 1))]}"
      return 0
    fi
  done
  return 1
}

egress_route_enabled() {
  [[ "${#INSTANCES[@]}" -gt 0 ]] || return 1
  [[ "${ENABLE_EGRESS_ROUTE}" != "no" ]]
}

ip_number() {
  local ip="$1"
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
  printf '%s' "$((o1 * 16777216 + o2 * 65536 + o3 * 256 + o4))"
}

egress_table_id() {
  local ip="$1"
  printf '%s' "$((100000 + ($(ip_number "${ip}") % 900000)))"
}

egress_rule_priority() {
  local ip="$1"
  printf '%s' "$((10000 + ($(ip_number "${ip}") % 20000)))"
}

policy_rule_active() {
  local route_ip="$1"
  local route_table="$2"
  local route_priority="$3"

  ip -4 rule show pref "${route_priority}" 2>/dev/null | awk \
    -v wanted_ip="${route_ip}" \
    -v wanted_table="${route_table}" '
      {
        has_from = 0
        has_table = 0
        for (i = 1; i <= NF; i++) {
          if ($i == "from" && ($(i + 1) == wanted_ip || $(i + 1) == wanted_ip "/32")) {
            has_from = 1
          }
          if (($i == "lookup" || $i == "table") && $(i + 1) == wanted_table) {
            has_table = 1
          }
        }
        if (has_from && has_table) {
          found = 1
        }
      }
      END { exit found ? 0 : 1 }
    '
}

route_table_has_default() {
  local route_table="$1"
  ip -4 route show table "${route_table}" 2>/dev/null | awk '$1 == "default" { found = 1 } END { exit found ? 0 : 1 }'
}

detect_egress_route_spec() {
  local egress_ip="$1"
  local route dev via src table priority existing_rules existing_routes

  route="$(ip -4 route get "${EGRESS_PROBE_IP}" from "${egress_ip}" 2>/dev/null || true)"
  if [[ -z "${route}" ]]; then
    err "无法探测 ${egress_ip} 的出口路由，请检查默认路由或使用 --enable-egress-route no"
    return 1
  fi

  dev="$(route_field "${route}" dev || true)"
  via="$(route_field "${route}" via || true)"
  src="$(route_field "${route}" src || true)"
  if [[ -z "${dev}" || "${dev}" == "lo" ]]; then
    err "无法为 ${egress_ip} 确定有效出口网卡：${route}"
    return 1
  fi
  if [[ -n "${src}" && "${src}" != "${egress_ip}" ]]; then
    err "路由探测返回的源地址不是指定出口 IP：route src=${src}, egress=${egress_ip}"
    return 1
  fi

  table="$(egress_table_id "${egress_ip}")"
  priority="$(egress_rule_priority "${egress_ip}")"

  existing_rules="$(ip -4 rule show pref "${priority}" 2>/dev/null || true)"
  if [[ -n "${existing_rules}" ]] && ! policy_rule_active "${egress_ip}" "${table}" "${priority}"; then
    err "策略路由优先级已被其他规则占用：pref ${priority}"
    err "${existing_rules}"
    return 1
  fi

  existing_routes="$(ip -4 route show table "${table}" 2>/dev/null || true)"
  if [[ -n "${existing_routes}" ]] && ! grep -Fq "src ${egress_ip}" <<<"${existing_routes}"; then
    err "策略路由表已存在且不像本脚本生成：table ${table}"
    err "${existing_routes}"
    return 1
  fi

  printf '%s|%s|%s|%s|%s\n' "${egress_ip}" "${table}" "${priority}" "${dev}" "${via}"
}

write_egress_route_files() {
  local conf_tmp="${EGRESS_ROUTE_CONF}.tmp.$$"
  local spec egress_ip table priority dev via

  umask 077
  : > "${conf_tmp}"
  for spec in "$@"; do
    IFS='|' read -r egress_ip table priority dev via <<<"${spec}"
    printf '%s|%s|%s|%s|%s\n' "${egress_ip}" "${table}" "${priority}" "${dev}" "${via}" >> "${conf_tmp}"
  done
  mv -f "${conf_tmp}" "${EGRESS_ROUTE_CONF}"
  chmod 600 "${EGRESS_ROUTE_CONF}" || true

  mkdir -p "$(dirname "${EGRESS_ROUTE_SCRIPT}")"
  cat > "${EGRESS_ROUTE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/shadowsocks-libev/egress-routes.conf"
STATE="/etc/shadowsocks-libev/egress-routes.state"
[[ -f "${CONF}" ]] || exit 0

desired_keys=()
while IFS='|' read -r egress_ip table priority dev via _; do
  [[ -n "${egress_ip}" ]] || continue
  [[ "${egress_ip}" != \#* ]] || continue
  [[ -n "${table}" && -n "${priority}" && -n "${dev}" ]] || continue

  if ! ip -o -4 addr show | awk -v wanted="${egress_ip}" '{ split($4, addr, "/"); if (addr[1] == wanted) found = 1 } END { exit found ? 0 : 1 }'; then
    echo "egress-route: ${egress_ip} is not assigned on this host" >&2
    exit 1
  fi

  desired_keys+=("${egress_ip}|${table}|${priority}")
  while ip -4 rule del pref "${priority}" from "${egress_ip}/32" table "${table}" 2>/dev/null; do :; done
  ip -4 rule add pref "${priority}" from "${egress_ip}/32" table "${table}"

  ip -4 route flush table "${table}" 2>/dev/null || true
  if [[ -n "${via}" ]]; then
    ip -4 route replace table "${table}" default via "${via}" dev "${dev}" src "${egress_ip}" onlink
  else
    ip -4 route replace table "${table}" default dev "${dev}" src "${egress_ip}"
  fi
done < "${CONF}"

if [[ -f "${STATE}" ]]; then
  while IFS='|' read -r old_ip old_table old_priority _; do
    [[ -n "${old_ip}" ]] || continue
    [[ "${old_ip}" != \#* ]] || continue
    [[ -n "${old_table}" && -n "${old_priority}" ]] || continue

    old_key="${old_ip}|${old_table}|${old_priority}"
    keep=false
    for desired_key in "${desired_keys[@]}"; do
      if [[ "${desired_key}" == "${old_key}" ]]; then
        keep=true
        break
      fi
    done
    if [[ "${keep}" == false ]]; then
      while ip -4 rule del pref "${old_priority}" from "${old_ip}/32" table "${old_table}" 2>/dev/null; do :; done
      ip -4 route flush table "${old_table}" 2>/dev/null || true
    fi
  done < "${STATE}"
fi

state_tmp="${STATE}.tmp.$$"
: > "${state_tmp}"
while IFS='|' read -r egress_ip table priority dev via _; do
  [[ -n "${egress_ip}" ]] || continue
  [[ "${egress_ip}" != \#* ]] || continue
  [[ -n "${table}" && -n "${priority}" && -n "${dev}" ]] || continue
  printf '%s|%s|%s|%s|%s\n' "${egress_ip}" "${table}" "${priority}" "${dev}" "${via}" >> "${state_tmp}"
done < "${CONF}"
mv -f "${state_tmp}" "${STATE}"
chmod 600 "${STATE}" || true

ip -4 route flush cache 2>/dev/null || true
EOF
  chmod 700 "${EGRESS_ROUTE_SCRIPT}"

  cat > "${EGRESS_ROUTE_SERVICE_FILE}" <<EOF
[Unit]
Description=Source Policy Routes For Shadowsocks-libev Egress
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${EGRESS_ROUTE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_one_config() {
  local bind_ip="$1"
  local port="$2"
  local method="$3"
  local password="$4"
  local conf_path="$5"

  local password_json method_json
  password_json="$(json_escape "${password}")"
  method_json="$(json_escape "${method}")"

  umask 077
  cat > "${conf_path}" <<EOF
{
  "server":"${bind_ip}",
  "server_port":${port},
  "password":"${password_json}",
  "timeout":300,
  "method":"${method_json}",
  "mode":"tcp_and_udp",
  "fast_open":false
}
EOF
  chmod 600 "${conf_path}" || true
}

write_instance_egress() {
  local egress_ip="$1"
  local egress_path="$2"

  umask 077
  printf '%s\n' "${egress_ip}" > "${egress_path}"
  chmod 600 "${egress_path}" || true
}

detect_http_host() {
  local fallback="${1:-}"
  local detected=""

  if [[ -n "${YAML_HTTP_HOST}" ]]; then
    printf '%s' "${YAML_HTTP_HOST}"
    return 0
  fi
  if [[ -n "${SERVER_IP}" ]]; then
    printf '%s' "${SERVER_IP}"
    return 0
  fi
  if [[ -n "${fallback}" ]]; then
    printf '%s' "${fallback}"
    return 0
  fi

  detected="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  if [[ -z "${detected}" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -n "${detected}" ]] || detected="<你的服务器IP>"
  printf '%s' "${detected}"
}

is_loopback_bind() {
  local bind="${1:-}"
  [[ "${bind}" == "127."* || "${bind}" == "localhost" || "${bind}" == "::1" ]]
}

should_manage_ufw() {
  [[ "${ENABLE_UFW}" == "yes" || ( "${ENABLE_UFW}" == "auto" && "${UFW_ACTIVE:-false}" == "true" ) ]]
}

ufw_allow_rule() {
  local rule="$1"

  if ! command -v ufw >/dev/null 2>&1; then
    err "ENABLE_UFW=${ENABLE_UFW}，但未找到 ufw 命令"
    return 1
  fi
  if ! ufw allow "${rule}"; then
    err "UFW 放行失败：${rule}"
    return 1
  fi
}

ufw_reload_rules() {
  if ! command -v ufw >/dev/null 2>&1; then
    err "ENABLE_UFW=${ENABLE_UFW}，但未找到 ufw 命令"
    return 1
  fi
  if ! ufw reload; then
    err "UFW reload 失败"
    return 1
  fi
}

write_yaml_http_unit() {
  cat > "${YAML_HTTP_SERVICE_FILE}" <<EOF
[Unit]
Description=Static HTTP Server For Clash YAML
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${YAML_DIR}
ExecStart=/usr/bin/python3 -m http.server ${YAML_HTTP_PORT} --bind ${YAML_HTTP_BIND} --directory ${YAML_DIR}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

ensure_yaml_http_service() {
  [[ "${YAML_HTTP_ENABLE}" == "yes" ]] || return 0

  write_yaml_http_unit || return 1
  systemctl daemon-reload || return 1
  systemctl enable "${YAML_HTTP_UNIT}" || return 1
  systemctl restart "${YAML_HTTP_UNIT}" || return 1
  sleep 0.5
  if ! systemctl is-active --quiet "${YAML_HTTP_UNIT}"; then
    err "YAML HTTP 服务启动失败：${YAML_HTTP_UNIT}"
    log_failure "${YAML_HTTP_UNIT}"
    return 1
  fi
}

yaml_owner_key() {
  local server_ip="$1"
  local port="$2"
  printf '%s:%s' "${server_ip}" "${port}"
}

clean_yaml_scalar() {
  local value="${1:-}"
  value="${value%%#*}"
  value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "${value}"
}

read_yaml_owner() {
  local file_path="$1"
  local value
  value="$(sed -n 's/^#[[:space:]]*yaml_owner:[[:space:]]*//p' "${file_path}" | head -n 1)"
  clean_yaml_scalar "${value}"
}

read_yaml_proxy_server() {
  local file_path="$1"
  local value
  value="$(sed -n 's/^[[:space:]]*server:[[:space:]]*//p' "${file_path}" | head -n 1)"
  clean_yaml_scalar "${value}"
}

read_yaml_proxy_port() {
  local file_path="$1"
  local value
  value="$(awk '
    /^[[:space:]]*server:[[:space:]]*/ { seen=1; next }
    seen && /^[[:space:]]*port:[[:space:]]*/ {
      sub(/^[[:space:]]*port:[[:space:]]*/, "")
      print
      exit
    }
  ' "${file_path}")"
  clean_yaml_scalar "${value}"
}

validate_yaml_file_owner() {
  local file_path="$1"
  local server_ip="$2"
  local port="$3"
  local expected_owner existing_owner existing_server existing_port

  [[ -f "${file_path}" ]] || return 0

  expected_owner="$(yaml_owner_key "${server_ip}" "${port}")"
  existing_owner="$(read_yaml_owner "${file_path}")"
  if [[ -n "${existing_owner}" ]]; then
    if [[ "${existing_owner}" == "${expected_owner}" ]]; then
      return 0
    fi
    err "YAML 文件已属于其他实例，拒绝覆盖：${file_path}"
    err "当前实例：${expected_owner}；文件归属：${existing_owner}"
    return 1
  fi

  existing_server="$(read_yaml_proxy_server "${file_path}")"
  existing_port="$(read_yaml_proxy_port "${file_path}")"
  if [[ "${existing_server}" == "${server_ip}" && "${existing_port}" == "${port}" ]]; then
    return 0
  fi

  err "YAML 文件已存在且无法确认属于当前实例，拒绝覆盖：${file_path}"
  err "当前实例：${expected_owner}；文件内容：${existing_server:-unknown}:${existing_port:-unknown}"
  return 1
}

write_clash_yaml() {
  local file_path="$1"
  local proxy_name="$2"
  local server_ip="$3"
  local port="$4"
  local method="$5"
  local password="$6"
  local yaml_owner="${7:-}"
  local proxy_name_yaml password_yaml

  yaml_owner="${yaml_owner:-$(yaml_owner_key "${server_ip}" "${port}")}"
  proxy_name_yaml="$(json_escape "${proxy_name}")"
  password_yaml="$(json_escape "${password}")"

  umask 077
  cat > "${file_path}" <<EOF
# yaml_owner: ${yaml_owner}
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${proxy_name_yaml}"
    type: ss
    server: ${server_ip}
    port: ${port}
    cipher: ${method}
    password: "${password_yaml}"
    udp: true

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - "${proxy_name_yaml}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF
  chmod 600 "${file_path}" || true
}

write_template_unit() {
  local desired after_line wants_line requires_line
  after_line="After=network-online.target"
  wants_line="Wants=network-online.target"
  requires_line=""

  if egress_route_enabled; then
    after_line="After=network-online.target ${EGRESS_ROUTE_UNIT}"
    wants_line="Wants=network-online.target"
    requires_line="Requires=${EGRESS_ROUTE_UNIT}"
  fi

  desired=$(cat <<EOF
[Unit]
Description=Shadowsocks-libev Server (%i)
${after_line}
${wants_line}
${requires_line}

[Service]
Type=simple
ExecStart=/bin/bash -c 'EGRESS=\$(cat "${CONF_DIR}/%i.egress") && exec ${SS_SERVER_BIN} -c "${CONF_DIR}/%i.json" -b "\$EGRESS"'
Restart=on-failure
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
  )

  if [[ -f "${TEMPLATE_SERVICE_FILE}" ]]; then
    if [[ "$(cat "${TEMPLATE_SERVICE_FILE}")" != "${desired}" ]]; then
      printf '%s' "${desired}" > "${TEMPLATE_SERVICE_FILE}"
      systemctl daemon-reload
    fi
  else
    printf '%s' "${desired}" > "${TEMPLATE_SERVICE_FILE}"
    systemctl daemon-reload
  fi
}

mk_ss_uri() {
  local server_ip="$1"
  local port="$2"
  local method="$3"
  local password="$4"
  local tag="$5"

  local enc tag_enc
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    enc="$(printf '%s:%s' "${method}" "${password}" | base64 -w0)"
  else
    enc="$(printf '%s:%s' "${method}" "${password}" | base64 | tr -d '\n')"
  fi
  tag_enc="$(url_encode "${tag}")"
  printf 'ss://%s@%s:%s#%s' "${enc}" "${server_ip}" "${port}" "${tag_enc}"
}

append_output() {
  local out_path="$1"
  local server_ip="$2"
  local port="$3"
  local method="$4"
  local password="$5"
  local ss_uri="$6"
  local egress_ip="${7:-}"
  local yaml_path="${8:-}"
  local yaml_url="${9:-}"

  umask 077
  {
    printf 'server: %s\n' "${server_ip}"
    printf 'port: %s\n' "${port}"
    printf 'method: %s\n' "${method}"
    printf 'password: %s\n' "${password}"
    if [[ -n "${egress_ip}" ]]; then
      printf 'egress_ip: %s\n' "${egress_ip}"
    fi
    if [[ -n "${yaml_path}" ]]; then
      printf 'yaml_file: %s\n' "${yaml_path}"
    fi
    if [[ -n "${yaml_url}" ]]; then
      printf 'yaml_url: %s\n' "${yaml_url}"
    fi
    printf 'ss_uri: %s\n' "${ss_uri}"
    printf '\n'
  } >> "${out_path}"
}

extract_pid_from_ss_line() {
  local line="$1"
  grep -oE 'pid=[0-9]+' <<<"${line}" | head -n 1 | cut -d= -f2 || true
}

check_port_available() {
  local listen_ip="$1"
  local port="$2"
  local unit="$3"
  local own_pid="" line pid ip_re

  command -v ss >/dev/null 2>&1 || return 0
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    own_pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
    [[ "${own_pid}" == "0" ]] && own_pid=""
  fi

  ip_re="${listen_ip//./\\.}"
  while IFS= read -r line; do
    if grep -Eq "(^|[[:space:]])(${ip_re}|0\\.0\\.0\\.0|\\[::\\]|\\*):${port}([[:space:]]|$)" <<<"${line}"; then
      pid="$(extract_pid_from_ss_line "${line}")"
      if [[ -n "${own_pid}" && -n "${pid}" && "${pid}" == "${own_pid}" ]]; then
        continue
      fi
      err "端口冲突：${listen_ip}:${port}（或 0.0.0.0:${port}）已被占用"
      [[ -n "${pid}" ]] && err "占用进程 PID：${pid}"
      return 1
    fi
  done < <(ss -H -lunpt 2>/dev/null || true)
}

restore_file_from_backup() {
  local target="$1"
  local existed="$2"
  local backup="$3"

  if [[ "${existed}" == "true" && -f "${backup}" ]]; then
    mv -f "${backup}" "${target}"
  else
    rm -f "${target}"
  fi
}

backup_egress_route_state() {
  [[ "${EGRESS_ROUTE_BACKED_UP:-false}" == "true" ]] && return 0
  EGRESS_ROUTE_BACKED_UP=true
  EGRESS_ROUTE_CONF_BACKUP="${EGRESS_ROUTE_CONF}.backup.$$"
  EGRESS_ROUTE_STATE_BACKUP="${EGRESS_ROUTE_STATE}.backup.$$"
  EGRESS_ROUTE_SCRIPT_BACKUP="${EGRESS_ROUTE_SCRIPT}.backup.$$"
  EGRESS_ROUTE_SERVICE_BACKUP="${EGRESS_ROUTE_SERVICE_FILE}.backup.$$"

  if [[ -f "${EGRESS_ROUTE_CONF}" ]]; then
    EGRESS_ROUTE_CONF_EXISTED=true
    cp -f "${EGRESS_ROUTE_CONF}" "${EGRESS_ROUTE_CONF_BACKUP}"
  else
    EGRESS_ROUTE_CONF_EXISTED=false
  fi

  if [[ -f "${EGRESS_ROUTE_STATE}" ]]; then
    EGRESS_ROUTE_STATE_EXISTED=true
    cp -f "${EGRESS_ROUTE_STATE}" "${EGRESS_ROUTE_STATE_BACKUP}"
  else
    EGRESS_ROUTE_STATE_EXISTED=false
  fi

  if [[ -f "${EGRESS_ROUTE_SCRIPT}" ]]; then
    EGRESS_ROUTE_SCRIPT_EXISTED=true
    cp -f "${EGRESS_ROUTE_SCRIPT}" "${EGRESS_ROUTE_SCRIPT_BACKUP}"
  else
    EGRESS_ROUTE_SCRIPT_EXISTED=false
  fi

  if [[ -f "${EGRESS_ROUTE_SERVICE_FILE}" ]]; then
    EGRESS_ROUTE_SERVICE_EXISTED=true
    cp -f "${EGRESS_ROUTE_SERVICE_FILE}" "${EGRESS_ROUTE_SERVICE_BACKUP}"
  else
    EGRESS_ROUTE_SERVICE_EXISTED=false
  fi

  if systemctl is-active --quiet "${EGRESS_ROUTE_UNIT}" 2>/dev/null; then
    EGRESS_ROUTE_WAS_ACTIVE=true
  else
    EGRESS_ROUTE_WAS_ACTIVE=false
  fi

  if systemctl is-enabled --quiet "${EGRESS_ROUTE_UNIT}" 2>/dev/null; then
    EGRESS_ROUTE_WAS_ENABLED=true
  else
    EGRESS_ROUTE_WAS_ENABLED=false
  fi
}

cleanup_egress_routes_from_file() {
  local state_file="$1"
  local route_ip route_table route_priority _

  [[ -f "${state_file}" ]] || return 0
  while IFS='|' read -r route_ip route_table route_priority _; do
    [[ -n "${route_ip}" ]] || continue
    [[ "${route_ip}" != \#* ]] || continue
    [[ -n "${route_table}" && -n "${route_priority}" ]] || continue
    while ip -4 rule del pref "${route_priority}" from "${route_ip}/32" table "${route_table}" 2>/dev/null; do :; done
    ip -4 route flush table "${route_table}" 2>/dev/null || true
  done < "${state_file}"
}

cleanup_current_egress_routes() {
  cleanup_egress_routes_from_file "${EGRESS_ROUTE_CONF}"
  cleanup_egress_routes_from_file "${EGRESS_ROUTE_STATE}"
  ip -4 route flush cache 2>/dev/null || true
}

seed_egress_route_state() {
  [[ -f "${EGRESS_ROUTE_STATE}" ]] && return 0
  [[ -f "${EGRESS_ROUTE_CONF}" ]] || return 0
  cp -f "${EGRESS_ROUTE_CONF}" "${EGRESS_ROUTE_STATE}"
  chmod 600 "${EGRESS_ROUTE_STATE}" || true
}

disable_egress_route_state() {
  backup_egress_route_state
  set +e
  cleanup_current_egress_routes
  systemctl disable --now "${EGRESS_ROUTE_UNIT}" >/dev/null 2>&1
  rm -f "${EGRESS_ROUTE_CONF}" "${EGRESS_ROUTE_STATE}" "${EGRESS_ROUTE_SCRIPT}" "${EGRESS_ROUTE_SERVICE_FILE}"
  systemctl daemon-reload >/dev/null 2>&1
  set -e
}

restore_egress_route_state() {
  [[ "${EGRESS_ROUTE_BACKED_UP:-false}" == "true" ]] || return 0

  set +e
  cleanup_current_egress_routes
  restore_file_from_backup "${EGRESS_ROUTE_CONF}" "${EGRESS_ROUTE_CONF_EXISTED}" "${EGRESS_ROUTE_CONF_BACKUP}"
  restore_file_from_backup "${EGRESS_ROUTE_STATE}" "${EGRESS_ROUTE_STATE_EXISTED}" "${EGRESS_ROUTE_STATE_BACKUP}"
  restore_file_from_backup "${EGRESS_ROUTE_SCRIPT}" "${EGRESS_ROUTE_SCRIPT_EXISTED}" "${EGRESS_ROUTE_SCRIPT_BACKUP}"
  restore_file_from_backup "${EGRESS_ROUTE_SERVICE_FILE}" "${EGRESS_ROUTE_SERVICE_EXISTED}" "${EGRESS_ROUTE_SERVICE_BACKUP}"
  systemctl daemon-reload >/dev/null 2>&1

  if [[ "${EGRESS_ROUTE_WAS_ENABLED}" == "true" ]]; then
    systemctl enable "${EGRESS_ROUTE_UNIT}" >/dev/null 2>&1
  else
    systemctl disable "${EGRESS_ROUTE_UNIT}" >/dev/null 2>&1
  fi

  if [[ "${EGRESS_ROUTE_WAS_ACTIVE}" == "true" ]]; then
    systemctl restart "${EGRESS_ROUTE_UNIT}" >/dev/null 2>&1
  else
    systemctl stop "${EGRESS_ROUTE_UNIT}" >/dev/null 2>&1
  fi
  set -e
}

cleanup_egress_route_backups() {
  [[ "${EGRESS_ROUTE_BACKED_UP:-false}" == "true" ]] || return 0
  rm -f "${EGRESS_ROUTE_CONF_BACKUP}" "${EGRESS_ROUTE_STATE_BACKUP}" "${EGRESS_ROUTE_SCRIPT_BACKUP}" "${EGRESS_ROUTE_SERVICE_BACKUP}"
}

backup_yaml_http_state() {
  [[ "${YAML_HTTP_BACKED_UP:-false}" == "true" ]] && return 0
  YAML_HTTP_BACKED_UP=true
  YAML_HTTP_SERVICE_BACKUP="${YAML_HTTP_SERVICE_FILE}.backup.$$"

  if [[ -f "${YAML_HTTP_SERVICE_FILE}" ]]; then
    YAML_HTTP_SERVICE_EXISTED=true
    cp -f "${YAML_HTTP_SERVICE_FILE}" "${YAML_HTTP_SERVICE_BACKUP}"
  else
    YAML_HTTP_SERVICE_EXISTED=false
  fi

  if systemctl is-active --quiet "${YAML_HTTP_UNIT}" 2>/dev/null; then
    YAML_HTTP_WAS_ACTIVE=true
  else
    YAML_HTTP_WAS_ACTIVE=false
  fi

  if systemctl is-enabled --quiet "${YAML_HTTP_UNIT}" 2>/dev/null; then
    YAML_HTTP_WAS_ENABLED=true
  else
    YAML_HTTP_WAS_ENABLED=false
  fi
}

restore_yaml_http_state() {
  [[ "${YAML_HTTP_BACKED_UP:-false}" == "true" ]] || return 0
  local restore_failed=false

  set +e
  restore_file_from_backup "${YAML_HTTP_SERVICE_FILE}" "${YAML_HTTP_SERVICE_EXISTED}" "${YAML_HTTP_SERVICE_BACKUP}"
  systemctl daemon-reload >/dev/null 2>&1

  if [[ "${YAML_HTTP_WAS_ENABLED}" == "true" ]]; then
    if ! systemctl enable "${YAML_HTTP_UNIT}" >/dev/null 2>&1; then
      err "[回滚] YAML HTTP 服务 enable 恢复失败：${YAML_HTTP_UNIT}"
      restore_failed=true
    fi
  else
    systemctl disable "${YAML_HTTP_UNIT}" >/dev/null 2>&1
  fi

  if [[ "${YAML_HTTP_WAS_ACTIVE}" == "true" ]]; then
    if ! systemctl restart "${YAML_HTTP_UNIT}" >/dev/null 2>&1; then
      err "[回滚] YAML HTTP 服务 restart 恢复失败：${YAML_HTTP_UNIT}"
      log_failure "${YAML_HTTP_UNIT}"
      restore_failed=true
    elif ! systemctl is-active --quiet "${YAML_HTTP_UNIT}"; then
      err "[回滚] YAML HTTP 服务未恢复 active：${YAML_HTTP_UNIT}"
      log_failure "${YAML_HTTP_UNIT}"
      restore_failed=true
    fi
  else
    systemctl stop "${YAML_HTTP_UNIT}" >/dev/null 2>&1
  fi
  set -e
  [[ "${restore_failed}" == "false" ]]
}

yaml_http_state_present() {
  [[ -f "${YAML_HTTP_SERVICE_FILE}" ]] && return 0
  systemctl is-active --quiet "${YAML_HTTP_UNIT}" 2>/dev/null && return 0
  systemctl is-enabled --quiet "${YAML_HTTP_UNIT}" 2>/dev/null && return 0
  return 1
}

disable_yaml_http_service() {
  yaml_http_state_present || return 0
  backup_yaml_http_state
  set +e
  systemctl disable --now "${YAML_HTTP_UNIT}" >/dev/null 2>&1
  rm -f "${YAML_HTTP_SERVICE_FILE}"
  systemctl daemon-reload >/dev/null 2>&1
  set -e
}

cleanup_yaml_http_backups() {
  [[ "${YAML_HTTP_BACKED_UP:-false}" == "true" ]] || return 0
  rm -f "${YAML_HTTP_SERVICE_BACKUP}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) require_arg "$1" "${2:-}"; PASSWORD="${2}"; shift 2 ;;
    --port) require_arg "$1" "${2:-}"; PORT="${2}"; shift 2 ;;
    --method) require_arg "$1" "${2:-}"; METHOD="${2}"; shift 2 ;;
    --tag) require_arg "$1" "${2:-}"; TAG="${2}"; shift 2 ;;
    --server-ip) require_arg "$1" "${2:-}"; SERVER_IP="${2}"; shift 2 ;;
    --enable-ufw) require_arg "$1" "${2:-}"; ENABLE_UFW="${2}"; shift 2 ;;
    --enable-egress-route) require_arg "$1" "${2:-}"; ENABLE_EGRESS_ROUTE="${2}"; shift 2 ;;
    --egress-probe-ip) require_arg "$1" "${2:-}"; EGRESS_PROBE_IP="${2}"; shift 2 ;;
    --conf-name) require_arg "$1" "${2:-}"; CONF_NAME="${2}"; shift 2 ;;
    --out-file) require_arg "$1" "${2:-}"; OUT_FILE="${2}"; shift 2 ;;
    --yaml-dir) require_arg "$1" "${2:-}"; YAML_DIR="${2}"; shift 2 ;;
    --yaml-http-enable) require_arg "$1" "${2:-}"; YAML_HTTP_ENABLE="${2}"; shift 2 ;;
    --yaml-http-port) require_arg "$1" "${2:-}"; YAML_HTTP_PORT="${2}"; shift 2 ;;
    --yaml-http-host) require_arg "$1" "${2:-}"; YAML_HTTP_HOST="${2}"; shift 2 ;;
    --yaml-http-bind) require_arg "$1" "${2:-}"; YAML_HTTP_BIND="${2}"; shift 2 ;;
    --instance) require_arg "$1" "${2:-}"; INSTANCES+=("${2}"); shift 2 ;;
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

if ! is_ipv4 "${EGRESS_PROBE_IP}"; then
  err "EGRESS_PROBE_IP 无效：${EGRESS_PROBE_IP}"
  exit 1
fi

if [[ -z "${YAML_HTTP_PORT}" || ! "${YAML_HTTP_PORT}" =~ ^[0-9]+$ || "${YAML_HTTP_PORT}" -lt 1 || "${YAML_HTTP_PORT}" -gt 65535 ]]; then
  err "YAML_HTTP_PORT 无效：${YAML_HTTP_PORT}"
  exit 1
fi

case "${ENABLE_UFW}" in
  auto|yes|no) ;;
  *) err "ENABLE_UFW 无效（auto|yes|no）：${ENABLE_UFW}"; exit 1 ;;
esac

case "${ENABLE_EGRESS_ROUTE}" in
  auto|yes|no) ;;
  *) err "ENABLE_EGRESS_ROUTE 无效（auto|yes|no）：${ENABLE_EGRESS_ROUTE}"; exit 1 ;;
esac

case "${YAML_HTTP_ENABLE}" in
  yes|no) ;;
  *) err "YAML_HTTP_ENABLE 无效（yes|no）：${YAML_HTTP_ENABLE}"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y shadowsocks-libev openssl curl ca-certificates qrencode iproute2 python3

mkdir -p "${CONF_DIR}"
mkdir -p "${YAML_DIR}"

SS_SERVER_BIN="$(command -v ss-server || true)"
if [[ -z "${SS_SERVER_BIN}" ]]; then
  err "未找到 ss-server，可执行文件安装异常"
  exit 1
fi

UFW_ACTIVE=false
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    UFW_ACTIVE=true
  fi
fi

if [[ "${#INSTANCES[@]}" -eq 0 ]]; then
  if [[ -z "${PASSWORD}" ]]; then
    PASSWORD="$(gen_password)"
  fi

  write_one_config "0.0.0.0" "${PORT}" "${METHOD}" "${PASSWORD}" "${CONF_FILE}"

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
    log_failure "${UNIT}"
    exit 1
  fi

  if should_manage_ufw; then
    ufw_allow_rule "${PORT}/tcp" || exit 1
    ufw_allow_rule "${PORT}/udp" || exit 1
    ufw_reload_rules || exit 1
  fi

  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
    if [[ -z "${SERVER_IP}" ]]; then
      SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
  fi
  [[ -n "${SERVER_IP}" ]] || SERVER_IP="<你的服务器IP>"

  YAML_HTTP_RESOLVED_HOST=""
  yaml_path="${YAML_DIR}/$(sanitize_yaml_name "${TAG}").yaml"
  yaml_url=""
  if [[ "${YAML_HTTP_ENABLE}" == "yes" ]]; then
    YAML_HTTP_RESOLVED_HOST="$(detect_http_host "${SERVER_IP}")"
    yaml_url="http://${YAML_HTTP_RESOLVED_HOST}:${YAML_HTTP_PORT}/${yaml_path##*/}"
  fi
  validate_yaml_file_owner "${yaml_path}" "${SERVER_IP}" "${PORT}" || exit 1
  write_clash_yaml "${yaml_path}" "${TAG}" "${SERVER_IP}" "${PORT}" "${METHOD}" "${PASSWORD}" "$(yaml_owner_key "${SERVER_IP}" "${PORT}")"
  if [[ "${YAML_HTTP_ENABLE}" == "yes" ]]; then
    backup_yaml_http_state
    if ! ensure_yaml_http_service; then
      restore_yaml_http_state
      exit 1
    fi
  else
    disable_yaml_http_service
  fi
  if [[ "${YAML_HTTP_ENABLE}" == "yes" ]] && should_manage_ufw && ! is_loopback_bind "${YAML_HTTP_BIND}"; then
    ufw_allow_rule "${YAML_HTTP_PORT}/tcp" || exit 1
    ufw_reload_rules || exit 1
  fi

  SS_URI="$(mk_ss_uri "${SERVER_IP}" "${PORT}" "${METHOD}" "${PASSWORD}" "${TAG}")"
  OUT_TMP="${OUT_FILE}.tmp.$$"
  : > "${OUT_TMP}"
  append_output "${OUT_TMP}" "${SERVER_IP}" "${PORT}" "${METHOD}" "${PASSWORD}" "${SS_URI}" "" "${yaml_path}" "${yaml_url}"
  mv -f "${OUT_TMP}" "${OUT_FILE}"

  printf '\n'
  systemctl --no-pager --full status "${UNIT}" | sed -n '1,30p' || true
  printf '\n端口监听：\n'
  ss -lunpt 2>/dev/null | grep -E ":${PORT}\b" || true
  printf '\nSS URI：\n%s\n' "${SS_URI}"
  printf '\nYAML 文件：\n%s\n' "${yaml_path}"
  if [[ -n "${yaml_url}" ]]; then
    printf '\nYAML HTTP 地址：\n%s\n' "${yaml_url}"
  fi
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
  cleanup_yaml_http_backups
  exit 0
fi

PLAN_LISTEN_IPS=()
PLAN_PORTS=()
PLAN_TAGS=()
PLAN_PASSES=()
PLAN_EGRESS_IPS=()
PLAN_NAMES=()
PLAN_UNITS=()
PLAN_CONFS=()
PLAN_EGRESS_FILES=()
PLAN_YAML_FILES=()
PLAN_YAML_PATHS=()
PLAN_YAML_URLS=()
PLAN_YAML_OWNERS=()
ROUTE_SPECS=()
ROUTE_IPS=()
USED_INSTANCE_KEYS=()
USED_TAGS=()
USED_YAML_FILES=()

for spec in "${INSTANCES[@]}"; do
  listen_ip="" local_port="" local_tag="" local_pass="" egress_ip=""
  IFS='|' read -r listen_ip local_port local_tag local_pass egress_ip _ <<<"${spec}||||||"

  if [[ -z "${listen_ip}" ]]; then
    err "--instance 需要提供 LISTEN_IP，格式：LISTEN_IP|PORT|TAG|PASSWORD|EGRESS_IP"
    exit 1
  fi
  if ! is_ipv4 "${listen_ip}"; then
    err "--instance LISTEN_IP 不是有效 IPv4：${listen_ip}"
    exit 1
  fi
  if ! is_local_ip "${listen_ip}"; then
    err "LISTEN_IP 不在本机：${listen_ip}"
    exit 1
  fi

  local_port="${local_port:-${PORT}}"
  if [[ ! "${local_port}" =~ ^[0-9]+$ || "${local_port}" -lt 1 || "${local_port}" -gt 65535 ]]; then
    err "--instance PORT 无效：${local_port}"
    exit 1
  fi

  egress_ip="${egress_ip:-${listen_ip}}"

  if ! is_ipv4 "${egress_ip}"; then
    err "EGRESS_IP 不是有效 IPv4：${egress_ip}"
    exit 1
  fi
  if ! is_local_ip "${egress_ip}"; then
    err "EGRESS_IP 不在本机：${egress_ip}"
    exit 1
  fi

  inst_name="$(sanitize_name "${CONF_NAME}_${listen_ip}_${local_port}")"
  inst_unit="shadowsocks-libev-ss@${inst_name}.service"
  inst_conf="${CONF_DIR}/${inst_name}.json"
  inst_egress="${CONF_DIR}/${inst_name}.egress"

  local_tag="${local_tag:-SS-${listen_ip}-${local_port}}"
  yaml_file_name="$(sanitize_yaml_name "${local_tag}").yaml"
  yaml_path="${YAML_DIR}/${yaml_file_name}"
  if [[ -z "${local_pass}" ]]; then
    local_pass="$(read_existing_password "${inst_conf}" || true)"
  fi
  local_pass="${local_pass:-$(gen_password)}"

  key="${listen_ip}:${local_port}"
  for used in "${USED_INSTANCE_KEYS[@]}"; do
    [[ "${used}" == "${key}" ]] && { err "重复实例监听地址：${key}"; exit 1; }
  done
  USED_INSTANCE_KEYS+=("${key}")

  for used in "${USED_TAGS[@]}"; do
    [[ "${used}" == "${local_tag}" ]] && { err "重复TAG：${local_tag}"; exit 1; }
  done
  USED_TAGS+=("${local_tag}")

  for used in "${USED_YAML_FILES[@]}"; do
    [[ "${used}" == "${yaml_file_name}" ]] && { err "重复YAML文件名：${yaml_file_name}"; exit 1; }
  done
  USED_YAML_FILES+=("${yaml_file_name}")

  yaml_owner="$(yaml_owner_key "${listen_ip}" "${local_port}")"
  validate_yaml_file_owner "${yaml_path}" "${listen_ip}" "${local_port}" || exit 1

  check_port_available "${listen_ip}" "${local_port}" "${inst_unit}"

  if egress_route_enabled; then
    route_seen=false
    for used in "${ROUTE_IPS[@]}"; do
      if [[ "${used}" == "${egress_ip}" ]]; then
        route_seen=true
        break
      fi
    done
    if [[ "${route_seen}" == false ]]; then
      ROUTE_SPECS+=("$(detect_egress_route_spec "${egress_ip}")")
      ROUTE_IPS+=("${egress_ip}")
    fi
  fi

  PLAN_LISTEN_IPS+=("${listen_ip}")
  PLAN_PORTS+=("${local_port}")
  PLAN_TAGS+=("${local_tag}")
  PLAN_PASSES+=("${local_pass}")
  PLAN_EGRESS_IPS+=("${egress_ip}")
  PLAN_NAMES+=("${inst_name}")
  PLAN_UNITS+=("${inst_unit}")
  PLAN_CONFS+=("${inst_conf}")
  PLAN_EGRESS_FILES+=("${inst_egress}")
  PLAN_YAML_FILES+=("${yaml_file_name}")
  PLAN_YAML_PATHS+=("${yaml_path}")
  PLAN_YAML_URLS+=("")
  PLAN_YAML_OWNERS+=("${yaml_owner}")
done

YAML_HTTP_RESOLVED_HOST=""
if [[ "${YAML_HTTP_ENABLE}" == "yes" ]]; then
  for ((i = 0; i < ${#PLAN_YAML_FILES[@]}; i++)); do
    http_host_fallback="$(first_public_ipv4 "${PLAN_EGRESS_IPS[$i]}" "${PLAN_LISTEN_IPS[$i]}" || true)"
    http_host_fallback="${http_host_fallback:-${PLAN_LISTEN_IPS[$i]}}"
    yaml_http_host="$(detect_http_host "${http_host_fallback}")"
    PLAN_YAML_URLS[$i]="http://${yaml_http_host}:${YAML_HTTP_PORT}/${PLAN_YAML_FILES[$i]}"
    if [[ -z "${YAML_HTTP_RESOLVED_HOST}" ]]; then
      YAML_HTTP_RESOLVED_HOST="${yaml_http_host}"
    fi
  done
fi

if egress_route_enabled; then
  printf "[路由] 写入源地址策略路由，用于固定每个实例的公网出口\n"
  backup_egress_route_state
  if ! seed_egress_route_state; then
    restore_egress_route_state
    exit 1
  fi
  if ! write_egress_route_files "${ROUTE_SPECS[@]}"; then
    restore_egress_route_state
    exit 1
  fi
  if ! systemctl daemon-reload; then
    restore_egress_route_state
    exit 1
  fi
  if ! systemctl enable "${EGRESS_ROUTE_UNIT}"; then
    restore_egress_route_state
    exit 1
  fi
  if ! systemctl restart "${EGRESS_ROUTE_UNIT}"; then
    log_failure "${EGRESS_ROUTE_UNIT}"
    restore_egress_route_state
    exit 1
  fi
  if ! systemctl is-active --quiet "${EGRESS_ROUTE_UNIT}"; then
    err "策略路由服务未处于 active 状态：${EGRESS_ROUTE_UNIT}"
    log_failure "${EGRESS_ROUTE_UNIT}"
    restore_egress_route_state
    exit 1
  fi
  for route_spec in "${ROUTE_SPECS[@]}"; do
    IFS='|' read -r route_ip route_table route_priority _ <<<"${route_spec}"
    if ! policy_rule_active "${route_ip}" "${route_table}" "${route_priority}"; then
      err "策略路由规则未生效：pref ${route_priority} from ${route_ip} lookup ${route_table}"
      err "当前 IPv4 策略规则："
      ip -4 rule show >&2 || true
      restore_egress_route_state
      exit 1
    fi
    if ! route_table_has_default "${route_table}"; then
      err "策略路由表缺少默认路由：table ${route_table}"
      err "当前 table ${route_table} 路由："
      ip -4 route show table "${route_table}" >&2 || true
      restore_egress_route_state
      exit 1
    fi
  done
elif [[ "${ENABLE_EGRESS_ROUTE}" == "no" ]]; then
  disable_egress_route_state
fi

if ! write_template_unit; then
  restore_egress_route_state
  exit 1
fi
if ! systemctl daemon-reload; then
  restore_egress_route_state
  exit 1
fi

PLAN_CONF_EXISTED=()
PLAN_EGRESS_EXISTED=()
PLAN_YAML_EXISTED=()
PLAN_WAS_ACTIVE=()
PLAN_WAS_ENABLED=()
PLAN_CONF_BACKUPS=()
PLAN_EGRESS_BACKUPS=()
PLAN_YAML_BACKUPS=()
OUT_TMP="${OUT_FILE}.tmp.$$"

rollback_multi_instances() {
  local i unit conf egress_file yaml_path conf_backup egress_backup yaml_backup
  local rollback_failed=false
  err "[回滚] 多实例部署失败，恢复本次运行前状态"
  set +e
  for ((i = ${#PLAN_LISTEN_IPS[@]} - 1; i >= 0; i--)); do
    unit="${PLAN_UNITS[$i]}"
    conf="${PLAN_CONFS[$i]}"
    egress_file="${PLAN_EGRESS_FILES[$i]}"
    yaml_path="${PLAN_YAML_PATHS[$i]}"
    conf_backup="${PLAN_CONF_BACKUPS[$i]}"
    egress_backup="${PLAN_EGRESS_BACKUPS[$i]}"
    yaml_backup="${PLAN_YAML_BACKUPS[$i]}"

    systemctl stop "${unit}" >/dev/null 2>&1
    restore_file_from_backup "${conf}" "${PLAN_CONF_EXISTED[$i]}" "${conf_backup}"
    restore_file_from_backup "${egress_file}" "${PLAN_EGRESS_EXISTED[$i]}" "${egress_backup}"
    restore_file_from_backup "${yaml_path}" "${PLAN_YAML_EXISTED[$i]}" "${yaml_backup}"

    if [[ "${PLAN_WAS_ENABLED[$i]}" == "true" ]]; then
      if ! systemctl enable "${unit}" >/dev/null 2>&1; then
        err "[回滚] 旧服务 enable 恢复失败：${unit}"
        rollback_failed=true
      fi
    else
      systemctl disable "${unit}" >/dev/null 2>&1
    fi
    if [[ "${PLAN_WAS_ACTIVE[$i]}" == "true" ]]; then
      if ! systemctl start "${unit}" >/dev/null 2>&1; then
        err "[回滚] 旧服务启动失败：${unit}"
        log_failure "${unit}"
        rollback_failed=true
      elif ! systemctl is-active --quiet "${unit}"; then
        err "[回滚] 旧服务未恢复 active：${unit}"
        log_failure "${unit}"
        rollback_failed=true
      fi
    fi
  done
  rm -f "${OUT_TMP}"
  restore_yaml_http_state || rollback_failed=true
  restore_egress_route_state || rollback_failed=true
  if [[ "${rollback_failed}" == "true" ]]; then
    err "[回滚] 部分旧状态未能恢复，请检查上面的 systemd 日志"
  fi
  set -e
  [[ "${rollback_failed}" == "false" ]]
}

for ((i = 0; i < ${#PLAN_LISTEN_IPS[@]}; i++)); do
  conf="${PLAN_CONFS[$i]}"
  egress_file="${PLAN_EGRESS_FILES[$i]}"
  yaml_path="${PLAN_YAML_PATHS[$i]}"
  conf_backup="${conf}.backup.$$"
  egress_backup="${egress_file}.backup.$$"
  yaml_backup="${yaml_path}.backup.$$"

  if [[ -f "${conf}" ]]; then
    PLAN_CONF_EXISTED+=("true")
    cp -f "${conf}" "${conf_backup}"
  else
    PLAN_CONF_EXISTED+=("false")
  fi

  if [[ -f "${egress_file}" ]]; then
    PLAN_EGRESS_EXISTED+=("true")
    cp -f "${egress_file}" "${egress_backup}"
  else
    PLAN_EGRESS_EXISTED+=("false")
  fi

  if [[ -f "${yaml_path}" ]]; then
    PLAN_YAML_EXISTED+=("true")
    cp -f "${yaml_path}" "${yaml_backup}"
  else
    PLAN_YAML_EXISTED+=("false")
  fi

  if systemctl is-active --quiet "${PLAN_UNITS[$i]}" 2>/dev/null; then
    PLAN_WAS_ACTIVE+=("true")
  else
    PLAN_WAS_ACTIVE+=("false")
  fi

  if systemctl is-enabled --quiet "${PLAN_UNITS[$i]}" 2>/dev/null; then
    PLAN_WAS_ENABLED+=("true")
  else
    PLAN_WAS_ENABLED+=("false")
  fi

  PLAN_CONF_BACKUPS+=("${conf_backup}")
  PLAN_EGRESS_BACKUPS+=("${egress_backup}")
  PLAN_YAML_BACKUPS+=("${yaml_backup}")
done

if ! backup_yaml_http_state; then
  restore_egress_route_state
  exit 1
fi

umask 077
: > "${OUT_TMP}"

printf '\n已启用多实例模式（每个实例独立监听，可强制指定出口 IP）。\n'
printf '\nClash 节点片段：\n'

for ((i = 0; i < ${#PLAN_LISTEN_IPS[@]}; i++)); do
  listen_ip="${PLAN_LISTEN_IPS[$i]}"
  local_port="${PLAN_PORTS[$i]}"
  local_tag="${PLAN_TAGS[$i]}"
  local_pass="${PLAN_PASSES[$i]}"
  egress_ip="${PLAN_EGRESS_IPS[$i]}"
  inst_name="${PLAN_NAMES[$i]}"
  inst_unit="${PLAN_UNITS[$i]}"
  inst_conf="${PLAN_CONFS[$i]}"
  inst_egress="${PLAN_EGRESS_FILES[$i]}"
  yaml_path="${PLAN_YAML_PATHS[$i]}"
  yaml_url="${PLAN_YAML_URLS[$i]}"
  yaml_owner="${PLAN_YAML_OWNERS[$i]}"

  if [[ "${PLAN_WAS_ACTIVE[$i]}" == "true" ]]; then
    systemctl stop "${inst_unit}" || { rollback_multi_instances; exit 1; }
  fi

  write_one_config "${listen_ip}" "${local_port}" "${METHOD}" "${local_pass}" "${inst_conf}"
  write_instance_egress "${egress_ip}" "${inst_egress}"
  write_clash_yaml "${yaml_path}" "${local_tag}" "${listen_ip}" "${local_port}" "${METHOD}" "${local_pass}" "${yaml_owner}"

  systemctl enable "${inst_unit}" || { rollback_multi_instances; exit 1; }
  systemctl restart "${inst_unit}" || { log_failure "${inst_unit}"; rollback_multi_instances; exit 1; }
  sleep 1
  if ! systemctl is-active --quiet "${inst_unit}"; then
    err "服务未处于 active 状态：${inst_unit}"
    log_failure "${inst_unit}"
    rollback_multi_instances
    exit 1
  fi

  if should_manage_ufw; then
    ufw_allow_rule "${local_port}/tcp" || { rollback_multi_instances; exit 1; }
    ufw_allow_rule "${local_port}/udp" || { rollback_multi_instances; exit 1; }
  fi

  ss_uri="$(mk_ss_uri "${listen_ip}" "${local_port}" "${METHOD}" "${local_pass}" "${local_tag}")"
  append_output "${OUT_TMP}" "${listen_ip}" "${local_port}" "${METHOD}" "${local_pass}" "${ss_uri}" "${egress_ip}" "${yaml_path}" "${yaml_url}"

  printf -- "- name: %s\n" "${local_tag}"
  printf -- "  type: ss\n"
  printf -- "  server: %s\n" "${listen_ip}"
  printf -- "  port: %s\n" "${local_port}"
  printf -- "  cipher: %s\n" "${METHOD}"
  printf -- "  password: %s\n" "${local_pass}"
  printf -- "  udp: true\n"
  printf -- "  # egress_ip: %s\n" "${egress_ip}"
  printf -- "  # yaml_file: %s\n" "${yaml_path}"
  if [[ -n "${yaml_url}" ]]; then
    printf -- "  # yaml_url: %s\n" "${yaml_url}"
  fi
done

if [[ "${YAML_HTTP_ENABLE}" == "yes" ]]; then
  if ! ensure_yaml_http_service; then
    rollback_multi_instances
    exit 1
  fi
else
  disable_yaml_http_service
fi

if should_manage_ufw; then
  if [[ "${YAML_HTTP_ENABLE}" == "yes" ]] && ! is_loopback_bind "${YAML_HTTP_BIND}"; then
    ufw_allow_rule "${YAML_HTTP_PORT}/tcp" || { rollback_multi_instances; exit 1; }
  fi
  ufw_reload_rules || { rollback_multi_instances; exit 1; }
fi

mv -f "${OUT_TMP}" "${OUT_FILE}"
for ((i = 0; i < ${#PLAN_CONF_BACKUPS[@]}; i++)); do
  rm -f "${PLAN_CONF_BACKUPS[$i]}" "${PLAN_EGRESS_BACKUPS[$i]}" "${PLAN_YAML_BACKUPS[$i]}"
done
cleanup_egress_route_backups
cleanup_yaml_http_backups

printf '\n已保存到：%s\n' "${OUT_FILE}"
if [[ "${YAML_HTTP_ENABLE}" == "yes" ]]; then
  printf 'YAML HTTP 入口：http://%s:%s/\n' "${YAML_HTTP_RESOLVED_HOST}" "${YAML_HTTP_PORT}"
  printf '\n每个客户端 YAML 地址：\n'
  for ((i = 0; i < ${#PLAN_YAML_URLS[@]}; i++)); do
    printf '%s\n' "${PLAN_YAML_URLS[$i]}"
  done
fi

#!/bin/bash
set -euo pipefail
export LC_ALL=C
IFS=$'\n\t'

# ========== 随机字符串生成 ==========
rand_str() {
  openssl rand -hex $1 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-$((2*$1))
}

# ========== 随机文件名 ==========
RND=$(rand_str 8)
SERVER_TOML="${RND}_cfg.toml"
CERT_PEM="${RND}_c.pem"
KEY_PEM="${RND}_k.pem"
TUIC_BIN="${RND}_srv"
LINK_FILE="123.txt"

MASQ_DOMAIN="www.bing.com"

# ========== 随机端口 ==========
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

# ========== 选择端口 ==========
read_port() {
  if [[ -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    return
  fi
  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    return
  fi
  TUIC_PORT=$(random_port)
}

# ========== 检查已有配置（跳过重复）==========
load_existing_config() {
  return 1  # 强制每次全新部署，不加载旧配置
}

# ========== 生成证书 ==========
generate_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && return
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM" 2>/dev/null || true
  chmod 644 "$CERT_PEM" 2>/dev/null || true
}

# ========== 下载 tuic-server ==========
check_tuic_server() {
  [[ -x "$TUIC_BIN" ]] && return
  curl -L -s -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux" >/dev/null 2>&1
  chmod +x "$TUIC_BIN" 2>/dev/null || true
}

# ========== 生成配置 ==========
generate_config() {
  TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || rand_str 16)
  TUIC_PASSWORD=$(rand_str 16)

  cat > "$SERVER_TOML" <<EOF >/dev/null
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192
[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"
[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]
[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(rand_str 16)"
maximum_clients_per_user = 999999999
[quic]
initial_mtu = $((1200 + RANDOM % 200))
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"
[quic.congestion_control]
controller = "bbr"
initial_window = 6291456
EOF
}

# ========== 获取公网IP ==========
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "127.0.0.1"
}

# ========== 生成TUIC链接到 123.txt ==========
generate_link() {
  local ip="$1"
  local link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}"
  echo "$link" > "$LINK_FILE"
}

# ========== 后台静默运行 ==========
run_background() {
  nohup "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 &
}

# ========== 主流程 ==========
main() {
  read_port "$@"
  generate_cert
  check_tuic_server
  generate_config
  ip=$(get_server_ip)
  generate_link "$ip"
  run_background
  echo "部署完成"
}

main "$@"

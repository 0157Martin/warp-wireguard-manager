#!/usr/bin/env bash
# Cloudflare WARP WireGuard backend exposed as a local SOCKS5 proxy.
# Author: 0157Martin
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly APP_NAME=warp-wireguard-manager
readonly VERSION=1.0.1
readonly CONFIG_DIR=/etc/warp-wireguard-manager
readonly PROFILE_FILE="$CONFIG_DIR/wgcf-profile.conf"
readonly ACCOUNT_FILE="$CONFIG_DIR/wgcf-account.toml"
readonly WIREPROXY_CONFIG="$CONFIG_DIR/wireproxy.conf"
readonly STATE_FILE="$CONFIG_DIR/state.env"
readonly WGCF_BIN=/usr/local/libexec/warp-wireguard-manager/wgcf
readonly WIREPROXY_BIN=/usr/local/libexec/warp-wireguard-manager/wireproxy
readonly SERVICE_FILE=/etc/systemd/system/warp-wireguard-manager.service
readonly SERVICE_NAME=warp-wireguard-manager
readonly WGCF_API=https://api.github.com/repos/ViRb3/wgcf/releases/latest
readonly WIREPROXY_API=https://api.github.com/repos/windtf/wireproxy/releases/latest
readonly DEFAULT_PORT=40000
readonly START_TIMEOUT=45

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { red "错误：$*"; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 运行。'; }

machine_arch() {
  case $(uname -m) in
    x86_64|amd64) printf amd64 ;;
    aarch64|arm64) printf arm64 ;;
    armv7l|armv7) printf armv7 ;;
    i386|i686) printf 386 ;;
    *) die "不支持的系统架构：$(uname -m)" ;;
  esac
}

install_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq tar coreutils iproute2
}

download_release_asset() {
  local api=$1 pattern=$2 destination=$3 archive=${4:-0}
  local temp metadata asset_name asset_url checksums_url checksum_line
  temp=$(mktemp -d)
  trap 'rm -rf -- "$temp"' RETURN
  metadata=$(curl --fail --silent --show-error --location --retry 3 -H 'Accept: application/vnd.github+json' "$api")
  asset_name=$(jq -r --arg pattern "$pattern" '.assets[] | select(.name | test($pattern)) | .name' <<<"$metadata" | sed -n '1p')
  asset_url=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$metadata")
  checksums_url=$(jq -r '.assets[] | select(.name == "checksums.txt") | .browser_download_url' <<<"$metadata")
  [[ -n $asset_name && $asset_url != null && $checksums_url != null ]] || die "无法解析发布资产：$pattern"
  curl --fail --silent --show-error --location --retry 3 "$asset_url" -o "$temp/$asset_name"
  curl --fail --silent --show-error --location --retry 3 "$checksums_url" -o "$temp/checksums.txt"
  checksum_line=$(awk -v name="$asset_name" '$2 == name || $2 == "*" name {print $1 "  " name; exit}' "$temp/checksums.txt")
  [[ -n $checksum_line ]] || die "发布校验文件中缺少：$asset_name"
  (cd "$temp" && printf '%s\n' "$checksum_line" | sha256sum -c - >/dev/null) || die "发布资产 SHA-256 校验失败：$asset_name"
  install -d -m 755 "$(dirname "$destination")"
  if [[ $archive == 1 ]]; then
    tar -xzf "$temp/$asset_name" -C "$temp"
    [[ -x $temp/wireproxy ]] || die 'wireproxy 压缩包内容无效。'
    install -m 755 "$temp/wireproxy" "$destination"
  else
    install -m 755 "$temp/$asset_name" "$destination"
  fi
  trap - RETURN
  rm -rf -- "$temp"
}

install_binaries() {
  local arch
  arch=$(machine_arch)
  download_release_asset "$WGCF_API" "^wgcf_[0-9.]+_linux_${arch}$" "$WGCF_BIN"
  download_release_asset "$WIREPROXY_API" "^wireproxy_linux_${arch}\\.tar\\.gz$" "$WIREPROXY_BIN" 1
}

generate_profile() {
  install -d -m 700 "$CONFIG_DIR"
  if [[ ! -s $ACCOUNT_FILE ]]; then
    (cd "$CONFIG_DIR" && "$WGCF_BIN" register --accept-tos)
  fi
  (cd "$CONFIG_DIR" && "$WGCF_BIN" generate)
  [[ -s $PROFILE_FILE ]] || die 'WGCF 未生成 WireGuard 配置。'
  if ! grep -q '^PrivateKey' "$PROFILE_FILE" ||
     ! grep -q '^PublicKey' "$PROFILE_FILE" ||
     ! grep -q '^Endpoint' "$PROFILE_FILE"; then
    die 'WGCF 配置缺少必要字段。'
  fi
  chmod 600 "$ACCOUNT_FILE" "$PROFILE_FILE"
}

write_config() {
  local port=$1 temporary
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    die 'SOCKS5 端口必须在 1024-65535。'
  fi
  temporary=$(mktemp "$CONFIG_DIR/wireproxy.conf.XXXXXX")
  cat >"$temporary" <<EOF
WGConfig = $PROFILE_FILE

[Socks5]
BindAddress = 127.0.0.1:$port
EOF
  "$WIREPROXY_BIN" -c "$temporary" -n >/dev/null || { rm -f -- "$temporary"; die 'WireProxy 配置校验失败。'; }
  install -m 600 "$temporary" "$WIREPROXY_CONFIG"
  rm -f -- "$temporary"
  printf 'BACKEND=wireguard\nPORT=%q\n' "$port" >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare WARP WireGuard local proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$WIREPROXY_BIN -c $WIREPROXY_CONFIG -i 127.0.0.1:40001
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$CONFIG_DIR
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

proxy_ready() {
  local port=${1:-$DEFAULT_PORT}
  systemctl is-active --quiet "$SERVICE_NAME" && ss -H -lnt "sport = :$port" 2>/dev/null | grep -q .
}

wait_for_proxy() {
  local port=$1 attempt
  for ((attempt=0; attempt<START_TIMEOUT; attempt++)); do
    proxy_ready "$port" && return 0
    if systemctl is-failed --quiet "$SERVICE_NAME"; then
      return 1
    fi
    sleep 1
  done
  return 1
}

show_service_failure() {
  red 'WireProxy 未能启动本机 SOCKS5 监听。'
  systemctl --no-pager --full status "$SERVICE_NAME" 2>&1 | tail -n 20 >&2 || true
  journalctl -u "$SERVICE_NAME" -n 40 --no-pager 2>&1 |
    sed -E \
      -e 's/((Private|Public|Preshared)Key[=: ]+)[^ ,;}]+/\1[REDACTED]/Ig' \
      -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[REDACTED-UUID]/g' |
    tail -n 30 >&2 || true
}

test_proxy() {
  local port=${1:-$DEFAULT_PORT} trace
  if ! proxy_ready "$port"; then
    show_service_failure
    die "127.0.0.1:$port 未监听。"
  fi
  trace=$(curl --fail --silent --show-error --max-time 20 --proxy "socks5h://127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace) || die '无法通过 WireGuard WARP 代理联网。'
  grep -q '^warp=on$' <<<"$trace" || die 'Cloudflare 未确认 WARP 已连接。'
  awk -F= '/^(ip|loc|warp)=/{printf "%s: %s\n", $1, $2}' <<<"$trace"
}

install_backend() {
  local port=${1:-$DEFAULT_PORT}
  install_dependencies
  install_binaries
  generate_profile
  write_config "$port"
  write_service
  systemctl enable --now "$SERVICE_NAME"
  if ! wait_for_proxy "$port"; then
    show_service_failure
    die "127.0.0.1:$port 在 ${START_TIMEOUT} 秒内未开始监听。"
  fi
  test_proxy "$port"
  green "WireGuard WARP 后端已就绪：127.0.0.1:$port"
}

status_backend() {
  local port=$DEFAULT_PORT
  # The state file is created by this script with mode 0600.
  # shellcheck disable=SC1090
  [[ -r $STATE_FILE ]] && { source "$STATE_FILE"; port=${PORT:-$DEFAULT_PORT}; }
  printf '后端：WireGuard / WireProxy\n服务：%s\n监听：127.0.0.1:%s\n' "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" "$port"
  "$WIREPROXY_BIN" -v 2>/dev/null || true
  proxy_ready "$port" && test_proxy "$port" || return 1
}

repair_backend() {
  [[ -x $WGCF_BIN && -x $WIREPROXY_BIN && -s $PROFILE_FILE ]] || { install_backend "${1:-$DEFAULT_PORT}"; return; }
  local port=${1:-$DEFAULT_PORT}
  write_config "$port"
  write_service
  systemctl enable --now "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  if ! wait_for_proxy "$port"; then
    show_service_failure
    die "127.0.0.1:$port 在 ${START_TIMEOUT} 秒内未开始监听。"
  fi
  test_proxy "$port"
  green 'WireGuard WARP 后端已修复。'
}

start_backend() {
  systemctl enable --now "$SERVICE_NAME"
}

stop_backend() {
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
}

diagnose_backend() {
  status_backend || true
  printf '%s\n' '最近连接日志：'
  journalctl -u "$SERVICE_NAME" -n 100 --no-pager 2>&1 | tail -n 30 || true
}

uninstall_backend() {
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f -- "$SERVICE_FILE"
  rm -rf -- "$CONFIG_DIR" "$(dirname "$WGCF_BIN")"
  systemctl daemon-reload
  green 'WireGuard WARP 后端已卸载。'
}

main() {
  require_root
  case ${1:-status} in
    install) install_backend "${2:-$DEFAULT_PORT}" ;;
    status) status_backend ;;
    test) test_proxy "${2:-$DEFAULT_PORT}" ;;
    start) start_backend ;;
    stop) stop_backend ;;
    diagnose) diagnose_backend ;;
    repair) repair_backend "${2:-$DEFAULT_PORT}" ;;
    uninstall) uninstall_backend ;;
    version) printf '%s %s\n' "$APP_NAME" "$VERSION" ;;
    *) die '用法：warp-wireguard [install|status|test|start|stop|diagnose|repair|uninstall|version] [端口]' ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

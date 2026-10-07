#!/usr/bin/env bash
# Bootstrap installer for warp-wireguard-manager.
# Author: Martin&林知远
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly COMMAND=/usr/local/bin/warp-wireguard
readonly SCRIPT_URL=https://raw.githubusercontent.com/0157Martin/warp-wireguard-manager/main/warp-wireguard.sh
readonly DEFAULT_PORT=40000

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 运行。'; }

install_manager() {
  local port=${1:-$DEFAULT_PORT} temporary
  temporary=$(mktemp)
  trap 'rm -f -- "$temporary"' RETURN
  curl --fail --show-error --location --retry 3 "$SCRIPT_URL" -o "$temporary"
  bash -n "$temporary" || die '下载的管理脚本语法校验失败。'
  grep -q '^# SPDX-License-Identifier: GPL-3.0-or-later$' "$temporary" || die '下载的管理脚本缺少许可证标识。'
  install -m 755 "$temporary" "$COMMAND"
  "$COMMAND" install "$port"
}

verify_manager() {
  local port=${1:-$DEFAULT_PORT}
  [[ -x $COMMAND ]] || die '尚未安装 warp-wireguard。'
  "$COMMAND" version
  "$COMMAND" status
  "$COMMAND" test "$port"
}

uninstall_manager() {
  if [[ -x $COMMAND ]]; then
    "$COMMAND" uninstall
  fi
  rm -f -- "$COMMAND"
  printf '%s\n' 'warp-wireguard-manager 已彻底卸载。'
}

main() {
  require_root
  case ${1:-install} in
    install) install_manager "${2:-$DEFAULT_PORT}" ;;
    verify) verify_manager "${2:-$DEFAULT_PORT}" ;;
    uninstall) uninstall_manager ;;
    *) die '用法：install.sh [install|verify|uninstall] [端口]' ;;
  esac
}

main "$@"

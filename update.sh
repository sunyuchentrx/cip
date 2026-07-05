#!/usr/bin/env bash

set -euo pipefail

REPO="${REPO:-sunyuchentrx/cip}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"

SERVICE_NAME="${SERVICE_NAME:-cip}"
INSTALL_DIR="${INSTALL_DIR:-/root}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/cip}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/cip.env}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
TMP_DIR=""
WAS_ACTIVE=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        printf '错误：请使用 root 权限运行，例如：\n'
        printf '  sudo cip-update\n'
        exit 1
    fi
}

require_command() {
    local missing=()
    local cmd

    for cmd in curl install systemctl rm; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        log "缺少依赖：${missing[*]}"
        exit 1
    fi
}

download() {
    local name="$1"
    local destination="$2"

    log "正在下载 ${name}"
    curl -fsSL "${RAW_BASE}/${name}" -o "$destination"
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

main() {
    require_root
    require_command

    TMP_DIR=$(mktemp -d)
    trap cleanup EXIT

    download "ssh_monitor.sh" "${TMP_DIR}/ssh_monitor.sh"
    download "cip" "${TMP_DIR}/cip"
    download "cip.service" "${TMP_DIR}/cip.service"
    download "update.sh" "${TMP_DIR}/update.sh"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        WAS_ACTIVE=1
        log "服务正在运行，先停止 ${SERVICE_NAME}"
        systemctl stop "$SERVICE_NAME"
    fi

    log "保留配置文件：${CONFIG_FILE}"
    log "删除旧程序文件"
    rm -f "${INSTALL_DIR}/ssh_monitor.sh" "${BIN_DIR}/cip" "${BIN_DIR}/cip-update" "$SERVICE_FILE"

    log "安装新程序文件"
    install -d "$INSTALL_DIR" "$BIN_DIR" "$CONFIG_DIR"
    install -m 0755 "${TMP_DIR}/ssh_monitor.sh" "${INSTALL_DIR}/ssh_monitor.sh"
    install -m 0755 "${TMP_DIR}/cip" "${BIN_DIR}/cip"
    install -m 0755 "${TMP_DIR}/update.sh" "${BIN_DIR}/cip-update"
    install -m 0644 "${TMP_DIR}/cip.service" "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null

    if [[ "$WAS_ACTIVE" == "1" ]]; then
        log "重新启动服务 ${SERVICE_NAME}"
        systemctl start "$SERVICE_NAME"
    fi

    log "更新完成。配置文件未改动：${CONFIG_FILE}"
}

main "$@"

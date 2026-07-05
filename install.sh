#!/usr/bin/env bash

set -euo pipefail

REPO="${REPO:-sunyuchentrx/cip}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"

SERVICE_NAME="${SERVICE_NAME:-cip}"
INSTALL_DIR="${INSTALL_DIR:-/root}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/cip}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        printf 'Error: run as root, for example:\n'
        printf '  sudo bash -c "$(curl -fsSL %s/install.sh)"\n' "$RAW_BASE"
        exit 1
    fi
}

require_command() {
    local missing=()
    local cmd

    for cmd in curl install systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        log "Missing dependencies: ${missing[*]}"
        log "Install them first, for example: apt-get update && apt-get install -y curl coreutils systemd"
        exit 1
    fi
}

download() {
    local name="$1"
    local destination="$2"

    log "Downloading ${name}"
    curl -fsSL "${RAW_BASE}/${name}" -o "$destination"
}

main() {
    require_root
    require_command

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    download "ssh_monitor.sh" "${tmp_dir}/ssh_monitor.sh"
    download "cip" "${tmp_dir}/cip"
    download "cip.service" "${tmp_dir}/cip.service"
    download "cip.env.example" "${tmp_dir}/cip.env.example"

    log "Installing files"
    install -d "$INSTALL_DIR" "$BIN_DIR" "$CONFIG_DIR"
    install -m 0755 "${tmp_dir}/ssh_monitor.sh" "${INSTALL_DIR}/ssh_monitor.sh"
    install -m 0755 "${tmp_dir}/cip" "${BIN_DIR}/cip"
    install -m 0644 "${tmp_dir}/cip.service" "$SERVICE_FILE"

    if [[ ! -f "${CONFIG_DIR}/cip.env" ]]; then
        install -m 0600 "${tmp_dir}/cip.env.example" "${CONFIG_DIR}/cip.env"
        log "Created config: ${CONFIG_DIR}/cip.env"
    else
        log "Keeping existing config: ${CONFIG_DIR}/cip.env"
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null

    log "Install complete."
    log "Edit config before starting: nano ${CONFIG_DIR}/cip.env"
    log "Start service: systemctl start ${SERVICE_NAME}"
    log "Manager menu: cip"
}

main "$@"

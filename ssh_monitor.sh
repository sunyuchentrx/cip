#!/usr/bin/env bash

set -u

# CIP monitor.
# Checks the current public IP and target port through an HTTP API. If the
# check fails several times in a row, it calls the configured IP switch URL.

SCRIPT_NAME="${SCRIPT_NAME:-CIP Monitor}"
DEVICE_NAME="${DEVICE_NAME:-}"
CONFIG_FILE="${CONFIG_FILE:-/etc/cip/cip.env}"

# Main settings. These can be overridden by /etc/cip/cip.env or environment.
TARGET_ADDRESS="${TARGET_ADDRESS:-auto}"
TARGET_PORT="${TARGET_PORT:-}"
CHECK_API_URL="${CHECK_API_URL:-}"
CHECK_API_URL_2="${CHECK_API_URL_2:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
MAX_FAILURES="${MAX_FAILURES:-3}"
SWITCH_IP_URL="${SWITCH_IP_URL:-}"
SWITCH_WAIT_SECONDS="${SWITCH_WAIT_SECONDS:-10}"
SWITCH_COOLDOWN_SECONDS="${SWITCH_COOLDOWN_SECONDS:-120}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

FAILURE_COUNT=0
LAST_SWITCH_TS=0
CURRENT_ADDRESS=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

send_telegram() {
    local message="$1"
    local title="$SCRIPT_NAME"

    if [[ -n "${DEVICE_NAME:-}" ]]; then
        title="${SCRIPT_NAME} - ${DEVICE_NAME}"
    fi

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        log "[TG] $message"
        return 0
    fi

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local response

    response=$(curl -sS --max-time 15 -X POST "$url" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${title}
------------------------------
${message}" \
        -d "disable_web_page_preview=true" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "[TG] sent"
    else
        log "[TG] send failed: $response"
    fi
}

device_label() {
    if [[ -n "${DEVICE_NAME:-}" ]]; then
        printf '%s\n' "$DEVICE_NAME"
    else
        printf '未设置\n'
    fi
}

notify_status() {
    local status="$1"
    local extra="${2:-}"
    local target="${CURRENT_ADDRESS:-unknown}:${TARGET_PORT:-unknown}"
    local message

    message="状态：${status}
设备：$(device_label)
目标：${target}"

    if [[ -n "$extra" ]]; then
        message="${message}
${extra}"
    fi

    message="${message}
时间：$(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram "$message"
}

get_current_ip() {
    local services=(
        "https://api.ipify.org"
        "https://ipinfo.io/ip"
        "https://icanhazip.com"
        "http://checkip.amazonaws.com"
    )
    local service ip

    for service in "${services[@]}"; do
        ip=$(curl -fsS --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '\n\r[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done

    return 1
}

refresh_target_address() {
    if [[ "${TARGET_ADDRESS:-auto}" != "auto" && -n "${TARGET_ADDRESS:-}" ]]; then
        CURRENT_ADDRESS="$TARGET_ADDRESS"
        return 0
    fi

    local ip
    if ip=$(get_current_ip); then
        CURRENT_ADDRESS="$ip"
        log "Target address set to current public IP: $CURRENT_ADDRESS"
        return 0
    fi

    log "Failed to get current public IP"
    return 1
}

check_single_api() {
    local api_url="$1"
    local address="$2"
    local port="$3"
    local label="$4"
    local url="${api_url}?address=${address}&port=${port}"
    local response code returned_address returned_port

    log "[CHECK][$label] API checking ${address}:${port}"

    response=$(curl -fsS --connect-timeout 8 --max-time 20 "$url" 2>&1)
    if [[ $? -ne 0 ]]; then
        log "[CHECK][$label] API request failed: $response"
        return 1
    fi

    code=$(printf '%s' "$response" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9]\+\).*/\1/p')
    returned_address=$(printf '%s' "$response" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    returned_port=$(printf '%s' "$response" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [[ "$code" == "200" && "$returned_address" == "$address" && "$returned_port" == "$port" ]]; then
        log "[CHECK][$label] success: ${address}:${port}"
        return 0
    fi

    log "[CHECK][$label] failed: $response"
    return 1
}

check_port_by_api() {
    local address="$1"
    local port="$2"
    local status_file_1 status_file_2 pid_1 pid_2 status_1 status_2

    status_file_1=$(mktemp)
    status_file_2=$(mktemp)

    (
        if check_single_api "$CHECK_API_URL" "$address" "$port" "api1"; then
            printf '0' > "$status_file_1"
        else
            printf '1' > "$status_file_1"
        fi
    ) &
    pid_1=$!

    (
        if check_single_api "$CHECK_API_URL_2" "$address" "$port" "api2"; then
            printf '0' > "$status_file_2"
        else
            printf '1' > "$status_file_2"
        fi
    ) &
    pid_2=$!

    wait "$pid_1"
    wait "$pid_2"

    status_1=$(cat "$status_file_1" 2>/dev/null || printf '1')
    status_2=$(cat "$status_file_2" 2>/dev/null || printf '1')
    rm -f "$status_file_1" "$status_file_2"

    if [[ "$status_1" == "0" || "$status_2" == "0" ]]; then
        log "[CHECK] success: at least one API confirmed ${address}:${port}"
        return 0
    fi

    log "[CHECK] failed: both APIs failed for ${address}:${port}"
    return 1
}

switch_ip() {
    local now old_ip new_ip result
    now=$(date +%s)

    if (( now - LAST_SWITCH_TS < SWITCH_COOLDOWN_SECONDS )); then
        log "Switch skipped: still in cooldown (${SWITCH_COOLDOWN_SECONDS}s)"
        return 1
    fi

    old_ip="${CURRENT_ADDRESS:-unknown}"
    log "Switching IP, current address: $old_ip"

    result=$(curl -fsS --connect-timeout 8 --max-time 20 "$SWITCH_IP_URL" 2>&1)
    if [[ $? -ne 0 ]]; then
        log "IP switch request failed: $result"
        send_telegram "状态：换 IP 失败
设备：$(device_label)
当前 IP：$old_ip
原因：接口请求失败
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        LAST_SWITCH_TS=$now
        return 1
    fi

    log "IP switch request succeeded: $result"
    sleep "$SWITCH_WAIT_SECONDS"

    if refresh_target_address; then
        new_ip="$CURRENT_ADDRESS"
    else
        new_ip="unknown"
    fi

    LAST_SWITCH_TS=$now
    log "IP switch completed: $old_ip -> $new_ip"
    send_telegram "状态：换 IP 完成
设备：$(device_label)
旧 IP：$old_ip
新 IP：$new_ip
端口：$TARGET_PORT
时间：$(date '+%Y-%m-%d %H:%M:%S')"
    return 0
}

check_config() {
    local errors=()
    local error

    [[ -z "${TARGET_PORT:-}" ]] && errors+=("TARGET_PORT 未配置")
    [[ -z "${CHECK_API_URL:-}" ]] && errors+=("CHECK_API_URL 未配置")
    [[ -z "${CHECK_API_URL_2:-}" ]] && errors+=("CHECK_API_URL_2 未配置")
    [[ -z "${SWITCH_IP_URL:-}" ]] && errors+=("SWITCH_IP_URL 未配置")
    [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || errors+=("CHECK_INTERVAL 必须是数字")
    [[ "$MAX_FAILURES" =~ ^[0-9]+$ ]] || errors+=("MAX_FAILURES 必须是数字")
    [[ "$SWITCH_WAIT_SECONDS" =~ ^[0-9]+$ ]] || errors+=("SWITCH_WAIT_SECONDS 必须是数字")
    [[ "$SWITCH_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || errors+=("SWITCH_COOLDOWN_SECONDS 必须是数字")

    if ! refresh_target_address; then
        errors+=("无法获取目标公网 IP")
    fi

    if (( ${#errors[@]} > 0 )); then
        log "配置错误："
        for error in "${errors[@]}"; do
            log "  - $error"
        done
        return 1
    fi

    return 0
}

check_dependencies() {
    local missing=()
    local cmd

    for cmd in curl sed date tr mktemp cat rm; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        log "缺少依赖：${missing[*]}"
        log "安装示例：apt-get update && apt-get install -y curl coreutils sed"
        return 1
    fi

    return 0
}

cleanup() {
    log "Stopping monitor"
    exit 0
}

main_loop() {
    log "Monitoring ${CURRENT_ADDRESS}:${TARGET_PORT} via ${CHECK_API_URL} and ${CHECK_API_URL_2}"
    notify_status "监控服务启动完成" "检测间隔：${CHECK_INTERVAL} 秒
失败阈值：${MAX_FAILURES} 次"

    while true; do
        if check_port_by_api "$CURRENT_ADDRESS" "$TARGET_PORT"; then
            if (( FAILURE_COUNT > 0 )); then
                log "Port recovered: ${CURRENT_ADDRESS}:${TARGET_PORT}"
            fi
            FAILURE_COUNT=0
        else
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            log "Port check failed (${FAILURE_COUNT}/${MAX_FAILURES})"

            if (( FAILURE_COUNT >= MAX_FAILURES )); then
                log "Failure threshold reached, triggering IP switch"
                send_telegram "状态：连续检测失败
设备：$(device_label)
目标：${CURRENT_ADDRESS}:${TARGET_PORT}
失败次数：${FAILURE_COUNT}/${MAX_FAILURES}
处理动作：准备换 IP
时间：$(date '+%Y-%m-%d %H:%M:%S')"

                switch_ip
                FAILURE_COUNT=0
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main() {
    log "=== CIP monitor starting ==="

    if ! check_dependencies; then
        exit 2
    fi

    if ! check_config; then
        exit 2
    fi

    trap cleanup SIGINT SIGTERM

    log "Target address: $CURRENT_ADDRESS"
    log "Target port: $TARGET_PORT"
    log "Check interval: ${CHECK_INTERVAL}s"
    log "Failure threshold: $MAX_FAILURES"
    log "Switch cooldown: ${SWITCH_COOLDOWN_SECONDS}s"

    main_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

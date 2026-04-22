#!/usr/bin/env bash

set -euo pipefail

# =========================
# Configurazione base
# =========================
DEFAULT_RAM_PERCENT="80"
MIN_TMPFS_MIB=512
MIN_FREE_MIB=256
LOGFILE="${HOME}/rclone-mount-ram.log"
TMPFS_PARENT="/tmp"

RC_HOST="127.0.0.1"
RC_PORT="5572"
DASH_REFRESH_SECONDS=1
MAX_ACTIVE_TRANSFERS=5
# =========================

RCLONE_PID=""
NEMO_PID=""
CLEANED_UP="false"

REMOTE_NAME=""
REMOTE=""
TMPFS_ROOT=""
MOUNTPOINT=""
CACHE_DIR=""
RAM_PERCENT=""

TMPFS_SIZE_KB=0
TMPFS_SIZE_MIB=0
CACHE_MAX_KB=0
CACHE_MAX_MIB=0
FREE_HEADROOM_KB=0
FREE_HEADROOM_MIB=0

need_cmds() {
    for cmd in rclone awk numfmt ps id mountpoint mount grep sed tr printf sudo mkdir chmod chown ss tail nemo mktemp curl jq tput du df find sleep seq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' is not installed." >&2
            exit 1
        fi
    done

    if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
        echo "Error: neither 'fusermount3' nor 'fusermount' is installed." >&2
        exit 1
    fi
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "${prompt} [${default}]: " value
    if [ -z "${value}" ]; then
        echo "${default}"
    else
        echo "${value}"
    fi
}

choose_remote() {
    mapfile -t REMOTES < <(rclone listremotes 2>/dev/null | sed 's/:$//')

    if [ "${#REMOTES[@]}" -eq 0 ]; then
        echo "No rclone remotes found. Run 'rclone config' first." >&2
        exit 1
    fi

    echo "Available rclone remotes:"
    PS3="Select a remote number: "
    select remote in "${REMOTES[@]}"; do
        if [ -n "${remote:-}" ]; then
            REMOTE_NAME="${remote}"
            REMOTE="${remote}:"
            break
        fi
        echo "Invalid selection."
    done
}

show_remote_info() {
    local remote="$1"
    local remote_type
    remote_type=$(rclone config show "${remote}" 2>/dev/null | awk -F' = ' '/^type = /{print $2; exit}')
    if [ -n "${remote_type}" ]; then
        echo "Selected remote: ${remote} (type: ${remote_type})"
    else
        echo "Selected remote: ${remote}"
    fi
}

collect_inputs() {
    choose_remote
    show_remote_info "${REMOTE_NAME}"

    RAM_PERCENT=$(prompt_default "Percent of MemAvailable to allocate to RAM tmpfs" "${DEFAULT_RAM_PERCENT}")
    if ! [[ "${RAM_PERCENT}" =~ ^[0-9]+$ ]] || [ "${RAM_PERCENT}" -lt 1 ] || [ "${RAM_PERCENT}" -gt 95 ]; then
        echo "RAM percent must be an integer between 1 and 95." >&2
        exit 1
    fi

    local safe_remote
    safe_remote=$(printf '%s' "${REMOTE_NAME}" | tr -cs '[:alnum:]_.-' '-')

    TMPFS_ROOT="${TMPFS_PARENT}/rclone-ram-${safe_remote}-$$"
    MOUNTPOINT="${TMPFS_ROOT}/mount"
    CACHE_DIR="${TMPFS_ROOT}/cache"
}

prepare_tmpfs_layout() {
    local mem_available_kb
    mem_available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)

    if [ -z "${mem_available_kb}" ] || ! [[ "${mem_available_kb}" =~ ^[0-9]+$ ]]; then
        echo "Error: unable to read MemAvailable from /proc/meminfo" >&2
        exit 1
    fi

    TMPFS_SIZE_KB=$(( mem_available_kb * RAM_PERCENT / 100 ))
    local min_tmpfs_kb=$(( MIN_TMPFS_MIB * 1024 ))
    if [ "${TMPFS_SIZE_KB}" -lt "${min_tmpfs_kb}" ]; then
        TMPFS_SIZE_KB="${min_tmpfs_kb}"
    fi

    FREE_HEADROOM_KB=$(( TMPFS_SIZE_KB / 10 ))
    local min_free_kb=$(( MIN_FREE_MIB * 1024 ))
    if [ "${FREE_HEADROOM_KB}" -lt "${min_free_kb}" ]; then
        FREE_HEADROOM_KB="${min_free_kb}"
    fi

    if [ "${FREE_HEADROOM_KB}" -ge "${TMPFS_SIZE_KB}" ]; then
        FREE_HEADROOM_KB=$(( TMPFS_SIZE_KB / 4 ))
    fi

    CACHE_MAX_KB=$(( TMPFS_SIZE_KB - FREE_HEADROOM_KB ))
    if [ "${CACHE_MAX_KB}" -le 0 ]; then
        echo "Error: computed cache size is invalid." >&2
        exit 1
    fi

    TMPFS_SIZE_MIB=$(( TMPFS_SIZE_KB / 1024 ))
    CACHE_MAX_MIB=$(( CACHE_MAX_KB / 1024 ))
    FREE_HEADROOM_MIB=$(( FREE_HEADROOM_KB / 1024 ))

    local mem_available_human
    local tmpfs_human
    local cache_human
    local free_human

    mem_available_human=$(numfmt --to=iec --suffix=B $(( mem_available_kb * 1024 )))
    tmpfs_human=$(numfmt --to=iec --suffix=B $(( TMPFS_SIZE_KB * 1024 )))
    cache_human=$(numfmt --to=iec --suffix=B $(( CACHE_MAX_KB * 1024 )))
    free_human=$(numfmt --to=iec --suffix=B $(( FREE_HEADROOM_KB * 1024 )))

    echo "MemAvailable: ${mem_available_human}"
    echo "Total RAM tmpfs size: ${tmpfs_human}"
    echo "Rclone VFS cache max size: ${cache_human}"
    echo "Reserved free space inside tmpfs: ${free_human}"
    echo "TMPFS root: ${TMPFS_ROOT}"
    echo "Mountpoint: ${MOUNTPOINT}"
    echo "Cache dir: ${CACHE_DIR}"
    echo "Log file: ${LOGFILE}"

    sudo mkdir -p "${TMPFS_ROOT}"

    if mountpoint -q "${TMPFS_ROOT}"; then
        echo "Error: ${TMPFS_ROOT} is already a mountpoint." >&2
        exit 1
    fi

    echo "Mounting tmpfs on ${TMPFS_ROOT} ..."
    sudo mount -t tmpfs -o "size=${TMPFS_SIZE_KB}k,uid=$(id -u),gid=$(id -g),mode=700" tmpfs "${TMPFS_ROOT}"

    sudo chown "$(id -u):$(id -g)" "${TMPFS_ROOT}"
    chmod 700 "${TMPFS_ROOT}"

    mkdir -p "${MOUNTPOINT}" "${CACHE_DIR}"

    if [ -n "$(find "${MOUNTPOINT}" -mindepth 1 -print -quit 2>/dev/null || true)" ]; then
        echo "Error: mountpoint is not empty: ${MOUNTPOINT}" >&2
        exit 1
    fi
}

pick_fuse_umount() {
    if command -v fusermount3 >/dev/null 2>&1; then
        echo "fusermount3"
    else
        echo "fusermount"
    fi
}

check_rc_port() {
    if ss -ltnH "( sport = :${RC_PORT} )" 2>/dev/null | grep -q .; then
        echo "Error: RC port ${RC_PORT} is already in use." >&2
        exit 1
    fi
}

human_bytes() {
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"
}

format_duration() {
    local t="${1:-0}"
    t="${t%.*}"
    [ -z "${t}" ] && t=0
    printf '%02d:%02d:%02d' $((t / 3600)) $(((t % 3600) / 60)) $((t % 60))
}

render_bar() {
    local used="${1:-0}"
    local total="${2:-1}"
    local width="${3:-30}"
    local pct fill empty

    [ "${total}" -le 0 ] && total=1
    [ "${used}" -lt 0 ] && used=0

    pct=$(( used * 100 / total ))
    [ "${pct}" -gt 100 ] && pct=100

    fill=$(( pct * width / 100 ))
    empty=$(( width - fill ))

    printf '['
    printf '%*s' "${fill}" '' | tr ' ' '#'
    printf '%*s' "${empty}" '' | tr ' ' '.'
    printf '] %3d%%' "${pct}"
}

wait_for_rc() {
    local url="http://${RC_HOST}:${RC_PORT}/core/stats"

    for _ in $(seq 1 50); do
        if curl -fsS -X POST "${url}" >/dev/null 2>&1; then
            return 0
        fi

        if ! ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
            break
        fi

        sleep 0.2
    done

    return 1
}

monitor_rclone_cli() {
    local url="http://${RC_HOST}:${RC_PORT}/core/stats"
    local key stats_json bytes speed checks transfers errors elapsed total_bytes eta
    local cache_used tmpfs_used tmpfs_avail tmpfs_total
    local -a active_lines=()

    tput civis 2>/dev/null || true

    while ps -p "${RCLONE_PID}" >/dev/null 2>&1; do
        stats_json=$(curl -fsS -X POST "${url}" 2>/dev/null || true)
        cache_used=$(du -sb "${CACHE_DIR}" 2>/dev/null | awk '{print $1+0}')
        read -r tmpfs_used tmpfs_avail tmpfs_total < <(
            df -B1 --output=used,avail,size "${TMPFS_ROOT}" 2>/dev/null | awk 'NR==2{print $1,$2,$3}'
        )

        tput home 2>/dev/null || true
        tput ed 2>/dev/null || printf '\033[2J\033[H'

        echo "rclone activity dashboard  |  press q to quit  |  Ctrl+C cleans everything"
        echo
        echo "Remote     : ${REMOTE}"
        echo "Mountpoint : ${MOUNTPOINT}"
        echo "Cache dir  : ${CACHE_DIR}"
        echo "RC         : http://${RC_HOST}:${RC_PORT}"
        echo

        if [ -n "${stats_json}" ]; then
            bytes=$(jq -r '.bytes // 0' <<<"${stats_json}")
            speed=$(jq -r '.speed // 0' <<<"${stats_json}")
            checks=$(jq -r '.checks // 0' <<<"${stats_json}")
            transfers=$(jq -r '.transfers // 0' <<<"${stats_json}")
            errors=$(jq -r '.errors // 0' <<<"${stats_json}")
            elapsed=$(jq -r '.elapsedTime // 0' <<<"${stats_json}")
            total_bytes=$(jq -r '.totalBytes // 0' <<<"${stats_json}")
            eta=$(jq -r 'if (.eta // null) == null then "-" else (.eta|tostring) end' <<<"${stats_json}")

            echo "Transferred: $(human_bytes "${bytes}")"
            echo "Speed      : $(human_bytes "${speed%.*}")/s"
            echo "Checks     : ${checks}"
            echo "Transfers  : ${transfers}"
            echo "Errors     : ${errors}"
            echo "Elapsed    : $(format_duration "${elapsed}")"
            echo "ETA        : ${eta}"

            if [ "${total_bytes}" -gt 0 ]; then
                printf "Progress   : "
                render_bar "${bytes}" "${total_bytes}" 36
                echo "  $(human_bytes "${bytes}") / $(human_bytes "${total_bytes}")"
            fi

            mapfile -t active_lines < <(
                jq -r '
                    .transferring[]? |
                    "\(.name // "unknown")|\(.percentage // 0)|\(.speedAvg // .speed // 0)|\(.bytes // 0)|\(.size // 0)"
                ' <<<"${stats_json}" 2>/dev/null | head -n "${MAX_ACTIVE_TRANSFERS}"
            )
        else
            echo "RC stats   : unavailable"
            active_lines=()
        fi

        echo
        echo "tmpfs use  : $(human_bytes "${tmpfs_used:-0}") / $(human_bytes "${tmpfs_total:-0}")"
        printf "tmpfs fill : "
        render_bar "${tmpfs_used:-0}" "${tmpfs_total:-1}" 36
        echo
        echo "cache use  : $(human_bytes "${cache_used:-0}") / $(human_bytes "$(( CACHE_MAX_MIB * 1024 * 1024 ))")"
        printf "cache fill : "
        render_bar "${cache_used:-0}" "$(( CACHE_MAX_MIB * 1024 * 1024 ))" 36
        echo

        echo
        echo "Active transfers:"
        if [ "${#active_lines[@]}" -eq 0 ]; then
            echo "  (idle)"
        else
            local line name pct spd cur size
            for line in "${active_lines[@]}"; do
                IFS='|' read -r name pct spd cur size <<<"${line}"
                echo "  - ${name}"
                printf '    %s%%  %s/s  %s / %s\n' \
                    "${pct%.*}" \
                    "$(human_bytes "${spd%.*}")" \
                    "$(human_bytes "${cur}")" \
                    "$(human_bytes "${size}")"
            done
        fi

        echo
        echo "Recent log:"
        tail -n 5 "${LOGFILE}" 2>/dev/null | sed 's/^/  /'

        IFS= read -rsn1 -t "${DASH_REFRESH_SECONDS}" key || true
        if [ "${key:-}" = "q" ] || [ "${key:-}" = "Q" ]; then
            break
        fi
    done

    tput cnorm 2>/dev/null || true
}

start_rclone_mount() {
    if mountpoint -q "${MOUNTPOINT}"; then
        echo "Error: ${MOUNTPOINT} is already mounted." >&2
        exit 1
    fi

    check_rc_port

    : > "${LOGFILE}"

    echo "--- Starting rclone mount in background... ---"

    rclone mount "${REMOTE}" "${MOUNTPOINT}" \
      --cache-dir "${CACHE_DIR}" \
      --vfs-cache-mode full \
      --vfs-cache-max-size "${CACHE_MAX_MIB}Mi" \
      --vfs-cache-min-free-space "${FREE_HEADROOM_MIB}Mi" \
      --vfs-cache-max-age 1h \
      --dir-cache-time 10m \
      --buffer-size 16M \
      --vfs-read-chunk-size 32M \
      --vfs-read-chunk-size-limit 256M \
      --transfers 4 \
      --rc \
      --rc-addr "${RC_HOST}:${RC_PORT}" \
      --rc-no-auth \
      --stats 1s \
      --stats-log-level NOTICE \
      --log-file "${LOGFILE}" \
      --log-level INFO &

    RCLONE_PID=$!

    echo "Waiting for rclone mount (PID: ${RCLONE_PID}) to become ready..."

    local mounted="false"
    for _ in $(seq 1 150); do
        if mountpoint -q "${MOUNTPOINT}"; then
            mounted="true"
            break
        fi

        if ! ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
            echo
            echo "Error: rclone mount failed to start!" >&2
            echo "Recent log output:" >&2
            tail -n 80 "${LOGFILE}" >&2 || true
            exit 1
        fi

        printf "."
        sleep 0.2
    done
    echo

    if [ "${mounted}" != "true" ]; then
        echo "Error: mountpoint did not become active in time: ${MOUNTPOINT}" >&2
        echo "Recent log output:" >&2
        tail -n 80 "${LOGFILE}" >&2 || true
        exit 1
    fi
}

launch_nemo() {
    echo "Mount is UP!"
    echo "Opening Nemo on local mountpoint..."
    nemo "${MOUNTPOINT}" >/dev/null 2>&1 &
    NEMO_PID=$!

    echo "--- Press q in the dashboard or CTRL+C to close everything ---"
    echo "--- Local mountpoint: ${MOUNTPOINT} ---"
    echo "--- Cache directory: ${CACHE_DIR} ---"
    echo "--- RC endpoint: http://${RC_HOST}:${RC_PORT} ---"

    if wait_for_rc; then
        monitor_rclone_cli
    else
        echo "Warning: RC dashboard unavailable, falling back to plain wait."
        wait "${RCLONE_PID}"
    fi
}

cleanup() {
    tput cnorm 2>/dev/null || true

    if [ "${CLEANED_UP}" = "true" ]; then
        return
    fi
    CLEANED_UP="true"

    echo
    echo "--- Shutdown requested: cleaning up... ---"

    if command -v nemo >/dev/null 2>&1; then
        nemo -q >/dev/null 2>&1 || true
    fi

    if [ -n "${NEMO_PID:-}" ] && ps -p "${NEMO_PID}" >/dev/null 2>&1; then
        kill "${NEMO_PID}" 2>/dev/null || true
        wait "${NEMO_PID}" 2>/dev/null || true
    fi

    if [ -n "${MOUNTPOINT:-}" ] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        echo "Unmounting rclone FUSE mount..."
        local FUSE_UMOUNT
        FUSE_UMOUNT=$(pick_fuse_umount)
        "${FUSE_UMOUNT}" -u "${MOUNTPOINT}" >/dev/null 2>&1 || sudo umount -l "${MOUNTPOINT}" >/dev/null 2>&1 || true
        sleep 1
    fi

    if [ -n "${RCLONE_PID:-}" ] && ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
        echo "Stopping rclone (PID: ${RCLONE_PID})..."
        kill -TERM "${RCLONE_PID}" 2>/dev/null || true

        for _ in $(seq 1 30); do
            if ! ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.2
        done

        if ps -p "${RCLONE_PID}" >/dev/null 2>&1; then
            kill -KILL "${RCLONE_PID}" 2>/dev/null || true
        fi

        wait "${RCLONE_PID}" 2>/dev/null || true
    fi

    if [ -n "${TMPFS_ROOT:-}" ] && mountpoint -q "${TMPFS_ROOT}" 2>/dev/null; then
        echo "Unmounting RAM tmpfs..."
        sudo umount "${TMPFS_ROOT}" >/dev/null 2>&1 || sudo umount -l "${TMPFS_ROOT}" >/dev/null 2>&1 || true
    fi

    if [ -n "${TMPFS_ROOT:-}" ] && [ -d "${TMPFS_ROOT}" ]; then
        sudo rmdir "${TMPFS_ROOT}" >/dev/null 2>&1 || true
    fi

    echo "--- Cleanup completed. ---"
}

trap cleanup INT TERM EXIT

main() {
    need_cmds
    collect_inputs
    prepare_tmpfs_layout
    start_rclone_mount
    launch_nemo
}

main "$@"

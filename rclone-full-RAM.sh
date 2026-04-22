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
    for cmd in rclone awk numfmt ps id mountpoint mount grep sed tr printf sudo mkdir chmod chown ss tail nemo mktemp; do
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

start_rclone_mount() {
    if mountpoint -q "${MOUNTPOINT}"; then
        echo "Error: ${MOUNTPOINT} is already mounted." >&2
        exit 1
    fi

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

    echo "--- Press CTRL+C to close Nemo, unmount rclone, stop rclone, and unmount tmpfs ---"
    echo "--- Local mountpoint: ${MOUNTPOINT} ---"
    echo "--- Cache directory: ${CACHE_DIR} ---"
    echo "--- Check tmpfs: findmnt --target ${TMPFS_ROOT} ---"
    echo "--- Check cache usage: du -sh ${CACHE_DIR} && df -h ${TMPFS_ROOT} ---"
    echo "--- Live log: tail -f ${LOGFILE} ---"

    wait "${RCLONE_PID}"
}

cleanup() {
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

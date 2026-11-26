#!/usr/bin/env bash
#
# TCP/IP 网络优化脚本 v3.2
#
# 支持:
#   Debian / Ubuntu / CentOS / AlmaLinux / Rocky Linux
#
# 功能:
#   1. 基于带宽、RTT 和内存计算 TCP 缓冲区
#   2. 检测并启用 BBR + FQ
#   3. 配置 UDP 最小缓冲区
#   4. 可选开启 IPv4/IPv6 转发
#   5. 可选配置 nf_conntrack 容量和超时
#   6. 安全备份配置文件及运行时 sysctl
#   7. 应用失败自动回滚
#   8. 支持逐层恢复
#

set -Eeuo pipefail
umask 077

if (( BASH_VERSINFO[0] < 4 )); then
    printf '[错误] 本脚本需要 Bash 4.0 或更高版本。\n' >&2
    exit 1
fi

# ============================================================
# 基础配置
# ============================================================

SCRIPT_VERSION="3.2"

# 使用独立的 sysctl.d 配置文件。
SYSCTL_FILE="/etc/sysctl.d/99-z-network-optimize.conf"

# v3.1 及更早版本使用的配置文件。
LEGACY_SYSCTL_FILE="/etc/sysctl.d/99-network-optimize.conf"

LIMITS_FILE="/etc/security/limits.d/99-network-optimize.conf"
MODULES_FILE="/etc/modules-load.d/network-optimize.conf"

# 旧版脚本可能生成的 journald 配置。
LEGACY_JOURNALD_FILE="/etc/systemd/journald.conf.d/99-network-optimize.conf"

STATE_DIR="/var/lib/network-optimize"
BACKUP_ROOT="${STATE_DIR}/backups"
CURRENT_FILE="${STATE_DIR}/current"

# ============================================================
# 全局变量
# ============================================================

OS_ID="unknown"
memory_mb=0

profile="unified"
target_bw_mbps=1000
target_rtt_ms=100

# enable_forwarding 仅代表 IPv4 转发。
enable_forwarding=0
enable_ipv6_forwarding=0
enable_conntrack_tuning=0
enable_conntrack_timeout_tuning=0
enable_limits=0

conntrack_available=0
use_bbr=0
use_fq=0

bdp_bytes=0

rmem_max=0
wmem_max=0

tcp_rmem_min=4096
tcp_rmem_mid=0
tcp_wmem_min=4096
tcp_wmem_mid=0

udp_rmem_min=16384
udp_wmem_min=16384

netdev_max_backlog=0
somaxconn=0
tcp_max_syn_backlog=0

# 全局 TCP 内存水位（单位：页）
tcp_mem_low=0
tcp_mem_pressure=0
tcp_mem_high=0
buffer_pages=0
flows_affordable=0
buffer_pct=200
buffer_limited_by_memory=0

# 其它单项参数
tcp_fin_timeout=30
tcp_max_tw_buckets=0
tcp_notsent_lowat=131072
ip_local_port_range="10240 65535"
file_max_target=0

conntrack_max=0
nofile_target=0

ACTIVE_BACKUP=""
TRANSACTION_ACTIVE=0

declare -a PARAM_ORDER=()
declare -A PARAM_VALUES=()
declare -a SKIPPED_KEYS=()
declare -a MODULES_TO_LOAD=()

# 冲突配置文件（含与本脚本重复 sysctl 参数的其他文件）
declare -a CONFLICT_FILES=()
declare -a HARMLESS_FILES=()
declare -A CONFLICT_KEYS=()
declare -A HARMLESS_KEYS=()
REMOVE_CONFLICTS=0

# sysctl --system 的扫描目录（按优先级从高到低）。
# 允许被环境变量覆盖，便于在隔离环境中测试。
SYSCTL_SCAN_DIRS=(
    /etc/sysctl.d
    /run/sysctl.d
    /usr/local/lib/sysctl.d
    /usr/lib/sysctl.d
    /lib/sysctl.d
)
SYSCTL_MAIN_CONF="/etc/sysctl.conf"

# ============================================================
# 颜色与日志
# ============================================================

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
fi

info() {
    printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"
}

warn() {
    printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2
}

error() {
    printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2
}

die() {
    error "$*"

    if [[ $TRANSACTION_ACTIVE -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
        warn "检测到未完成的配置事务，正在自动回滚……"

        TRANSACTION_ACTIVE=0

        set +e
        restore_backup_contents "$ACTIVE_BACKUP" "rollback"
        set -e
    fi

    exit 1
}

# ============================================================
# 异常处理
# ============================================================

on_error() {
    local rc=$1
    local line=$2

    trap - ERR INT TERM

    error "脚本在第 ${line} 行发生错误，退出码: ${rc}"

    if [[ $TRANSACTION_ACTIVE -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
        warn "正在恢复本次修改前的配置……"

        TRANSACTION_ACTIVE=0

        set +e
        restore_backup_contents "$ACTIVE_BACKUP" "rollback"
        set -e

        warn "自动回滚已执行。"
        warn "失败事务备份保留在: $ACTIVE_BACKUP"
    fi

    exit "$rc"
}

on_signal() {
    local rc=$1

    trap - ERR INT TERM

    warn "收到中断信号。"

    if [[ $TRANSACTION_ACTIVE -eq 1 && -n "$ACTIVE_BACKUP" ]]; then
        warn "正在恢复本次修改前的配置……"

        TRANSACTION_ACTIVE=0

        set +e
        restore_backup_contents "$ACTIVE_BACKUP" "rollback"
        set -e
    fi

    exit "$rc"
}

trap 'on_error $? $LINENO' ERR
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# ============================================================
# 通用工具
# ============================================================

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "此脚本必须以 root 权限运行。"
    fi
}

require_commands() {
    local command_name=""
    local missing=0

    for command_name in \
        sysctl mktemp cp mv rm mkdir chmod chown stat \
        date grep tee basename dirname awk cat id
    do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "缺少必要命令: $command_name"
            missing=1
        fi
    done

    if [[ $missing -ne 0 ]]; then
        die "请先安装缺少的基础工具。"
    fi
}

min_value() {
    local a=$1
    local b=$2

    if (( a < b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

round_pow2() {
    local value=${1:-0}
    local min_allowed=${2:-1}
    local max_allowed=${3:-32768}
    local p=1

    if ! is_uint "$value"; then
        printf '%s\n' "$min_allowed"
        return 0
    fi

    while (( p * 2 <= value )); do
        p=$(( p * 2 ))
    done

    # 向上取最近的 2 的幂
    if (( p < value )); then
        p=$(( p * 2 ))
    fi

    if (( p < min_allowed )); then
        p=$min_allowed
    fi

    if (( p > max_allowed )); then
        p=$max_allowed
    fi

    printf '%s\n' "$p"
}

max_value() {
    local a=$1
    local b=$2

    if (( a > b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

is_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

get_sysctl_value() {
    local key=$1
    sysctl -n "$key" 2>/dev/null
}

get_sysctl_uint() {
    local key=$1
    local fallback=$2
    local value=""

    if value=$(get_sysctl_value "$key"); then
        if is_uint "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    printf '%s\n' "$fallback"
}

sysctl_key_exists() {
    local key=$1
    sysctl -n "$key" >/dev/null 2>&1
}

add_param() {
    local key=$1
    local value=$2

    if ! sysctl_key_exists "$key"; then
        SKIPPED_KEYS+=("$key")
        return 0
    fi

    if [[ -n ${PARAM_VALUES[$key]+present} ]]; then
        PARAM_VALUES["$key"]="$value"
        return 0
    fi

    PARAM_ORDER+=("$key")
    PARAM_VALUES["$key"]="$value"
}

add_module_once() {
    local module=$1
    local existing=""

    for existing in "${MODULES_TO_LOAD[@]}"; do
        if [[ "$existing" == "$module" ]]; then
            return 0
        fi
    done

    MODULES_TO_LOAD+=("$module")
}

ask_yes_no() {
    local prompt=$1
    local default_value=$2
    local answer=""

    while true; do
        read -r -p "$prompt" answer || die "无法读取输入。"

        if [[ -z "$answer" ]]; then
            answer=$default_value
        fi

        case "$answer" in
            y|Y|yes|YES|Yes)
                ASK_RESULT=1
                return 0
                ;;
            n|N|no|NO|No)
                ASK_RESULT=0
                return 0
                ;;
            *)
                error "请输入 y 或 n。"
                ;;
        esac
    done
}

read_integer() {
    local prompt=$1
    local default_value=$2
    local min_allowed=$3
    local max_allowed=$4
    local input=""

    while true; do
        read -r -p "$prompt" input || die "无法读取输入。"

        input=${input:-$default_value}

        if ! is_uint "$input"; then
            error "请输入有效的正整数。"
            continue
        fi

        if (( input < min_allowed || input > max_allowed )); then
            error "请输入 ${min_allowed} 到 ${max_allowed} 之间的数值。"
            continue
        fi

        READ_INTEGER_RESULT=$input
        return 0
    done
}

normalize_sysctl_value() {
    local value=${1:-}
    local -a fields=()

    read -r -a fields <<< "$value" || true
    printf '%s' "${fields[*]}"
}

# ============================================================
# 系统检测
# ============================================================

detect_os() {
    local mem_kb=0

    if [[ -r /etc/os-release ]]; then
        OS_ID=$(
            awk -F= '
                $1 == "ID" {
                    gsub(/"/, "", $2)
                    print $2
                    exit
                }
            ' /etc/os-release
        )

        OS_ID=${OS_ID:-unknown}
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
    fi

    if [[ -r /proc/meminfo ]]; then
        mem_kb=$(
            awk '
                /^MemTotal:/ {
                    print $2
                    exit
                }
            ' /proc/meminfo
        )
    fi

    if ! is_uint "${mem_kb:-}" || (( mem_kb <= 0 )); then
        memory_mb=1024
        warn "无法准确读取内存容量，暂按 1024 MB 计算。"
    else
        memory_mb=$((mem_kb / 1024))

        if (( memory_mb <= 0 )); then
            memory_mb=1
        fi
    fi

    info "操作系统: ${OS_ID}"
    info "物理内存: ${memory_mb} MB"
}

# ============================================================
# 安全状态目录
# ============================================================

ensure_secure_state_dir() {
    local path=""
    local owner_uid=""

    for path in "$STATE_DIR" "$BACKUP_ROOT"; do
        if [[ -L "$path" ]]; then
            die "安全检查失败，路径是符号链接: $path"
        fi

        if [[ -e "$path" && ! -d "$path" ]]; then
            die "安全检查失败，路径不是目录: $path"
        fi

        mkdir -p -- "$path"
        chown root:root "$path"
        chmod 0700 "$path"

        owner_uid=$(stat -c '%u' "$path")

        if [[ "$owner_uid" != "0" ]]; then
            die "安全检查失败，目录不属于 root: $path"
        fi
    done

    if [[ -L "$CURRENT_FILE" ]]; then
        die "安全检查失败，current 状态文件不能是符号链接。"
    fi

    if [[ -e "$CURRENT_FILE" && ! -f "$CURRENT_FILE" ]]; then
        die "安全检查失败，current 状态路径不是普通文件。"
    fi
}

# ============================================================
# 配置文件映射
# ============================================================

target_for_id() {
    local id=$1

    case "$id" in
        sysctl-z)
            printf '%s\n' "$SYSCTL_FILE"
            ;;
        sysctl-legacy)
            printf '%s\n' "$LEGACY_SYSCTL_FILE"
            ;;
        # 兼容 v3.1 及更早版本的备份格式。
        sysctl)
            printf '%s\n' "$LEGACY_SYSCTL_FILE"
            ;;
        limits)
            printf '%s\n' "$LIMITS_FILE"
            ;;
        modules)
            printf '%s\n' "$MODULES_FILE"
            ;;
        legacy-journald)
            printf '%s\n' "$LEGACY_JOURNALD_FILE"
            ;;
        *)
            return 1
            ;;
    esac
}

managed_ids() {
    printf '%s\n' \
        "sysctl-z" \
        "sysctl-legacy" \
        "limits" \
        "modules" \
        "legacy-journald"
}

validate_managed_target() {
    local path=$1

    if [[ -L "$path" ]]; then
        die "拒绝修改符号链接配置文件: $path"
    fi

    if [[ -e "$path" && ! -f "$path" ]]; then
        die "配置目标不是普通文件: $path"
    fi
}

get_current_backup_name() {
    local value=""

    if [[ ! -f "$CURRENT_FILE" ]]; then
        return 1
    fi

    value=$(<"$CURRENT_FILE")
    value=${value//$'\n'/}

    if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "current 状态文件内容无效，将忽略。"
        return 1
    fi

    if [[ -L "${BACKUP_ROOT}/${value}" ]]; then
        warn "current 指向了符号链接备份，将忽略。"
        return 1
    fi

    if [[ ! -d "${BACKUP_ROOT}/${value}" ]]; then
        warn "current 指向的备份不存在，将忽略: $value"
        return 1
    fi

    printf '%s\n' "$value"
}

set_current_backup_name() {
    local value=${1:-}
    local temp_file=""

    if [[ -z "$value" ]]; then
        rm -f -- "$CURRENT_FILE"
        return 0
    fi

    if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi

    temp_file=$(mktemp "${STATE_DIR}/.current.XXXXXX")

    printf '%s\n' "$value" > "$temp_file"

    chmod 0600 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$CURRENT_FILE"
}

# ============================================================
# 备份与恢复
# ============================================================

create_backup() {
    local timestamp=""
    local previous=""
    local id=""
    local target=""
    local backup_name=""

    ensure_secure_state_dir

    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    ACTIVE_BACKUP=$(mktemp -d "${BACKUP_ROOT}/${timestamp}.XXXXXX")

    chmod 0700 "$ACTIVE_BACKUP"
    chown root:root "$ACTIVE_BACKUP"

    backup_name=$(basename "$ACTIVE_BACKUP")

    mkdir -p "${ACTIVE_BACKUP}/files"
    chmod 0700 "${ACTIVE_BACKUP}/files"

    if previous=$(get_current_backup_name); then
        printf '%s\n' "$previous" > "${ACTIVE_BACKUP}/previous"
    else
        : > "${ACTIVE_BACKUP}/previous"
    fi

    {
        printf 'version=%s\n' "$SCRIPT_VERSION"
        printf 'date_utc=%s\n' "$timestamp"
        printf 'os=%s\n' "$OS_ID"
        printf 'memory_mb=%s\n' "$memory_mb"
        printf 'profile=%s\n' "$profile"
        printf 'bandwidth_mbps=%s\n' "$target_bw_mbps"
        printf 'rtt_ms=%s\n' "$target_rtt_ms"
        printf 'ipv4_forwarding=%s\n' "$enable_forwarding"
        printf 'ipv6_forwarding=%s\n' "$enable_ipv6_forwarding"
        printf 'conntrack=%s\n' "$enable_conntrack_tuning"
        printf 'conntrack_timeout=%s\n' "$enable_conntrack_timeout_tuning"
        printf 'backup_name=%s\n' "$backup_name"
    } > "${ACTIVE_BACKUP}/metadata"

    : > "${ACTIVE_BACKUP}/manifest"

    while IFS= read -r id; do
        target=$(target_for_id "$id")
        validate_managed_target "$target"

        if [[ -f "$target" ]]; then
            cp -a -- "$target" "${ACTIVE_BACKUP}/files/${id}"
            printf '%s\tpresent\n' "$id" >> "${ACTIVE_BACKUP}/manifest"
        else
            printf '%s\tabsent\n' "$id" >> "${ACTIVE_BACKUP}/manifest"
        fi
    done < <(managed_ids)

    snapshot_runtime_sysctl

    info "本次配置备份已创建: $ACTIVE_BACKUP"
}

snapshot_runtime_sysctl() {
    local key=""
    local value=""
    local snapshot_file="${ACTIVE_BACKUP}/runtime-sysctl.tsv"

    : > "$snapshot_file"
    chmod 0600 "$snapshot_file"

    for key in "${PARAM_ORDER[@]}"; do
        if value=$(get_sysctl_value "$key"); then
            value=${value//$'\n'/ }
            value=${value//$'\t'/ }

            printf '%s\t%s\n' "$key" "$value" >> "$snapshot_file"
        else
            warn "无法保存运行时参数: $key"
        fi
    done
}

restore_managed_files() {
    local backup_dir=$1
    local id=""
    local state=""
    local target=""
    local source_file=""

    if [[ ! -f "${backup_dir}/manifest" ]]; then
        error "备份缺少 manifest: $backup_dir"
        return 1
    fi

    while IFS=$'\t' read -r id state; do
        [[ -n "$id" ]] || continue

        if ! target=$(target_for_id "$id"); then
            error "备份中包含未知配置项目: $id"
            return 1
        fi

        if [[ -L "$target" ]]; then
            error "恢复目标被替换为符号链接，拒绝继续: $target"
            return 1
        fi

        if [[ -e "$target" && ! -f "$target" ]]; then
            error "恢复目标不是普通文件: $target"
            return 1
        fi

        case "$state" in
            present)
                source_file="${backup_dir}/files/${id}"

                if [[ -L "$source_file" || ! -f "$source_file" ]]; then
                    error "备份文件损坏或类型异常: $source_file"
                    return 1
                fi

                mkdir -p "$(dirname "$target")"
                rm -f -- "$target"
                cp -a -- "$source_file" "$target"
                ;;
            absent)
                rm -f -- "$target"
                ;;
            *)
                error "无效的备份状态: $id -> $state"
                return 1
                ;;
        esac
    done < "${backup_dir}/manifest"
}

restore_runtime_sysctl() {
    local backup_dir=$1
    local mode=${2:-restore}
    local snapshot_file="${backup_dir}/runtime-sysctl.tsv"
    local log_file="${backup_dir}/${mode}-runtime.log"
    local key=""
    local value=""
    local failures=0

    if [[ ! -f "$snapshot_file" ]]; then
        warn "备份中不存在运行时 sysctl 快照。"
        return 0
    fi

    : > "$log_file"

    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue

        if [[ ! "$key" =~ ^[A-Za-z0-9_.]+$ ]]; then
            warn "跳过备份中的无效 sysctl 名称: $key"
            failures=$((failures + 1))
            continue
        fi

        if ! sysctl -w "${key}=${value}" >> "$log_file" 2>&1; then
            warn "恢复运行时参数失败: $key"
            failures=$((failures + 1))
        fi
    done < "$snapshot_file"

    if (( failures > 0 )); then
        warn "共有 ${failures} 个运行时参数未能恢复。"
        warn "详细日志: $log_file"
    fi

    return 0
}

restore_backup_contents() {
    local backup_dir=$1
    local mode=${2:-restore}
    local system_log="${backup_dir}/${mode}-sysctl-system.log"

    if [[ -L "$backup_dir" ]]; then
        error "备份目录不能是符号链接: $backup_dir"
        return 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        error "备份目录不存在: $backup_dir"
        return 1
    fi

    info "正在恢复配置文件……"

    if ! restore_managed_files "$backup_dir"; then
        error "配置文件恢复失败。"
        return 1
    fi

    # 还原此前被移除的冲突配置文件。
    restore_conflict_files "$backup_dir" || true

    if ! sysctl --system > "$system_log" 2>&1; then
        warn "执行 sysctl --system 时存在错误。"
        warn "详细日志: $system_log"
    fi

    restore_runtime_sysctl "$backup_dir" "$mode"

    return 0
}

restore_latest_backup() {
    local backup_name=""
    local backup_dir=""
    local previous=""
    local answer=""

    ensure_secure_state_dir

    if ! backup_name=$(get_current_backup_name); then
        die "没有找到可恢复的有效备份。"
    fi

    backup_dir="${BACKUP_ROOT}/${backup_name}"

    printf '\n'
    warn "即将恢复以下备份:"
    printf '  %s\n\n' "$backup_dir"

    read -r -p "确认恢复吗？[y/N]: " answer || die "无法读取输入。"
    answer=${answer:-N}

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "已取消恢复。"
        return 0
    fi

    restore_backup_contents "$backup_dir" "restore"

    if [[ -f "${backup_dir}/previous" ]]; then
        previous=$(<"${backup_dir}/previous")
        previous=${previous//$'\n'/}
    fi

    if [[ -n "$previous" \
        && "$previous" =~ ^[A-Za-z0-9._-]+$ \
        && ! -L "${BACKUP_ROOT}/${previous}" \
        && -d "${BACKUP_ROOT}/${previous}" ]]; then

        set_current_backup_name "$previous"
    else
        set_current_backup_name ""
    fi

    info "配置恢复完成。"

    warn "已经加载的内核模块不会被强制卸载。"
    warn "limits.d 的变化只影响新的登录会话。"
}

# ============================================================
# 内核功能检测
# ============================================================

prepare_kernel_features() {
    local available_cc=""
    local fq_ready=0
    local modprobe_output=""

    use_bbr=0
    use_fq=0
    conntrack_available=0
    MODULES_TO_LOAD=()

    # --------------------------------------------------------
    # 检测 BBR
    # --------------------------------------------------------

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    if available_cc=$(
        get_sysctl_value "net.ipv4.tcp_available_congestion_control"
    ); then
        if grep -qw "bbr" <<< "$available_cc"; then
            use_bbr=1

            if command -v modprobe >/dev/null 2>&1; then
                add_module_once "tcp_bbr"
            fi
        fi
    fi

    if [[ $use_bbr -eq 1 ]]; then
        if command -v modprobe >/dev/null 2>&1; then
            if modprobe sch_fq >/dev/null 2>&1; then
                fq_ready=1
                add_module_once "sch_fq"
            fi
        fi

        if [[ -d /sys/module/sch_fq ]]; then
            fq_ready=1
        fi

        if [[ $fq_ready -eq 1 ]] \
            && sysctl_key_exists "net.core.default_qdisc"; then

            use_fq=1
        else
            warn "内核支持 BBR，但未确认 FQ 队列模块可用。"
            warn "将启用 BBR，但保留当前默认 qdisc。"
        fi
    else
        warn "当前内核未提供 BBR，将保留原有拥塞控制算法。"
    fi

    # --------------------------------------------------------
    # 检测 conntrack
    # --------------------------------------------------------

    if [[ $enable_conntrack_tuning -eq 1 ]]; then
        info "用户已请求启用 nf_conntrack 调优。"

        if ! sysctl_key_exists "net.netfilter.nf_conntrack_max"; then
            if ! command -v modprobe >/dev/null 2>&1; then
                die "系统不存在 modprobe，且 nf_conntrack 尚未加载。"
            fi

            info "正在加载 nf_conntrack 内核模块……"

            if ! modprobe_output=$(modprobe nf_conntrack 2>&1); then
                error "加载 nf_conntrack 失败:"
                printf '%s\n' "$modprobe_output" >&2
                die "用户请求了 conntrack 调优，但模块无法加载。"
            fi
        fi

        if ! sysctl_key_exists "net.netfilter.nf_conntrack_max"; then
            die "nf_conntrack 已尝试加载，但内核未提供 nf_conntrack_max。"
        fi

        conntrack_available=1

        if command -v modprobe >/dev/null 2>&1; then
            add_module_once "nf_conntrack"
        fi

        info "nf_conntrack 已就绪，将写入连接追踪配置。"
    fi
}

# ============================================================
# 参数计算
# ============================================================

calculate_params() {
    local memory_buffer_cap=0
    local mid_rmem_default=0
    local mid_wmem_default=0

    local desired_backlog=0
    local desired_somaxconn=0
    local desired_syn_backlog=0
    local desired_conntrack=0

    local memory_bytes=0
    local memory_socket_cap=0
    local effective_cap=0
    local desired_buffer=0

    local memory_conntrack_cap=0
    local current_conntrack_count=0
    local conntrack_live_min=0

    local nr_open=1048576

    # 1 Mbps × 1 ms = 125 bytes。
    bdp_bytes=$((target_bw_mbps * 125 * target_rtt_ms))
    memory_bytes=$((memory_mb * 1024 * 1024))

    # --------------------------------------------------------
    # 统一策略（单一配置，无档位）
    #
    # 队列参数按内存规模线性伸缩，避免小内存机器被大队列拖垮。
    # 单连接缓冲区目标统一取 2x BDP，再由内存上限收敛。
    # --------------------------------------------------------

    # 按内存线性估算后，统一向上取到 2 的幂。
    # 队列长度取 2 的幂更符合内核/内核态哈希表的习惯，也便于人工核对。
    desired_backlog=$(round_pow2 $(( memory_mb * 8 )) 2048 32768)
    desired_somaxconn=$(round_pow2 $(( memory_mb * 8 )) 4096 32768)
    desired_syn_backlog=$(round_pow2 $(( memory_mb * 8 )) 4096 32768)

    desired_conntrack=262144
    nofile_target=262144

    memory_buffer_cap=$(( memory_bytes / 8 ))
    mid_rmem_default=262144
    mid_wmem_default=65536

    # 单个 socket 的最大缓冲区预算约为物理内存的 1/16。
    memory_socket_cap=$((memory_bytes / 16))

    if (( memory_socket_cap < 8 * 1024 * 1024 )); then
        memory_socket_cap=$((8 * 1024 * 1024))
    fi

    effective_cap=$(
        min_value "$memory_buffer_cap" "$memory_socket_cap"
    )

    # --------------------------------------------------------
    # 单连接缓冲区
    #
    # 首选 2x BDP（留一倍余量，能跑满单流）。
    # 若内存吃不下，退化到 1x BDP，换更多并发数。
    # --------------------------------------------------------

    # 首选 2x BDP（留一倍余量，能跑满单流）。
    # 若内存吃不下，退化到 1.5x BDP，在并发数与单流吞吐间取平衡。
    # 最后仍受内存预算硬性收敛。
    buffer_pct=200
    desired_buffer=$(( bdp_bytes * buffer_pct / 100 ))

    buffer_limited_by_memory=0

    if (( desired_buffer > effective_cap )); then
        # 2x BDP 超出内存预算，退到 1.5x BDP。
        buffer_pct=150
        desired_buffer=$(( bdp_bytes * buffer_pct / 100 ))
        buffer_limited_by_memory=1
    fi

    # 最低为 8 MiB。
    if (( desired_buffer < 8 * 1024 * 1024 )); then
        desired_buffer=$((8 * 1024 * 1024))
    fi

    # 最终仍不得超出内存预算。
    if (( desired_buffer > effective_cap )); then
        desired_buffer=$effective_cap
    fi

    # --------------------------------------------------------
    # TCP 缓冲区
    #
    # 完全使用本次计算结果，不继承旧脚本留下的值。
    # --------------------------------------------------------

    tcp_rmem_min=4096
    tcp_wmem_min=4096

    rmem_max=$desired_buffer
    wmem_max=$desired_buffer

    tcp_rmem_mid=$mid_rmem_default
    tcp_wmem_mid=$mid_wmem_default

    if (( tcp_rmem_mid > rmem_max )); then
        tcp_rmem_mid=$rmem_max
    fi

    if (( tcp_wmem_mid > wmem_max )); then
        tcp_wmem_mid=$wmem_max
    fi

    # --------------------------------------------------------
    # 全局 TCP 内存（tcp_mem）
    #
    # 单位是页。经验规则：
    #   单连接页数 = 单连接上限 / 页大小
    #   high      = 单连接页数 × 预期并发大流数 × 1.2
    #   pressure  = high × 0.75
    #   low       = high × 0.625
    # 同时不允许超过物理内存的 25%。
    # --------------------------------------------------------

    local page_size=4096
    if command -v getconf >/dev/null 2>&1; then
        page_size=$(getconf PAGESIZE 2>/dev/null || printf '4096')
    fi
    is_uint "$page_size" || page_size=4096

    buffer_pages=$(( rmem_max / page_size ))

    # 预期并发大流数：按内存规模估算，1 GB 约 8 条，8 GB 约 64 条。
    flows_affordable=$(( memory_mb / 128 ))
    flows_affordable=$(max_value "$flows_affordable" 8)
    flows_affordable=$(min_value "$flows_affordable" 64)

    tcp_mem_high=$(( buffer_pages * flows_affordable * 12 / 10 ))

    # 上限：物理内存的 25%，换算成页。
    local memory_pages=0
    memory_pages=$(( memory_bytes / page_size ))
    local tcp_mem_cap=0
    tcp_mem_cap=$(( memory_pages / 4 ))

    if (( tcp_mem_high > tcp_mem_cap )); then
        tcp_mem_high=$tcp_mem_cap
    fi

    # 下限：内核默认值的量级，避免设得过小导致自动调优被压制。
    local tcp_mem_floor=0
    tcp_mem_floor=$(( memory_pages * 3 / 32 ))

    if (( tcp_mem_high < tcp_mem_floor )); then
        tcp_mem_high=$tcp_mem_floor
    fi

    if (( tcp_mem_high < 16384 )); then
        tcp_mem_high=16384
    fi

    tcp_mem_pressure=$(( tcp_mem_high * 3 / 4 ))
    tcp_mem_low=$(( tcp_mem_high * 5 / 8 ))

    # 按最终生效的 tcp_mem 反算真实可支撑的大流数。
    # （pressure 是实际天花板，high 只是硬上限）
    if (( buffer_pages > 0 )); then
        flows_affordable=$(( tcp_mem_pressure / buffer_pages ))

        if (( flows_affordable < 1 )); then
            flows_affordable=1
        fi
    fi

    # --------------------------------------------------------
    # 队列参数
    #
    # 统一策略，不继承旧脚本的激进参数。
    # --------------------------------------------------------

    netdev_max_backlog=$desired_backlog
    somaxconn=$desired_somaxconn
    tcp_max_syn_backlog=$desired_syn_backlog

    # UDP 最小缓冲区。
    udp_rmem_min=16384
    udp_wmem_min=16384

    # --------------------------------------------------------
    # Conntrack 容量
    # --------------------------------------------------------

    if [[ $conntrack_available -eq 1 ]]; then
        # 按每个潜在 conntrack 条目预留约 16 KiB 总内存预算。
        memory_conntrack_cap=$((memory_bytes / 16384))

        if (( memory_conntrack_cap < 32768 )); then
            memory_conntrack_cap=32768
        fi

        conntrack_max=$(
            min_value "$desired_conntrack" "$memory_conntrack_cap"
        )

        current_conntrack_count=$(
            get_sysctl_uint "net.netfilter.nf_conntrack_count" 0
        )

        # 至少保留当前使用量的 25% 余量，并额外保留 1024 个条目。
        conntrack_live_min=$(( current_conntrack_count * 5 / 4 + 1024 ))

        if (( conntrack_live_min < 32768 )); then
            conntrack_live_min=32768
        fi

        if (( conntrack_max < conntrack_live_min )); then
            conntrack_max=$conntrack_live_min

            warn "Conntrack 当前使用量较高。"
            warn "为避免容量低于当前使用量，上限调整为 ${conntrack_max}。"
        fi
    fi

    # --------------------------------------------------------
    # 文件句柄
    # --------------------------------------------------------

    if sysctl_key_exists "fs.nr_open"; then
        nr_open=$(get_sysctl_uint "fs.nr_open" 1048576)
    fi

    if (( nofile_target > nr_open )); then
        nofile_target=$nr_open
    fi

    # --------------------------------------------------------
    # TIME_WAIT 桶上限
    # --------------------------------------------------------

    tcp_max_tw_buckets=$(( memory_mb * 64 ))
    tcp_max_tw_buckets=$(max_value "$tcp_max_tw_buckets" 65536)
    tcp_max_tw_buckets=$(min_value "$tcp_max_tw_buckets" 1048576)

    # --------------------------------------------------------
    # fs.file-max
    #
    # 现代内核默认即为「无上限」。仅当当前值更小、且确实是个
    # 有限的低值时，才抬到按内存估算的目标值；否则不动。
    # --------------------------------------------------------

    file_max_target=0

    if sysctl_key_exists "fs.file-max"; then
        local current_file_max=0

        current_file_max=$(
            get_sysctl_uint "fs.file-max" 0
        )

        # 目标值：按 nofile 目标乘以余量，再设一个下限。
        local desired_file_max=0
        desired_file_max=$(( nofile_target * 4 ))
        desired_file_max=$(max_value "$desired_file_max" 1048576)

        # 当前值已是天文数字（>= 2^31）时，视为无上限，跳过。
        if (( current_file_max > 0 && current_file_max < 2147483648 )); then
            if (( current_file_max < desired_file_max )); then
                file_max_target=$desired_file_max
            fi
        fi
    fi
}

# ============================================================
# 构造 sysctl 参数
# ============================================================

build_sysctl_params() {
    PARAM_ORDER=()
    PARAM_VALUES=()
    SKIPPED_KEYS=()

    # 网络核心缓冲区。
    add_param "net.core.rmem_max" "$rmem_max"
    add_param "net.core.wmem_max" "$wmem_max"
    add_param "net.core.netdev_max_backlog" "$netdev_max_backlog"
    add_param "net.core.somaxconn" "$somaxconn"

    # TCP 缓冲区。
    add_param \
        "net.ipv4.tcp_rmem" \
        "${tcp_rmem_min} ${tcp_rmem_mid} ${rmem_max}"

    add_param \
        "net.ipv4.tcp_wmem" \
        "${tcp_wmem_min} ${tcp_wmem_mid} ${wmem_max}"

    add_param \
        "net.ipv4.tcp_max_syn_backlog" \
        "$tcp_max_syn_backlog"

    add_param "net.ipv4.tcp_mtu_probing" "1"
    add_param "net.ipv4.tcp_window_scaling" "1"
    add_param "net.ipv4.tcp_moderate_rcvbuf" "1"

    # TCP Fast Open（客户端 + 服务端）。
    add_param "net.ipv4.tcp_fastopen" "3"

    # 全局 TCP 内存水位（单位：页）。
    add_param \
        "net.ipv4.tcp_mem" \
        "${tcp_mem_low} ${tcp_mem_pressure} ${tcp_mem_high}"

    # 长连接：空闲后不重置拥塞窗口。
    add_param "net.ipv4.tcp_slow_start_after_idle" "0"

    # TIME_WAIT / 端口复用。
    add_param "net.ipv4.tcp_timestamps" "1"
    add_param "net.ipv4.tcp_tw_reuse" "1"
    add_param "net.ipv4.tcp_fin_timeout" "$tcp_fin_timeout"
    add_param "net.ipv4.tcp_max_tw_buckets" "$tcp_max_tw_buckets"
    add_param "net.ipv4.ip_local_port_range" "$ip_local_port_range"

    # 低延迟发送：减少发送侧排队。
    add_param "net.ipv4.tcp_notsent_lowat" "$tcp_notsent_lowat"

    # 队列溢出保持默认行为，避免把「慢」变成「断」。
    add_param "net.ipv4.tcp_abort_on_overflow" "0"

    # SYN 洪水保护。
    add_param "net.ipv4.tcp_syncookies" "1"

    # 文件句柄总量上限（仅当当前值更小、且系统确实支持时抬高）。
    if [[ $file_max_target -gt 0 ]]; then
        add_param "fs.file-max" "$file_max_target"
    fi

    # UDP 最小缓冲区。
    add_param "net.ipv4.udp_rmem_min" "$udp_rmem_min"
    add_param "net.ipv4.udp_wmem_min" "$udp_wmem_min"

    # IPv4 转发。
    if [[ $enable_forwarding -eq 1 ]]; then
        add_param "net.ipv4.ip_forward" "1"
    fi

    # IPv6 转发。
    if [[ $enable_ipv6_forwarding -eq 1 ]]; then
        add_param "net.ipv6.conf.all.forwarding" "1"
        add_param "net.ipv6.conf.default.forwarding" "1"
    fi

    # Conntrack。
    if [[ $conntrack_available -eq 1 ]]; then
        add_param \
            "net.netfilter.nf_conntrack_max" \
            "$conntrack_max"

        if [[ $enable_conntrack_timeout_tuning -eq 1 ]]; then
            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_established" \
                "7200"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_time_wait" \
                "120"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_close_wait" \
                "60"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_fin_wait" \
                "120"

            add_param \
                "net.netfilter.nf_conntrack_tcp_timeout_syn_recv" \
                "60"

            add_param \
                "net.netfilter.nf_conntrack_udp_timeout" \
                "30"

            add_param \
                "net.netfilter.nf_conntrack_udp_timeout_stream" \
                "120"
        fi
    fi

    # BBR 和 FQ。
    if [[ $use_bbr -eq 1 ]]; then
        add_param \
            "net.ipv4.tcp_congestion_control" \
            "bbr"
    fi

    if [[ $use_fq -eq 1 ]]; then
        add_param "net.core.default_qdisc" "fq"
    fi
}

# ============================================================
# 检查重复配置
# ============================================================

# ------------------------------------------------------------
# sysctl --system 的真实加载顺序
#
# 规则（man sysctl，SYSTEM FILE PRECEDENCE）：
#   1. 按目录优先级扫描：
#      /etc/sysctl.d -> /run/sysctl.d -> /usr/local/lib/sysctl.d
#      -> /usr/lib/sysctl.d -> /lib/sysctl.d
#   2. 同名文件只在优先级最高的目录生效一次，后续目录中的同名文件被忽略。
#   3. 实际生效的文件再按文件名全局字典序排序。
#   4. /etc/sysctl.conf 最后加载。
#
# 结论：只有"文件名排在脚本文件之后"的文件才会覆盖脚本参数。
# ------------------------------------------------------------

sysctl_effective_files() {
    local dir=""
    local file=""
    local base=""
    local -A loaded=()

    for dir in "${SYSCTL_SCAN_DIRS[@]}"
    do
        [[ -d "$dir" ]] || continue

        for file in "$dir"/*.conf; do
            [[ -f "$file" ]] || continue
            [[ -L "$file" ]] && continue

            base=$(basename "$file")
            [[ -n ${loaded[$base]+x} ]] && continue

            loaded["$base"]=1
            printf '%s\n' "$file"
        done
    done

    if [[ -f "$SYSCTL_MAIN_CONF" && ! -L "$SYSCTL_MAIN_CONF" ]]; then
        printf '%s\n' "$SYSCTL_MAIN_CONF"
    fi
}

collect_sysctl_conflicts() {
    CONFLICT_FILES=()
    HARMLESS_FILES=()
    CONFLICT_KEYS=()
    HARMLESS_KEYS=()

    local LC_COLLATE=C

    local key=""
    local escaped_key=""
    local file=""
    local base=""
    local our_base=""
    local matched=""

    our_base=$(basename "$SYSCTL_FILE")

    while IFS= read -r file; do
        [[ "$file" == "$SYSCTL_FILE" ]] && continue
        [[ "$file" == "$LEGACY_SYSCTL_FILE" ]] && continue

        matched=""

        for key in "${PARAM_ORDER[@]}"; do
            escaped_key=${key//./\\.}

            if grep -Eq \
                "^[[:space:]]*${escaped_key}[[:space:]]*=" \
                "$file" 2>/dev/null; then

                matched+="${key} "
            fi
        done

        [[ -n "$matched" ]] || continue

        # /etc/sysctl.conf 永远最后加载，必然覆盖。
        if [[ "$file" == "/etc/sysctl.conf" ]]; then
            CONFLICT_FILES+=("$file")
            CONFLICT_KEYS["$file"]="$matched"
            continue
        fi

        base=$(basename "$file")

        if [[ "$base" > "$our_base" ]]; then
            CONFLICT_FILES+=("$file")
            CONFLICT_KEYS["$file"]="$matched"
        else
            HARMLESS_FILES+=("$file")
            HARMLESS_KEYS["$file"]="$matched"
        fi
    done < <(sysctl_effective_files)
}

file_owner_hint() {
    local file=$1
    local owner=""

    if command -v dpkg >/dev/null 2>&1; then
        owner=$(dpkg -S "$file" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
    fi

    printf '%s\n' "$owner"
}

prompt_remove_conflicts() {
    REMOVE_CONFLICTS=0

    local file=""
    local owner=""

    if (( ${#CONFLICT_FILES[@]} == 0 && ${#HARMLESS_FILES[@]} == 0 )); then
        info "未发现与本次参数重复的其他 sysctl 配置文件。"
        return 0
    fi

    # 先列出无害文件，说明为什么不动它们。
    if (( ${#HARMLESS_FILES[@]} > 0 )); then
        printf '\n'
        info "以下 ${#HARMLESS_FILES[@]} 个文件含同名参数，但加载顺序早于本脚本，不会覆盖："

        for file in "${HARMLESS_FILES[@]}"; do
            printf '  [保留] %s\n' "$file"
            printf '         参数: %s\n' "${HARMLESS_KEYS[$file]}"
        done
    fi

    if (( ${#CONFLICT_FILES[@]} == 0 )); then
        printf '\n'
        info "没有需要处理的冲突文件。"
        return 0
    fi

    printf '\n'
    warn "检测到 ${#CONFLICT_FILES[@]} 个文件会覆盖本脚本参数（加载顺序更晚）："
    printf '\n'

    for file in "${CONFLICT_FILES[@]}"; do
        printf '  %s\n' "$file"
        printf '      冲突参数: %s\n' "${CONFLICT_KEYS[$file]}"

        owner=$(file_owner_hint "$file")

        if [[ -n "$owner" ]]; then
            printf '      所属软件包: %s\n' "$owner"
        fi
    done

    printf '\n'
    warn "sysctl --system 按文件名全局字典序加载，/etc/sysctl.conf 最后加载，"
    warn "文件名排在 $(basename "$SYSCTL_FILE") 之后的文件会覆盖脚本参数。"
    printf '\n'
    warn "处理方式："
    warn "  · 文件里只有冲突参数  -> 整个文件移除"
    warn "  · 还含其他无关配置    -> 只注释掉冲突行，其余原样保留"
    warn "处理前会完整备份原文件，可用“恢复最近一次配置”还原。"

    ask_yes_no \
        "是否处理以上冲突文件，使脚本生成的配置成为唯一来源？[y/N]: " \
        "N"

    if [[ $ASK_RESULT -eq 1 ]]; then
        REMOVE_CONFLICTS=1
    else
        warn "已保留冲突文件，脚本参数可能在重启后被覆盖。"
    fi
}
# 判断冲突文件的处理方式：
#   delete —— 文件里除冲突参数外没有别的设置，可整体移除。
#   strip  —— 文件还含有其他配置，只注释掉冲突行，保留其余内容。
conflict_file_mode() {
    local file=$1
    local line=""
    local key=""
    local total=0
    local conflicting=0
    local -a keys=()
    local -A is_conflict=()

    read -r -a keys <<< "${CONFLICT_KEYS[$file]}"

    for key in "${keys[@]}"; do
        is_conflict["$key"]=1
    done

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*= ]] || continue

        key=${BASH_REMATCH[1]}
        total=$(( total + 1 ))

        if [[ -n ${is_conflict[$key]+x} ]]; then
            conflicting=$(( conflicting + 1 ))
        fi
    done < "$file"

    if (( total > 0 && total == conflicting )); then
        printf 'delete\n'
    else
        printf 'strip\n'
    fi
}

strip_conflict_lines() {
    local file=$1
    local tmp=""
    local line=""
    local key=""
    local stamp=""
    local -a keys=()
    local -A is_conflict=()

    read -r -a keys <<< "${CONFLICT_KEYS[$file]}"

    for key in "${keys[@]}"; do
        is_conflict["$key"]=1
    done

    tmp=$(mktemp "${file}.XXXXXX") || return 1
    stamp=$(date -u '+%Y-%m-%d')

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*= ]]; then
            key=${BASH_REMATCH[1]}

            if [[ -n ${is_conflict[$key]+x} ]]; then
                printf '# [network-optimize %s] %s\n' "$stamp" "$line" >> "$tmp"
                continue
            fi
        fi

        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    chmod --reference="$file" "$tmp" 2>/dev/null || true
    chown --reference="$file" "$tmp" 2>/dev/null || true

    if ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

backup_conflict_files() {
    (( REMOVE_CONFLICTS == 1 )) || return 0
    (( ${#CONFLICT_FILES[@]} > 0 )) || return 0

    local dir="${ACTIVE_BACKUP}/conflict-files"
    local map="${ACTIVE_BACKUP}/conflicts.tsv"
    local index=0
    local file=""
    local name=""
    local mode=""

    mkdir -p "$dir"
    chmod 0700 "$dir"

    : > "$map"
    chmod 0600 "$map"

    for file in "${CONFLICT_FILES[@]}"; do
        if [[ -L "$file" || ! -f "$file" ]]; then
            warn "跳过备份（类型异常）: $file"
            continue
        fi

        index=$(( index + 1 ))
        name=$(printf '%04d' "$index")
        mode=$(conflict_file_mode "$file")

        if ! cp -a -- "$file" "${dir}/${name}"; then
            warn "备份失败，跳过该文件: $file"
            index=$(( index - 1 ))
            continue
        fi

        printf '%s\t%s\t%s\n' "$name" "$file" "$mode" >> "$map"
    done
}

remove_conflict_files() {
    (( REMOVE_CONFLICTS == 1 )) || return 0

    local map="${ACTIVE_BACKUP}/conflicts.tsv"
    local file=""
    local name=""
    local mode=""

    [[ -f "$map" ]] || return 0

    while IFS=$'\t' read -r name file mode; do
        [[ -n "$file" ]] || continue

        if [[ -L "$file" || ! -f "$file" ]]; then
            warn "跳过（类型异常或已不存在）: $file"
            continue
        fi

        case "$mode" in
            delete)
                if rm -f -- "$file"; then
                    info "已移除冲突文件（仅含冲突参数）: $file"
                else
                    warn "移除失败: $file"
                fi
                ;;
            strip)
                if strip_conflict_lines "$file"; then
                    info "已注释冲突行，保留其余配置: $file"
                else
                    warn "注释失败: $file"
                fi
                ;;
            *)
                warn "未知处理方式，跳过: $file（$mode）"
                ;;
        esac
    done < "$map"
}

restore_conflict_files() {
    local backup_dir=$1
    local map="${backup_dir}/conflicts.tsv"
    local dir="${backup_dir}/conflict-files"
    local name=""
    local path=""
    local mode=""

    [[ -f "$map" ]] || return 0

    while IFS=$'\t' read -r name path mode; do
        [[ -n "$name" && -n "$path" ]] || continue

        if [[ -L "$path" ]]; then
            warn "拒绝还原到符号链接: $path"
            continue
        fi

        if [[ ! -f "$dir/$name" ]]; then
            warn "备份文件缺失，无法还原: $path"
            continue
        fi

        case "$mode" in
            strip)
                if cp -a -- "$dir/$name" "$path"; then
                    info "已还原被注释的冲突行: $path"
                else
                    warn "还原失败: $path"
                fi
                ;;
            *)
                if [[ -e "$path" ]]; then
                    cp -a -- "$dir/$name" "${path}.restored"
                    warn "目标已存在，冲突文件还原为: ${path}.restored"
                else
                    mkdir -p "$(dirname "$path")"
                    cp -a -- "$dir/$name" "$path"
                    info "已还原冲突文件: $path"
                fi
                ;;
        esac
    done < "$map"

    return 0
}

# ============================================================
# 原子写入配置
# ============================================================

write_sysctl_file() {
    local temp_file=""
    local key=""

    validate_managed_target "$SYSCTL_FILE"

    mkdir -p "$(dirname "$SYSCTL_FILE")"
    temp_file=$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")

    {
        printf '# TCP/IP network optimization\n'
        printf '# Generated by network optimize script v%s\n' \
            "$SCRIPT_VERSION"
        printf '# Policy: unified (single profile)\n'
        printf '# Bandwidth: %s Mbps\n' "$target_bw_mbps"
        printf '# RTT: %s ms\n' "$target_rtt_ms"
        printf '# BDP: %s bytes\n' "$bdp_bytes"
        printf '\n'

        for key in "${PARAM_ORDER[@]}"; do
            printf '%s = %s\n' "$key" "${PARAM_VALUES[$key]}"
        done
    } > "$temp_file"

    chmod 0644 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$SYSCTL_FILE"
}

remove_legacy_sysctl_file() {
    validate_managed_target "$LEGACY_SYSCTL_FILE"

    if [[ -f "$LEGACY_SYSCTL_FILE" ]]; then
        rm -f -- "$LEGACY_SYSCTL_FILE"
        info "已迁移并移除旧版 sysctl 配置文件。"
    fi
}

write_limits_file() {
    local temp_file=""

    validate_managed_target "$LIMITS_FILE"

    mkdir -p "$(dirname "$LIMITS_FILE")"

    if [[ $enable_limits -ne 1 ]]; then
        rm -f -- "$LIMITS_FILE"
        return 0
    fi

    temp_file=$(mktemp "${LIMITS_FILE}.tmp.XXXXXX")

    cat > "$temp_file" <<EOF
# Generated by network optimize script v${SCRIPT_VERSION}
#
# 主要影响新的 PAM 登录会话。
# systemd 服务请在服务单元中设置 LimitNOFILE。

*    soft    nofile    ${nofile_target}
*    hard    nofile    ${nofile_target}
root soft    nofile    ${nofile_target}
root hard    nofile    ${nofile_target}
EOF

    chmod 0644 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$LIMITS_FILE"
}

write_modules_file() {
    local temp_file=""
    local module=""

    validate_managed_target "$MODULES_FILE"

    mkdir -p "$(dirname "$MODULES_FILE")"
    temp_file=$(mktemp "${MODULES_FILE}.tmp.XXXXXX")

    {
        printf '# Generated by network optimize script v%s\n' \
            "$SCRIPT_VERSION"

        for module in "${MODULES_TO_LOAD[@]}"; do
            printf '%s\n' "$module"
        done
    } > "$temp_file"

    chmod 0644 "$temp_file"
    chown root:root "$temp_file"

    mv -f -- "$temp_file" "$MODULES_FILE"
}

remove_legacy_journald_file() {
    validate_managed_target "$LEGACY_JOURNALD_FILE"

    if [[ -f "$LEGACY_JOURNALD_FILE" ]]; then
        rm -f -- "$LEGACY_JOURNALD_FILE"
        info "已移除旧版脚本生成的 journald 配置。"
    fi
}

# ============================================================
# 应用与验证
# ============================================================

apply_sysctl_file() {
    local output=""
    local rc=0
    local log_file="${ACTIVE_BACKUP}/apply.log"

    info "正在应用网络参数……"

    if output=$(sysctl -p "$SYSCTL_FILE" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    printf '%s\n' "$output" | tee "$log_file"

    if (( rc != 0 )); then
        error "sysctl 配置应用失败，准备自动回滚。"
        return "$rc"
    fi

    info "sysctl 配置应用成功。"
}

verify_param() {
    local key=$1
    local expected=$2

    local actual=""
    local expected_normalized=""
    local actual_normalized=""

    if ! actual=$(get_sysctl_value "$key"); then
        printf '  %-48s %s无法读取%s\n' \
            "$key" "$RED" "$NC"
        return 0
    fi

    expected_normalized=$(normalize_sysctl_value "$expected")
    actual_normalized=$(normalize_sysctl_value "$actual")

    if [[ "$actual_normalized" == "$expected_normalized" ]]; then
        printf '  %-48s %sOK%s\n' \
            "$key" "$GREEN" "$NC"
    else
        printf '  %-48s %s不一致%s\n' \
            "$key" "$YELLOW" "$NC"

        printf '    期望: %s\n' "$expected"
        printf '    实际: %s\n' "$actual"
    fi
}

verify_applied_config() {
    local key=""

    printf '\n'
    printf '%s================ 应用验证 ================%s\n' \
        "$BLUE" "$NC"

    for key in "${PARAM_ORDER[@]}"; do
        verify_param "$key" "${PARAM_VALUES[$key]}"
    done

    printf '%s==========================================%s\n' \
        "$BLUE" "$NC"
}

# ============================================================
# 配置摘要
# ============================================================

show_summary() {
    local actual_cc="unknown"
    local actual_qdisc="unknown"
    local actual_ipv4_forwarding="unknown"
    local actual_ipv6_forwarding="unknown"

    actual_cc=$(
        get_sysctl_value "net.ipv4.tcp_congestion_control" \
            || printf 'unknown'
    )

    actual_qdisc=$(
        get_sysctl_value "net.core.default_qdisc" \
            || printf 'unknown'
    )

    actual_ipv4_forwarding=$(
        get_sysctl_value "net.ipv4.ip_forward" \
            || printf 'unknown'
    )

    actual_ipv6_forwarding=$(
        get_sysctl_value "net.ipv6.conf.all.forwarding" \
            || printf 'unknown'
    )

    printf '\n'
    printf '%s================ 配置摘要 ================%s\n' \
        "$GREEN" "$NC"

    printf '优化策略       : 统一配置（%s）\n' "$profile"
    printf '目标带宽       : %s Mbps\n' "$target_bw_mbps"
    printf '目标 RTT       : %s ms\n' "$target_rtt_ms"
    printf '目标 BDP       : %s bytes\n' "$bdp_bytes"
    printf '系统内存       : %s MB\n' "$memory_mb"

    printf '最大接收缓冲   : %s bytes\n' "$rmem_max"
    printf '最大发送缓冲   : %s bytes\n' "$wmem_max"

    printf 'TCP 接收中间值 : %s bytes\n' "$tcp_rmem_mid"
    printf 'TCP 发送中间值 : %s bytes\n' "$tcp_wmem_mid"

    printf 'UDP 接收最小值 : %s bytes\n' "$udp_rmem_min"
    printf 'UDP 发送最小值 : %s bytes\n' "$udp_wmem_min"

    printf 'netdev backlog : %s\n' "$netdev_max_backlog"
    printf 'somaxconn      : %s\n' "$somaxconn"
    printf 'SYN backlog    : %s\n' "$tcp_max_syn_backlog"

    printf 'TCP 全局内存   : %s %s %s 页\n' \
        "$tcp_mem_low" "$tcp_mem_pressure" "$tcp_mem_high"

    printf '单连接页数     : %s 页\n' "$buffer_pages"
    printf '可支撑大流数   : 约 %s 条\n' "$flows_affordable"

    if [[ $buffer_limited_by_memory -eq 1 ]]; then
        printf '缓冲区倍率     : 1.5x BDP（内存受限，已从 2x 降级）\n'
    else
        printf '缓冲区倍率     : 2x BDP\n'
    fi

    printf 'TIME_WAIT 上限 : %s\n' "$tcp_max_tw_buckets"
    printf 'fin_timeout    : %s 秒\n' "$tcp_fin_timeout"
    printf '本地端口范围   : %s\n' "$ip_local_port_range"
    printf 'notsent_lowat  : %s\n' "$tcp_notsent_lowat"

    if [[ $file_max_target -gt 0 ]]; then
        printf 'fs.file-max    : %s（本次抬高）\n' "$file_max_target"
    else
        printf 'fs.file-max    : 本次未修改（当前值已足够）\n'
    fi

    printf '拥塞控制       : %s\n' "$actual_cc"
    printf '默认 qdisc     : %s\n' "$actual_qdisc"

    if [[ $enable_forwarding -eq 1 ]]; then
        printf 'IPv4 转发      : 已开启\n'
    else
        printf 'IPv4 转发      : 本次未修改，当前值 %s\n' \
            "$actual_ipv4_forwarding"
    fi

    if [[ $enable_ipv6_forwarding -eq 1 ]]; then
        printf 'IPv6 转发      : 已开启\n'
    else
        printf 'IPv6 转发      : 本次未修改，当前值 %s\n' \
            "$actual_ipv6_forwarding"
    fi

    if [[ $conntrack_available -eq 1 ]]; then
        printf 'Conntrack 状态 : 已调优\n'
        printf 'Conntrack 上限 : %s\n' "$conntrack_max"

        if [[ $enable_conntrack_timeout_tuning -eq 1 ]]; then
            printf 'Conntrack 超时 : 已启用高周转配置\n'
            printf '  established  : 7200 秒\n'
            printf '  time_wait    : 120 秒\n'
            printf '  close_wait   : 60 秒\n'
            printf '  fin_wait     : 120 秒\n'
            printf '  syn_recv     : 60 秒\n'
            printf '  UDP          : 30 秒\n'
            printf '  UDP stream   : 120 秒\n'
        else
            printf 'Conntrack 超时 : 本次未修改\n'
        fi
    else
        printf 'Conntrack 调优 : 本次未启用\n'
    fi

    if [[ $enable_limits -eq 1 ]]; then
        printf '登录会话 nofile: %s\n' "$nofile_target"
    else
        printf '登录会话 limits: 未配置\n'
    fi

    printf 'sysctl 文件    : %s\n' "$SYSCTL_FILE"

    if (( REMOVE_CONFLICTS == 1 && ${#CONFLICT_FILES[@]} > 0 )); then
        printf '冲突文件处理   : %s 个（已备份）\n' "${#CONFLICT_FILES[@]}"
    elif (( ${#CONFLICT_FILES[@]} > 0 )); then
        printf '冲突文件处理   : 未处理（%s 个仍会覆盖）\n' "${#CONFLICT_FILES[@]}"
    else
        printf '冲突文件处理   : 无需处理\n'
    fi

    printf '配置备份       : %s\n' "$ACTIVE_BACKUP"

    printf '%s==========================================%s\n' \
        "$GREEN" "$NC"

    if (( ${#SKIPPED_KEYS[@]} > 0 )); then
        printf '\n'
        warn "以下内核参数不存在，因此已跳过:"
        printf '  - %s\n' "${SKIPPED_KEYS[@]}"
    fi

    if [[ $enable_limits -eq 1 ]]; then
        printf '\n'
        warn "limits.d 仅影响新的 PAM 登录会话和部分应用。"
        warn "systemd 服务应单独配置 LimitNOFILE。"
    fi
}

# ============================================================
# 用户配置
# ============================================================

collect_user_options() {
    local ASK_RESULT=0
    local READ_INTEGER_RESULT=0

    printf '\n'

    ask_yes_no \
        "是否开启 IPv4 转发？仅路由器或 NAT 网关需要 [y/N]: " \
        "N"

    enable_forwarding=$ASK_RESULT

    ask_yes_no \
        "是否开启 IPv6 转发？可能影响 RA/SLAAC 获取默认路由 [y/N]: " \
        "N"

    enable_ipv6_forwarding=$ASK_RESULT

    # --------------------------------------------------------
    # 检测本机是否已在做 IP 转发（NAT 网关 / 中转节点）
    #
    # 这类节点的 conntrack 表压力远高于普通主机，
    # 一旦表打满，新连接会被直接丢弃（表现为"时好时坏"）。
    # 因此检测到转发已开启时，主动提示并把默认值改为 y。
    # --------------------------------------------------------

    local forwarding_active=0
    local current_ipv4_forward=0
    local current_ipv6_forward=0
    local conntrack_prompt=""
    local conntrack_default="N"
    local conntrack_timeout_prompt=""
    local conntrack_timeout_default="N"

    current_ipv4_forward=$(
        get_sysctl_uint "net.ipv4.ip_forward" 0
    )

    current_ipv6_forward=$(
        get_sysctl_uint "net.ipv6.conf.all.forwarding" 0
    )

    if (( current_ipv4_forward == 1 || current_ipv6_forward == 1 )); then
        forwarding_active=1
    fi

    if (( enable_forwarding == 1 || enable_ipv6_forwarding == 1 )); then
        forwarding_active=1
    fi

    conntrack_prompt="是否调优 nf_conntrack？仅 NAT/状态防火墙节点建议开启 [y/N]: "
    conntrack_timeout_prompt="是否缩短 conntrack 空闲连接超时？高连接周转节点可开启 [y/N]: "

    if (( forwarding_active == 1 )); then
        conntrack_default="y"
        conntrack_timeout_default="y"

        conntrack_prompt="是否调优 nf_conntrack？检测到 IP 转发已开启，建议开启 [Y/n]: "
        conntrack_timeout_prompt="是否缩短 conntrack 空闲连接超时？检测到转发，建议开启 [Y/n]: "

        printf '\n'
        info "检测到本机 IP 转发已开启（IPv4=${current_ipv4_forward} IPv6=${current_ipv6_forward}）。"
        info "转发/NAT 节点的 conntrack 表更易打满，已将 conntrack 两项默认值改为 y。"
        warn "如果不希望调优 conntrack，请显式输入 n。"
    fi

    ask_yes_no "$conntrack_prompt" "$conntrack_default"

    enable_conntrack_tuning=$ASK_RESULT

    if [[ $enable_conntrack_tuning -eq 1 ]]; then
        ask_yes_no "$conntrack_timeout_prompt" "$conntrack_timeout_default"

        enable_conntrack_timeout_tuning=$ASK_RESULT
    else
        enable_conntrack_timeout_tuning=0
    fi

    printf '\n'

    read_integer \
        "请输入目标网络带宽 Mbps，默认 1000: " \
        "1000" \
        "1" \
        "1000000"

    target_bw_mbps=$READ_INTEGER_RESULT

    read_integer \
        "请输入目标 RTT 毫秒，默认 100: " \
        "100" \
        "1" \
        "60000"

    target_rtt_ms=$READ_INTEGER_RESULT

    printf '\n'

    ask_yes_no \
        "是否写入登录会话 nofile 限制？systemd 服务通常需单独配置 [y/N]: " \
        "N"

    enable_limits=$ASK_RESULT
}

# ============================================================
# 优化事务
# ============================================================

optimize_network() {
    local backup_name=""

    collect_user_options

    info "正在检测内核功能……"
    prepare_kernel_features

    info "正在计算网络参数……"
    calculate_params
    build_sysctl_params

    if (( ${#PARAM_ORDER[@]} == 0 )); then
        die "没有可应用的 sysctl 参数。"
    fi

    info "正在检查 sysctl 配置冲突……"
    collect_sysctl_conflicts
    prompt_remove_conflicts

    create_backup
    TRANSACTION_ACTIVE=1

    backup_conflict_files
    remove_conflict_files

    write_sysctl_file
    remove_legacy_sysctl_file
    write_limits_file
    write_modules_file
    remove_legacy_journald_file

    apply_sysctl_file

    backup_name=$(basename "$ACTIVE_BACKUP")
    set_current_backup_name "$backup_name"

    TRANSACTION_ACTIVE=0

    verify_applied_config
    show_summary

    printf '\n'
    info "网络优化完成。"
    info "如需恢复，请重新运行脚本并选择“恢复最近一次配置”。"

    if [[ $enable_limits -eq 1 ]]; then
        warn "nofile 限制需要重新登录或重启对应服务后才会生效。"
    fi

    if [[ $enable_forwarding -eq 1 ]]; then
        warn "开启 IPv4 转发并不等于已配置 NAT。"
        warn "NAT 和防火墙规则仍需通过 nftables/iptables/firewalld 配置。"
    fi

    if [[ $enable_ipv6_forwarding -eq 1 ]]; then
        warn "开启 IPv6 转发可能改变 RA 接收行为。"
        warn "如果上游通过 RA 提供默认路由，请检查对应接口的 accept_ra。"
    fi
}

# ============================================================
# 主菜单
# ============================================================

show_banner() {
    printf '%s\n' \
        "${GREEN}==============================================${NC}" \
        "${GREEN}       TCP/IP 网络优化脚本 v${SCRIPT_VERSION}${NC}" \
        "${GREEN}==============================================${NC}"
}

show_usage() {
    cat <<EOF
用法:
  $0
  $0 --optimize
  $0 --restore
  $0 --help

选项:
  --optimize    进入网络优化流程
  --restore     恢复最近一次配置
  --help        显示帮助
EOF
}

interactive_menu() {
    local choice=""

    printf '\n'
    printf '请选择操作:\n'
    printf '1) 优化网络配置\n'
    printf '2) 恢复最近一次配置\n'
    printf '3) 退出\n'

    while true; do
        read -r -p "请输入选项 [1-3]: " choice \
            || die "无法读取输入。"

        case "$choice" in
            1)
                optimize_network
                return 0
                ;;
            2)
                restore_latest_backup
                return 0
                ;;
            3)
                return 0
                ;;
            *)
                error "请输入 1、2 或 3。"
                ;;
        esac
    done
}

main() {
    local action=${1:-}

    case "$action" in
        --help|-h)
            show_usage
            return 0
            ;;
    esac

    require_root
    require_commands
    detect_os
    ensure_secure_state_dir
    show_banner

    case "$action" in
        "")
            interactive_menu
            ;;
        --optimize)
            optimize_network
            ;;
        --restore)
            restore_latest_backup
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
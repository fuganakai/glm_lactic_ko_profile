#!/bin/bash
# ============================================================
# workflow/common.sh — 全ステップ共通のユーティリティ
#
# 使い方（各ステップスクリプトの先頭で source する）:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
#   parse_args "$@"
#   load_config
# ============================================================

# ============================================================
# ログ関数
# ============================================================

# ログファイルパス（load_config 後に TRIAL_DIR が確定したら上書き可能）
_LOG_FILE=""

_log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%dT%H:%M:%S')] [${level}] $*"
    echo "${msg}" >&2
    if [ -n "${_LOG_FILE}" ]; then
        echo "${msg}" >> "${_LOG_FILE}"
    fi
}

log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# ============================================================
# 引数パース（各ステップスクリプトから parse_args "$@" で呼ぶ）
#
# 対応オプション:
#   --trial-dir <path>   既存の試行ディレクトリを指定（省略時は new-trial-dir で自動採番）
#   --dry-run            ドライラン（コマンドを表示するだけで実行しない）
#   --force              出力ファイルが既存でも再実行する
# ============================================================
TRIAL_DIR=""
DRY_RUN=false
FORCE=false

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --trial-dir)
                shift
                TRIAL_DIR="$1"
                ;;
            --trial-dir=*)
                TRIAL_DIR="${1#--trial-dir=}"
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --force)
                FORCE=true
                ;;
            *)
                log_error "不明なオプション: $1"
                exit 1
                ;;
        esac
        shift
    done
}

# ============================================================
# 設定の読み込み
#
# workflow/config.sh を source して変数をエクスポートする。
# ============================================================

# スクリプトがどこにあっても、プロジェクトルートを正しく解決する
_WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${_WORKFLOW_DIR}/.." && pwd)"

load_config() {
    local config_file="${_WORKFLOW_DIR}/config.sh"
    if [ ! -f "${config_file}" ]; then
        log_error "設定ファイルが見つかりません: ${config_file}"
        exit 1
    fi

    # shellcheck source=workflow/config.sh
    source "${config_file}"

    # パスを絶対パスに正規化（相対パスで書かれていた場合）
    GENOME_DIR="$(cd "${PROJECT_ROOT}" && realpath -m "${GENOME_DIR}")"
    RESPONSE_CSV_DIR="$(cd "${PROJECT_ROOT}" && realpath -m "${RESPONSE_CSV_DIR}")"

    # processed データ置き場（固定）
    PROCESSED_DIR="${PROJECT_ROOT}/data/glm_lactic_ko_profile/processed"

    export GENOME_DIR RESPONSE_CSV_DIR
    export KOFAMSCAN_DIR KOFAMSCAN_KO_LIST KOFAMSCAN_PROFILES
    export CONDA_BASE CONDA_ENV_PROKKA CONDA_ENV_KOFAM CONDA_ENV_ML
    export MIN_SAMPLES_KO MIN_GENOME_LEN RANDOM_STATE N_ESTIMATORS
    export N_TRIALS_RF N_TRIALS_MLP N_TRIALS_XGB TOP_N_KO TOP_N_PAIRS
    export SPLIT_INFO_DIR SEEDS PROCESSED_DIR PROJECT_ROOT
    export SGE_CPUS_PROKKA SGE_MEM_PROKKA
    export SGE_CPUS_KOFAMSCAN SGE_MEM_KOFAMSCAN
    export SGE_CPUS_BENCH SGE_MEM_BENCH
    export SGE_CPUS_SHAP SGE_MEM_SHAP

    log_info "workflow/config.sh を読み込みました"
}

# ============================================================
# 試行ディレクトリの決定
#
# parse_args → load_config の後に呼ぶ。
# TRIAL_DIR が未設定なら new-trial-dir で新規採番する。
# ============================================================
resolve_trial_dir() {
    if [ -n "${TRIAL_DIR}" ]; then
        if [ ! -d "${TRIAL_DIR}" ]; then
            log_error "指定した --trial-dir が見つかりません: ${TRIAL_DIR}"
            exit 1
        fi
        log_info "既存の試行ディレクトリを使用: ${TRIAL_DIR}"
    else
        TRIAL_DIR="$(cd "${PROJECT_ROOT}" && new-trial-dir)"
        log_info "新しい試行ディレクトリ: ${TRIAL_DIR}"
    fi

    export TRIAL_DIR

    # ログファイルを試行ディレクトリ直下に設定
    _LOG_FILE="${TRIAL_DIR}/pipeline.log"
}

# ============================================================
# conda 環境のアクティベート
# ============================================================
activate_conda() {
    local env_name="$1"
    # shellcheck source=/dev/null
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate "${env_name}"
    log_info "conda 環境をアクティベート: ${env_name}"
}

# ============================================================
# SGE ジョブ投入ヘルパー
#
# submit_job <job_name> <cpus> <mem> <log_dir> <script_and_args...>
#   USE_SGE=true  → qsub 投入、ジョブIDを stdout に出力
#   USE_SGE=false → 直接実行（フォアグラウンド）
#
# USE_SGE は呼び出し元スクリプトで設定しておくこと（デフォルト false）。
# ============================================================
USE_SGE="${USE_SGE:-false}"
QSUB_EXTRA_OPTS="${QSUB_EXTRA_OPTS:-}"

submit_job() {
    local job_name="$1"
    local cpus="$2"
    local mem="$3"
    local log_dir="$4"
    shift 4
    local cmd=("$@")

    mkdir -p "${log_dir}"

    if [ "${USE_SGE}" = true ]; then
        if [ "${DRY_RUN}" = true ]; then
            log_info "[DRY-RUN] qsub -N ${job_name} -pe smp ${cpus} -l mem=${mem} ... ${cmd[*]}"
            return
        fi
        # shellcheck disable=SC2086
        qsub ${QSUB_EXTRA_OPTS} \
            -N "${job_name}" \
            -pe smp "${cpus}" \
            -l "mem=${mem}" \
            -cwd \
            -o "${log_dir}/" \
            -e "${log_dir}/" \
            -sync y \
            "${cmd[@]}"
    else
        if [ "${DRY_RUN}" = true ]; then
            log_info "[DRY-RUN] ${cmd[*]}"
            return
        fi
        log_info "実行: ${cmd[*]}"
        "${cmd[@]}"
    fi
}

# ============================================================
# 出力ファイルのスキップ判定
#
# should_skip <output_file>
#   出力ファイルが存在し、かつ --force が指定されていなければ true を返す
# ============================================================
should_skip() {
    local output_file="$1"
    if [ -f "${output_file}" ] && [ "${FORCE}" = false ]; then
        log_info "スキップ（既存）: ${output_file}"
        return 0  # true: スキップすべき
    fi
    return 1  # false: 実行すべき
}

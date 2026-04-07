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
# config/pipeline.yaml の読み込み
#
# プロジェクトルートの config/pipeline.yaml を読んで
# 各設定を bash 変数としてエクスポートする。
# ============================================================

# スクリプトがどこにあっても、プロジェクトルートを正しく解決する
_WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${_WORKFLOW_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pipeline.yaml"

_yaml_get() {
    # 単純な "key: value" 形式の YAML から値を取り出す
    # リスト ([40,41,...]) はそのまま文字列として返す
    local key="$1"
    grep -E "^${key}:" "${CONFIG_FILE}" \
        | head -1 \
        | sed -E 's/^[^:]+:[[:space:]]*//' \
        | sed 's/^"//; s/"$//'
}

load_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "config/pipeline.yaml が見つかりません: ${CONFIG_FILE}"
        log_error "pipeline.sh を先に実行するか、--config で設定ファイルを生成してください"
        exit 1
    fi

    # 入力・ツールパス
    GENOME_DIR="$(_yaml_get genome_dir)"
    RESPONSE_CSV_DIR="$(_yaml_get response_csv_dir)"
    KOFAMSCAN_DIR="$(_yaml_get kofamscan_dir)"
    KOFAMSCAN_KO_LIST="$(_yaml_get kofamscan_ko_list)"
    KOFAMSCAN_PROFILES="$(_yaml_get kofamscan_profiles)"

    # conda 環境
    CONDA_BASE="$(_yaml_get conda_base)"
    CONDA_ENV_PROKKA="$(_yaml_get conda_env_prokka)"
    CONDA_ENV_KOFAM="$(_yaml_get conda_env_kofam)"
    CONDA_ENV_ML="$(_yaml_get conda_env_ml)"

    # パラメータ
    MIN_SAMPLES_KO="$(_yaml_get min_samples_ko)"
    MIN_GENOME_LEN="$(_yaml_get min_genome_len)"
    RANDOM_STATE="$(_yaml_get random_state)"
    N_ESTIMATORS="$(_yaml_get n_estimators)"
    N_TRIALS_RF="$(_yaml_get n_trials_rf)"
    N_TRIALS_MLP="$(_yaml_get n_trials_mlp)"
    N_TRIALS_XGB="$(_yaml_get n_trials_xgb)"
    TOP_N_KO="$(_yaml_get top_n_ko)"
    TOP_N_PAIRS="$(_yaml_get top_n_pairs)"

    # 試行ディレクトリ・出力先
    SPLIT_INFO_DIR="$(_yaml_get split_info_dir)"
    # seeds: [40,41,...] → "40 41 ..." に変換
    SEEDS="$(_yaml_get seeds | tr -d '[]' | tr ',' ' ')"

    # processed データ置き場
    PROCESSED_DIR="${PROJECT_ROOT}/data/glm_lactic_ko_profile/processed"

    export GENOME_DIR RESPONSE_CSV_DIR
    export KOFAMSCAN_DIR KOFAMSCAN_KO_LIST KOFAMSCAN_PROFILES
    export CONDA_BASE CONDA_ENV_PROKKA CONDA_ENV_KOFAM CONDA_ENV_ML
    export MIN_SAMPLES_KO MIN_GENOME_LEN RANDOM_STATE N_ESTIMATORS
    export N_TRIALS_RF N_TRIALS_MLP N_TRIALS_XGB TOP_N_KO TOP_N_PAIRS
    export SPLIT_INFO_DIR SEEDS PROCESSED_DIR PROJECT_ROOT

    log_info "config/pipeline.yaml を読み込みました"
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

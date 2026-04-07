#!/bin/bash
# ============================================================
# workflow/step00_filter.sh — Step 0: サンプルフィルタリング
#
# genome_dir の .fna ファイルをゲノム長でフィルタリングし、
# filtered_samples.txt を生成する。
#
# 使い方:
#   bash workflow/step00_filter.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力ファイルが既存でも再実行する
#
# 前提:
#   config/pipeline.yaml が存在すること（pipeline.sh または手動で生成）
#
# 出力:
#   data/glm_lactic_ko_profile/processed/filtered_samples.txt
#   ${TRIAL_DIR}/run_info.txt  （新規 trial_dir の場合のみ）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

parse_args "$@"
load_config
resolve_trial_dir

# エラー時に行番号をログへ記録
trap 'log_error "line ${LINENO}: ${BASH_COMMAND}"' ERR

# ============================================================
# run_info.txt の生成（新規 trial_dir の場合）
# ============================================================
RUN_INFO="${TRIAL_DIR}/run_info.txt"
if [ ! -f "${RUN_INFO}" ]; then
    {
        echo "date:    $(date '+%Y-%m-%d %H:%M:%S')"
        echo "branch:  $(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        echo "commit:  $(git -C "${PROJECT_ROOT}" log -1 --format='%h  %s' 2>/dev/null || echo unknown)"
        echo "config:"
        cat "${CONFIG_FILE}"
    } > "${RUN_INFO}"
    log_info "run_info.txt -> ${RUN_INFO}"
fi

# ============================================================
# 出力パスの定義
# ============================================================
OUTPUT_FILE="${PROCESSED_DIR}/filtered_samples.txt"

# ============================================================
# スキップ判定
# ============================================================
if should_skip "${OUTPUT_FILE}"; then
    log_info "Step 0 完了（スキップ）: ${OUTPUT_FILE}"
    exit 0
fi

# ============================================================
# Step 0 実行
# ============================================================
log_info "Step 0: サンプルフィルタリング開始"
log_info "  genome_dir:      ${GENOME_DIR}"
log_info "  min_genome_len:  ${MIN_GENOME_LEN}"
log_info "  出力:            ${OUTPUT_FILE}"

activate_conda "${CONDA_ENV_ML}"

mkdir -p "${PROCESSED_DIR}"

if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] python scripts/00_filter_samples.py \\"
    log_info "    --genome-dir     ${GENOME_DIR} \\"
    log_info "    --min-genome-len ${MIN_GENOME_LEN} \\"
    log_info "    --output         ${OUTPUT_FILE}"
    exit 0
fi

python "${SCRIPT_DIR}/00_filter_samples.py" \
    --genome-dir     "${GENOME_DIR}" \
    --min-genome-len "${MIN_GENOME_LEN}" \
    --output         "${OUTPUT_FILE}"

log_info "Step 0 完了: ${OUTPUT_FILE}"

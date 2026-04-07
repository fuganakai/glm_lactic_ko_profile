#!/bin/bash
# ============================================================
# workflow/step08_vis_all.sh — Step 8: 全データセット横断 R² 比較図
#
# 全データセットの R² を1枚の図にまとめる。
# デフォルトモードでは r2_scores.csv を、
# ext モードでは summary/r2_mean_std.csv を使用する（自動判定）。
#
# 使い方:
#   bash workflow/step08_vis_all.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力ファイルが既存でも再実行する
#
# 前提:
#   - デフォルトモード: step05_bench.sh 実行済み
#   - ext モード:       step07_aggregate.sh 実行済み
#   - config/pipeline.yaml が存在する
#
# 出力:
#   ${TRIAL_DIR}/figures/r2_all_datasets.png
#   ${TRIAL_DIR}/logs/08_vis_all.log
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

parse_args "$@"
load_config
resolve_trial_dir

trap 'log_error "line ${LINENO}: ${BASH_COMMAND}"' ERR

# ============================================================
# パスの定義
# ============================================================
FIG_DIR="${TRIAL_DIR}/figures"
OUTPUT_FILE="${FIG_DIR}/r2_all_datasets.png"
LOG_FILE="${TRIAL_DIR}/logs/08_vis_all.log"

# ============================================================
# スキップ判定
# ============================================================
if should_skip "${OUTPUT_FILE}"; then
    log_info "Step 8 完了（スキップ）: ${OUTPUT_FILE}"
    exit 0
fi

# ============================================================
# 前提チェック（少なくとも1データセットの結果が必要）
# ============================================================
if [ ! -d "${RESPONSE_CSV_DIR}" ]; then
    log_error "RESPONSE_CSV_DIR が見つかりません: ${RESPONSE_CSV_DIR}"
    exit 1
fi

mapfile -t DATASETS < <(find "${RESPONSE_CSV_DIR}" -name "*.csv" | xargs -I{} basename {} .csv | sort)
FOUND=false
for DATASET in "${DATASETS[@]}"; do
    if [ -n "${SPLIT_INFO_DIR}" ]; then
        [ -f "${TRIAL_DIR}/${DATASET}/summary/r2_mean_std.csv" ] && FOUND=true && break
    else
        [ -f "${TRIAL_DIR}/${DATASET}/r2_scores.csv" ] && FOUND=true && break
    fi
done

if [ "${FOUND}" = false ]; then
    log_error "R² 結果ファイルが見つかりません。step05（および ext モードでは step07）を先に実行してください"
    exit 1
fi

log_info "Step 8: 全データセット R² 比較図"
log_info "  results_dir: ${TRIAL_DIR}"
log_info "  出力:        ${OUTPUT_FILE}"

if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] python scripts/08_visualize_all_datasets.py \\"
    log_info "    --results-dir ${TRIAL_DIR} \\"
    log_info "    --output-dir  ${FIG_DIR}"
    exit 0
fi

mkdir -p "${FIG_DIR}" "$(dirname "${LOG_FILE}")"
activate_conda "${CONDA_ENV_ML}"

python "${PROJECT_ROOT}/scripts/08_visualize_all_datasets.py" \
    --results-dir "${TRIAL_DIR}" \
    --output-dir  "${FIG_DIR}" \
    > "${LOG_FILE}" 2>&1

log_info "Step 8 完了: ${OUTPUT_FILE}"

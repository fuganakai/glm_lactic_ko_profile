#!/bin/bash
# ============================================================
# workflow/step04_ko_profile.sh — Step 4: KO プロファイル行列作成
#
# 全サンプルの KO アノテーション CSV を集約し、
# sample × KO バイナリ行列 (ko_profile.csv) を生成する。
# 全サンプルの Step 3 完了後に実行すること。
#
# 使い方:
#   bash workflow/step04_ko_profile.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力ファイルが既存でも再実行する
#
# 前提:
#   - step03_to_csv.sh 実行済み（ko_annotations/{sample}_genome.csv が存在する）
#   - config/pipeline.yaml が存在する
#
# 出力:
#   data/glm_lactic_ko_profile/processed/ko_profile.csv
#   data/glm_lactic_ko_profile/processed/ko_list.txt
#   ${TRIAL_DIR}/logs/04_ko_profile/04_ko_profile.log
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
KO_ANNOT_DIR="${PROCESSED_DIR}/ko_annotations"
KO_PROFILE="${PROCESSED_DIR}/ko_profile.csv"
KO_LIST_FILE="${PROCESSED_DIR}/ko_list.txt"
LOG_DIR="${TRIAL_DIR}/logs/04_ko_profile"
LOG_FILE="${LOG_DIR}/04_ko_profile.log"

# ============================================================
# 前提チェック
# ============================================================
if [ ! -d "${KO_ANNOT_DIR}" ]; then
    log_error "ko_annotations ディレクトリが見つかりません: ${KO_ANNOT_DIR}"
    log_error "先に step03_to_csv.sh を実行してください"
    exit 1
fi

N_CSV=$(find "${KO_ANNOT_DIR}" -name "*_genome.csv" | wc -l)
if [ "${N_CSV}" -eq 0 ]; then
    log_error "ko_annotations に *_genome.csv が見つかりません: ${KO_ANNOT_DIR}"
    exit 1
fi

log_info "Step 4: KO プロファイル作成"
log_info "  入力:          ${KO_ANNOT_DIR}  (${N_CSV} ファイル)"
log_info "  min_samples_ko: ${MIN_SAMPLES_KO}"
log_info "  出力 profile:  ${KO_PROFILE}"
log_info "  出力 ko_list:  ${KO_LIST_FILE}"

# ============================================================
# スキップ判定（profile と ko_list の両方が存在する場合）
# ============================================================
if [ -f "${KO_PROFILE}" ] && [ -f "${KO_LIST_FILE}" ] && [ "${FORCE}" = false ]; then
    log_info "スキップ（既存）: ${KO_PROFILE}"
    exit 0
fi

mkdir -p "${LOG_DIR}"

if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] python scripts/04_make_ko_profile.py \\"
    log_info "    --ko-annot-dir   ${KO_ANNOT_DIR} \\"
    log_info "    --min-samples-ko ${MIN_SAMPLES_KO} \\"
    log_info "    --output-profile ${KO_PROFILE} \\"
    log_info "    --output-ko-list ${KO_LIST_FILE}"
    exit 0
fi

activate_conda "${CONDA_ENV_ML}"

python "${PROJECT_ROOT}/scripts/04_make_ko_profile.py" \
    --ko-annot-dir   "${KO_ANNOT_DIR}" \
    --min-samples-ko "${MIN_SAMPLES_KO}" \
    --output-profile "${KO_PROFILE}" \
    --output-ko-list "${KO_LIST_FILE}" \
    2>&1 | tee "${LOG_FILE}"

log_info "Step 4 完了: ${KO_PROFILE}"

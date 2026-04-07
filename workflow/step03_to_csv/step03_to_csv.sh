#!/bin/bash
# ============================================================
# workflow/step03_to_csv.sh — Step 3: KoFamScan → CSV 変換
#
# KoFamScan の出力 (.txt) を KO アノテーション CSV に変換する。
# 軽量処理のため SGE は使わずローカルで実行する。
#
# 使い方:
#   bash workflow/step03_to_csv.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みサンプルも再実行する
#
# 前提:
#   - step02_kofamscan.sh 実行済み（kofamscan_out/{sample}.txt が存在する）
#   - config/pipeline.yaml が存在する
#
# 出力:
#   data/glm_lactic_ko_profile/processed/ko_annotations/{sample}_genome.csv
#   ${TRIAL_DIR}/logs/03_to_csv/03_to_csv.log
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

parse_args "$@"
load_config
resolve_trial_dir

trap 'log_error "line ${LINENO}: ${BASH_COMMAND}"' ERR

# ============================================================
# パスの定義
# ============================================================
FILTERED_SAMPLES="${PROCESSED_DIR}/filtered_samples.txt"
KOFAMSCAN_OUT_DIR="${PROCESSED_DIR}/kofamscan_out"
KO_ANNOT_DIR="${PROCESSED_DIR}/ko_annotations"
LOG_DIR="${TRIAL_DIR}/logs/03_to_csv"
LOG_FILE="${LOG_DIR}/03_to_csv.log"

# ============================================================
# 前提チェック
# ============================================================
if [ ! -f "${FILTERED_SAMPLES}" ]; then
    log_error "filtered_samples.txt が見つかりません: ${FILTERED_SAMPLES}"
    log_error "先に step00_filter.sh を実行してください"
    exit 1
fi

mapfile -t SAMPLES < "${FILTERED_SAMPLES}"
if [ ${#SAMPLES[@]} -eq 0 ]; then
    log_error "filtered_samples.txt が空です"
    exit 1
fi

log_info "Step 3: KoFamScan → CSV  サンプル数: ${#SAMPLES[@]}"
log_info "  入力:  ${KOFAMSCAN_OUT_DIR}"
log_info "  出力:  ${KO_ANNOT_DIR}"

mkdir -p "${KO_ANNOT_DIR}" "${LOG_DIR}"

activate_conda "${CONDA_ENV_ML}"

# ============================================================
# サンプルごとに変換
# ============================================================
SKIP_COUNT=0
RUN_COUNT=0
MISS_COUNT=0

for SAMPLE in "${SAMPLES[@]}"; do
    INPUT="${KOFAMSCAN_OUT_DIR}/${SAMPLE}.txt"
    OUTPUT="${KO_ANNOT_DIR}/${SAMPLE}_genome.csv"

    if [ ! -f "${INPUT}" ]; then
        log_warn "KoFamScan 出力が見つかりません、スキップ: ${INPUT}"
        MISS_COUNT=$((MISS_COUNT + 1))
        continue
    fi

    if should_skip "${OUTPUT}"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] python scripts/03_kofamscan_to_csv.py --input ${INPUT} --output ${OUTPUT}"
        continue
    fi

    python "${SCRIPT_DIR}/03_kofamscan_to_csv.py" \
        --input  "${INPUT}" \
        --output "${OUTPUT}" \
        >> "${LOG_FILE}" 2>&1

    RUN_COUNT=$((RUN_COUNT + 1))
done

log_info "Step 3 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}  入力なし=${MISS_COUNT}"
if [ "${MISS_COUNT}" -gt 0 ]; then
    log_warn "${MISS_COUNT} サンプルの KoFamScan 出力が見つかりませんでした。step02 を確認してください"
fi

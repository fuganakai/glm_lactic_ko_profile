#!/bin/bash
# ============================================================
# workflow/step07_aggregate.sh — Step 7: seed 集約（ext モードのみ）
#
# step05_bench.sh を複数 seed で実行した結果を集約し、
# mean ± std サマリーを生成する。
# SPLIT_INFO_DIR が未設定（デフォルトモード）の場合はスキップする。
#
# 使い方:
#   bash workflow/step07_aggregate.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みデータセットも再実行する
#
# 前提:
#   - step05_bench.sh (ext モード) 実行済み
#     （{TRIAL_DIR}/{dataset}/seed{N}/r2_scores.csv が存在する）
#   - config/pipeline.yaml が存在する
#
# 出力:
#   ${TRIAL_DIR}/{dataset}/summary/r2_mean_std.csv
#   ${TRIAL_DIR}/{dataset}/summary/feature_importance_mean.csv
#   ${TRIAL_DIR}/{dataset}/summary/sample_predictions_all.csv
#   ${TRIAL_DIR}/logs/07_aggregate/{dataset}.log
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

parse_args "$@"
load_config
resolve_trial_dir

trap 'log_error "line ${LINENO}: ${BASH_COMMAND}"' ERR

# ============================================================
# ext モード以外はスキップ
# ============================================================
if [ -z "${SPLIT_INFO_DIR}" ]; then
    log_info "Step 7: SPLIT_INFO_DIR が未設定のためスキップ（デフォルトモードでは不要）"
    exit 0
fi

# ============================================================
# パスの定義
# ============================================================
LOG_DIR="${TRIAL_DIR}/logs/07_aggregate"

# ============================================================
# 前提チェック
# ============================================================
if [ ! -d "${RESPONSE_CSV_DIR}" ]; then
    log_error "RESPONSE_CSV_DIR が見つかりません: ${RESPONSE_CSV_DIR}"
    exit 1
fi

mapfile -t DATASETS < <(find "${RESPONSE_CSV_DIR}" -name "*.csv" | xargs -I{} basename {} .csv | sort)
if [ ${#DATASETS[@]} -eq 0 ]; then
    log_error "RESPONSE_CSV_DIR に .csv が見つかりません: ${RESPONSE_CSV_DIR}"
    exit 1
fi

log_info "Step 7: seed 集約  データセット=${#DATASETS[@]}  seeds=(${SEEDS})"

mkdir -p "${LOG_DIR}"
activate_conda "${CONDA_ENV_ML}"

# ============================================================
# データセットごとに集約
# ============================================================
RUN_COUNT=0
SKIP_COUNT=0

for DATASET in "${DATASETS[@]}"; do
    DATASET_DIR="${TRIAL_DIR}/${DATASET}"
    SUMMARY_FILE="${DATASET_DIR}/summary/r2_mean_std.csv"

    if [ -f "${SUMMARY_FILE}" ] && [ "${FORCE}" = false ]; then
        log_info "スキップ（既存）: ${DATASET}/summary"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # 少なくとも1つの seed 結果が存在するか確認
    FOUND=false
    for SEED in ${SEEDS}; do
        if [ -f "${DATASET_DIR}/seed${SEED}/r2_scores.csv" ]; then
            FOUND=true; break
        fi
    done
    if [ "${FOUND}" = false ]; then
        log_warn "seed 結果が見つかりません、スキップ: ${DATASET}"
        continue
    fi

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] python scripts/07_aggregate_seeds.py --results-dir ${DATASET_DIR} --seeds ${SEEDS}"
        continue
    fi

    log_info "集約: ${DATASET}"
    # seeds をスペース区切りで渡す
    # shellcheck disable=SC2086
    python "${SCRIPT_DIR}/07_aggregate_seeds.py" \
        --results-dir "${DATASET_DIR}" \
        --seeds       ${SEEDS} \
        > "${LOG_DIR}/${DATASET}.log" 2>&1

    RUN_COUNT=$((RUN_COUNT + 1))
done

log_info "Step 7 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}"

#!/bin/bash
# ============================================================
# workflow/step06_visualize.sh — Step 6a/b: 可視化
#
# step05_bench.sh の出力から 7 種類の図を生成する。
#
# モード:
#   デフォルト (SPLIT_INFO_DIR=""):
#     データセットごとに1回実行
#     出力: ${TRIAL_DIR}/{dataset}/figures/
#
#   共有 fold split モード (SPLIT_INFO_DIR 設定済み):
#     データセット × seed の全組み合わせを実行
#     出力: ${TRIAL_DIR}/{dataset}/seed{seed}/figures/
#
# 使い方:
#   bash workflow/step06_visualize.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みジョブも再実行する
#
# 前提:
#   - step05_bench.sh 実行済み（r2_scores.csv が存在する）
#   - config/pipeline.yaml が存在する
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
LOG_DIR="${TRIAL_DIR}/logs/06_visualize"

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

if [ -n "${SPLIT_INFO_DIR}" ]; then
    USE_EXT=true
    log_info "Step 6 visualize  モード=ext  データセット=${#DATASETS[@]}  seeds=(${SEEDS})"
else
    USE_EXT=false
    log_info "Step 6 visualize  モード=default  データセット=${#DATASETS[@]}"
fi

mkdir -p "${LOG_DIR}"
activate_conda "${CONDA_ENV_ML}"

# ============================================================
# 実行
# ============================================================
RUN_COUNT=0
SKIP_COUNT=0

for DATASET in "${DATASETS[@]}"; do
    if [ "${USE_EXT}" = true ]; then
        for SEED in ${SEEDS}; do
            RESULTS_DIR="${TRIAL_DIR}/${DATASET}/seed${SEED}"
            FIG_DIR="${RESULTS_DIR}/figures"
            SKIP_FILE="${FIG_DIR}/r2_comparison.png"

            if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                log_info "スキップ（既存）: ${DATASET}/seed${SEED}"
                SKIP_COUNT=$((SKIP_COUNT + 1)); continue
            fi
            if [ ! -f "${RESULTS_DIR}/r2_scores.csv" ]; then
                log_warn "r2_scores.csv が見つかりません、スキップ: ${RESULTS_DIR}"
                continue
            fi
            if [ "${DRY_RUN}" = true ]; then
                log_info "[DRY-RUN] visualize ${DATASET} seed${SEED}"; continue
            fi

            log_info "可視化: ${DATASET} seed${SEED}"
            mkdir -p "${FIG_DIR}"
            python "${PROJECT_ROOT}/scripts/06_visualize.py" \
                --results-dir "${RESULTS_DIR}" \
                --output-dir  "${FIG_DIR}" \
                --top-n-ko    "${TOP_N_KO}" \
                > "${LOG_DIR}/${DATASET}_seed${SEED}.log" 2>&1
            RUN_COUNT=$((RUN_COUNT + 1))
        done
    else
        RESULTS_DIR="${TRIAL_DIR}/${DATASET}"
        FIG_DIR="${RESULTS_DIR}/figures"
        SKIP_FILE="${FIG_DIR}/r2_comparison.png"

        if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
            log_info "スキップ（既存）: ${DATASET}"
            SKIP_COUNT=$((SKIP_COUNT + 1)); continue
        fi
        if [ ! -f "${RESULTS_DIR}/r2_scores.csv" ]; then
            log_warn "r2_scores.csv が見つかりません、スキップ: ${RESULTS_DIR}"
            continue
        fi
        if [ "${DRY_RUN}" = true ]; then
            log_info "[DRY-RUN] visualize ${DATASET}"; continue
        fi

        log_info "可視化: ${DATASET}"
        mkdir -p "${FIG_DIR}"
        python "${PROJECT_ROOT}/scripts/06_visualize.py" \
            --results-dir "${RESULTS_DIR}" \
            --output-dir  "${FIG_DIR}" \
            --top-n-ko    "${TOP_N_KO}" \
            > "${LOG_DIR}/${DATASET}.log" 2>&1
        RUN_COUNT=$((RUN_COUNT + 1))
    fi
done

log_info "Step 6 visualize 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}"

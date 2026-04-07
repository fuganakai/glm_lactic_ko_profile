#!/bin/bash
# ============================================================
# workflow/check_progress.sh — パイプライン進捗確認
#
# 使い方:
#   bash workflow/check_progress.sh [trial_dir]
#
# trial_dir を省略した場合、最新の試行ディレクトリを自動検出。
#
# 監視:
#   watch -n 30 bash workflow/check_progress.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# config.sh から設定読み込み
source "${SCRIPT_DIR}/config.sh"
SEEDS_ARR=(${SEEDS})
N_SEEDS=${#SEEDS_ARR[@]}

# trial_dir の決定（相対パスはPROJECT_ROOTからの相対として解決）
if [ "${1:-}" != "" ]; then
    if [[ "$1" = /* ]]; then
        TRIAL_DIR="$1"
    else
        TRIAL_DIR="${PROJECT_ROOT}/$1"
    fi
else
    OUTPUT_BASE="${PROJECT_ROOT}/output/glm_lactic_ko_profile"
    TRIAL_DIR=$(find "${OUTPUT_BASE}" -maxdepth 1 -type d -name '[0-9][0-9][0-9]' 2>/dev/null \
                | sort -V | tail -1 || true)
    if [ -z "${TRIAL_DIR}" ]; then
        echo "試行ディレクトリが見つかりません: ${OUTPUT_BASE}" >&2
        exit 1
    fi
fi

echo "=== 進捗確認: ${TRIAL_DIR} ==="
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# データセット一覧（response_csvs から取得）
RESPONSE_CSV_DIR_ABS="$(cd "${PROJECT_ROOT}" && realpath -m "${RESPONSE_CSV_DIR}")"
DATASETS=()
if [ -d "${RESPONSE_CSV_DIR_ABS}" ]; then
    while IFS= read -r f; do
        DATASETS+=("$(basename "${f}" .csv)")
    done < <(find "${RESPONSE_CSV_DIR_ABS}" -maxdepth 1 -name "*.csv" | sort)
fi
N_DATASETS=${#DATASETS[@]}

if [ ${N_DATASETS} -eq 0 ]; then
    echo "データセットが見つかりません: ${RESPONSE_CSV_DIR_ABS}"
    exit 0
fi

# ---- extモード判定（SPLIT_INFO_DIR が設定されているか、またはseedディレクトリが存在するか）----
FIRST_DS="${DATASETS[0]}"
if [ -n "${SPLIT_INFO_DIR:-}" ] || [ -d "${TRIAL_DIR}/${FIRST_DS}/seed${SEEDS_ARR[0]}" ]; then
    USE_EXT=true
    TOTAL_UNITS=$((N_DATASETS * N_SEEDS))
else
    USE_EXT=false
    TOTAL_UNITS=${N_DATASETS}
fi

# ============================================================
# ヘルパー: ファイル数カウント（extモード）
# ============================================================
count_ext() {
    local filename="$1"
    local count=0
    for DS in "${DATASETS[@]}"; do
        for SEED in "${SEEDS_ARR[@]}"; do
            [ -f "${TRIAL_DIR}/${DS}/seed${SEED}/${filename}" ] && ((count++)) || true
        done
    done
    echo "${count}"
}

# ============================================================
# ヘルパー: ファイル数カウント（非extモード）
# ============================================================
count_flat() {
    local filename="$1"
    local count=0
    for DS in "${DATASETS[@]}"; do
        [ -f "${TRIAL_DIR}/${DS}/${filename}" ] && ((count++)) || true
    done
    echo "${count}"
}

# ============================================================
# ヘルパー: 表示
# ============================================================
show_step() {
    local label="$1"
    local done_n="$2"
    local total="$3"
    local pct=0
    [ "${total}" -gt 0 ] && pct=$(( done_n * 100 / total ))
    printf "%-30s %4d / %4d (%3d%%)\n" "${label}" "${done_n}" "${total}" "${pct}"
}

# ============================================================
# 各ステップのカウント
# ============================================================
if [ "${USE_EXT}" = true ]; then
    N5_R2=$(count_ext "r2_scores.csv")
    N5_XGB=$(count_ext "r2_scores_xgb.csv")
    N6B=$(count_ext "shap_values_xgb.csv")
    N7=$(count_ext "aggregated_r2.csv")   # step07 の出力（データセット単位）
    # step06: データセット単位
    N6=0
    for DS in "${DATASETS[@]}"; do
        [ -f "${TRIAL_DIR}/${DS}/r2_boxplot.png" ] && ((N6++)) || true
    done
    N8=0
    [ -f "${TRIAL_DIR}/all_datasets_r2.png" ] && N8=1
else
    N5_R2=$(count_flat "r2_scores.csv")
    N5_XGB=$(count_flat "r2_scores_xgb.csv")
    N6=$(count_flat "r2_boxplot.png")
    N6B=$(count_flat "shap_values_xgb.csv")
    N7=0  # extモードのみ
    N8=0
    [ -f "${TRIAL_DIR}/all_datasets_r2.png" ] && N8=1
fi

echo "[Step 5 ] モデル学習 (RF/Lasso/MLP):"
show_step "  r2_scores.csv"      "${N5_R2}"  "${TOTAL_UNITS}"

echo "[Step 5 ] モデル学習 (XGBoost):"
show_step "  r2_scores_xgb.csv"  "${N5_XGB}" "${TOTAL_UNITS}"

echo "[Step 6 ] 可視化:"
if [ "${USE_EXT}" = true ]; then
    show_step "  r2_boxplot.png"    "${N6}"   "${N_DATASETS}"
else
    show_step "  r2_boxplot.png"    "${N6}"   "${TOTAL_UNITS}"
fi

echo "[Step 6b] XGBoost + SHAP:"
show_step "  shap_values_xgb.csv" "${N6B}"  "${TOTAL_UNITS}"

if [ "${USE_EXT}" = true ]; then
    echo "[Step 7 ] seed集約:"
    show_step "  aggregated_r2.csv"  "${N7}"   "${TOTAL_UNITS}"
fi

echo "[Step 8 ] 全データセット横断図:"
show_step "  all_datasets_r2.png" "${N8}"   "1"

echo ""

# ============================================================
# SGE 実行中ジョブ
# ============================================================
echo "--- 実行中 SGE ジョブ ---"
if command -v qstat &>/dev/null; then
    # ジョブID, 名前, 状態, 開始時刻 を表示
    RUNNING=$(qstat 2>/dev/null | tail -n +3 || true)
    if [ -n "${RUNNING}" ]; then
        printf "  %-10s %-25s %-5s %s\n" "JobID" "Name" "State" "Start"
        echo "${RUNNING}" | awk '{printf "  %-10s %-25s %-5s %s\n", $1, $3, $5, $6" "$7}'
    else
        echo "  （実行中ジョブなし）"
    fi
else
    echo "  （qstat が見つかりません）"
fi

echo ""

# ============================================================
# 最近のログエラー確認
# ============================================================
LOG_DIR="${TRIAL_DIR}/logs/05_bench_models"
if [ -d "${LOG_DIR}" ]; then
    ERR_COUNT=$(grep -rl "Error\|Traceback\|FAILED" "${LOG_DIR}" 2>/dev/null | wc -l || echo 0)
    if [ "${ERR_COUNT}" -gt 0 ]; then
        echo "--- [WARN] エラーログ検出: ${ERR_COUNT} ファイル ---"
        grep -rl "Error\|Traceback\|FAILED" "${LOG_DIR}" 2>/dev/null | head -5 | sed 's/^/  /'
    fi
fi

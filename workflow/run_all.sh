#!/bin/bash
# ============================================================
# workflow/run_all.sh — 全ステップを順番に実行するラッパー
#
# 各ステップを step00 → step08 の順に呼び出す。
# trial_dir は最初のステップで採番し、以降すべてに引き渡す。
#
# 使い方:
#   bash workflow/run_all.sh [options]
#
# オプション:
#   --trial-dir <path>   既存の試行ディレクトリを再利用
#   --dry-run            全ステップをドライランモードで実行
#   --force              全ステップで出力済みファイルを上書き
#   --skip-prokka        Step 1 (Prokka) をスキップ（.faa 生成済みの場合）
#   --skip-kofamscan     Step 2 (KoFamScan) をスキップ（.txt 生成済みの場合）
#   --from <step>        指定ステップから再開（例: --from 5）
#   --only <step>        指定ステップのみ実行（例: --only 4）
#
# SGE 使用時:
#   USE_SGE=true bash workflow/run_all.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# オプション解析（common.sh の parse_args とは別に独自実装）
# ============================================================
TRIAL_DIR_OPT=""
DRY_RUN_OPT=""
FORCE_OPT=""
SKIP_PROKKA=false
SKIP_KOFAMSCAN=false
FROM_STEP=0
ONLY_STEP=""

while [ $# -gt 0 ]; do
    case $1 in
        --trial-dir)      shift; TRIAL_DIR_OPT="--trial-dir $1" ;;
        --trial-dir=*)    TRIAL_DIR_OPT="--trial-dir ${1#--trial-dir=}" ;;
        --dry-run)        DRY_RUN_OPT="--dry-run" ;;
        --force)          FORCE_OPT="--force" ;;
        --skip-prokka)    SKIP_PROKKA=true ;;
        --skip-kofamscan) SKIP_KOFAMSCAN=true ;;
        --from)           shift; FROM_STEP="$1" ;;
        --from=*)         FROM_STEP="${1#--from=}" ;;
        --only)           shift; ONLY_STEP="$1" ;;
        --only=*)         ONLY_STEP="${1#--only=}" ;;
        *) echo "[ERROR] 不明なオプション: $1" >&2; exit 1 ;;
    esac
    shift
done

# ============================================================
# ステップ実行ヘルパー
# ============================================================
_TRIAL_DIR_RESOLVED=""

run_step() {
    local step_num="$1"
    local step_script="$2"
    shift 2
    local extra_args=("$@")

    # --only 指定時は対象ステップ以外スキップ
    if [ -n "${ONLY_STEP}" ] && [ "${step_num}" != "${ONLY_STEP}" ]; then
        return
    fi

    # --from 指定時は対象ステップ未満をスキップ
    if [ "${step_num}" -lt "${FROM_STEP}" ]; then
        echo "[run_all.sh] Step ${step_num} スキップ (--from ${FROM_STEP})"
        return
    fi

    echo ""
    echo "============================================================"
    echo "[run_all.sh] Step ${step_num}: ${step_script}"
    echo "============================================================"

    # 最初のステップ実行後に trial_dir を確定させる
    # （後続ステップには --trial-dir を明示的に渡す）
    local trial_arg="${TRIAL_DIR_OPT}"
    if [ -n "${_TRIAL_DIR_RESOLVED}" ]; then
        trial_arg="--trial-dir ${_TRIAL_DIR_RESOLVED}"
    fi

    # ステップ実行
    bash "${SCRIPT_DIR}/${step_script}" \
        ${trial_arg} \
        ${DRY_RUN_OPT} \
        ${FORCE_OPT} \
        "${extra_args[@]+"${extra_args[@]}"}"

    # step00 完了後に trial_dir を取得（以降のステップに引き渡す）
    if [ "${step_num}" -eq 0 ] && [ -z "${_TRIAL_DIR_RESOLVED}" ]; then
        # common.sh の resolve_trial_dir が出力した TRIAL_DIR を間接的に取得するため、
        # 最新の試行ディレクトリを検索する
        _PROJ_NAME="glm_lactic_ko_profile"
        _BASE_OUT="$(cd "${SCRIPT_DIR}/.." && pwd)/output/${_PROJ_NAME}"
        _TRIAL_DIR_RESOLVED="$(find "${_BASE_OUT}" -maxdepth 1 -type d -name '[0-9][0-9][0-9]' \
            2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "${_TRIAL_DIR_RESOLVED}" ]; then
            echo "[run_all.sh] trial_dir 確定: ${_TRIAL_DIR_RESOLVED}"
        fi
    fi
}

# ============================================================
# --trial-dir が指定されている場合は最初から確定
# ============================================================
if [ -n "${TRIAL_DIR_OPT}" ]; then
    _TRIAL_DIR_RESOLVED="${TRIAL_DIR_OPT#--trial-dir }"
fi

# ============================================================
# ステップ実行
# ============================================================
echo "[run_all.sh] パイプライン開始  $(date '+%Y-%m-%d %H:%M:%S')"
echo "[run_all.sh] USE_SGE=${USE_SGE:-false}"

run_step 0 "step00_filter.sh"

if [ "${SKIP_PROKKA}" = false ]; then
    run_step 1 "step01_prokka.sh"
else
    echo "[run_all.sh] Step 1 スキップ (--skip-prokka)"
fi

if [ "${SKIP_KOFAMSCAN}" = false ]; then
    run_step 2 "step02_kofamscan.sh"
else
    echo "[run_all.sh] Step 2 スキップ (--skip-kofamscan)"
fi

run_step 3 "step03_to_csv.sh"
run_step 4 "step04_ko_profile.sh"
run_step 5 "step05_bench.sh"
run_step 6 "step06_visualize.sh"
run_step 6 "step06b_xgb_shap.sh"
run_step 7 "step07_aggregate.sh"
run_step 8 "step08_vis_all.sh"

echo ""
echo "[run_all.sh] 全ステップ完了  $(date '+%Y-%m-%d %H:%M:%S')"
if [ -n "${_TRIAL_DIR_RESOLVED}" ]; then
    echo "[run_all.sh] 結果: ${_TRIAL_DIR_RESOLVED}"
fi

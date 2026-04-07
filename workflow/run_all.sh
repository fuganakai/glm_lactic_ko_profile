#!/bin/bash
# ============================================================
# workflow/run_all.sh — 全ステップを順番に実行するラッパー
#
# ステップ一覧:
#   0   step00_filter.sh       サンプルフィルタリング
#   1   step01_prokka.sh       Prokka アノテーション
#   2   step02_kofamscan.sh    KoFamScan アノテーション
#   3   step03_to_csv.sh       KoFamScan → CSV 変換
#   4   step04_ko_profile.sh   KO プロファイル行列作成
#   5   step05_bench.sh        モデル学習
#   6   step06_visualize.sh    可視化
#   6b  step06b_xgb_shap.sh   XGBoost + SHAP 解析
#   7   step07_aggregate.sh    seed 集約（ext モードのみ）
#   8   step08_vis_all.sh      全データセット横断 R² 図
#
# 使い方:
#   bash workflow/run_all.sh [options]
#
# オプション:
#   --trial-dir <path>      既存の試行ディレクトリを再利用
#   --dry-run               全ステップをドライランモードで実行
#   --force                 全ステップで出力済みファイルを上書き
#   --steps <list>          実行するステップをカンマ区切りで指定
#                           例: --steps 0,1,2,3,4,5,6    (6b を省く)
#                               --steps 5,6,6b,7,8       (前半を省く)
#   --skip <list>           省くステップをカンマ区切りで指定
#                           例: --skip 6b                 (xgb_shap を省く)
#                               --skip 1,2               (prokka/kofamscan を省く)
#   --from <step>           指定ステップから再開
#                           例: --from 5
#
# SGE 使用時:
#   USE_SGE=true bash workflow/run_all.sh
#
# 例:
#   # xgb_shap を省いて全実行
#   bash workflow/run_all.sh --skip 6b
#
#   # step5 から再開（既存 trial_dir に追記）
#   bash workflow/run_all.sh --trial-dir output/glm_lactic_ko_profile/001 --from 5
#
#   # step5 と step6 だけ実行
#   bash workflow/run_all.sh --trial-dir output/glm_lactic_ko_profile/001 --steps 5,6
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# ステップ定義（順番に実行される）
# ============================================================
# 識別子と対応スクリプトの配列（順序保証のため2つに分けて管理）
ALL_STEP_IDS=(0 1 2 3 4 5 6 6b 7 8)
declare -A STEP_SCRIPT=(
    [0]="step00_filter.sh"
    [1]="step01_prokka.sh"
    [2]="step02_kofamscan.sh"
    [3]="step03_to_csv.sh"
    [4]="step04_ko_profile.sh"
    [5]="step05_bench.sh"
    [6]="step06_visualize.sh"
    [6b]="step06b_xgb_shap.sh"
    [7]="step07_aggregate.sh"
    [8]="step08_vis_all.sh"
)

# ============================================================
# オプション解析
# ============================================================
TRIAL_DIR_OPT=""
DRY_RUN_OPT=""
FORCE_OPT=""
STEPS_OPT=""    # --steps で指定されたステップ（カンマ区切り）
SKIP_OPT=""     # --skip で指定されたステップ（カンマ区切り）
FROM_STEP=""    # --from で指定されたステップ

while [ $# -gt 0 ]; do
    case $1 in
        --trial-dir)   shift; TRIAL_DIR_OPT="--trial-dir $1" ;;
        --trial-dir=*) TRIAL_DIR_OPT="--trial-dir ${1#--trial-dir=}" ;;
        --dry-run)     DRY_RUN_OPT="--dry-run" ;;
        --force)       FORCE_OPT="--force" ;;
        --steps)       shift; STEPS_OPT="$1" ;;
        --steps=*)     STEPS_OPT="${1#--steps=}" ;;
        --skip)        shift; SKIP_OPT="$1" ;;
        --skip=*)      SKIP_OPT="${1#--skip=}" ;;
        --from)        shift; FROM_STEP="$1" ;;
        --from=*)      FROM_STEP="${1#--from=}" ;;
        *) echo "[ERROR] 不明なオプション: $1" >&2; exit 1 ;;
    esac
    shift
done

# ============================================================
# 実行するステップを決定
# ============================================================

# --steps と --skip の両方指定はエラー
if [ -n "${STEPS_OPT}" ] && [ -n "${SKIP_OPT}" ]; then
    echo "[ERROR] --steps と --skip は同時に指定できません" >&2
    exit 1
fi

# 実行対象ステップを配列に格納
declare -A RUN_STEPS  # 実行する場合は 1

if [ -n "${STEPS_OPT}" ]; then
    # --steps 指定: 指定されたステップのみ実行
    for id in $(echo "${STEPS_OPT}" | tr ',' ' '); do
        if [ -z "${STEP_SCRIPT[${id}]+x}" ]; then
            echo "[ERROR] 不明なステップ: ${id}  (有効: ${ALL_STEP_IDS[*]})" >&2
            exit 1
        fi
        RUN_STEPS[${id}]=1
    done
elif [ -n "${SKIP_OPT}" ]; then
    # --skip 指定: 指定されたステップを除いて全実行
    declare -A SKIP_STEPS
    for id in $(echo "${SKIP_OPT}" | tr ',' ' '); do
        if [ -z "${STEP_SCRIPT[${id}]+x}" ]; then
            echo "[ERROR] 不明なステップ: ${id}  (有効: ${ALL_STEP_IDS[*]})" >&2
            exit 1
        fi
        SKIP_STEPS[${id}]=1
    done
    for id in "${ALL_STEP_IDS[@]}"; do
        [ -z "${SKIP_STEPS[${id}]+x}" ] && RUN_STEPS[${id}]=1
    done
else
    # デフォルト: 全ステップ実行
    for id in "${ALL_STEP_IDS[@]}"; do
        RUN_STEPS[${id}]=1
    done
fi

# --from 指定: 指定ステップより前を除外
if [ -n "${FROM_STEP}" ]; then
    if [ -z "${STEP_SCRIPT[${FROM_STEP}]+x}" ]; then
        echo "[ERROR] 不明なステップ: ${FROM_STEP}  (有効: ${ALL_STEP_IDS[*]})" >&2
        exit 1
    fi
    FOUND_FROM=false
    for id in "${ALL_STEP_IDS[@]}"; do
        [ "${id}" = "${FROM_STEP}" ] && FOUND_FROM=true
        [ "${FOUND_FROM}" = false ] && unset "RUN_STEPS[${id}]"
    done
fi

# ============================================================
# --trial-dir が指定されている場合は最初から確定
# ============================================================
_TRIAL_DIR_RESOLVED=""
if [ -n "${TRIAL_DIR_OPT}" ]; then
    _TRIAL_DIR_RESOLVED="${TRIAL_DIR_OPT#--trial-dir }"
fi

# ============================================================
# 実行計画を表示
# ============================================================
echo "[run_all.sh] パイプライン開始  $(date '+%Y-%m-%d %H:%M:%S')"
echo "[run_all.sh] USE_SGE=${USE_SGE:-false}"
PLAN=()
for id in "${ALL_STEP_IDS[@]}"; do
    if [ -n "${RUN_STEPS[${id}]+x}" ]; then
        PLAN+=("${id}(${STEP_SCRIPT[${id}]})")
    fi
done
echo "[run_all.sh] 実行ステップ: ${PLAN[*]}"
echo ""

# ============================================================
# ステップ実行
# ============================================================
for STEP_ID in "${ALL_STEP_IDS[@]}"; do
    # 実行対象でなければスキップ
    if [ -z "${RUN_STEPS[${STEP_ID}]+x}" ]; then
        echo "[run_all.sh] Step ${STEP_ID} スキップ"
        continue
    fi

    SCRIPT="${STEP_SCRIPT[${STEP_ID}]}"

    echo "============================================================"
    echo "[run_all.sh] Step ${STEP_ID}: ${SCRIPT}"
    echo "============================================================"

    # trial_dir を引数として組み立て
    local_trial_arg="${TRIAL_DIR_OPT}"
    if [ -n "${_TRIAL_DIR_RESOLVED}" ]; then
        local_trial_arg="--trial-dir ${_TRIAL_DIR_RESOLVED}"
    fi

    bash "${SCRIPT_DIR}/${SCRIPT}" \
        ${local_trial_arg} \
        ${DRY_RUN_OPT} \
        ${FORCE_OPT}

    # step00 完了後に trial_dir を確定（以降のステップに引き渡す）
    if [ "${STEP_ID}" = "0" ] && [ -z "${_TRIAL_DIR_RESOLVED}" ]; then
        _PROJ_NAME="glm_lactic_ko_profile"
        _BASE_OUT="$(cd "${SCRIPT_DIR}/.." && pwd)/output/${_PROJ_NAME}"
        _TRIAL_DIR_RESOLVED="$(find "${_BASE_OUT}" -maxdepth 1 -type d -name '[0-9][0-9][0-9]' \
            2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "${_TRIAL_DIR_RESOLVED}" ]; then
            echo "[run_all.sh] trial_dir 確定: ${_TRIAL_DIR_RESOLVED}"
        fi
    fi

    echo ""
done

echo "[run_all.sh] 全ステップ完了  $(date '+%Y-%m-%d %H:%M:%S')"
if [ -n "${_TRIAL_DIR_RESOLVED}" ]; then
    echo "[run_all.sh] 結果: ${_TRIAL_DIR_RESOLVED}"
fi

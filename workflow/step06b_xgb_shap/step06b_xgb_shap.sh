#!/bin/bash
# ============================================================
# workflow/step06b_xgb_shap.sh — Step 6c/d: XGBoost + SHAP 解析
#
# ko_profile.csv × 各レスポンスCSV で XGBoost を学習し、
# SHAP 値および SHAP interaction 値を計算する。
# メモリ消費が大きい（64GB 推奨）。
#
# モード:
#   デフォルト (SPLIT_INFO_DIR=""):
#     データセットごとに1回実行
#     出力: ${TRIAL_DIR}/{dataset}/
#
#   共有 fold split モード (SPLIT_INFO_DIR 設定済み):
#     データセット × seed の全組み合わせを実行
#     出力: ${TRIAL_DIR}/{dataset}/seed{seed}/
#
# 使い方:
#   bash workflow/step06b_xgb_shap.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みジョブも再実行する
#
# SGE 使用時:
#   USE_SGE=true bash workflow/step06b_xgb_shap.sh --trial-dir ...
#   ※ メモリ 64GB を要求するため SGE 推奨
#
# 前提:
#   - step04_ko_profile.sh 実行済み（ko_profile.csv が存在する）
#   - config/pipeline.yaml が存在する
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
KO_PROFILE="${PROCESSED_DIR}/ko_profile.csv"
LOG_DIR="${TRIAL_DIR}/logs/06_xgb_shap"
SGE_LOG_DIR="${TRIAL_DIR}/logs/sge"
CPUS_PER_JOB="${SGE_CPUS_SHAP}"
MEM_PER_JOB="${SGE_MEM_SHAP}"

# ============================================================
# 前提チェック
# ============================================================
if [ ! -f "${KO_PROFILE}" ]; then
    log_error "ko_profile.csv が見つかりません: ${KO_PROFILE}"
    log_error "先に step04_ko_profile.sh を実行してください"
    exit 1
fi
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
    log_info "Step 6b XGBoost+SHAP  モード=ext  データセット=${#DATASETS[@]}  seeds=(${SEEDS})"
else
    USE_EXT=false
    log_info "Step 6b XGBoost+SHAP  モード=default  データセット=${#DATASETS[@]}"
fi

mkdir -p "${LOG_DIR}" "${SGE_LOG_DIR}"

# ============================================================
# SGE モード（メモリが大きいため SGE 推奨）
# ============================================================
if [ "${USE_SGE}" = true ]; then
    for DATASET in "${DATASETS[@]}"; do
        RESPONSE_CSV="${RESPONSE_CSV_DIR}/${DATASET}.csv"

        if [ "${USE_EXT}" = true ]; then
            for SEED in ${SEEDS}; do
                OUT_DIR="${TRIAL_DIR}/${DATASET}/seed${SEED}"
                SKIP_FILE="${OUT_DIR}/shap_values_xgb.csv"

                if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                    log_info "スキップ（既存）: ${DATASET}/seed${SEED}"; continue
                fi

                SPLIT_TSV="${SPLIT_INFO_DIR}/${DATASET}/${DATASET}_5fold_seed${SEED}.tsv"
                JOBSCRIPT="$(mktemp --suffix=.sh)"
                cat > "${JOBSCRIPT}" <<JOBEOF
#!/bin/bash
#$ -pe smp ${CPUS_PER_JOB}
#$ -l mem_user=${MEM_PER_JOB}
#$ -l h_vmem=${MEM_PER_JOB}
#$ -l mem_req=${MEM_PER_JOB}
#$ -cwd
#$ -o ${SGE_LOG_DIR}/
#$ -e ${SGE_LOG_DIR}/
set -euo pipefail
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV_ML}"
python "${SCRIPT_DIR}/06_xgb_shap.py" \\
    --ko-profile-csv "${KO_PROFILE}" \\
    --response-csv   "${RESPONSE_CSV}" \\
    --split-tsv      "${SPLIT_TSV}" \\
    --output-dir     "${OUT_DIR}" \\
    --min-samples-ko ${MIN_SAMPLES_KO} \\
    --random-state   ${RANDOM_STATE} \\
    --n-trials       ${N_TRIALS_XGB} \\
    --top-n-pairs    ${TOP_N_PAIRS} \\
    > "${LOG_DIR}/${DATASET}_seed${SEED}.log" 2>&1
JOBEOF
                if [ "${DRY_RUN}" = true ]; then
                    log_info "[DRY-RUN] qsub xgb_shap ${DATASET} seed${SEED}"
                    cat "${JOBSCRIPT}"; rm -f "${JOBSCRIPT}"; continue
                fi
                log_info "SGE 投入: ${DATASET} seed${SEED}"
                # shellcheck disable=SC2086
                qsub ${QSUB_EXTRA_OPTS} -N "xgbshap_${DATASET}_s${SEED}" "${JOBSCRIPT}"
                rm -f "${JOBSCRIPT}"
            done

        else
            OUT_DIR="${TRIAL_DIR}/${DATASET}"
            SKIP_FILE="${OUT_DIR}/shap_values_xgb.csv"

            if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                log_info "スキップ（既存）: ${DATASET}"; continue
            fi

            JOBSCRIPT="$(mktemp --suffix=.sh)"
            cat > "${JOBSCRIPT}" <<JOBEOF
#!/bin/bash
#$ -pe smp ${CPUS_PER_JOB}
#$ -l mem_user=${MEM_PER_JOB}
#$ -l h_vmem=${MEM_PER_JOB}
#$ -l mem_req=${MEM_PER_JOB}
#$ -cwd
#$ -o ${SGE_LOG_DIR}/
#$ -e ${SGE_LOG_DIR}/
set -euo pipefail
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV_ML}"
python "${SCRIPT_DIR}/06_xgb_shap.py" \\
    --ko-profile-csv "${KO_PROFILE}" \\
    --response-csv   "${RESPONSE_CSV}" \\
    --output-dir     "${OUT_DIR}" \\
    --min-samples-ko ${MIN_SAMPLES_KO} \\
    --random-state   ${RANDOM_STATE} \\
    --n-trials       ${N_TRIALS_XGB} \\
    --top-n-pairs    ${TOP_N_PAIRS} \\
    > "${LOG_DIR}/${DATASET}.log" 2>&1
JOBEOF
            if [ "${DRY_RUN}" = true ]; then
                log_info "[DRY-RUN] qsub xgb_shap ${DATASET}"
                cat "${JOBSCRIPT}"; rm -f "${JOBSCRIPT}"; continue
            fi
            log_info "SGE 投入: ${DATASET}"
            # shellcheck disable=SC2086
            qsub ${QSUB_EXTRA_OPTS} -N "xgbshap_${DATASET}" "${JOBSCRIPT}"
            rm -f "${JOBSCRIPT}"
        fi
    done

    if [ "${DRY_RUN}" = false ]; then
        log_info "SGE ジョブの完了を待機中..."
        qwait "xgbshap_*" 2>/dev/null || true
        log_info "Step 6b 完了（SGE）"
    fi
    exit 0
fi

# ============================================================
# ローカル実行
# ============================================================
activate_conda "${CONDA_ENV_ML}"

RUN_COUNT=0
SKIP_COUNT=0

for DATASET in "${DATASETS[@]}"; do
    RESPONSE_CSV="${RESPONSE_CSV_DIR}/${DATASET}.csv"

    if [ "${USE_EXT}" = true ]; then
        for SEED in ${SEEDS}; do
            OUT_DIR="${TRIAL_DIR}/${DATASET}/seed${SEED}"
            SKIP_FILE="${OUT_DIR}/shap_values_xgb.csv"
            SPLIT_TSV="${SPLIT_INFO_DIR}/${DATASET}/${DATASET}_5fold_seed${SEED}.tsv"

            if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                log_info "スキップ（既存）: ${DATASET}/seed${SEED}"
                SKIP_COUNT=$((SKIP_COUNT + 1)); continue
            fi
            if [ "${DRY_RUN}" = true ]; then
                log_info "[DRY-RUN] xgb_shap ${DATASET} seed${SEED}"; continue
            fi

            log_info "XGBoost+SHAP: ${DATASET} seed${SEED}"
            mkdir -p "${OUT_DIR}"
            python "${SCRIPT_DIR}/06_xgb_shap.py" \
                --ko-profile-csv "${KO_PROFILE}" \
                --response-csv   "${RESPONSE_CSV}" \
                --split-tsv      "${SPLIT_TSV}" \
                --output-dir     "${OUT_DIR}" \
                --min-samples-ko "${MIN_SAMPLES_KO}" \
                --random-state   "${RANDOM_STATE}" \
                --n-trials       "${N_TRIALS_XGB}" \
                --top-n-pairs    "${TOP_N_PAIRS}" \
                > "${LOG_DIR}/${DATASET}_seed${SEED}.log" 2>&1
            RUN_COUNT=$((RUN_COUNT + 1))
        done
    else
        OUT_DIR="${TRIAL_DIR}/${DATASET}"
        SKIP_FILE="${OUT_DIR}/shap_values_xgb.csv"

        if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
            log_info "スキップ（既存）: ${DATASET}"
            SKIP_COUNT=$((SKIP_COUNT + 1)); continue
        fi
        if [ "${DRY_RUN}" = true ]; then
            log_info "[DRY-RUN] xgb_shap ${DATASET}"; continue
        fi

        log_info "XGBoost+SHAP: ${DATASET}"
        mkdir -p "${OUT_DIR}"
        python "${SCRIPT_DIR}/06_xgb_shap.py" \
            --ko-profile-csv "${KO_PROFILE}" \
            --response-csv   "${RESPONSE_CSV}" \
            --output-dir     "${OUT_DIR}" \
            --min-samples-ko "${MIN_SAMPLES_KO}" \
            --random-state   "${RANDOM_STATE}" \
            --n-trials       "${N_TRIALS_XGB}" \
            --top-n-pairs    "${TOP_N_PAIRS}" \
            > "${LOG_DIR}/${DATASET}.log" 2>&1
        RUN_COUNT=$((RUN_COUNT + 1))
    fi
done

log_info "Step 6b XGBoost+SHAP 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}"

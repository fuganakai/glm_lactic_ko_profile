#!/bin/bash
# ============================================================
# workflow/step05_bench.sh — Step 5: モデル学習（per-dataset）
#
# ko_profile.csv × 各レスポンスCSV で Lasso/Ridge/RF/MLP を学習する。
#
# モード:
#   デフォルト (SPLIT_INFO_DIR=""):
#     データセットごとに内部 KFold で1回実行
#     出力: ${TRIAL_DIR}/{dataset}/
#
#   共有 fold split モード (SPLIT_INFO_DIR 設定済み):
#     データセット × seed の全組み合わせを実行
#     出力: ${TRIAL_DIR}/{dataset}/seed{seed}/
#
# 使い方:
#   bash workflow/step05_bench.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みジョブも再実行する
#
# SGE 使用時:
#   USE_SGE=true bash workflow/step05_bench.sh --trial-dir ...
#
# 前提:
#   - step04_ko_profile.sh 実行済み（ko_profile.csv が存在する）
#   - config/pipeline.yaml が存在する
#
# 出力:
#   ${TRIAL_DIR}/{dataset}/r2_scores.csv  (デフォルト)
#   ${TRIAL_DIR}/{dataset}/seed{seed}/r2_scores.csv  (ext モード)
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
LOG_DIR="${TRIAL_DIR}/logs/05_bench_models"
SGE_LOG_DIR="${TRIAL_DIR}/logs/sge"
CPUS_PER_JOB="${SGE_CPUS_BENCH}"
MEM_PER_JOB="${SGE_MEM_BENCH}"

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

# データセット一覧を取得
mapfile -t DATASETS < <(find "${RESPONSE_CSV_DIR}" -name "*.csv" | xargs -I{} basename {} .csv | sort)
if [ ${#DATASETS[@]} -eq 0 ]; then
    log_error "RESPONSE_CSV_DIR に .csv が見つかりません: ${RESPONSE_CSV_DIR}"
    exit 1
fi

# モード判定
if [ -n "${SPLIT_INFO_DIR}" ]; then
    USE_EXT=true
    log_info "Step 5: モデル学習  モード=ext  データセット=${#DATASETS[@]}  seeds=(${SEEDS})"
else
    USE_EXT=false
    log_info "Step 5: モデル学習  モード=default  データセット=${#DATASETS[@]}"
fi

mkdir -p "${LOG_DIR}" "${SGE_LOG_DIR}"

# ============================================================
# SGE モード
# ============================================================
if [ "${USE_SGE}" = true ]; then
    JOB_IDS=()

    for DATASET in "${DATASETS[@]}"; do
        RESPONSE_CSV="${RESPONSE_CSV_DIR}/${DATASET}.csv"

        if [ "${USE_EXT}" = true ]; then
            # ext モード: seed ごとにジョブ投入
            for SEED in ${SEEDS}; do
                OUT_DIR="${TRIAL_DIR}/${DATASET}/seed${SEED}"
                SKIP_FILE="${OUT_DIR}/r2_scores.csv"

                if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                    log_info "スキップ（既存）: ${SKIP_FILE}"
                    continue
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
python "${SCRIPT_DIR}/05_bench_models.py" \\
    --ko-profile-csv "${KO_PROFILE}" \\
    --response-csv   "${RESPONSE_CSV}" \\
    --split-tsv      "${SPLIT_TSV}" \\
    --output-dir     "${OUT_DIR}" \\
    --model          all \\
    --random-state   ${RANDOM_STATE} \\
    --n-trials-rf    ${N_TRIALS_RF} \\
    --n-trials-mlp   ${N_TRIALS_MLP} \\
    --n-trials-xgb   ${N_TRIALS_XGB} \\
    > "${LOG_DIR}/${DATASET}_seed${SEED}.log" 2>&1
JOBEOF
                if [ "${DRY_RUN}" = true ]; then
                    log_info "[DRY-RUN] qsub bench ${DATASET} seed${SEED}"
                    cat "${JOBSCRIPT}"; rm -f "${JOBSCRIPT}"; continue
                fi
                log_info "SGE 投入: ${DATASET} seed${SEED}"
                # shellcheck disable=SC2086
                SUBMITTED=$(qsub ${QSUB_EXTRA_OPTS} -N "bench_${DATASET}_s${SEED}" "${JOBSCRIPT}" 2>&1)
                rm -f "${JOBSCRIPT}"
                JID=$(echo "${SUBMITTED}" | grep -oP 'Your job \K[0-9]+' || true)
                [ -n "${JID}" ] && JOB_IDS+=("${JID}")
            done

        else
            # デフォルトモード: データセットごとに1ジョブ
            OUT_DIR="${TRIAL_DIR}/${DATASET}"
            SKIP_FILE="${OUT_DIR}/r2_scores.csv"

            if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                log_info "スキップ（既存）: ${SKIP_FILE}"
                continue
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
python "${SCRIPT_DIR}/05_bench_models.py" \\
    --ko-profile-csv "${KO_PROFILE}" \\
    --response-csv   "${RESPONSE_CSV}" \\
    --output-dir     "${OUT_DIR}" \\
    --model          all \\
    --random-state   ${RANDOM_STATE} \\
    --n-trials-rf    ${N_TRIALS_RF} \\
    --n-trials-mlp   ${N_TRIALS_MLP} \\
    --n-trials-xgb   ${N_TRIALS_XGB} \\
    > "${LOG_DIR}/${DATASET}.log" 2>&1
JOBEOF
            if [ "${DRY_RUN}" = true ]; then
                log_info "[DRY-RUN] qsub bench ${DATASET}"
                cat "${JOBSCRIPT}"; rm -f "${JOBSCRIPT}"; continue
            fi
            log_info "SGE 投入: ${DATASET}"
            # shellcheck disable=SC2086
            SUBMITTED=$(qsub ${QSUB_EXTRA_OPTS} -N "bench_${DATASET}" "${JOBSCRIPT}" 2>&1)
            rm -f "${JOBSCRIPT}"
            JID=$(echo "${SUBMITTED}" | grep -oP 'Your job \K[0-9]+' || true)
            [ -n "${JID}" ] && JOB_IDS+=("${JID}")
        fi
    done

    # SGEジョブの完了を待つ（hold_jid + sync y で確実に待機）
    if [ "${DRY_RUN}" = false ] && [ ${#JOB_IDS[@]} -gt 0 ]; then
        log_info "SGE ジョブの完了を待機中... (job IDs: ${JOB_IDS[*]})"
        HOLD_LIST=$(IFS=,; echo "${JOB_IDS[*]}")
        SYNC_SCRIPT="$(mktemp --suffix=.sh)"
        printf '#!/bin/sh\nexit 0\n' > "${SYNC_SCRIPT}"
        # shellcheck disable=SC2086
        qsub ${QSUB_EXTRA_OPTS} \
            -hold_jid "${HOLD_LIST}" \
            -sync y \
            -N "bench_sync" \
            "${SYNC_SCRIPT}" >/dev/null 2>&1 || true
        rm -f "${SYNC_SCRIPT}"
        log_info "Step 5 完了（SGE）"
    elif [ "${DRY_RUN}" = false ]; then
        log_info "Step 5: 投入したジョブなし（全スキップ）"
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
            SKIP_FILE="${OUT_DIR}/r2_scores.csv"
            SPLIT_TSV="${SPLIT_INFO_DIR}/${DATASET}/${DATASET}_5fold_seed${SEED}.tsv"

            if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
                log_info "スキップ（既存）: ${DATASET}/seed${SEED}"
                SKIP_COUNT=$((SKIP_COUNT + 1)); continue
            fi
            if [ "${DRY_RUN}" = true ]; then
                log_info "[DRY-RUN] bench ${DATASET} seed${SEED}"; continue
            fi

            log_info "学習: ${DATASET} seed${SEED}"
            mkdir -p "${OUT_DIR}"
            python "${SCRIPT_DIR}/05_bench_models.py" \
                --ko-profile-csv "${KO_PROFILE}" \
                --response-csv   "${RESPONSE_CSV}" \
                --split-tsv      "${SPLIT_TSV}" \
                --output-dir     "${OUT_DIR}" \
                --model          all \
                --random-state   "${RANDOM_STATE}" \
                --n-trials-rf    "${N_TRIALS_RF}" \
                --n-trials-mlp   "${N_TRIALS_MLP}" \
                --n-trials-xgb   "${N_TRIALS_XGB}" \
                > "${LOG_DIR}/${DATASET}_seed${SEED}.log" 2>&1
            RUN_COUNT=$((RUN_COUNT + 1))
        done
    else
        OUT_DIR="${TRIAL_DIR}/${DATASET}"
        SKIP_FILE="${OUT_DIR}/r2_scores.csv"

        if [ -f "${SKIP_FILE}" ] && [ "${FORCE}" = false ]; then
            log_info "スキップ（既存）: ${DATASET}"
            SKIP_COUNT=$((SKIP_COUNT + 1)); continue
        fi
        if [ "${DRY_RUN}" = true ]; then
            log_info "[DRY-RUN] bench ${DATASET}"; continue
        fi

        log_info "学習: ${DATASET}"
        mkdir -p "${OUT_DIR}"
        python "${SCRIPT_DIR}/05_bench_models.py" \
            --ko-profile-csv "${KO_PROFILE}" \
            --response-csv   "${RESPONSE_CSV}" \
            --output-dir     "${OUT_DIR}" \
            --model          all \
            --random-state   "${RANDOM_STATE}" \
            --n-trials-rf    "${N_TRIALS_RF}" \
            --n-trials-mlp   "${N_TRIALS_MLP}" \
            --n-trials-xgb   "${N_TRIALS_XGB}" \
            > "${LOG_DIR}/${DATASET}.log" 2>&1
        RUN_COUNT=$((RUN_COUNT + 1))
    fi
done

log_info "Step 5 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}"

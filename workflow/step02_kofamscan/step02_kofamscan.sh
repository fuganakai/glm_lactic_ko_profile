#!/bin/bash
# ============================================================
# workflow/step02_kofamscan.sh — Step 2: KoFamScan（全サンプル）
#
# Prokka が生成した .faa に対して KoFamScan を実行し、
# KO アノテーション結果 (.txt) を生成する。
#
# 使い方:
#   bash workflow/step02_kofamscan.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みサンプルも再実行する
#
# SGE 使用時:
#   USE_SGE=true bash workflow/step02_kofamscan.sh --trial-dir ...
#
# 前提:
#   - step01_prokka.sh 実行済み（prokka_out/{sample}/{sample}.faa が存在する）
#   - config/pipeline.yaml が存在する
#
# 出力:
#   data/glm_lactic_ko_profile/processed/kofamscan_out/{sample}.txt
#   ${TRIAL_DIR}/logs/02_kofamscan/{sample}.log
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
PROKKA_OUT_DIR="${PROCESSED_DIR}/prokka_out"
KOFAMSCAN_OUT_DIR="${PROCESSED_DIR}/kofamscan_out"
LOG_DIR="${TRIAL_DIR}/logs/02_kofamscan"
CPUS_PER_JOB=8   # SGE: cluster.yaml の run_kofamscan と合わせる

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

log_info "Step 2: KoFamScan  サンプル数: ${#SAMPLES[@]}"
log_info "  prokka_out: ${PROKKA_OUT_DIR}"
log_info "  出力先:     ${KOFAMSCAN_OUT_DIR}"
log_info "  ログ:       ${LOG_DIR}"
log_info "  USE_SGE:    ${USE_SGE}"

mkdir -p "${KOFAMSCAN_OUT_DIR}" "${LOG_DIR}"

# ============================================================
# SGE: job array 用の一時スクリプトを生成して投入
# ============================================================
if [ "${USE_SGE}" = true ]; then
    SAMPLE_LIST_TMP="$(mktemp)"
    printf '%s\n' "${SAMPLES[@]}" > "${SAMPLE_LIST_TMP}"
    N=${#SAMPLES[@]}

    SGE_LOG_DIR="${TRIAL_DIR}/logs/sge"
    mkdir -p "${SGE_LOG_DIR}"

    JOBSCRIPT="$(mktemp --suffix=.sh)"
    cat > "${JOBSCRIPT}" <<JOBEOF
#!/bin/bash
#$ -pe smp ${CPUS_PER_JOB}
#$ -l mem=16G
#$ -cwd
#$ -o ${SGE_LOG_DIR}/
#$ -e ${SGE_LOG_DIR}/
set -euo pipefail
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV_KOFAM}"

SAMPLE=\$(sed -n "\${SGE_TASK_ID}p" "${SAMPLE_LIST_TMP}")
FAA="${PROKKA_OUT_DIR}/\${SAMPLE}/\${SAMPLE}.faa"
OUTPUT="${KOFAMSCAN_OUT_DIR}/\${SAMPLE}.txt"
LOG_FILE="${LOG_DIR}/\${SAMPLE}.log"

bash "${SCRIPT_DIR}/02_run_kofamscan.sh" \\
    --faa           "\${FAA}" \\
    --sample        "\${SAMPLE}" \\
    --kofamscan-dir "${KOFAMSCAN_DIR}" \\
    --ko-list       "${KOFAMSCAN_KO_LIST}" \\
    --profiles      "${KOFAMSCAN_PROFILES}" \\
    --output        "\${OUTPUT}" \\
    --cpus          ${CPUS_PER_JOB} \\
    > "\${LOG_FILE}" 2>&1
JOBEOF

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] qsub -t 1-${N} ${JOBSCRIPT}"
        cat "${JOBSCRIPT}"
        rm -f "${JOBSCRIPT}" "${SAMPLE_LIST_TMP}"
        exit 0
    fi

    log_info "SGE job array 投入: 1-${N}  (${N} サンプル)"
    # shellcheck disable=SC2086
    qsub ${QSUB_EXTRA_OPTS} \
        -t "1-${N}" \
        -sync y \
        "${JOBSCRIPT}"

    rm -f "${JOBSCRIPT}" "${SAMPLE_LIST_TMP}"
    log_info "Step 2 完了（SGE）"
    exit 0
fi

# ============================================================
# ローカル実行
# ============================================================
activate_conda "${CONDA_ENV_KOFAM}"

SKIP_COUNT=0
RUN_COUNT=0

for SAMPLE in "${SAMPLES[@]}"; do
    FAA="${PROKKA_OUT_DIR}/${SAMPLE}/${SAMPLE}.faa"
    OUTPUT="${KOFAMSCAN_OUT_DIR}/${SAMPLE}.txt"
    LOG_FILE="${LOG_DIR}/${SAMPLE}.log"

    if [ ! -f "${FAA}" ]; then
        log_warn "FAA が見つかりません、スキップ: ${FAA}"
        continue
    fi

    if should_skip "${OUTPUT}"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] kofamscan ${SAMPLE}"
        continue
    fi

    log_info "KoFamScan 実行: ${SAMPLE}"

    bash "${SCRIPT_DIR}/02_run_kofamscan.sh" \
        --faa           "${FAA}" \
        --sample        "${SAMPLE}" \
        --kofamscan-dir "${KOFAMSCAN_DIR}" \
        --ko-list       "${KOFAMSCAN_KO_LIST}" \
        --profiles      "${KOFAMSCAN_PROFILES}" \
        --output        "${OUTPUT}" \
        --cpus          "${CPUS_PER_JOB}" \
        > "${LOG_FILE}" 2>&1

    RUN_COUNT=$((RUN_COUNT + 1))
done

log_info "Step 2 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}"

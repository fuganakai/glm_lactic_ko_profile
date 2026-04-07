#!/bin/bash
# ============================================================
# workflow/step01_prokka.sh — Step 1: Prokka（全サンプル）
#
# filtered_samples.txt に列挙されたサンプルに対して Prokka を実行し、
# タンパク質配列 (.faa) を生成する。
#
# 使い方:
#   bash workflow/step01_prokka.sh [options]
#
# オプション:
#   --trial-dir <path>   試行ディレクトリを指定（省略時は自動採番）
#   --dry-run            コマンドを表示するだけで実行しない
#   --force              出力済みサンプルも再実行する
#
# SGE 使用時は環境変数で制御:
#   USE_SGE=true bash workflow/step01_prokka.sh
#   QSUB_EXTRA_OPTS="-l d_rt=24:00:00" USE_SGE=true bash workflow/step01_prokka.sh
#
# 前提:
#   - step00_filter.sh 実行済み（filtered_samples.txt が存在する）
#   - config/pipeline.yaml が存在する
#
# 出力:
#   data/glm_lactic_ko_profile/processed/prokka_out/{sample}/{sample}.faa
#   ${TRIAL_DIR}/logs/01_prokka/{sample}.log
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
LOG_DIR="${TRIAL_DIR}/logs/01_prokka"
CPUS_PER_JOB="${SGE_CPUS_PROKKA}"
MEM_PER_JOB="${SGE_MEM_PROKKA}"

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

log_info "Step 1: Prokka  サンプル数: ${#SAMPLES[@]}"
log_info "  genome_dir:  ${GENOME_DIR}"
log_info "  出力先:      ${PROKKA_OUT_DIR}"
log_info "  ログ:        ${LOG_DIR}"
log_info "  USE_SGE:     ${USE_SGE}"

mkdir -p "${PROKKA_OUT_DIR}" "${LOG_DIR}"

# ============================================================
# conda 環境をアクティベート（ローカル実行時のみ必要）
# SGE 実行時は各ジョブの qsub スクリプト内でアクティベートする
# ============================================================
if [ "${USE_SGE}" = false ] && [ "${DRY_RUN}" = false ]; then
    activate_conda "${CONDA_ENV_PROKKA}"
fi

# ============================================================
# SGE: job array 用の一時スクリプトを生成して投入
# ============================================================
if [ "${USE_SGE}" = true ]; then
    # サンプルリストを一時ファイルに書く（job array のインデックスで参照）
    SAMPLE_LIST_TMP="$(mktemp)"
    printf '%s\n' "${SAMPLES[@]}" > "${SAMPLE_LIST_TMP}"
    N=${#SAMPLES[@]}

    SGE_LOG_DIR="${TRIAL_DIR}/logs/sge"
    mkdir -p "${SGE_LOG_DIR}"

    # job array スクリプト
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
conda activate "${CONDA_ENV_PROKKA}"

SAMPLE=\$(sed -n "\${SGE_TASK_ID}p" "${SAMPLE_LIST_TMP}")
FNA="${GENOME_DIR}/\${SAMPLE}.fna"
OUT_DIR="${PROKKA_OUT_DIR}/\${SAMPLE}"
LOG_FILE="${LOG_DIR}/\${SAMPLE}.log"

bash "${SCRIPT_DIR}/01_run_prokka.sh" \\
    --fna        "\${FNA}" \\
    --sample     "\${SAMPLE}" \\
    --output-dir "\${OUT_DIR}" \\
    --cpus       ${CPUS_PER_JOB} \\
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
    log_info "Step 1 完了（SGE）"
    exit 0
fi

# ============================================================
# ローカル実行: サンプルを順番に処理
# ============================================================
SKIP_COUNT=0
RUN_COUNT=0

for SAMPLE in "${SAMPLES[@]}"; do
    FNA="${GENOME_DIR}/${SAMPLE}.fna"
    OUT_DIR="${PROKKA_OUT_DIR}/${SAMPLE}"
    FAA="${OUT_DIR}/${SAMPLE}.faa"
    LOG_FILE="${LOG_DIR}/${SAMPLE}.log"

    if [ ! -f "${FNA}" ]; then
        log_warn "FNA が見つかりません、スキップ: ${FNA}"
        continue
    fi

    if should_skip "${FAA}"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] prokka ${SAMPLE}"
        continue
    fi

    log_info "Prokka 実行: ${SAMPLE}"
    mkdir -p "${OUT_DIR}"

    bash "${SCRIPT_DIR}/01_run_prokka.sh" \
        --fna        "${FNA}" \
        --sample     "${SAMPLE}" \
        --output-dir "${OUT_DIR}" \
        --cpus       "${CPUS_PER_JOB}" \
        > "${LOG_FILE}" 2>&1

    RUN_COUNT=$((RUN_COUNT + 1))
done

log_info "Step 1 完了: 実行=${RUN_COUNT}  スキップ=${SKIP_COUNT}"

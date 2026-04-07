#!/bin/bash
# ============================================================
# workflow/submit.sh — run_all.sh を qsub で投入するラッパー
#
# trial_dir を事前に確定してから run_all.sh 自体を qsub に投げる。
# run_all.sh の stdout/stderr は ${TRIAL_DIR}/run_all.log に一本化する。
#
# 使い方:
#   bash workflow/submit.sh [options]
#
# オプション:
#   --wall-time <HH:MM:SS>  SGE のウォールタイム制限 (default: 72:00:00)
#   --sync                  qsub の完了を待ってから返る
#   --dry-run               投入コマンドを表示するだけで実行しない
#
#   以下は run_all.sh にそのまま渡される:
#   --skip  <list>          省くステップ (例: --skip 6b)
#   --steps <list>          実行するステップ (例: --steps 5,6,7,8)
#   --from  <step>          指定ステップから再開
#   --force                 出力済みファイルを上書き
#
# SGE 環境変数:
#   QSUB_EXTRA_OPTS         qsub に追加で渡すオプション
#
# ログの場所:
#   ${TRIAL_DIR}/run_all.log   run_all.sh 自体の stdout+stderr
#   ${TRIAL_DIR}/logs/sge/     各ステップのSGEジョブログ
#   ${TRIAL_DIR}/logs/stepXX/  各ステップのコマンドログ
#
# 注意:
#   run_all.sh 内で qsub を使う（-sync y）ため、
#   クラスタがジョブ内からの qsub 投入を許可している必要があります。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# オプション解析
# ============================================================
SYNC_OPT=""
DRY_RUN=false
PASSTHROUGH_ARGS=()

while [ $# -gt 0 ]; do
    case $1 in
        --sync)         SYNC_OPT="-sync y" ;;
        --dry-run)      DRY_RUN=true; PASSTHROUGH_ARGS+=("--dry-run") ;;
        # run_all.sh へのパススルー
        --skip|--steps|--from)
            PASSTHROUGH_ARGS+=("$1" "$2"); shift ;;
        --skip=*|--steps=*|--from=*)
            PASSTHROUGH_ARGS+=("$1") ;;
        --force)
            PASSTHROUGH_ARGS+=("$1") ;;
        *) echo "[ERROR] 不明なオプション: $1" >&2; exit 1 ;;
    esac
    shift
done

# ============================================================
# 設定読み込み・trial_dir の確定（qsub 投入前に決める）
# ============================================================
load_config

TRIAL_DIR="$(cd "${PROJECT_ROOT}" && new-trial-dir)"
echo "[submit.sh] trial_dir: ${TRIAL_DIR}"

LOG_FILE="${TRIAL_DIR}/run_all.log"
SGE_LOG_DIR="${TRIAL_DIR}/logs/sge"
mkdir -p "${SGE_LOG_DIR}"

# ============================================================
# qsub ジョブスクリプトを生成
# ============================================================
JOBSCRIPT="$(mktemp --suffix=.sh)"

# PASSTHROUGH_ARGS を安全にクォートして埋め込む
PASSTHROUGH_STR=""
for arg in "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"; do
    PASSTHROUGH_STR="${PASSTHROUGH_STR} $(printf '%q' "${arg}")"
done

cat > "${JOBSCRIPT}" <<JOBEOF
#!/bin/sh
#$ -cwd
#$ -pe smp 1
#$ -l mem_user=4G
#$ -l h_vmem=4G
#$ -l mem_req=4G
#$ -o ${LOG_FILE}
#$ -e ${LOG_FILE}.err
set -euo pipefail

start_time=\$(date +%s)
echo "[run_all] 開始: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "[run_all] ノード: \$(hostname)"
echo "[run_all] trial_dir: ${TRIAL_DIR}"

bash "${SCRIPT_DIR}/run_all.sh" \\
    --trial-dir "${TRIAL_DIR}" \\
    ${PASSTHROUGH_STR}

end_time=\$(date +%s)
echo "[run_all] 完了: \$(date '+%Y-%m-%d %H:%M:%S')  (所要時間: \$((end_time - start_time)) 秒)"
JOBEOF

# ============================================================
# 投入（または dry-run 表示）
# ============================================================
if [ "${DRY_RUN}" = true ]; then
    echo "[submit.sh] [DRY-RUN] 以下のスクリプトを qsub に投入します:"
    echo "------------------------------------------------------------"
    cat "${JOBSCRIPT}"
    echo "------------------------------------------------------------"
    echo "[submit.sh] [DRY-RUN] qsub コマンド:"
    echo "  qsub ${QSUB_EXTRA_OPTS:-} -N run_all ${SYNC_OPT} ${JOBSCRIPT}"
    rm -f "${JOBSCRIPT}"
    exit 0
fi

echo "[submit.sh] qsub 投入中..."
# shellcheck disable=SC2086
QSUB_OUTPUT=$(qsub ${QSUB_EXTRA_OPTS:-} \
    -N "run_all" \
    ${SYNC_OPT} \
    "${JOBSCRIPT}" 2>&1)
QSUB_EXIT=$?

rm -f "${JOBSCRIPT}"

if [ "${QSUB_EXIT}" -ne 0 ]; then
    echo "[ERROR] qsub 失敗:" >&2
    echo "${QSUB_OUTPUT}" >&2
    exit 1
fi

JOB_ID=$(echo "${QSUB_OUTPUT}" | grep -oP 'Your job \K[0-9]+' || echo "unknown")

echo ""
echo "============================================================"
echo "[submit.sh] 投入完了"
echo "  ジョブID:   ${JOB_ID}"
echo "  trial_dir:  ${TRIAL_DIR}"
echo "  メインログ: ${LOG_FILE}"
echo "  SGEログ:    ${SGE_LOG_DIR}/"
echo "============================================================"
echo ""
echo "進捗確認:"
echo "  tail -f ${LOG_FILE}"
echo ""
echo "ジョブ状態確認:"
echo "  qstat -j ${JOB_ID}"

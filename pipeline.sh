#!/bin/bash
# ============================================================
# pipeline.sh  —  KO profile → Lasso/Ridge/RF 予測パイプライン
#
# 入力: {genome_dir}/{sample}.fna
# フロー: Prokka → KoFamScan → KO profile → Lasso/Ridge/RF → 可視化
#
# 使い方:
#   bash pipeline.sh              # 通常実行
#   bash pipeline.sh --dry-run    # 実行内容の確認のみ
#   bash pipeline.sh --dag        # 依存関係グラフを dag.png に出力
# ============================================================
set -euo pipefail

# ============================================================
# [1] ユーザー設定 — ここだけ編集する
# ============================================================

# --- 入力データ ---
GENOME_DIR="data/genomes"              # {sample}.fna が入ったディレクトリ ← 要変更
IL12_CSV="data/il12_reporter.csv"      # ← 要変更

# --- KoFamScan データベース ---
KOFAMSCAN_DIR="/path/to/kofamscan/bin"      # ← 要変更
KOFAMSCAN_KO_LIST="/path/to/kofamscan/ko_list"   # ← 要変更
KOFAMSCAN_PROFILES="/path/to/kofamscan/profiles" # ← 要変更

# --- conda 環境 ---
CONDA_BASE="/home/nakai/miniforge3"    # ← 要変更
CONDA_ENV_PROKKA="prokka_env"          # ← 要変更
CONDA_ENV_KOFAM="kofam_env"           # ← 要変更
CONDA_ENV_ML="ml_env"                  # ← 要変更

# --- SGE設定 (ローカル実行なら USE_SGE=false のまま) ---
USE_SGE=false
MAX_JOBS=20
# qsub に追加で渡すオプション (空でも可)
# 例: QSUB_EXTRA_OPTS="-l d_rt=24:00:00"  # 実行時間制限
#     QSUB_EXTRA_OPTS="-m e -M your@email"  # 完了メール
QSUB_EXTRA_OPTS=""

# --- パラメータ ---
MIN_SAMPLES_KO=5
MIN_GENOME_LEN=160000   # サンプルフィルタ: 最小ゲノム長 (bp)
RANDOM_STATE=42
N_ESTIMATORS=500        # RandomForest の木の数 (Optuna 非使用時のフォールバック)
N_TRIALS_RF=50          # RandomForest の Optuna チューニング試行数
N_TRIALS_MLP=80         # MLP の Optuna チューニング試行数
TOP_N_KO=20             # 可視化で表示する上位KO数
RESULTS_DIR="results/models"

# ============================================================
# [2] 引数処理
# ============================================================
DRY_RUN=false
SHOW_DAG=false

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --dag)     SHOW_DAG=true ;;
        *) echo "[ERROR] 不明なオプション: $arg" >&2; exit 1 ;;
    esac
done

# ============================================================
# [3] 初期チェック
# ============================================================
if [ ! -d "$GENOME_DIR" ]; then
    echo "[ERROR] GENOME_DIR が見つかりません: $GENOME_DIR" >&2; exit 1
fi
if [ ! -f "$IL12_CSV" ]; then
    echo "[ERROR] IL12_CSV が見つかりません: $IL12_CSV" >&2; exit 1
fi

mkdir -p config logs

# ============================================================
# [4] config/pipeline.yaml を生成
# ============================================================
cat > config/pipeline.yaml <<EOF
genome_dir:           "${GENOME_DIR}"
il12_csv:             "${IL12_CSV}"
kofamscan_dir:        "${KOFAMSCAN_DIR}"
kofamscan_ko_list:    "${KOFAMSCAN_KO_LIST}"
kofamscan_profiles:   "${KOFAMSCAN_PROFILES}"
conda_base:           "${CONDA_BASE}"
conda_env_prokka:     "${CONDA_ENV_PROKKA}"
conda_env_kofam:      "${CONDA_ENV_KOFAM}"
conda_env_ml:         "${CONDA_ENV_ML}"
min_samples_ko:       ${MIN_SAMPLES_KO}
min_genome_len:       ${MIN_GENOME_LEN}
random_state:         ${RANDOM_STATE}
n_estimators:         ${N_ESTIMATORS}
n_trials_rf:          ${N_TRIALS_RF}
n_trials_mlp:         ${N_TRIALS_MLP}
top_n_ko:             ${TOP_N_KO}
results_dir:          "${RESULTS_DIR}"
EOF

echo "[pipeline.sh] config/pipeline.yaml を生成しました"
echo "[pipeline.sh] 結果出力先: ${RESULTS_DIR}"

# ============================================================
# [5] conda ml_env をアクティベート (snakemake はここに入っている)
# ============================================================
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV_ML}"

# ============================================================
# [6] Step 0: サンプルフィルタリング (Snakemake より先に実行)
#     filtered_samples.txt を生成してから Snakemake に渡す
# ============================================================
if [ "$SHOW_DAG" = false ] && [ "$DRY_RUN" = false ]; then
    echo "[pipeline.sh] Step 0: サンプルフィルタリング"
    python scripts/00_filter_samples.py \
        --genome-dir     "${GENOME_DIR}" \
        --il12-csv       "${IL12_CSV}" \
        --min-genome-len "${MIN_GENOME_LEN}" \
        --output         data/filtered_samples.txt
fi

# ============================================================
# [7] DAG可視化モード
# ============================================================
if [ "$SHOW_DAG" = true ]; then
    snakemake --dag --snakefile Snakefile --configfile config/pipeline.yaml \
    | dot -Tpng > dag.png
    echo "[pipeline.sh] dag.png を生成しました"
    exit 0
fi

# ============================================================
# [8] 実行
# ============================================================
if [ "$USE_SGE" = true ]; then
    SNAKEMAKE_CMD="snakemake \
        --snakefile Snakefile \
        --configfile config/pipeline.yaml \
        --cluster-config config/cluster.yaml \
        --cluster 'qsub ${QSUB_EXTRA_OPTS} {cluster.options} -cwd -o logs/ -e logs/' \
        --jobs ${MAX_JOBS} \
        --latency-wait 60 \
        --keep-going \
        --rerun-incomplete \
        --scheduler greedy \
        --printshellcmds"
else
    SNAKEMAKE_CMD="snakemake \
        --snakefile Snakefile \
        --configfile config/pipeline.yaml \
        --cores 8 \
        --keep-going \
        --rerun-incomplete \
        --scheduler greedy \
        --printshellcmds"
fi

if [ "$DRY_RUN" = true ]; then
    echo "[pipeline.sh] ドライラン"
    eval "$SNAKEMAKE_CMD --dryrun"
    exit 0
fi

echo "[pipeline.sh] パイプライン開始"
eval "$SNAKEMAKE_CMD"
echo "[pipeline.sh] 完了"

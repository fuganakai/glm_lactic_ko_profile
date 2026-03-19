#!/bin/bash
# ============================================================
# pipeline.sh  —  KO profile → Lasso/Ridge/RF/MLP 予測パイプライン
#
# 入力: {genome_dir}/{sample}.fna  +  {response_csv_dir}/*.csv
# フロー: Prokka → KoFamScan → KO profile → モデル × データセット → 可視化
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
GENOME_DIR="data/glm_lactic_ko_profile/raw/genomes"              # {sample}.fna が入ったディレクトリ ← 要変更
RESPONSE_CSV_DIR="data/glm_lactic_ko_profile/raw/response_csvs"  # il12_reporter.csv, tnf_reporter.csv 等 ← 要変更

# --- KoFamScan データベース ---
KOFAMSCAN_DIR="/path/to/kofamscan/bin"          # ← 要変更
KOFAMSCAN_KO_LIST="/path/to/kofamscan/ko_list"  # ← 要変更
KOFAMSCAN_PROFILES="/path/to/kofamscan/profiles" # ← 要変更

# --- conda 環境 ---
CONDA_BASE="/home/nakai/miniforge3"    # ← 要変更
CONDA_ENV_PROKKA="prokka_env"          # ← 要変更
CONDA_ENV_KOFAM="kofam_env"           # ← 要変更
CONDA_ENV_ML="ml_env"                  # ← 要変更

# --- 共有 fold split (オプション) ---
# 他の研究者と揃えたい場合に設定する。空("")のままにするとデフォルト(内部KFold)で動作。
# ディレクトリ構造: {SPLIT_INFO_DIR}/{dataset}/{dataset}_5fold_seed{N}.tsv
SPLIT_INFO_DIR=""           # 例: "/path/to/criterion_2603/split_info_5fold_random"
SEEDS="40 41 42 43 44 45 46 47 48 49"  # 使用する seed (スペース区切り)

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

# ============================================================
# [2] 引数処理
# ============================================================
DRY_RUN=false
SHOW_DAG=false
TRIAL_DIR_OPT=""

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)   DRY_RUN=true ;;
        --dag)       SHOW_DAG=true ;;
        --trial-dir)
            shift
            TRIAL_DIR_OPT="$1"
            ;;
        --trial-dir=*)
            TRIAL_DIR_OPT="${1#--trial-dir=}"
            ;;
        *) echo "[ERROR] 不明なオプション: $1" >&2; exit 1 ;;
    esac
    shift
done

# ============================================================
# [3] 初期チェック
# ============================================================
if [ ! -d "$GENOME_DIR" ]; then
    echo "[ERROR] GENOME_DIR が見つかりません: $GENOME_DIR" >&2; exit 1
fi
if [ ! -d "$RESPONSE_CSV_DIR" ]; then
    echo "[ERROR] RESPONSE_CSV_DIR が見つかりません: $RESPONSE_CSV_DIR" >&2; exit 1
fi
if [ -z "$(ls "${RESPONSE_CSV_DIR}"/*.csv 2>/dev/null)" ]; then
    echo "[ERROR] RESPONSE_CSV_DIR に .csv ファイルが見つかりません: $RESPONSE_CSV_DIR" >&2; exit 1
fi
if [ -n "$SPLIT_INFO_DIR" ] && [ ! -d "$SPLIT_INFO_DIR" ]; then
    echo "[ERROR] SPLIT_INFO_DIR が見つかりません: $SPLIT_INFO_DIR" >&2; exit 1
fi

mkdir -p config

# ============================================================
# [4] 試行ディレクトリを決定
# ============================================================
_PROJ_NAME="glm_lactic_ko_profile"
_BASE_OUT="output/${_PROJ_NAME}"

if [ "$SHOW_DAG" = true ] || [ "$DRY_RUN" = true ]; then
    # dry-run / dag 時はダミーパス（実ディレクトリは作らない）
    TRIAL_DIR="${TRIAL_DIR_OPT:-${_BASE_OUT}/preview}"
    LOGS_SGE="${TRIAL_DIR}/logs/sge"
elif [ -n "$TRIAL_DIR_OPT" ]; then
    # --trial-dir 指定: 既存ディレクトリを使用（再採番しない）
    TRIAL_DIR="${TRIAL_DIR_OPT}"
    if [ ! -d "$TRIAL_DIR" ]; then
        echo "[ERROR] 指定した --trial-dir が見つかりません: $TRIAL_DIR" >&2; exit 1
    fi
    echo "[pipeline.sh] 既存の試行ディレクトリを使用: ${TRIAL_DIR}"
    LOGS_SGE="${TRIAL_DIR}/logs/sge"
    mkdir -p "${LOGS_SGE}"
else
    # 通常実行: 新しい試行番号を採番
    TRIAL_DIR="$(new-trial-dir)"
    echo "[pipeline.sh] 試行ディレクトリ: ${TRIAL_DIR}"
    LOGS_SGE="${TRIAL_DIR}/logs/sge"
    mkdir -p "${LOGS_SGE}"
fi
RESULTS_DIR="${TRIAL_DIR}"

# ============================================================
# [5] config/pipeline.yaml を生成
# ============================================================
cat > config/pipeline.yaml <<EOF
genome_dir:           "${GENOME_DIR}"
response_csv_dir:     "${RESPONSE_CSV_DIR}"
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
split_info_dir:       "${SPLIT_INFO_DIR}"
seeds:                [$(echo "$SEEDS" | tr ' ' ',')]
EOF

echo "[pipeline.sh] config/pipeline.yaml を生成しました"
echo "[pipeline.sh] 結果出力先: ${RESULTS_DIR}"
echo "[pipeline.sh] レスポンスCSVディレクトリ: ${RESPONSE_CSV_DIR}"
echo "[pipeline.sh] データセット: $(ls "${RESPONSE_CSV_DIR}"/*.csv | xargs -I{} basename {} .csv | tr '\n' ' ')"
if [ -n "$SPLIT_INFO_DIR" ]; then
    echo "[pipeline.sh] 共有 fold split モード: ${SPLIT_INFO_DIR}  seeds: ${SEEDS}"
else
    echo "[pipeline.sh] デフォルトモード: 内部 KFold(5)"
fi

# run_info.txt を試行ディレクトリに書き込む (dry-run/dag/--trial-dir 指定時はスキップ)
if [ "$SHOW_DAG" = false ] && [ "$DRY_RUN" = false ] && [ -z "$TRIAL_DIR_OPT" ]; then
    {
        echo "date:    $(date '+%Y-%m-%d %H:%M:%S')"
        echo "branch:  $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        echo "commit:  $(git log -1 --format='%h  %s' 2>/dev/null || echo unknown)"
        echo "config:"
        cat config/pipeline.yaml
    } > "${RESULTS_DIR}/run_info.txt"
    echo "[pipeline.sh] run_info.txt -> ${RESULTS_DIR}/run_info.txt"
fi

# ============================================================
# [6] conda ml_env をアクティベート (snakemake はここに入っている)
# ============================================================
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV_ML}"

# ============================================================
# [7] Step 0: サンプルフィルタリング (Snakemake より先に実行)
#     ゲノム長のみでフィルタリング。レスポンスCSVとの照合は Step 5 が担当。
# ============================================================
if [ "$SHOW_DAG" = false ] && [ "$DRY_RUN" = false ]; then
    echo "[pipeline.sh] Step 0: サンプルフィルタリング（ゲノム長のみ）"
    python scripts/00_filter_samples.py \
        --genome-dir     "${GENOME_DIR}" \
        --min-genome-len "${MIN_GENOME_LEN}" \
        --output         data/glm_lactic_ko_profile/processed/filtered_samples.txt
fi

# ============================================================
# [8] DAG可視化モード
# ============================================================
if [ "$SHOW_DAG" = true ]; then
    snakemake --dag --snakefile Snakefile --configfile config/pipeline.yaml \
    | dot -Tpng > dag.png
    echo "[pipeline.sh] dag.png を生成しました"
    exit 0
fi

# ============================================================
# [9] 実行
# ============================================================
if [ "$USE_SGE" = true ]; then
    SNAKEMAKE_CMD="snakemake \
        --snakefile Snakefile \
        --configfile config/pipeline.yaml \
        --config trial_dir=${TRIAL_DIR} \
        --cluster-config config/cluster.yaml \
        --cluster 'qsub ${QSUB_EXTRA_OPTS} {cluster.options} -cwd -o ${LOGS_SGE}/ -e ${LOGS_SGE}/' \
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
        --config trial_dir=${TRIAL_DIR} \
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

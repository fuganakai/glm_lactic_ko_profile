#!/bin/bash
# ============================================================
# workflow/config.sh — ユーザー設定ファイル
#
# ここだけ編集する。pipeline.sh や pipeline.yaml は不要。
#
# 使い方:
#   1. このファイルを環境に合わせて編集する
#   2. bash workflow/run_all.sh  で実行
# ============================================================

# ============================================================
# 入力データ
# ============================================================
GENOME_DIR="data/glm_lactic_ko_profile/raw/genomes"             # {sample}.fna が入ったディレクトリ
RESPONSE_CSV_DIR="data/glm_lactic_ko_profile/raw/response_csvs" # レスポンスCSV群のディレクトリ

# ============================================================
# KoFamScan データベース
# ============================================================
KOFAMSCAN_DIR="/path/to/kofamscan/bin"           # exec_annotation があるディレクトリ ← 要変更
KOFAMSCAN_KO_LIST="/path/to/kofamscan/ko_list"   # ← 要変更
KOFAMSCAN_PROFILES="/path/to/kofamscan/profiles" # ← 要変更

# ============================================================
# conda 環境
# ============================================================
CONDA_BASE="/home/nakai/miniforge3" # ← 要変更
CONDA_ENV_PROKKA="prokka_env"       # ← 要変更
CONDA_ENV_KOFAM="kofam_env"         # ← 要変更
CONDA_ENV_ML="ml_env"               # ← 要変更

# ============================================================
# 共有 fold split（オプション）
# 他の研究者と fold を揃えたい場合に設定する。
# 不要なら空文字のままにする（内部 KFold で動作）。
# ディレクトリ構造: {SPLIT_INFO_DIR}/{dataset}/{dataset}_5fold_seed{N}.tsv
# ============================================================
SPLIT_INFO_DIR=""                              # 例: "/path/to/split_info_5fold_random"
SEEDS="40 41 42 43 44 45 46 47 48 49"         # ext モード時に使う seed（スペース区切り）

# ============================================================
# 解析パラメータ
# ============================================================
MIN_SAMPLES_KO=5         # この数以上のサンプルで検出された KO のみ学習対象に含める
MIN_GENOME_LEN=160000    # サンプルフィルタ: 最小ゲノム長 (bp)
RANDOM_STATE=42          # 乱数シード
N_ESTIMATORS=500         # RandomForest の木の数（Optuna 非使用時のフォールバック）
N_TRIALS_RF=50           # RandomForest の Optuna チューニング試行数
N_TRIALS_MLP=80          # MLP の Optuna チューニング試行数
N_TRIALS_XGB=50          # XGBoost の Optuna チューニング試行数
TOP_N_KO=20              # 可視化で表示する上位 KO 数
TOP_N_PAIRS=100          # SHAP interaction 上位ペア出力数

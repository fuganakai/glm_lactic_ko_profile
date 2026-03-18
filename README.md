# KO profile → IL-12 予測パイプライン

KEGG Orthology (KO) のプレゼンス/アブセンスプロファイルから
IL-12 産生量を **Lasso / Ridge / Random Forest / MLP** で予測し、結果を可視化するパイプラインです。

embedding (DNABERT-2 / ESM-2) は使いません。GPU 不要。

---

## パイプラインの流れ

```
genome_dir/*.fna
    ↓ 00_filter_samples.py      — ゲノム長フィルタ（最小 160,000 bp）
filtered_samples.txt
    ↓ 01_run_prokka.sh          — Prokka によるタンパク質予測
{sample}.faa  (アミノ酸配列)
    ↓ 02_run_kofamscan.sh       — KoFamScan による KO アノテーション
{sample}.txt  (KoFamScan 出力)
    ↓ 03_kofamscan_to_csv.py    — 閾値フィルタ & CSV 変換
{sample}_genome.csv
    ↓ 04_make_ko_profile.py     — 全サンプル集約 → バイナリ行列
ko_profile.csv  (sample × KO)
    ↓ 05_bench_models.py        — Lasso / Ridge / RF / MLP 予測（Optuna チューニング付き）
r2_scores.csv, sample_predictions_{lasso,ridge,rf,mlp}.csv, feature_importances.csv
    ↓ 06_visualize.py           — 7種の可視化図を生成
output/glm_lactic_ko_profile/{NNN}/{dataset}/figures/*.png
```

---

## セットアップ手順

### Step 1: リポジトリのクローン

```bash
git clone <this-repo>
cd glm_lactic_ko_profile
```

---

### Step 2: Prokka のインストール

Prokka はゲノム配列 (`.fna`) からタンパク質配列 (`.faa`) を予測するツールです。

→ https://github.com/tseemann/prokka

```bash
conda create -n prokka_env -c conda-forge -c bioconda prokka
```

インストール確認:

```bash
conda activate prokka_env
prokka --version
```

---

### Step 3: KoFamScan のインストールとデータベースの準備

KoFamScan は HMM プロファイルを使って KO アノテーションを行うツールです。

→ https://github.com/takaram/kofam_scan

```bash
conda create -n kofam_env -c conda-forge -c bioconda kofamscan
```

データベース（`ko_list` と `profiles/`）は KEGG FTP から別途ダウンロードが必要です:

→ https://www.genome.jp/ftp/tools/kofam_scan/

```bash
# 例: /db/kofamscan/ に展開した場合
ls /db/kofamscan/
# ko_list   profiles/
```

ダウンロード後の `ko_list` と `profiles/` ディレクトリのパスを後の手順で `pipeline.sh` に記載します。

---

### Step 4: Python 環境のセットアップ

```bash
conda create -n ml_env python=3.10
conda activate ml_env
conda install -c conda-forge setuptools
pip install -r requirements.txt
```

> **Note:** `setuptools` は conda でインストールします。pip のみだと `pkg_resources` が見つからず snakemake が起動しない場合があります。

`requirements.txt` の内容:

```
pandas>=1.5
numpy>=1.23
scikit-learn>=1.2
optuna>=3.0
snakemake>=7.0
setuptools
pulp<2.8
matplotlib>=3.6
seaborn>=0.12
```

---

### Step 5: データの配置

```
glm_lactic_ko_profile/
└── data/
    └── glm_lactic_ko_profile/
        ├── raw/                         # 生データ（変更・上書き禁止）
        │   ├── genomes/                 # ← ゲノム配列を入れるディレクトリ
        │   │   ├── F001.fna             #   ファイル名の stem がサンプルID になる
        │   │   ├── F002.fna
        │   │   └── ...
        │   └── response_csvs/           # ← レスポンス変数 CSV を入れるディレクトリ
        │       └── il12_reporter.csv    #   ファイル名の stem がデータセット名になる
        └── processed/                   # スクリプトが自動生成（コミット不要）
```

`il12_reporter.csv` は以下の形式が必要です（`sample_id` 列は必須）:

```
sample_id,IL-12 Reporter (cps)
F001,12345.6
F002,23456.7
...
```

> **サンプルの絞り込み:** Step 0 ではゲノム長のみでフィルタリングします。
> レスポンス CSV に含まれないサンプルは Step 5 の学習時に自動的に除外されます。

---

### Step 6: pipeline.sh の設定

`pipeline.sh` の上部にある変数を自分の環境に合わせて編集します。
**ここだけ編集すれば、全スクリプトに自動反映されます。**

```bash
# --- 入力データ ---
GENOME_DIR="data/glm_lactic_ko_profile/raw/genomes"              # .fna が入ったディレクトリ
RESPONSE_CSV_DIR="data/glm_lactic_ko_profile/raw/response_csvs"  # レスポンス変数 CSV を入れたディレクトリ

# --- KoFamScan データベース ---
KOFAMSCAN_DIR="/path/to/kofamscan/bin"       # kofamscan 実行ファイルのディレクトリ
KOFAMSCAN_KO_LIST="/path/to/ko_list"         # ko_list ファイルのパス
KOFAMSCAN_PROFILES="/path/to/profiles"       # profiles/ ディレクトリのパス

# --- conda 環境 ---
CONDA_BASE="/home/yourname/miniforge3"  # conda info --base で確認
CONDA_ENV_PROKKA="prokka_env"
CONDA_ENV_KOFAM="kofam_env"
CONDA_ENV_ML="ml_env"
```

`conda info --base` でインストール先を確認できます:

```bash
conda info --base
# /home/yourname/miniforge3  ← これを CONDA_BASE に設定
```

---

### Step 7: SGE クラスターの設定（ローカル実行なら不要）

SGE クラスターで実行する場合は `pipeline.sh` の以下を変更します:

```bash
USE_SGE=true
MAX_JOBS=20   # 同時投入ジョブ数

# qsub に全ジョブ共通で追加するオプション (不要なら空のまま)
QSUB_EXTRA_OPTS="-l d_rt=24:00:00"
```

ローカル実行なら `USE_SGE=false`（デフォルト）のままで構いません。

#### ジョブごとのリソース設定

各ステップのCPU数・メモリは `config/cluster.yaml` で設定します。

```yaml
# 例: run_prokka のCPUを増やす場合
run_prokka:
  options: >-
    -pe smp 16
    -l mem=32G
```

実行されるコマンドのイメージ:

```
qsub {QSUB_EXTRA_OPTS} {cluster.options} -cwd -o output/.../NNN/logs/sge/ -e output/.../NNN/logs/sge/ <jobscript>
#     ↑ pipeline.sh で設定  ↑ cluster.yaml で設定      ↑ 試行ディレクトリ配下に自動設定
```

---

### Step 8: 実行

```bash
# まず内容確認（ドライラン）
bash pipeline.sh --dry-run

# 本実行
bash pipeline.sh

# 依存関係グラフの確認
bash pipeline.sh --dag
```

---

## 主なパラメータ（pipeline.sh）

| 変数 | デフォルト | 説明 |
|---|---|---|
| `MIN_GENOME_LEN` | 160000 | サンプルフィルタ: 最小ゲノム長 (bp) |
| `MIN_SAMPLES_KO` | 5 | KO をモデルに含める最低サンプル数 |
| `RANDOM_STATE` | 42 | 乱数シード |
| `N_ESTIMATORS` | 500 | Random Forest の木の数 (Optuna 非使用時) |
| `N_TRIALS_RF` | 50 | RF の Optuna チューニング試行数 |
| `N_TRIALS_MLP` | 80 | MLP の Optuna チューニング試行数 |
| `TOP_N_KO` | 20 | 可視化で表示する上位 KO 数 |

> **試行ディレクトリについて:** 結果の出力先は `pipeline.sh` で指定する変数ではなく、
> `new-trial-dir` コマンドが自動的に `output/glm_lactic_ko_profile/001/`、`002/`… と
> 連番で生成します。実行のたびに新しいディレクトリが作られるため、過去の試行結果が上書きされません。

---

## 出力

```
output/
└── glm_lactic_ko_profile/
    ├── 001/                           # 1回目の実行（new-trial-dir が自動採番）
    │   ├── run_info.txt               # 実行日時・ブランチ・コミット・設定を自動記録
    │   ├── logs/
    │   │   ├── 01_prokka/{sample}.log # Snakemake log: ディレクティブのログ
    │   │   ├── 02_kofamscan/
    │   │   ├── 05_bench_models/
    │   │   ├── 06_visualize/
    │   │   └── sge/                   # SGEジョブの stdout/stderr (USE_SGE=true 時)
    │   └── il12_reporter/             # データセット名ごとにサブディレクトリが作られる
    │       ├── sample_predictions_lasso.csv
    │       ├── sample_predictions_ridge.csv
    │       ├── sample_predictions_rf.csv
    │       ├── sample_predictions_mlp.csv
    │       ├── r2_scores.csv                  # 全モデル × 全fold + overall の R² テーブル
    │       ├── feature_importances.csv        # fold平均寄与度 (Lasso:|係数|, Ridge:|係数|, RF:MDI)
    │       ├── ko_prevalence.csv              # KO ごとのサンプル出現率
    │       ├── best_params_rf.csv             # Optuna によるRF最適ハイパーパラメータ
    │       ├── best_params_mlp.csv            # Optuna によるMLP最適ハイパーパラメータ
    │       └── figures/
    │           ├── r2_comparison.png              # [図1] R² 比較棒グラフ
    │           ├── pred_vs_actual.png             # [図2] 予測値 vs 実測値 散布図
    │           ├── feature_importance_ranking.png # [図3] 上位KO 寄与度ランキング
    │           ├── r2_cv_distribution.png         # [図4] CV R² 分布 (Violin plot)
    │           ├── feature_importance_heatmap.png # [図5] 寄与度ヒートマップ
    │           ├── prevalence_vs_importance.png   # [図6] KO 出現率 vs 寄与度
    │           └── cumulative_importance.png      # [図7] 累積寄与度カーブ (Pareto)
    ├── 002/                           # 2回目の実行（設定変更後など）
    └── ...

data/glm_lactic_ko_profile/
├── raw/
│   ├── genomes/                   # 入力ゲノム配列（手動配置）
│   └── response_csvs/             # レスポンス変数 CSV（手動配置）
└── processed/                     # パイプラインが自動生成
    ├── filtered_samples.txt       # Step 0 が生成するフィルタ済みサンプルリスト
    ├── prokka_out/{sample}/       # Prokka 出力
    ├── kofamscan_out/{sample}.txt # KoFamScan 出力
    ├── ko_annotations/{sample}_genome.csv
    ├── ko_profile.csv             # sample × KO バイナリ行列
    └── ko_list.txt                # モデルに使用した KO 一覧
```

---

## 可視化の説明

| 図 | 内容 | 用途 |
|---|---|---|
| 図1 R² 比較棒グラフ | 4モデルのfold別・全体R²を横並び表示 | モデル精度の比較 |
| 図2 Predicted vs Actual | y_pred vs y_true の散布図 | 予測の当てはまり確認 |
| 図3 KO ランキング | 上位N KOの寄与度 (モデルごと) | 重要KOの特定 |
| 図4 CV R² 分布 | foldにわたるR²のViolin plot | モデルの安定性評価 |
| 図5 Importance ヒートマップ | 上位KOをモデル横断で比較 (正規化) | 一貫して重要なKOの把握 |
| 図6 Prevalence vs Importance | KO出現率と寄与度の関係 | 希少だが重要なKOの発見 |
| 図7 Pareto カーブ | 上位N個のKOが占める累積寄与割合 | 必要な特徴量数の把握 |

---

## スクリプト一覧

| スクリプト | 役割 |
|---|---|
| `scripts/00_filter_samples.py` | ゲノム長でフィルタリング（最小 bp 未満を除外） |
| `scripts/01_run_prokka.sh` | .fna → .faa (Prokka) |
| `scripts/02_run_kofamscan.sh` | .faa → KO アノテーション (KoFamScan) |
| `scripts/03_kofamscan_to_csv.py` | KoFamScan 出力 → CSV |
| `scripts/04_make_ko_profile.py` | KO アノテーション群 → バイナリプロファイル行列 |
| `scripts/05_bench_models.py` | KO profile × Lasso / Ridge / RF / MLP で予測 (Optuna チューニング付き) |
| `scripts/06_visualize.py` | ベンチマーク結果の可視化 (7図) |
| `scripts/07_aggregate_seeds.py` | seed 別結果の集約サマリー生成 |
| `scripts/check_progress.sh` | 各ステップの進捗確認 |

---

## メインパイプラインとの関係

このリポジトリは [glm_lactic](../README.md) の KO profile 部分を抜き出したものです。
embedding (DNABERT-2 / ESM-2) を使ったより高精度なモデルはメインリポジトリを参照してください。

---

---

## 他のレスポンス変数への応用

本パイプラインは IL-12 予測のために開発しましたが、**任意の連続値レスポンス変数**に対して転用できます。

### 複数データセットの同時解析

`RESPONSE_CSV_DIR` に複数の CSV を配置すると、ファイル名（拡張子なし）がデータセット名となり、
Snakemake がデータセットごとに独立した結果ディレクトリを生成します。

```
data/glm_lactic_ko_profile/raw/response_csvs/
├── il12_reporter.csv   → output/glm_lactic_ko_profile/NNN/il12_reporter/
└── tnf_reporter.csv    → output/glm_lactic_ko_profile/NNN/tnf_reporter/
```

両データセットは Snakemake によって並列実行されます（`--cores` / `--jobs` の上限まで）。

各 CSV は `sample_id` 列と数値列1列以上があれば動作します（列名は任意）。
数値列が1列のみの場合は自動検出し、複数ある場合は `--response-col` で指定できます。

---

### 他研究者とサンプル・fold を揃えて解析する

他の研究者と同一の fold 分割で結果を比較したい場合、**共有 fold split モード**を使います。

`pipeline.sh` で `SPLIT_INFO_DIR` を指定するだけでデフォルト（内部 KFold）から切り替わります:

```bash
# pipeline.sh の設定セクション
SPLIT_INFO_DIR="/path/to/criterion_2603/split_info_5fold_random"
SEEDS="40 41 42 43 44 45 46 47 48 49"
```

#### 共有 fold split ファイルの形式

以下のディレクトリ構造で TSV を配置してください:

```
{SPLIT_INFO_DIR}/
└── {dataset名}/
    ├── {dataset名}_5fold_seed40.tsv
    ├── {dataset名}_5fold_seed41.tsv
    ⋮
    └── {dataset名}_5fold_seed49.tsv
```

各 TSV の形式（タブ区切り）:

```
sample_id	fold
F001	0
F002	1
F003	3
...
```

> `dataset名` は `RESPONSE_CSV_DIR` 内の CSV ファイル名（拡張子なし）と一致させてください。

#### 出力（共有 fold split モード）

seed ごとの結果 + 全 seed を集約したサマリーが生成されます:

```
output/glm_lactic_ko_profile/NNN/{dataset}/
├── seed40/
│   ├── r2_scores.csv
│   ├── feature_importances.csv
│   ├── sample_predictions_{lasso,ridge,rf,mlp}.csv
│   └── figures/
├── seed41/ ...
⋮
├── seed49/
└── summary/
    ├── r2_mean_std.csv              # モデル別 mean / std / median / min / max
    ├── r2_per_seed_fold.csv         # seed × fold の詳細 R²
    ├── feature_importance_mean.csv  # KO 別平均寄与度
    └── sample_predictions_all.csv   # 全 seed・全 fold の予測値
```

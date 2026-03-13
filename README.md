# KO profile → IL-12 予測パイプライン

KEGG Orthology (KO) のプレゼンス/アブセンスプロファイルから
IL-12 産生量を **Lasso / Ridge / Random Forest** で予測し、結果を可視化するパイプラインです。

embedding (DNABERT-2 / ESM-2) は使いません。GPU 不要。

---

## パイプラインの流れ

```
genome_dir/*.fna  +  il12_reporter.csv
    ↓ 00_filter_samples.py      — 共通サンプル抽出 & ゲノム長フィルタ
filtered_samples.txt
    ↓ 01_run_prokka.sh          — Prokka によるタンパク質予測
{sample}.faa  (アミノ酸配列)
    ↓ 02_run_kofamscan.sh       — KoFamScan による KO アノテーション
{sample}.txt  (KoFamScan 出力)
    ↓ 03_kofamscan_to_csv.py    — 閾値フィルタ & CSV 変換
{sample}_genome.csv
    ↓ 04_make_ko_profile.py     — 全サンプル集約 → バイナリ行列
ko_profile.csv  (sample × KO)
    ↓ 05_bench_models.py        — Lasso / Ridge / Random Forest 予測
r2_scores.csv, sample_predictions_{lasso,ridge,rf}.csv, feature_importances.csv
    ↓ 06_visualize.py           — 7種の可視化図を生成
results/models/figures/*.png
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

conda でインストールする場合:

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
pip install -r requirements.txt
```

`requirements.txt` の内容:

```
pandas>=1.5
numpy>=1.23
scikit-learn>=1.2
snakemake>=7.0
matplotlib>=3.6
seaborn>=0.12
```

---

### Step 5: データの配置

以下の構成になるようにデータを配置します。

```
glm_lactic_ko_profile/
└── data/
    ├── genomes/                 # ← ゲノム配列を入れるディレクトリ
    │   ├── sample001.fna        #   ファイル名の stem がサンプルID になる
    │   ├── sample002.fna
    │   └── ...
    └── il12_reporter.csv        # ← IL-12 測定値CSV
```

`il12_reporter.csv` は以下の2列が必要です（列名はこの通りにすること）:

```
sample_id,IL-12 Reporter (cps)
sample001,12345.6
sample002,23456.7
...
```

> **ディレクトリ名やファイル名を変えたい場合**
> `data/genomes/` や `data/il12_reporter.csv` はデフォルト値です。
> 別の場所にデータがある場合は、次の手順で `pipeline.sh` を編集してパスを変えるだけで動きます。

---

### Step 6: pipeline.sh の設定

`pipeline.sh` の上部にある変数を自分の環境に合わせて編集します。
**ここだけ編集すれば、全スクリプトに自動反映されます。**

```bash
# --- 入力データ ---
GENOME_DIR="data/genomes"              # .fna が入ったディレクトリ
IL12_CSV="data/il12_reporter.csv"      # IL-12 測定値CSV

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

SGE クラスターで実行する場合は以下も変更します:

```bash
USE_SGE=true
MAX_JOBS=20   # 同時投入ジョブ数
```

ローカル実行なら `USE_SGE=false`（デフォルト）のままで構いません。

> **sun サーバーの場合:** `qsub ファイル名` のみで投入できます。`-g`（グループ指定）は不要です。

---

### Step 8: 実行

設定が完了したら実行します。

```bash
# まず内容確認（ドライラン）
bash pipeline.sh --dry-run

# 本実行
bash pipeline.sh
```

---

## 主なパラメータ（pipeline.sh）

| 変数 | デフォルト | 説明 |
|---|---|---|
| `MIN_GENOME_LEN` | 160000 | サンプルフィルタ: 最小ゲノム長 (bp)。これ未満のサンプルは除外される |
| `MIN_SAMPLES_KO` | 5 | KO をモデルに含める最低サンプル数 |
| `RANDOM_STATE` | 42 | 乱数シード |
| `N_ESTIMATORS` | 500 | Random Forest の木の数 |
| `TOP_N_KO` | 20 | 可視化で表示する上位 KO 数 |
| `RESULTS_DIR` | `results/models` | 結果出力先 |

---

## 出力

```
results/models/
├── sample_predictions_lasso.csv   # サンプルごとの予測値 (Lasso)
├── sample_predictions_ridge.csv   # サンプルごとの予測値 (Ridge)
├── sample_predictions_rf.csv      # サンプルごとの予測値 (Random Forest)
├── r2_scores.csv                  # 全モデル × 全fold + overall の R² テーブル
├── feature_importances.csv        # fold平均寄与度 (Lasso:|係数|, Ridge:|係数|, RF:MDI)
├── ko_prevalence.csv              # KO ごとのサンプル出現率
└── figures/
    ├── r2_comparison.png              # [図1] R² 比較棒グラフ (fold別 + overall)
    ├── pred_vs_actual.png             # [図2] 予測値 vs 実測値 散布図
    ├── feature_importance_ranking.png # [図3] 上位KO 寄与度ランキング (水平棒グラフ)
    ├── r2_cv_distribution.png         # [図4] CV R² 分布 (Violin plot)
    ├── feature_importance_heatmap.png # [図5] 寄与度ヒートマップ (モデル間比較)
    ├── prevalence_vs_importance.png   # [図6] KO 出現率 vs 寄与度 散布図
    └── cumulative_importance.png      # [図7] 累積寄与度カーブ (Pareto)

data/
├── filtered_samples.txt           # Step 0 が生成するフィルタ済みサンプルリスト
├── prokka_out/{sample}/           # Prokka 出力
├── kofamscan_out/{sample}.txt     # KoFamScan 出力
├── ko_annotations/{sample}_genome.csv
├── ko_profile.csv                 # sample × KO バイナリ行列
└── ko_list.txt                    # モデルに使用した KO 一覧
```

---

## 可視化の説明

| 図 | 内容 | 用途 |
|---|---|---|
| 図1 R² 比較棒グラフ | 3モデルのfold別・全体R²を横並び表示 | モデル精度の比較 |
| 図2 Predicted vs Actual | y_pred vs y_true の散布図 | 予測の当てはまり確認 |
| 図3 KO ランキング | 上位N KOの寄与度 (モデルごと) | 重要KOの特定 |
| 図4 CV R² 分布 | 5foldにわたるR²のViolin plot | モデルの安定性評価 |
| 図5 Importance ヒートマップ | 上位KOをモデル横断で比較 (正規化) | 一貫して重要なKOの把握 |
| 図6 Prevalence vs Importance | KO出現率と寄与度の関係 | 希少だが重要なKOの発見 |
| 図7 Pareto カーブ | 上位N個のKOが占める累積寄与割合 | 必要な特徴量数の把握 |

---

## スクリプト一覧

| スクリプト | 役割 |
|---|---|
| `scripts/00_filter_samples.py` | genome_dir と IL-12 CSV の共通サンプルを抽出し、ゲノム長でフィルタリング |
| `scripts/01_run_prokka.sh` | .fna → .faa (Prokka) |
| `scripts/02_run_kofamscan.sh` | .faa → KO アノテーション (KoFamScan) |
| `scripts/03_kofamscan_to_csv.py` | KoFamScan出力 → CSV |
| `scripts/04_make_ko_profile.py` | KO アノテーション群 → バイナリプロファイル行列 |
| `scripts/05_bench_models.py` | KO profile × Lasso / Ridge / Random Forest で IL-12 予測 |
| `scripts/06_visualize.py` | ベンチマーク結果の可視化 (7図) |

---

## メインパイプラインとの関係

このリポジトリは [glm_lactic](../README.md) の KO profile 部分を抜き出したものです。
embedding (DNABERT-2 / ESM-2) を使ったより高精度なモデルはメインリポジトリを参照してください。

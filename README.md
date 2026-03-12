# KO profile → IL-12 予測パイプライン

KEGG Orthology (KO) のプレゼンス/アブセンスプロファイルから
IL-12 産生量を **Lasso / Ridge / Random Forest** で予測し、結果を可視化するスタンドアロンパイプラインです。

embedding (DNABERT-2 / ESM-2) は使いません。GPU 不要。

---

## 概要

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

## 必要な環境

| ツール | 用途 | conda 環境 |
|---|---|---|
| Prokka | ゲノムアノテーション (.fna → .faa) | `prokka_env` |
| KoFamScan | KO アノテーション (.faa → .txt) | `kofam_env` |
| Python (scikit-learn, matplotlib 等) | プロファイル作成・予測・可視化 | `ml_env` |

---

## 必要なもの

```
data/
├── genomes/                 # {sample}.fna が入ったディレクトリ
│   ├── sample001.fna        # ファイル名の stem がサンプルIDとして自動検出される
│   ├── sample002.fna
│   └── ...
└── il12_reporter.csv        # sample_id, IL-12 Reporter (cps) の2列
```

`sample_list.txt` は不要。`GENOME_DIR` 内の `.fna` ファイルからサンプルが自動検出される。

KoFamScan のデータベース (`ko_list`, `profiles`) も別途必要です。
→ https://www.genome.jp/ftp/tools/kofam_scan/

---

## セットアップ

```bash
git clone <this-repo>
cd ko_profile

# Python依存パッケージ
conda activate ml_env
pip install -r requirements.txt
```

---

## 実行

```bash
# 1. pipeline.sh の「ユーザー設定」セクションを編集（詳細は下記）
# 2. 実行確認 (ドライラン)
bash pipeline.sh --dry-run

# 3. 本実行
bash pipeline.sh
```

SGEクラスター上で実行する場合は `USE_SGE=true` に変更してください。

### pipeline.sh の設定項目

**ユーザーが変更するのは `pipeline.sh` 上部の変数のみ。** 変数を変えると
`config/pipeline.yaml` が自動生成され、全スクリプトに反映される。

#### 入力パス

| 変数 | デフォルト | 説明 |
|---|---|---|
| `GENOME_DIR` | `data/genomes` | `{sample}.fna` が入ったディレクトリ（`.fna` から自動検出） |
| `IL12_CSV` | `data/il12_reporter.csv` | IL-12測定値CSV |

例えばゲノムが `data/my_genomes/` にある場合：

```bash
# pipeline.sh
GENOME_DIR="data/my_genomes"   # ← ここだけ変える
```

これだけで全ステップに反映される。

#### KoFamScan データベース

| 変数 | 説明 |
|---|---|
| `KOFAMSCAN_DIR` | kofamscan 実行ファイルのディレクトリ |
| `KOFAMSCAN_KO_LIST` | `ko_list` ファイルのパス |
| `KOFAMSCAN_PROFILES` | `profiles/` ディレクトリのパス |

#### conda 環境

| 変数 | 説明 |
|---|---|
| `CONDA_BASE` | conda のインストール先 (`conda info --base` で確認) |
| `CONDA_ENV_PROKKA` | Prokka 用 conda 環境名 |
| `CONDA_ENV_KOFAM` | KoFamScan 用 conda 環境名 |
| `CONDA_ENV_ML` | Python ML ツール用 conda 環境名 |

### 主なパラメータ（pipeline.sh）

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

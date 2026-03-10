# KO profile → IL-12 予測パイプライン

KEGG Orthology (KO) のプレゼンス/アブセンスプロファイルから
IL-12 産生量を Lasso / Ridge で予測するスタンドアロンパイプラインです。

embedding (DNABERT-2 / ESM-2) は使いません。GPU 不要。

---

## 概要

```
{sample}.fna  (ゲノム配列)
    ↓ 01_run_prokka.sh          — Prokka によるタンパク質予測
{sample}.faa  (アミノ酸配列)
    ↓ 02_run_kofamscan.sh       — KoFamScan による KO アノテーション
{sample}.txt  (KoFamScan 出力)
    ↓ 03_kofamscan_to_csv.py    — 閾値フィルタ & CSV 変換
{sample}_genome.csv
    ↓ 04_make_ko_profile.py     — 全サンプル集約 → バイナリ行列
ko_profile.csv  (sample × KO)
    ↓ 05_bench_lasso_ridge.py   — Lasso / Ridge 予測
sample_predictions_{lasso,ridge}.csv
```

---

## 必要な環境

| ツール | 用途 | conda 環境 |
|---|---|---|
| Prokka | ゲノムアノテーション (.fna → .faa) | `prokka_env` |
| KoFamScan | KO アノテーション (.faa → .txt) | `kofam_env` |
| Python (scikit-learn 等) | プロファイル作成・予測 | `ml_env` |

---

## 必要なもの

```
data/
├── genomes/                 # {sample}.fna が入ったディレクトリ
│   ├── sample001.fna
│   ├── sample002.fna
│   └── ...
├── sample_list.txt          # 1行1サンプルID
└── il12_reporter.csv        # sample_id, IL-12 Reporter (cps) の2列
```

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
# 1. pipeline.sh の「ユーザー設定」セクションを編集
#    - GENOME_DIR, SAMPLE_LIST, IL12_CSV
#    - KOFAMSCAN_DIR, KOFAMSCAN_KO_LIST, KOFAMSCAN_PROFILES
#    - CONDA_BASE, CONDA_ENV_PROKKA, CONDA_ENV_KOFAM, CONDA_ENV_ML

# 2. 実行確認 (ドライラン)
bash pipeline.sh --dry-run

# 3. 本実行
bash pipeline.sh
```

SGEクラスター上で実行する場合は `USE_SGE=true` に変更してください。

---

## 出力

```
results/lasso_ridge/
├── sample_predictions_lasso.csv   # サンプルごとの予測値 (Lasso)
└── sample_predictions_ridge.csv   # サンプルごとの予測値 (Ridge)

data/
├── prokka_out/{sample}/           # Prokka 出力
├── kofamscan_out/{sample}.txt     # KoFamScan 出力
├── ko_annotations/{sample}_genome.csv
├── ko_profile.csv                 # sample × KO バイナリ行列
└── ko_list.txt                    # モデルに使用した KO 一覧
```

---

## スクリプト一覧

| スクリプト | 役割 |
|---|---|
| `scripts/01_run_prokka.sh` | .fna → .faa (Prokka) |
| `scripts/02_run_kofamscan.sh` | .faa → KO アノテーション (KoFamScan) |
| `scripts/03_kofamscan_to_csv.py` | KoFamScan出力 → CSV |
| `scripts/04_make_ko_profile.py` | KO アノテーション群 → バイナリプロファイル行列 |
| `scripts/05_bench_lasso_ridge.py` | KO profile × Lasso/Ridge で IL-12 予測 |

---

## メインパイプラインとの関係

このリポジトリは [glm_lactic](../README.md) の KO profile 部分を抜き出したものです。
embedding (DNABERT-2 / ESM-2) を使ったより高精度なモデルはメインリポジトリを参照してください。

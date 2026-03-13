# Claude Code Instructions

## 出力ディレクトリ

解析結果や生成ファイルは `get_output(__file__)` で取得したHDDパスに保存すること。

```python
from shadow_helper import get_output

output_dir = get_output(__file__)
result_path = output_dir / "result.csv"
```

## ジョブ投入

計算ジョブは `qsub` で投入する。スクリプトはジョブスケジューラ（PBS/SGE）に対応した形式で書くこと。

## Git フロー

- 作業前に `git pull` で最新を取得する
- コミットは小さく、意味のある単位で行う
- `output/` はコミットしない（`.gitignore` で除外済み）

## コーディング規約

- 関数・変数名は英語
- コメントは日本語可

## Snakemake パイプライン構成

### フォルダ・ファイル構成

新規パイプラインプロジェクトは以下の構成で作ること：

```
project/
├── pipeline.sh          # エントリーポイント（ユーザー設定 + snakemake 実行）
├── Snakefile            # ルール定義
├── config/
│   ├── cluster.yaml     # SGEジョブリソース設定（ルール別）
│   └── pipeline.yaml    # pipeline.sh が自動生成（コミット不要）
├── scripts/
│   ├── 00_xxxx.py       # 前処理（Snakemake より先に pipeline.sh から実行）
│   ├── 01_xxxx.sh       # ステップ1（Snakemake から呼ばれる）
│   ├── 02_xxxx.py       # ステップ2 ...
│   └── check_progress.sh  # 進捗確認スクリプト（必ず作成）
├── logs/
│   └── 01_xxxx/{sample}.log
└── data/                # 中間ファイル（コミット不要）
```

### pipeline.sh の設計

- ユーザーが編集するのは冒頭の設定セクションのみ
- `USE_SGE=true/false` でローカル実行と SGE クラスタ実行を切り替え
- `QSUB_EXTRA_OPTS` で時間制限・メール通知などの追加オプションを渡せる
- `pipeline.sh` が `config/pipeline.yaml` を自動生成してから Snakemake を起動する
- `--dry-run` / `--dag` オプションを必ず用意する

### SGE クラスタ実行（USE_SGE=true）

- `config/cluster.yaml` にルール別のCPU・メモリを定義する
- Snakemake のクラスタオプション：

```bash
--cluster-config config/cluster.yaml \
--cluster 'qsub ${QSUB_EXTRA_OPTS} {cluster.options} -cwd -o logs/ -e logs/' \
--jobs ${MAX_JOBS} \
--latency-wait 60 \
--keep-going \
--rerun-incomplete
```

### 進捗確認スクリプト

パイプラインを含むプロジェクトでは必ず `scripts/check_progress.sh` を作成すること。
各ステップの出力ファイル数をカウントして進捗率を表示する：

```
[Step1] prokka:      412 / 592 ( 69.6%)
[Step2] kofamscan:   301 / 592 ( 50.8%)
[Step3] ko_csv:      301 / 592 ( 50.8%)
[Step4] ko_profile:    0 /   1 (  0.0%)
```

監視は別ターミナルで `watch -n 30 bash scripts/check_progress.sh` で行う。

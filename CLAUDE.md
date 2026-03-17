# Claude Code Instructions

## 出力ディレクトリ

`output/` はプロジェクトルートにある HDD へのシンボリックリンク（`init-repo` で設定）。

### ディレクトリ構造

出力は **試行番号付きサブディレクトリ** に保存する：

```
output/
└── {project_name}/
    ├── 001/
    │   ├── run_info.txt   ← Git・実行環境の記録（自動生成）
    │   └── (出力ファイル群)
    ├── 002/
    │   ├── run_info.txt
    │   └── (出力ファイル群)
    └── ...
```

- `{project_name}` はリポジトリのルートディレクトリ名
- 試行番号は既存ディレクトリの最大値 + 1（ゼロ埋め3桁）

### run_info.txt の内容

各試行ディレクトリ作成時に以下を記録する：

```
date:    2026-03-17 10:30:00
branch:  main
commit:  a1b2c3d  Add new analysis step
config:
  (config/pipeline.yaml の内容をここに貼付、なければ省略)
```

### 試行ディレクトリの作成（Python）

スクリプト・パイプラインの先頭で次のように呼ぶ：

```python
from pathlib import Path
import subprocess, datetime, shutil

def new_trial_dir(project_root: Path) -> Path:
    project_name = project_root.name
    base = project_root / "output" / project_name
    base.mkdir(parents=True, exist_ok=True)
    existing = sorted(p for p in base.iterdir() if p.is_dir() and p.name.isdigit())
    n = int(existing[-1].name) + 1 if existing else 1
    trial = base / f"{n:03d}"
    trial.mkdir()

    # run_info.txt
    branch = subprocess.check_output(
        ["git", "-C", str(project_root), "rev-parse", "--abbrev-ref", "HEAD"],
        text=True).strip()
    commit = subprocess.check_output(
        ["git", "-C", str(project_root), "log", "-1", "--format=%h  %s"],
        text=True).strip()
    info = [
        f"date:    {datetime.datetime.now():%Y-%m-%d %H:%M:%S}",
        f"branch:  {branch}",
        f"commit:  {commit}",
    ]
    cfg = project_root / "config" / "pipeline.yaml"
    if cfg.exists():
        info += ["config:", cfg.read_text().rstrip()]
    (trial / "run_info.txt").write_text("\n".join(info) + "\n")
    return trial
```

使い方：

```python
PROJECT_ROOT = Path(__file__).parents[1]  # プロジェクトルートまでの階層を調整
trial_dir = new_trial_dir(PROJECT_ROOT)
result_path = trial_dir / "result.csv"
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

## ディレクトリ構造

### data/ の構成（全プロジェクト共通）

`data/` ディレクトリは必ず以下のように分けること：

```
data/
└── {project_name}/
    ├── raw/          # 生データ（変更・上書き禁止。元データをそのまま保存）
    └── processed/    # 処理途中・加工済みデータ（スクリプトが生成するファイル）
```

- `data/` 直下にはプロジェクト名のディレクトリを作り、その中に `raw/` と `processed/` を置く
- `raw/` は読み取り専用として扱い、スクリプトから直接書き込まない
- `processed/` はいつでも再生成できる中間ファイルを置く
- `data/` 全体はコミットしない（`.gitignore` で除外）

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
└── data/
    └── {project_name}/
        ├── raw/         # 生データ（コミット不要）
        └── processed/   # 中間ファイル（コミット不要）
```

ログは **試行ディレクトリの下** に配置する（試行間の混在を防ぐため）：

```
output/
└── {project_name}/
    ├── 001/
    │   ├── run_info.txt
    │   ├── logs/
    │   │   ├── 01_xxxx/          # Snakemake log: ディレクティブのログ
    │   │   │   └── {sample}.log
    │   │   └── sge/              # SGEジョブのstdout/stderr
    │   │       ├── {job}.o{id}
    │   │       └── {job}.e{id}
    │   └── (出力ファイル群)
    └── 002/
        ├── run_info.txt
        ├── logs/
        └── (出力ファイル群)
```

### pipeline.sh の設計

- ユーザーが編集するのは冒頭の設定セクションのみ
- `USE_SGE=true/false` でローカル実行と SGE クラスタ実行を切り替え
- `QSUB_EXTRA_OPTS` で時間制限・メール通知などの追加オプションを渡せる
- `pipeline.sh` が `config/pipeline.yaml` を自動生成してから Snakemake を起動する
- `--dry-run` / `--dag` オプションを必ず用意する

### SGE クラスタ実行（USE_SGE=true）

- `config/cluster.yaml` にルール別のCPU・メモリを定義する
- `pipeline.sh` で試行ディレクトリを先に決め、その下の `logs/sge/` をSGEに渡す：

```bash
# pipeline.sh 内で trial_dir を決定する
TRIAL_DIR="$(python3 scripts/new_trial_dir.py)"   # 試行番号ディレクトリを作成して返す
LOGS_SGE="${TRIAL_DIR}/logs/sge"
mkdir -p "${LOGS_SGE}"

snakemake \
  --config trial_dir="${TRIAL_DIR}" \
  --cluster-config config/cluster.yaml \
  --cluster "qsub ${QSUB_EXTRA_OPTS} {cluster.options} -cwd -o ${LOGS_SGE}/ -e ${LOGS_SGE}/" \
  --jobs ${MAX_JOBS} \
  --latency-wait 60 \
  --keep-going \
  --rerun-incomplete
```

- Snakefile では `config["trial_dir"]` を参照してログパスを構築する：

```python
TRIAL_DIR = config["trial_dir"]

rule some_rule:
    input:  ...
    output: ...
    log:    os.path.join(TRIAL_DIR, "logs", "01_xxxx", "{sample}.log")
    shell:
        "some_command {input} > {output} 2> {log}"
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

### Snakemakeのログ種別（3種類）

Snakemakeで扱うログには以下の3種類がある。混同しないこと：

| 種類 | 場所 | 内容 | 特徴 |
|------|------|------|------|
| **① `log:` ディレクティブ** | Snakefile の `log:` で指定したファイル | ルールのコマンドの stdout/stderr | **ルール失敗後も残る**。エラー解析の第一候補 |
| **② SGEジョブログ** | `qsub -o ... -e ...` で指定したディレクトリ | SGEが生成する `{name}.o{jobid}` / `{name}.e{jobid}` | ジョブのキュー情報・実行ノード・時間なども含む |
| **③ Snakemake本体ログ** | `.snakemake/log/` | DAG構築・ルール実行の履歴 | Snakemake自体のデバッグ用 |

**エラー時に見る順番**: ① `log:` のファイル → ② SGEジョブの `.e{jobid}` ファイル → ③ `.snakemake/log/`

---

## シェルスクリプトの落とし穴と対処法

### 落とし穴1: `set -euo pipefail` + `ls` のグロブ不一致

**現象**: スクリプトがエラーメッセージなしに黙って終了する。

**原因**:

```bash
# 初回実行など、対象ディレクトリが存在しない場合
_LAST_N=$(ls -d "${_BASE_OUT}"/[0-9][0-9][0-9] 2>/dev/null | sort -V | tail -1 | xargs -r basename)
#         ↑ マッチなし → 終了コード2         ↑ 2>/dev/null はエラーメッセージを消すだけ
# pipefail により パイプ全体の終了コードも非ゼロ
# -e により スクリプト即終了（ログにも何も書かれない）
```

**解決策**:

```bash
# 方法1: || true で失敗を無視（最小変更）
_LAST_N=$(ls -d "${_BASE_OUT}"/[0-9][0-9][0-9] 2>/dev/null | sort -V | tail -1 | xargs -r basename || true)

# 方法2: find を使う（マッチなしでも終了コード0）
_LAST_N=$(find "${_BASE_OUT}" -maxdepth 1 -type d -name '[0-9][0-9][0-9]' 2>/dev/null \
          | sort -V | tail -1 | xargs -r basename || true)
```

### 落とし穴2: `-e` で止まったエラーがログに残らない

**原因**: `set -e` はスクリプトを即終了させるが、エラーログへの書き込み処理が実行されない。

**対処法: `trap ERR` でエラー行番号をログに残す**

シェルスクリプトの先頭に以下を追加する：

```bash
#!/bin/bash
set -euo pipefail

LOGFILE="pipeline.log"   # ログファイルパスを変数で管理

# エラー時にログに行番号とコマンドを記録してから終了
trap 'echo "[$(date +%Y-%m-%dT%H:%M:%S)] ERROR at line $LINENO: $BASH_COMMAND" \
      | tee -a "$LOGFILE" >&2' ERR
```

これにより `set -e` で終了する直前に「どの行で何のコマンドが失敗したか」がログに書き込まれる。

### 落とし穴3: ログに何も書かれていないのにスクリプトが終了する

原因の調べ方：

```bash
# 1. スクリプトを bash -x で実行して全コマンドをトレース
bash -x pipeline.sh 2>&1 | tee debug.log

# 2. set -e を一時的に無効化して最後まで実行させる
bash +e pipeline.sh

# 3. $? で各コマンドの終了コードを確認
some_command; echo "exit code: $?"
```

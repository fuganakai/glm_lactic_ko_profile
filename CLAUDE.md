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

- Python: PEP8 準拠
- 関数・変数名は英語
- コメントは日本語可

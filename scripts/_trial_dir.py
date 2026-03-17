"""
scripts/_trial_dir.py — 試行ディレクトリの作成ユーティリティ

CLAUDE.md の「出力ディレクトリ」規約に基づき、
output/{project_name}/{NNN}/ を作成して run_info.txt を書き込む。
"""

import datetime
import subprocess
from pathlib import Path


def new_trial_dir(project_root: Path) -> Path:
    """
    output/{project_name}/{NNN}/ を作成して run_info.txt を書き込み、パスを返す。

    Parameters
    ----------
    project_root : Path
        プロジェクトルートディレクトリ（リポジトリの最上位）

    Returns
    -------
    Path
        作成した試行ディレクトリのパス（例: output/glm_lactic_ko_profile/001/）
    """
    project_name = project_root.name
    base = project_root / "output" / project_name
    base.mkdir(parents=True, exist_ok=True)

    existing = sorted(p for p in base.iterdir() if p.is_dir() and p.name.isdigit())
    n = int(existing[-1].name) + 1 if existing else 1
    trial = base / f"{n:03d}"
    trial.mkdir()

    # git 情報を取得（失敗しても続行）
    def _git(*args):
        try:
            return subprocess.check_output(
                ["git", "-C", str(project_root)] + list(args), text=True
            ).strip()
        except Exception:
            return "unknown"

    branch = _git("rev-parse", "--abbrev-ref", "HEAD")
    commit = _git("log", "-1", "--format=%h  %s")

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

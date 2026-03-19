#!/usr/bin/env python3
"""
scripts/08_visualize_all_datasets.py — 全データセット横断 R² 比較プロット

全データセット（代謝物）を横軸に並べ、各モデルの R² を組み合わせて表示する。

  棒グラフ:  各データセットで全モデル最大の fold 平均 R²
  箱ひげ図:  4 モデルの fold 平均 R² の分布（1モデル1点 = 計4点）
  散布点:    各モデルの fold 平均 R²（モデルごとに色・マーカーを変える）

モード自動検出:
  デフォルト:       {results_dir}/{dataset}/r2_scores.csv を使用（fold 平均を計算）
  seed あり:        {results_dir}/{dataset}/summary/r2_mean_std.csv を使用
                    (seed × fold 平均済みの r2_mean 列)

INPUT:
    --results-dir   {TRIAL_DIR}  (dataset/ サブディレクトリを含む親ディレクトリ)
    --output-dir    図の出力先 (default: {results_dir}/figures)
    --seeds         seed 番号リスト (省略時: 自動検出)

OUTPUT:
    {output_dir}/r2_all_datasets.png
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import seaborn as sns

# ─── スタイル設定 ──────────────────────────────────────────────────
sns.set_theme(style="whitegrid", font_scale=1.1)

MODELS = ["lasso", "ridge", "rf", "mlp"]
MODEL_COLORS  = {"lasso": "#4C72B0", "ridge": "#DD8452", "rf": "#55A868", "mlp": "#C44E52"}
MODEL_MARKERS = {"lasso": "o",       "ridge": "s",       "rf": "^",       "mlp": "D"}
MODEL_LABELS  = {"lasso": "Lasso",   "ridge": "Ridge",   "rf": "Random Forest", "mlp": "MLP"}
DPI = 150


# ────────────────────────────────────────────────────────────────────
# データ読み込み
# ────────────────────────────────────────────────────────────────────
def detect_seed_mode(results_dir: Path, datasets: list) -> tuple:
    """seed サブディレクトリの有無でモードを自動検出。(use_seeds, seeds) を返す"""
    if not datasets:
        return False, []
    first = results_dir / datasets[0]
    seed_dirs = sorted(
        int(p.name.replace("seed", ""))
        for p in first.glob("seed*")
        if p.is_dir() and p.name.replace("seed", "").isdigit()
    )
    return bool(seed_dirs), seed_dirs


def load_r2_default(dataset_dir: Path) -> dict:
    """デフォルトモード: fold 平均 R² を {model: value} で返す"""
    r2_path = dataset_dir / "r2_scores.csv"
    if not r2_path.exists():
        return {}
    df = pd.read_csv(r2_path)
    fold_df = df[df["fold"] != "overall"].copy()
    fold_df["r2"] = fold_df["r2"].astype(float)
    return fold_df.groupby("model")["r2"].mean().to_dict()


def load_r2_seed(dataset_dir: Path) -> dict:
    """seed モード: seed × fold 平均 R² を {model: value} で返す"""
    # 07_aggregate_seeds.py が生成した r2_mean_std.csv を優先
    summary_path = dataset_dir / "summary" / "r2_mean_std.csv"
    if summary_path.exists():
        df = pd.read_csv(summary_path)
        return dict(zip(df["model"], df["r2_mean"].astype(float)))

    # fallback: r2_per_seed_fold.csv から直接計算
    detail_path = dataset_dir / "summary" / "r2_per_seed_fold.csv"
    if detail_path.exists():
        df = pd.read_csv(detail_path)
        df["r2"] = df["r2"].astype(float)
        return df.groupby("model")["r2"].mean().to_dict()

    return {}


# ────────────────────────────────────────────────────────────────────
# プロット
# ────────────────────────────────────────────────────────────────────
def plot_r2_all_datasets(r2_data: dict, output_path: str):
    """
    Parameters
    ----------
    r2_data : {dataset_name: {model_name: r2_fold_mean}}
    """
    # R² 最大値の高い順にソート
    datasets = sorted(
        r2_data.keys(),
        key=lambda ds: max(
            (v for v in r2_data[ds].values() if not np.isnan(v)),
            default=0.0,
        ),
        reverse=True,
    )
    n = len(datasets)
    if n == 0:
        print("  [fig8] データがありません。スキップします。")
        return

    x = np.arange(n)
    bar_width = 0.35

    # A4横（297×210mm）比率 ≈ 1.414:1
    fig_w = max(12, n * 0.6 + 3)
    fig_h = fig_w / 1.414
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    # ── 棒グラフ（全モデル最大値、負値は 0 にクリップ） ──────────
    max_vals = []
    for ds in datasets:
        vals = [r2_data[ds].get(m, np.nan) for m in MODELS]
        finite = [v for v in vals if not np.isnan(v)]
        max_vals.append(max(0.0, max(finite)) if finite else 0.0)

    ax.bar(
        x, max_vals,
        width=bar_width,
        color="steelblue",
        alpha=0.85,
        zorder=2,
        label="_nolegend_",
    )

    # ── 散布点（モデルごとに色・マーカーを変える、負値は 0 にクリップ） ──
    for ds_i, ds in enumerate(datasets):
        for model in MODELS:
            val = r2_data[ds].get(model, np.nan)
            if np.isnan(val):
                continue
            ax.scatter(
                ds_i, max(0.0, val),
                color=MODEL_COLORS[model],
                marker=MODEL_MARKERS[model],
                s=65,
                zorder=3,
                linewidths=0.6,
                edgecolors="white",
            )

    # ── 軸・ラベル ───────────────────────────────────────────────
    ax.set_xticks(x)
    ax.set_xticklabels(datasets, rotation=45, ha="right", fontsize=9)
    ax.set_ylabel("R² Score (fold mean)")
    ax.set_xlabel("Dataset (metabolite)")
    ax.set_title(
        "R² Comparison Across Datasets (bar = best model, dots = each model)",
        fontsize=12,
    )

    ax.set_ylim(bottom=0.0, top=1.0)

    # ── 凡例（モデル別） ─────────────────────────────────────────
    legend_handles = [
        plt.scatter(
            [], [],
            color=MODEL_COLORS[m],
            marker=MODEL_MARKERS[m],
            s=65,
            label=MODEL_LABELS[m],
        )
        for m in MODELS
    ]
    ax.legend(
        handles=legend_handles,
        title="Model",
        bbox_to_anchor=(1.01, 1),
        loc="upper left",
        fontsize=9,
    )

    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    print(f"  [fig8] {output_path}")


# ────────────────────────────────────────────────────────────────────
# メイン
# ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="全データセット横断 R² 比較プロット")
    parser.add_argument(
        "--results-dir", required=True,
        help="{TRIAL_DIR}  (dataset/ サブディレクトリを含む親ディレクトリ)",
    )
    parser.add_argument(
        "--output-dir", default=None,
        help="図の出力先 (default: {results_dir}/figures)",
    )
    parser.add_argument(
        "--seeds", type=int, nargs="*", default=None,
        help="seed 番号リスト (省略時: 自動検出)",
    )
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    if not results_dir.exists():
        print(f"[ERROR] results-dir が見つかりません: {results_dir}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.output_dir) if args.output_dir else results_dir / "figures"
    out_dir.mkdir(parents=True, exist_ok=True)

    # dataset ディレクトリ一覧（隠しディレクトリ・figures・logs は除外）
    _EXCLUDE = {"figures", "logs"}
    datasets = sorted(
        p.name for p in results_dir.iterdir()
        if p.is_dir() and not p.name.startswith(".") and p.name not in _EXCLUDE
    )
    if not datasets:
        print("[ERROR] データセットディレクトリが見つかりません。", file=sys.stderr)
        sys.exit(1)

    print(f"[visualize_all] データセット ({len(datasets)} 件): {datasets}")

    # seed モード検出
    use_seeds, auto_seeds = detect_seed_mode(results_dir, datasets)
    if args.seeds is not None:
        use_seeds = bool(args.seeds)
        seeds = args.seeds
    else:
        seeds = auto_seeds

    if use_seeds:
        print(f"[visualize_all] seed モード (seeds={seeds})")
    else:
        print("[visualize_all] デフォルトモード (内部 KFold)")

    # R² データ読み込み
    r2_data = {}
    for ds in datasets:
        ds_dir = results_dir / ds
        vals = load_r2_seed(ds_dir) if use_seeds else load_r2_default(ds_dir)
        if vals:
            r2_data[ds] = vals
        else:
            print(f"  [WARNING] {ds}: R² データが見つかりません。スキップします。")

    if not r2_data:
        print("[ERROR] 有効なデータセットがありません。", file=sys.stderr)
        sys.exit(1)

    plot_r2_all_datasets(r2_data, str(out_dir / "r2_all_datasets.png"))
    print(f"[visualize_all] 完了: {out_dir}/r2_all_datasets.png")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
scripts/07_aggregate_seeds.py — seed 別ベンチマーク結果の集約

05_bench_models.py を複数 seed で実行した結果を集約し、
mean ± std サマリーと平均 feature importance を出力する。

INPUT:
    --results-dir   {results_dir}/{dataset}  (seed{N}/ サブディレクトリを自動検出)
    --seeds         使用する seed 番号リスト (省略時: 発見された全 seed)

OUTPUT:
    {results_dir}/summary/r2_mean_std.csv         (model × fold の mean/std/N)
    {results_dir}/summary/feature_importance_mean.csv  (KO 別平均寄与度)
    {results_dir}/summary/sample_predictions_all.csv   (全 seed × fold 予測値)
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd


def _load_seed_results(results_dir: Path, seeds: list[int]) -> dict:
    """各 seed の CSV を読み込んで辞書で返す"""
    r2_dfs = []
    imp_dfs = []
    pred_dfs = []

    found_seeds = []
    for seed in seeds:
        seed_dir = results_dir / f"seed{seed}"
        if not seed_dir.exists():
            print(f"[WARNING] seed{seed} ディレクトリが見つかりません: {seed_dir}")
            continue

        r2_path  = seed_dir / "r2_scores.csv"
        imp_path = seed_dir / "feature_importances.csv"

        if not r2_path.exists():
            print(f"[WARNING] r2_scores.csv が見つかりません: {r2_path}")
            continue

        r2_df = pd.read_csv(r2_path)
        r2_df["seed"] = seed
        r2_dfs.append(r2_df)

        if imp_path.exists():
            imp_df = pd.read_csv(imp_path)
            imp_df["seed"] = seed
            imp_dfs.append(imp_df)

        # 予測値 CSV (モデル別)
        for pred_path in sorted(seed_dir.glob("sample_predictions_*.csv")):
            pred_df = pd.read_csv(pred_path)
            pred_df["seed"] = seed
            pred_dfs.append(pred_df)

        found_seeds.append(seed)

    if not found_seeds:
        print("[ERROR] 有効な seed ディレクトリが1つも見つかりません。", file=sys.stderr)
        sys.exit(1)

    print(f"[aggregate_seeds] 有効な seed: {found_seeds}  ({len(found_seeds)} 本)")

    return {
        "r2":   pd.concat(r2_dfs,  ignore_index=True) if r2_dfs  else pd.DataFrame(),
        "imp":  pd.concat(imp_dfs, ignore_index=True) if imp_dfs  else pd.DataFrame(),
        "pred": pd.concat(pred_dfs, ignore_index=True) if pred_dfs else pd.DataFrame(),
        "found_seeds": found_seeds,
    }


def main():
    parser = argparse.ArgumentParser(description="seed 別ベンチマーク結果の集約")
    parser.add_argument("--results-dir", required=True,
                        help="{results_dir}/{dataset}  (seed{N}/ サブディレクトリを持つ親ディレクトリ)")
    parser.add_argument("--seeds", type=int, nargs="*", default=None,
                        help="集約する seed 番号 (省略時: seed_dir を自動検出)")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    if not results_dir.exists():
        print(f"[ERROR] results-dir が見つかりません: {results_dir}", file=sys.stderr)
        sys.exit(1)

    # seed リストの決定
    if args.seeds:
        seeds = args.seeds
    else:
        seeds = sorted(
            int(p.name.replace("seed", ""))
            for p in results_dir.glob("seed*")
            if p.is_dir() and p.name.replace("seed", "").isdigit()
        )
        print(f"[aggregate_seeds] seed を自動検出: {seeds}")

    if not seeds:
        print("[ERROR] seed ディレクトリが見つかりません。--seeds で指定してください。",
              file=sys.stderr)
        sys.exit(1)

    data = _load_seed_results(results_dir, seeds)
    summary_dir = results_dir / "summary"
    summary_dir.mkdir(parents=True, exist_ok=True)

    # ── R² スコアのサマリー ─────────────────────────────────────────
    r2_df = data["r2"]
    # "overall" fold は集計から除外（fold 番号が整数のもののみ対象）
    r2_folds = r2_df[r2_df["fold"] != "overall"].copy()
    r2_folds["fold"] = r2_folds["fold"].astype(int)
    r2_folds["r2"]   = r2_folds["r2"].astype(float)

    r2_summary = (
        r2_folds.groupby("model")["r2"]
        .agg(r2_mean="mean", r2_std="std", r2_median="median",
             r2_min="min", r2_max="max", N="count")
        .reset_index()
        .sort_values("r2_mean", ascending=False)
    )
    out_r2 = summary_dir / "r2_mean_std.csv"
    r2_summary.to_csv(out_r2, index=False)
    print(f"[aggregate_seeds] R² サマリー → {out_r2}")
    print(r2_summary.to_string(index=False))

    # ── seed × fold 別の詳細 R² も出力 ─────────────────────────────
    out_r2_detail = summary_dir / "r2_per_seed_fold.csv"
    r2_folds.to_csv(out_r2_detail, index=False)
    print(f"[aggregate_seeds] R² 詳細 (seed × fold) → {out_r2_detail}")

    # ── Feature importance の平均 ──────────────────────────────────
    imp_df = data["imp"]
    if not imp_df.empty:
        imp_cols = [c for c in imp_df.columns
                    if c.startswith("importance_") and c != "importance_sum"]
        ko_col = "ko"

        imp_mean = (
            imp_df.groupby(ko_col)[imp_cols]
            .mean()
            .reset_index()
        )
        imp_mean["importance_sum_mean"] = imp_mean[imp_cols].sum(axis=1)
        imp_mean = imp_mean.sort_values("importance_sum_mean", ascending=False).reset_index(drop=True)

        out_imp = summary_dir / "feature_importance_mean.csv"
        imp_mean.to_csv(out_imp, index=False)
        print(f"[aggregate_seeds] Feature importance 平均 → {out_imp}")

    # ── 全 seed × fold 予測値の結合 ─────────────────────────────────
    pred_df = data["pred"]
    if not pred_df.empty:
        out_pred = summary_dir / "sample_predictions_all.csv"
        pred_df.to_csv(out_pred, index=False)
        print(f"[aggregate_seeds] 全予測値 → {out_pred}")

    print(f"[aggregate_seeds] 完了: {summary_dir}")


if __name__ == "__main__":
    main()

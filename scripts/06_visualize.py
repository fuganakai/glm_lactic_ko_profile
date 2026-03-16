#!/usr/bin/env python3
"""
scripts/06_visualize.py — ベンチマーク結果の可視化

05_bench_models.py の出力を読み込み、以下の図を生成する。

  図1: R² 比較 棒グラフ          r2_comparison.png
  図2: Predicted vs Actual 散布図  pred_vs_actual.png
  図3: Feature Importance ランキング feature_importance_ranking.png
  図4: CV R² 分布 Violin/Box plot  r2_cv_distribution.png
  図5: Feature Importance ヒートマップ feature_importance_heatmap.png
  図6: KO Prevalence vs Importance   prevalence_vs_importance.png
  図7: 累積寄与度カーブ（Pareto）    cumulative_importance.png

INPUT:
    --results-dir   05_bench_models.py の出力ディレクトリ
    --output-dir    図の出力先 (default: {results_dir}/figures)
    --top-n-ko      ランキング・ヒートマップに表示する上位KO数 (default: 20)
"""

import argparse
import os
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib

try:
    from shadow_helper import get_output
    _has_shadow = True
except ImportError:
    _has_shadow = False


def _default_results_dir():
    if _has_shadow:
        return str(get_output(__file__))
    return str(Path(__file__).parent.parent / "output" / "models")
matplotlib.use("Agg")  # ヘッドレス環境対応
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import seaborn as sns

# ─── スタイル設定 ──────────────────────────────────────────────────
sns.set_theme(style="whitegrid", font_scale=1.1)
MODEL_COLORS = {"lasso": "#4C72B0", "ridge": "#DD8452", "rf": "#55A868", "mlp": "#C44E52"}
MODEL_LABELS = {"lasso": "Lasso", "ridge": "Ridge", "rf": "Random Forest", "mlp": "MLP"}
DPI = 150


def load_data(results_dir: str):
    rd = Path(results_dir)

    r2_df = pd.read_csv(rd / "r2_scores.csv")

    pred_dfs = {}
    for m in ("lasso", "ridge", "rf", "mlp"):
        f = rd / f"sample_predictions_{m}.csv"
        if f.exists():
            pred_dfs[m] = pd.read_csv(f)

    imp_df = pd.read_csv(rd / "feature_importances.csv")

    prev_df = None
    pf = rd / "ko_prevalence.csv"
    if pf.exists():
        prev_df = pd.read_csv(pf)

    return r2_df, pred_dfs, imp_df, prev_df


# ────────────────────────────────────────────────────────────────────
# 図1: R² 比較 棒グラフ
# ────────────────────────────────────────────────────────────────────
def plot_r2_comparison(r2_df: pd.DataFrame, output_path: str):
    fold_df  = r2_df[r2_df["fold"] != "overall"].copy()
    fold_df["fold"] = fold_df["fold"].astype(int)

    models = fold_df["model"].unique().tolist()
    folds  = sorted(fold_df["fold"].unique())
    n_models = len(models)
    x = np.arange(len(folds))
    width = 0.8 / n_models

    fig, ax = plt.subplots(figsize=(9, 5))

    for i, model in enumerate(models):
        vals = []
        for fold in folds:
            row = fold_df[(fold_df["model"] == model) & (fold_df["fold"] == fold)]
            vals.append(float(row["r2"].values[0]) if len(row) else np.nan)
        bars = ax.bar(
            x + i * width - (n_models - 1) * width / 2,
            vals,
            width=width * 0.9,
            label=MODEL_LABELS.get(model, model),
            color=MODEL_COLORS.get(model, None),
            alpha=0.85,
        )

    # overall R² を横線で追加
    for model in models:
        row = r2_df[(r2_df["model"] == model) & (r2_df["fold"] == "overall")]
        if len(row):
            ax.axhline(
                float(row["r2"].values[0]),
                color=MODEL_COLORS.get(model, "gray"),
                linestyle="--", linewidth=1.5,
                label=f"{MODEL_LABELS.get(model, model)} (overall)",
            )

    ax.set_xlabel("Fold")
    ax.set_ylabel("R² Score")
    ax.set_title("R² Score per Fold — Lasso / Ridge / Random Forest / MLP")
    ax.set_xticks(x)
    ax.set_xticklabels([f"Fold {f}" for f in folds])
    ax.legend(bbox_to_anchor=(1.01, 1), loc="upper left", fontsize=9)
    ax.set_ylim(bottom=min(0, r2_df[r2_df["fold"] != "overall"]["r2"].astype(float).min() - 0.05))
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI)
    plt.close()
    print(f"  [fig1] {output_path}")


# ────────────────────────────────────────────────────────────────────
# 図2: Predicted vs Actual 散布図
# ────────────────────────────────────────────────────────────────────
def plot_pred_vs_actual(pred_dfs: dict, output_path: str):
    n = len(pred_dfs)
    fig, axes = plt.subplots(1, n, figsize=(5 * n, 5), sharey=False)
    if n == 1:
        axes = [axes]

    for ax, (model, df) in zip(axes, pred_dfs.items()):
        color = MODEL_COLORS.get(model, "steelblue")
        ax.scatter(df["y_true"], df["y_pred"],
                   alpha=0.6, s=40, color=color, edgecolors="white", linewidth=0.4)

        vmin = min(df["y_true"].min(), df["y_pred"].min())
        vmax = max(df["y_true"].max(), df["y_pred"].max())
        ax.plot([vmin, vmax], [vmin, vmax], "k--", linewidth=1, label="y = x")

        overall_r2 = r2_score_manual(df["y_true"].values, df["y_pred"].values)
        ax.set_title(f"{MODEL_LABELS.get(model, model)}\nR²={overall_r2:.3f}")
        ax.set_xlabel("Actual IL-12 Reporter")
        ax.set_ylabel("Predicted IL-12 Reporter")
        ax.legend(fontsize=8)

    plt.suptitle("Predicted vs Actual — All Folds", y=1.02, fontsize=13)
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    print(f"  [fig2] {output_path}")


def r2_score_manual(y_true, y_pred):
    ss_res = np.sum((y_true - y_pred) ** 2)
    ss_tot = np.sum((y_true - np.mean(y_true)) ** 2)
    return 1 - ss_res / ss_tot if ss_tot > 0 else 0.0


# ────────────────────────────────────────────────────────────────────
# 図3: Feature Importance ランキング（水平棒グラフ）
# ────────────────────────────────────────────────────────────────────
def plot_feature_importance_ranking(imp_df: pd.DataFrame, top_n: int, output_path: str):
    imp_cols = [c for c in imp_df.columns if c.startswith("importance_") and c != "importance_sum"]
    models = [c.replace("importance_", "") for c in imp_cols]
    n = len(models)

    top = imp_df.head(top_n).copy()

    fig, axes = plt.subplots(1, n, figsize=(6 * n, max(6, top_n * 0.4 + 1)), sharey=True)
    if n == 1:
        axes = [axes]

    for ax, (model, col) in zip(axes, zip(models, imp_cols)):
        sorted_top = top.sort_values(col, ascending=True)
        color = MODEL_COLORS.get(model, "steelblue")
        ax.barh(sorted_top["ko"], sorted_top[col], color=color, alpha=0.85)
        ax.set_title(MODEL_LABELS.get(model, model))
        ax.set_xlabel("Importance (avg over folds)")
        ax.tick_params(axis="y", labelsize=8)

    plt.suptitle(f"Top {top_n} KO Feature Importances", fontsize=13)
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    print(f"  [fig3] {output_path}")


# ────────────────────────────────────────────────────────────────────
# 図4: CV R² 分布 Violin/Box plot
# ────────────────────────────────────────────────────────────────────
def plot_r2_cv_distribution(r2_df: pd.DataFrame, output_path: str):
    fold_df = r2_df[r2_df["fold"] != "overall"].copy()
    fold_df["r2"] = fold_df["r2"].astype(float)
    fold_df["model_label"] = fold_df["model"].map(
        lambda m: MODEL_LABELS.get(m, m)
    )

    models_order = [MODEL_LABELS.get(m, m) for m in ["lasso", "ridge", "rf", "mlp"]
                    if m in fold_df["model"].unique()]

    fig, ax = plt.subplots(figsize=(8, 5))
    palette = {MODEL_LABELS.get(m, m): MODEL_COLORS.get(m, None)
               for m in ["lasso", "ridge", "rf", "mlp"]}

    sns.violinplot(
        data=fold_df, x="model_label", y="r2",
        order=models_order, palette=palette,
        inner="box", ax=ax, cut=0,
    )
    sns.stripplot(
        data=fold_df, x="model_label", y="r2",
        order=models_order, color="black",
        size=5, jitter=True, alpha=0.7, ax=ax,
    )

    ax.set_xlabel("")
    ax.set_ylabel("R² Score (per fold)")
    ax.set_title("Cross-Validation R² Distribution")
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI)
    plt.close()
    print(f"  [fig4] {output_path}")


# ────────────────────────────────────────────────────────────────────
# 図5: Feature Importance ヒートマップ（モデル間比較）
# ────────────────────────────────────────────────────────────────────
def plot_feature_importance_heatmap(imp_df: pd.DataFrame, top_n: int, output_path: str):
    imp_cols = [c for c in imp_df.columns if c.startswith("importance_") and c != "importance_sum"]
    models = [c.replace("importance_", "") for c in imp_cols]

    top = imp_df.head(top_n).copy()
    heat = top.set_index("ko")[imp_cols].copy()
    heat.columns = [MODEL_LABELS.get(m, m) for m in models]

    # 各列を 0-1 正規化して比較しやすくする
    heat_norm = (heat - heat.min()) / (heat.max() - heat.min() + 1e-12)

    fig, ax = plt.subplots(figsize=(max(5, len(models) * 2), max(6, top_n * 0.35 + 1)))
    sns.heatmap(
        heat_norm,
        ax=ax,
        cmap="YlOrRd",
        linewidths=0.3,
        linecolor="white",
        annot=False,
        cbar_kws={"label": "Normalized Importance"},
    )
    ax.set_title(f"Top {top_n} KO Feature Importance Heatmap\n(normalized per model)")
    ax.set_ylabel("")
    ax.tick_params(axis="y", labelsize=8)
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    print(f"  [fig5] {output_path}")


# ────────────────────────────────────────────────────────────────────
# 図6: KO Prevalence vs Importance 散布図
# ────────────────────────────────────────────────────────────────────
def plot_prevalence_vs_importance(imp_df: pd.DataFrame, prev_df: pd.DataFrame,
                                  top_n: int, output_path: str):
    merged = imp_df.merge(prev_df, on="ko", how="inner")

    imp_cols = [c for c in imp_df.columns if c.startswith("importance_") and c != "importance_sum"]
    models = [c.replace("importance_", "") for c in imp_cols]
    n = len(models)

    fig, axes = plt.subplots(1, n, figsize=(5 * n, 5))
    if n == 1:
        axes = [axes]

    for ax, (model, col) in zip(axes, zip(models, imp_cols)):
        color = MODEL_COLORS.get(model, "steelblue")
        ax.scatter(
            merged["prevalence_rate"],
            merged[col],
            alpha=0.5, s=25, color=color, edgecolors="none",
        )

        # 上位 top_n KO にラベル
        top_ko = merged.nlargest(top_n, col)
        for _, row in top_ko.iterrows():
            ax.annotate(
                row["ko"],
                xy=(row["prevalence_rate"], row[col]),
                fontsize=6, alpha=0.8,
                xytext=(3, 3), textcoords="offset points",
            )

        ax.set_xlabel("KO Prevalence Rate (fraction of samples)")
        ax.set_ylabel(f"Importance ({MODEL_LABELS.get(model, model)})")
        ax.set_title(MODEL_LABELS.get(model, model))
        ax.xaxis.set_major_formatter(mticker.PercentFormatter(xmax=1.0))

    plt.suptitle("KO Prevalence vs Feature Importance", fontsize=13)
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    print(f"  [fig6] {output_path}")


# ────────────────────────────────────────────────────────────────────
# 図7: 累積寄与度カーブ（Pareto）
# ────────────────────────────────────────────────────────────────────
def plot_cumulative_importance(imp_df: pd.DataFrame, output_path: str):
    imp_cols = [c for c in imp_df.columns if c.startswith("importance_") and c != "importance_sum"]
    models = [c.replace("importance_", "") for c in imp_cols]

    fig, ax = plt.subplots(figsize=(8, 5))

    for model, col in zip(models, imp_cols):
        vals = imp_df[col].values.astype(float)
        total = vals.sum()
        if total == 0:
            continue
        sorted_vals = np.sort(vals)[::-1]
        cumulative = np.cumsum(sorted_vals) / total
        x = np.arange(1, len(cumulative) + 1)
        ax.plot(x, cumulative,
                label=MODEL_LABELS.get(model, model),
                color=MODEL_COLORS.get(model, None),
                linewidth=2)

    # 80% / 90% ラインを引く
    for thresh, ls in [(0.8, "--"), (0.9, ":")]:
        ax.axhline(thresh, color="gray", linestyle=ls, linewidth=1,
                   label=f"{int(thresh*100)}% threshold")

    ax.set_xlabel("Number of KOs (ranked by importance)")
    ax.set_ylabel("Cumulative Importance Fraction")
    ax.set_title("Cumulative Feature Importance (Pareto Curve)")
    ax.set_ylim(0, 1.02)
    ax.xaxis.set_major_locator(mticker.MaxNLocator(integer=True))
    ax.legend()
    plt.tight_layout()
    plt.savefig(output_path, dpi=DPI)
    plt.close()
    print(f"  [fig7] {output_path}")


# ────────────────────────────────────────────────────────────────────
# メイン
# ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="ベンチマーク結果の可視化")
    parser.add_argument("--results-dir", default=None,
                        help="05_bench_models.py の出力ディレクトリ (default: get_output(__file__))")
    parser.add_argument("--output-dir",  default=None,
                        help="図の出力先 (default: {results_dir}/figures)")
    parser.add_argument("--top-n-ko",    type=int, default=20,
                        help="ランキング表示上位KO数 (default: 20)")
    args = parser.parse_args()

    if args.results_dir is None:
        args.results_dir = _default_results_dir()
    out_dir = args.output_dir or os.path.join(args.results_dir, "figures")
    os.makedirs(out_dir, exist_ok=True)

    print(f"[visualize] データ読み込み: {args.results_dir}")
    r2_df, pred_dfs, imp_df, prev_df = load_data(args.results_dir)

    print("[visualize] 図の生成中...")

    plot_r2_comparison(
        r2_df,
        os.path.join(out_dir, "r2_comparison.png"),
    )

    if pred_dfs:
        plot_pred_vs_actual(
            pred_dfs,
            os.path.join(out_dir, "pred_vs_actual.png"),
        )

    plot_feature_importance_ranking(
        imp_df, args.top_n_ko,
        os.path.join(out_dir, "feature_importance_ranking.png"),
    )

    plot_r2_cv_distribution(
        r2_df,
        os.path.join(out_dir, "r2_cv_distribution.png"),
    )

    plot_feature_importance_heatmap(
        imp_df, args.top_n_ko,
        os.path.join(out_dir, "feature_importance_heatmap.png"),
    )

    if prev_df is not None:
        plot_prevalence_vs_importance(
            imp_df, prev_df, args.top_n_ko,
            os.path.join(out_dir, "prevalence_vs_importance.png"),
        )
    else:
        print("  [fig6] ko_prevalence.csv が見つからないためスキップ")

    plot_cumulative_importance(
        imp_df,
        os.path.join(out_dir, "cumulative_importance.png"),
    )

    print(f"[visualize] 完了: {out_dir}/")


if __name__ == "__main__":
    main()

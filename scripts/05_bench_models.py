#!/usr/bin/env python3
"""
scripts/05_bench_models.py — KO profile × Lasso / Ridge / RandomForest ベンチマーク

embedding を使わず、KO 存在/不在バイナリ行列のみを特徴量として
Lasso / Ridge / RandomForest で IL-12 を予測する。

INPUT:
    --ko-profile-csv  ko_profile.csv  (sample × KO バイナリ行列)
    --il12-csv        IL-12 reporter CSV
    --sample-list     サンプルIDリスト
    --output-dir      結果出力先

OUTPUT:
    {output_dir}/sample_predictions_{model}.csv   (model ごと)
    {output_dir}/r2_scores.csv                    (全モデル × 全fold)
    {output_dir}/feature_importances.csv          (全KO の寄与度)
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LassoCV, RidgeCV
from sklearn.model_selection import KFold
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import r2_score


def main():
    parser = argparse.ArgumentParser(description="KO profile × Lasso/Ridge/RF ベンチマーク")
    parser.add_argument("--ko-profile-csv", required=True)
    parser.add_argument("--il12-csv",       required=True)
    parser.add_argument("--sample-list",    required=True)
    parser.add_argument("--output-dir",     required=True)
    parser.add_argument("--model",          default="all",
                        choices=["lasso", "ridge", "rf", "all"],
                        help="使用するモデル (default: all)")
    parser.add_argument("--min-samples-ko", type=int, default=5,
                        help="KO保有サンプル数の下限フィルタ (default: 5)")
    parser.add_argument("--random-state",   type=int, default=42)
    parser.add_argument("--n-estimators",   type=int, default=500,
                        help="RandomForest の木の数 (default: 500)")
    parser.add_argument("--top-n-ko",       type=int, default=30,
                        help="feature_importances.csv に出力する上位KO数 (default: 30)")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    # ── データ読み込み ──────────────────────────────────────────────
    il12_df = pd.read_csv(args.il12_csv)
    il12_dict = {str(r["sample_id"]): float(r["IL-12 Reporter (cps)"])
                 for _, r in il12_df.iterrows()
                 if not np.isnan(float(r["IL-12 Reporter (cps)"]))}

    sample_list = [l.strip() for l in Path(args.sample_list).read_text().splitlines() if l.strip()]
    valid_sids  = [s for s in sample_list if s in il12_dict]

    profile_df = pd.read_csv(args.ko_profile_csv)
    profile_df["sample_id"] = profile_df["sample_id"].astype(str)
    profile_df = profile_df.set_index("sample_id")

    # ── サンプル & KO フィルタリング ───────────────────────────────
    common_sids = [s for s in valid_sids if s in profile_df.index]
    ko_cols = [c for c in profile_df.columns
               if profile_df.loc[common_sids, c].sum() >= args.min_samples_ko]

    print(f"[bench_models] サンプル: {len(common_sids)}  KO特徴量: {len(ko_cols)}")

    X = profile_df.loc[common_sids, ko_cols].values.astype(np.float32)
    y = np.array([il12_dict[s] for s in common_sids], dtype=np.float32)

    # KO prevalence（可視化スクリプト用）
    ko_prevalence = profile_df.loc[common_sids, ko_cols].sum(axis=0)
    ko_prev_df = pd.DataFrame({
        "ko": ko_cols,
        "prevalence": ko_prevalence.values,
        "prevalence_rate": ko_prevalence.values / len(common_sids),
    })
    ko_prev_df.to_csv(os.path.join(args.output_dir, "ko_prevalence.csv"), index=False)

    # ── モデル定義 ─────────────────────────────────────────────────
    def make_models(model_arg):
        result = []
        if model_arg in ("lasso", "all"):
            result.append(("lasso", LassoCV(cv=5, random_state=args.random_state, max_iter=5000)))
        if model_arg in ("ridge", "all"):
            result.append(("ridge", RidgeCV(cv=5)))
        if model_arg in ("rf", "all"):
            result.append(("rf", RandomForestRegressor(
                n_estimators=args.n_estimators,
                random_state=args.random_state,
                n_jobs=-1,
            )))
        return result

    models_to_run = make_models(args.model)
    kf = KFold(n_splits=5, shuffle=True, random_state=args.random_state)
    sids_arr = np.array(common_sids)

    all_r2_rows = []
    # KO × モデル の寄与度を累積（fold平均を取る）
    importance_accum = {name: np.zeros(len(ko_cols)) for name, _ in models_to_run}
    fold_counts = {name: 0 for name, _ in models_to_run}

    for model_name, clf_template in models_to_run:
        all_preds = []

        for fold_idx, (tr_idx, te_idx) in enumerate(kf.split(sids_arr)):
            X_tr, y_tr = X[tr_idx], y[tr_idx]
            X_te, y_te = X[te_idx], y[te_idx]

            sc = StandardScaler().fit(X_tr)
            clf = type(clf_template)(**clf_template.get_params())
            clf.fit(sc.transform(X_tr), y_tr)

            y_te_pred = clf.predict(sc.transform(X_te))
            r2 = r2_score(y_te, y_te_pred)
            print(f"  [{model_name}] Fold {fold_idx}: R²={r2:.4f}")

            all_r2_rows.append({
                "model": model_name, "fold": fold_idx, "r2": float(r2)
            })

            for sid, yt, yp in zip(sids_arr[te_idx], y_te, y_te_pred):
                all_preds.append({
                    "model": model_name, "fold": fold_idx,
                    "sample_id": sid, "y_true": float(yt), "y_pred": float(yp),
                })

            # ── 寄与度の収集 ───────────────────────────────────────
            if model_name == "rf":
                importance_accum[model_name] += clf.feature_importances_
            else:
                # Lasso / Ridge は係数絶対値
                importance_accum[model_name] += np.abs(clf.coef_)
            fold_counts[model_name] += 1

        pred_df = pd.DataFrame(all_preds)
        pred_df.to_csv(
            os.path.join(args.output_dir, f"sample_predictions_{model_name}.csv"), index=False)

        overall_r2 = r2_score(pred_df["y_true"], pred_df["y_pred"])
        print(f"  [{model_name}] 全fold R²={overall_r2:.4f}")

        all_r2_rows.append({
            "model": model_name, "fold": "overall", "r2": float(overall_r2)
        })

    # ── R² スコアの保存 ────────────────────────────────────────────
    r2_df = pd.DataFrame(all_r2_rows)
    r2_df.to_csv(os.path.join(args.output_dir, "r2_scores.csv"), index=False)
    print(f"[bench_models] R² scores -> {args.output_dir}/r2_scores.csv")

    # ── 寄与度の保存 ───────────────────────────────────────────────
    imp_df = pd.DataFrame({"ko": ko_cols})
    for model_name, _ in models_to_run:
        avg_imp = importance_accum[model_name] / fold_counts[model_name]
        imp_df[f"importance_{model_name}"] = avg_imp

    # 全モデルの合計寄与度でソートして top_n_ko 出力
    imp_cols = [c for c in imp_df.columns if c.startswith("importance_")]
    imp_df["importance_sum"] = imp_df[imp_cols].sum(axis=1)
    imp_df = imp_df.sort_values("importance_sum", ascending=False).reset_index(drop=True)
    imp_df.to_csv(os.path.join(args.output_dir, "feature_importances.csv"), index=False)
    print(f"[bench_models] Feature importances -> {args.output_dir}/feature_importances.csv")

    print(f"[bench_models] 完了: {args.output_dir}")


if __name__ == "__main__":
    main()

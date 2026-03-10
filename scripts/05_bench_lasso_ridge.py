#!/usr/bin/env python3
"""
scripts/05_bench_lasso_ridge.py — KO profile × Lasso/Ridge ベンチマーク

embedding を使わず、KO 存在/不在バイナリ行列のみを特徴量として
Lasso / Ridge で IL-12 を予測する。

INPUT:
    --ko-profile-csv  ko_profile.csv  (sample × KO バイナリ行列)
    --il12-csv        IL-12 reporter CSV
    --sample-list     サンプルIDリスト
    --output-dir      結果出力先

OUTPUT:
    {output_dir}/sample_predictions.csv
    {output_dir}/top_ko_coefficients.csv  (Lasso/Ridge の係数上位)
"""

import argparse
import os
import sys
from pathlib import Path
from typing import Dict, List

import numpy as np
import pandas as pd
from sklearn.linear_model import LassoCV, RidgeCV
from sklearn.model_selection import KFold
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import r2_score


def main():
    parser = argparse.ArgumentParser(description="KO profile × Lasso/Ridge ベンチマーク")
    parser.add_argument("--ko-profile-csv", required=True)
    parser.add_argument("--il12-csv",       required=True)
    parser.add_argument("--sample-list",    required=True)
    parser.add_argument("--output-dir",     required=True)
    parser.add_argument("--model",          default="both",
                        choices=["lasso", "ridge", "both"],
                        help="使用するモデル (default: both)")
    parser.add_argument("--min-samples-ko", type=int, default=5,
                        help="KO保有サンプル数の下限フィルタ (default: 5)")
    parser.add_argument("--random-state",   type=int, default=42)
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    # データ読み込み
    il12_df = pd.read_csv(args.il12_csv)
    il12_dict = {str(r["sample_id"]): float(r["IL-12 Reporter (cps)"])
                 for _, r in il12_df.iterrows()
                 if not np.isnan(float(r["IL-12 Reporter (cps)"]))}

    sample_list = [l.strip() for l in Path(args.sample_list).read_text().splitlines() if l.strip()]
    valid_sids  = [s for s in sample_list if s in il12_dict]

    profile_df = pd.read_csv(args.ko_profile_csv)
    profile_df["sample_id"] = profile_df["sample_id"].astype(str)
    profile_df = profile_df.set_index("sample_id")

    # 有効サンプル & KO フィルタリング
    common_sids = [s for s in valid_sids if s in profile_df.index]
    ko_cols = [c for c in profile_df.columns
               if profile_df.loc[common_sids, c].sum() >= args.min_samples_ko]

    print(f"[lasso_ridge] サンプル: {len(common_sids)}  KO特徴量: {len(ko_cols)}")

    X = profile_df.loc[common_sids, ko_cols].values.astype(np.float32)
    y = np.array([il12_dict[s] for s in common_sids], dtype=np.float32)

    models_to_run = []
    if args.model in ("lasso", "both"):
        models_to_run.append(("lasso", LassoCV(cv=5, random_state=args.random_state, max_iter=5000)))
    if args.model in ("ridge", "both"):
        models_to_run.append(("ridge", RidgeCV(cv=5)))

    kf = KFold(n_splits=5, shuffle=True, random_state=args.random_state)
    sids_arr = np.array(common_sids)

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

            for sid, yt, yp in zip(sids_arr[te_idx], y_te, y_te_pred):
                all_preds.append({
                    "model": model_name, "fold": fold_idx,
                    "sample_id": sid, "y_true": float(yt), "y_pred": float(yp),
                })

        pred_df = pd.DataFrame(all_preds)
        pred_df.to_csv(
            os.path.join(args.output_dir, f"sample_predictions_{model_name}.csv"), index=False)

        overall_r2 = r2_score(pred_df["y_true"], pred_df["y_pred"])
        print(f"  [{model_name}] 全fold R²={overall_r2:.4f}")

    print(f"[lasso_ridge] 完了: {args.output_dir}")


if __name__ == "__main__":
    main()

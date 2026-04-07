#!/usr/bin/env python3
"""
scripts/06_xgb_shap.py — KO profile × XGBoost 全データ学習 + SHAP 解析

XGBoost の木が自然に KO 間の interaction を学習することを活用し、
SHAP 値および SHAP interaction 値で各 KO・KO ペアの寄与を定量化する。

CV 評価（Nested CV）は step5（05_bench_models.py）で実施済み。
本スクリプトは best_params_xgb.csv を読み込み、全データで最終モデルを学習して SHAP を計算する。

INPUT:
    --ko-profile-csv  ko_profile.csv  (sample × KO バイナリ行列)
    --response-csv    レスポンス変数 CSV (sample_id 列 + 数値列1つ以上)
    --response-col    使用するレスポンス列名 (省略時は sample_id 以外の最初の数値列)
    --output-dir      結果出力先（best_params_xgb.csv もここから読み込む）

OUTPUT:
    {output_dir}/models/
        xgb_final.joblib              最終モデル（全データ学習）
        xgb_scaler_final.joblib       対応 StandardScaler
    {output_dir}/
        ko_cols.txt                   KO 名リスト（SHAP 配列の軸対応）
        shap_values_xgb.csv           SHAP 値 (n_samples × n_features)
        shap_interaction_raw_xgb.npy  生 SHAP interaction 値 (n_samples, n_ko, n_ko)
        shap_interaction_mean_xgb.npy 平均 |interaction| 行列 (n_ko, n_ko)
        shap_interaction_top_pairs.csv 上位 N ペアの KO 組み合わせと寄与度
"""

import argparse
import json
import os
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import shap
from sklearn.preprocessing import StandardScaler
from xgboost import XGBRegressor

import subprocess


def _default_output_dir():
    return subprocess.check_output(["new-trial-dir"], text=True).strip()


def _build_xgb(params, random_state):
    """チューニング済みパラメータから XGBRegressor を構築"""
    return XGBRegressor(
        n_estimators=params["n_estimators"],
        max_depth=params["max_depth"],
        learning_rate=params["learning_rate"],
        subsample=params["subsample"],
        colsample_bytree=params["colsample_bytree"],
        reg_alpha=params["reg_alpha"],
        reg_lambda=params["reg_lambda"],
        tree_method="hist",
        random_state=random_state,
        n_jobs=-1,
        verbosity=0,
    )


def main():
    parser = argparse.ArgumentParser(
        description="KO profile × XGBoost ベンチマーク + SHAP 解析"
    )
    parser.add_argument("--ko-profile-csv", required=True)
    parser.add_argument("--response-csv",   required=True,
                        help="レスポンス変数 CSV (sample_id 列必須)")
    parser.add_argument("--response-col",   default=None,
                        help="レスポンス列名 (省略時: sample_id 以外の最初の数値列)")
    parser.add_argument("--output-dir",     default=None,
                        help="結果出力先 (default: output/{project_name}/{NNN}/)")
    parser.add_argument("--min-samples-ko", type=int, default=5,
                        help="KO 保有サンプル数の下限フィルタ (default: 5)")
    parser.add_argument("--random-state",   type=int, default=42)
    parser.add_argument("--top-n-pairs",    type=int, default=100,
                        help="shap_interaction_top_pairs.csv に出力する上位ペア数 (default: 100)")
    args = parser.parse_args()

    if args.output_dir is None:
        args.output_dir = _default_output_dir()
    os.makedirs(args.output_dir, exist_ok=True)

    models_dir = os.path.join(args.output_dir, "models")
    os.makedirs(models_dir, exist_ok=True)

    # ── データ読み込み ──────────────────────────────────────────────
    resp_df = pd.read_csv(args.response_csv)
    resp_df["sample_id"] = resp_df["sample_id"].astype(str)

    if args.response_col:
        resp_col = args.response_col
        if resp_col not in resp_df.columns:
            print(f"[ERROR] --response-col '{resp_col}' が CSV に存在しません。"
                  f"利用可能列: {list(resp_df.columns)}", file=sys.stderr)
            sys.exit(1)
    else:
        numeric_cols = [c for c in resp_df.columns
                        if c != "sample_id" and pd.api.types.is_numeric_dtype(resp_df[c])]
        if not numeric_cols:
            print("[ERROR] response CSV に数値列が見つかりません。", file=sys.stderr)
            sys.exit(1)
        resp_col = numeric_cols[0]
        print(f"[xgb_shap] レスポンス列を自動検出: '{resp_col}'")

    resp_dict = {r["sample_id"]: float(r[resp_col])
                 for _, r in resp_df.iterrows()
                 if not np.isnan(float(r[resp_col]))}

    profile_df = pd.read_csv(args.ko_profile_csv)
    profile_df["sample_id"] = profile_df["sample_id"].astype(str)
    profile_df = profile_df.set_index("sample_id")

    # ── サンプル & KO フィルタリング ───────────────────────────────
    common_sids = [s for s in profile_df.index if s in resp_dict]

    fold_arr = None
    if args.split_tsv:
        split_df = pd.read_csv(args.split_tsv, sep="\t")
        split_df["sample_id"] = split_df["sample_id"].astype(str)
        split_dict = dict(zip(split_df["sample_id"], split_df["fold"].astype(int)))
        before = len(common_sids)
        common_sids = [s for s in common_sids if s in split_dict]
        print(f"[xgb_shap] split-tsv 適用: {before} → {len(common_sids)} サンプル "
              f"({before - len(common_sids)} 件除外)")
        fold_arr = np.array([split_dict[s] for s in common_sids])

    ko_cols = [c for c in profile_df.columns
               if profile_df.loc[common_sids, c].sum() >= args.min_samples_ko]

    print(f"[xgb_shap] サンプル: {len(common_sids)}  KO特徴量: {len(ko_cols)}")

    X = profile_df.loc[common_sids, ko_cols].values.astype(np.float32)
    y = np.array([resp_dict[s] for s in common_sids], dtype=np.float32)
    sids_arr = np.array(common_sids)

    # KO 名リストを保存（SHAP 配列の軸対応用）
    Path(os.path.join(args.output_dir, "ko_cols.txt")).write_text("\n".join(ko_cols) + "\n")

    # ── CV 設定 ─────────────────────────────────────────────────────
    inner_cv = KFold(n_splits=3, shuffle=True, random_state=args.random_state)

    if fold_arr is not None:
        unique_folds = sorted(set(fold_arr))
        print(f"[xgb_shap] 共有 fold split 使用: {len(unique_folds)} folds")

        def _outer_cv_iter():
            for fi in unique_folds:
                te_idx = np.where(fold_arr == fi)[0]
                tr_idx = np.where(fold_arr != fi)[0]
                yield fi, tr_idx, te_idx
    else:
        outer_cv_kf = KFold(n_splits=5, shuffle=True, random_state=args.random_state)

        def _outer_cv_iter():
            for fi, (tr_idx, te_idx) in enumerate(outer_cv_kf.split(sids_arr)):
                yield fi, tr_idx, te_idx

    # ── Nested CV 評価 ──────────────────────────────────────────────
    all_preds = []
    all_r2_rows = []
    best_params_rows = []

    print("[xgb_shap] === XGB ===")
    for fold_idx, tr_idx, te_idx in _outer_cv_iter():
        X_tr, y_tr = X[tr_idx], y[tr_idx]
        X_te, y_te = X[te_idx], y[te_idx]

        print(f"  [xgb] Fold {fold_idx}: Optuna チューニング ({args.n_trials} trials)...")
        best_params, inner_r2 = _tune_xgb_with_optuna(
            X_tr, y_tr, inner_cv, args.n_trials, args.random_state, fold_idx
        )
        print(f"  [xgb] Fold {fold_idx}: 内側R²={inner_r2:.4f}, params={best_params}")
        best_params_rows.append({
            "fold": fold_idx,
            "inner_cv_r2": float(inner_r2),
            "params": json.dumps(best_params),
        })

        sc = StandardScaler().fit(X_tr)
        clf = _build_xgb(best_params, args.random_state)
        clf.fit(sc.transform(X_tr), y_tr)

        y_te_pred = clf.predict(sc.transform(X_te))
        r2 = r2_score(y_te, y_te_pred)
        print(f"  [xgb] Fold {fold_idx}: R²={r2:.4f}")
        all_r2_rows.append({"model": "xgb", "fold": fold_idx, "r2": float(r2)})

        for sid, yt, yp in zip(sids_arr[te_idx], y_te, y_te_pred):
            all_preds.append({
                "model": "xgb", "fold": fold_idx,
                "sample_id": sid, "response_col": resp_col,
                "y_true": float(yt), "y_pred": float(yp),
            })

    pred_df = pd.DataFrame(all_preds)
    pred_df.to_csv(os.path.join(args.output_dir, "sample_predictions_xgb.csv"), index=False)

    overall_r2 = r2_score(pred_df["y_true"], pred_df["y_pred"])
    print(f"  [xgb] 全fold R²={overall_r2:.4f}")
    all_r2_rows.append({"model": "xgb", "fold": "overall", "r2": float(overall_r2)})

    r2_df = pd.DataFrame(all_r2_rows)
    r2_df.to_csv(os.path.join(args.output_dir, "r2_scores_xgb.csv"), index=False)

    bp_df = pd.DataFrame(best_params_rows)
    bp_df.to_csv(os.path.join(args.output_dir, "best_params_xgb.csv"), index=False)
    print(f"  [xgb] best_params -> {args.output_dir}/best_params_xgb.csv")

    # ── Final model（全データで学習）────────────────────────────────
    best_row = max(best_params_rows, key=lambda r: r["inner_cv_r2"])
    best_params_final = json.loads(best_row["params"])
    print(f"  [xgb] Final model params (best inner R²={best_row['inner_cv_r2']:.4f}): {best_params_final}")

    sc_final = StandardScaler().fit(X)
    clf_final = _build_xgb(best_params_final, args.random_state)
    clf_final.fit(sc_final.transform(X), y)

    joblib.dump(clf_final, os.path.join(models_dir, "xgb_final.joblib"))
    joblib.dump(sc_final,  os.path.join(models_dir, "xgb_scaler_final.joblib"))
    print(f"  [xgb] Final model -> {models_dir}/xgb_final.joblib")

    # ── SHAP 値（通常）──────────────────────────────────────────────
    print("[xgb_shap] SHAP 値を計算中...")
    X_scaled = sc_final.transform(X).astype(np.float32)
    explainer = shap.TreeExplainer(clf_final)

    shap_values = explainer.shap_values(X_scaled)  # (n_samples, n_ko)
    shap_df = pd.DataFrame(shap_values, columns=ko_cols)
    shap_df.insert(0, "sample_id", common_sids)
    shap_df.to_csv(os.path.join(args.output_dir, "shap_values_xgb.csv"), index=False)
    print(f"  [xgb] SHAP values -> {args.output_dir}/shap_values_xgb.csv")

    # ── SHAP interaction 値 ──────────────────────────────────────────
    print("[xgb_shap] SHAP interaction 値を計算中（時間がかかります）...")
    shap_interaction = explainer.shap_interaction_values(X_scaled)
    # shape: (n_samples, n_ko, n_ko)
    shap_interaction = shap_interaction.astype(np.float32)

    # 生データを .npy 保存
    raw_path = os.path.join(args.output_dir, "shap_interaction_raw_xgb.npy")
    np.save(raw_path, shap_interaction)
    print(f"  [xgb] SHAP interaction raw -> {raw_path}  "
          f"shape={shap_interaction.shape}  "
          f"size={shap_interaction.nbytes / 1e9:.2f} GB")

    # 平均 |interaction| 行列 (n_ko, n_ko)
    mean_abs_interaction = np.abs(shap_interaction).mean(axis=0)  # (n_ko, n_ko)
    mean_path = os.path.join(args.output_dir, "shap_interaction_mean_xgb.npy")
    np.save(mean_path, mean_abs_interaction.astype(np.float32))
    print(f"  [xgb] SHAP interaction mean -> {mean_path}  shape={mean_abs_interaction.shape}")

    # 上位ペア CSV（対角・下三角を除いた上三角のみ）
    n_ko = len(ko_cols)
    rows_upper = []
    for i in range(n_ko):
        for j in range(i + 1, n_ko):
            rows_upper.append({
                "ko_i": ko_cols[i],
                "ko_j": ko_cols[j],
                "mean_abs_interaction": float(mean_abs_interaction[i, j]),
            })
    top_df = (pd.DataFrame(rows_upper)
              .sort_values("mean_abs_interaction", ascending=False)
              .head(args.top_n_pairs)
              .reset_index(drop=True))
    top_path = os.path.join(args.output_dir, "shap_interaction_top_pairs.csv")
    top_df.to_csv(top_path, index=False)
    print(f"  [xgb] SHAP interaction top {args.top_n_pairs} pairs -> {top_path}")

    print(f"[xgb_shap] 完了: {args.output_dir}")


if __name__ == "__main__":
    main()

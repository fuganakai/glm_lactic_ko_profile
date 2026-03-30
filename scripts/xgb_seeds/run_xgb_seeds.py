#!/usr/bin/env python3
"""
scripts/xgb_seeds/run_xgb_seeds.py — XGBoost Nested CV × 複数 random seed

SHAP 計算なし。指定した複数の random seed それぞれで Nested CV を実行し、
seed 間のばらつきを確認するためのスクリプト。

INPUT:
    --ko-profile-csv  ko_profile.csv  (sample × KO バイナリ行列)
    --response-csv    レスポンス変数 CSV (sample_id 列 + 数値列1つ以上)
    --response-col    使用するレスポンス列名 (省略時は sample_id 以外の最初の数値列)
    --split-tsv       共有 fold split TSV (sample_id 列 + fold 列)
                      省略時: 内部 KFold(5, shuffle, random_state)
    --seeds           実行する random seed のリスト (デフォルト: 0 1 2 3 4)
    --output-dir      結果出力先

OUTPUT:
    {output_dir}/
        sample_predictions_xgb.csv  全 seed × fold の予測値
        r2_scores_xgb.csv           seed × fold の R²
        best_params_xgb.csv         seed × fold の Optuna チューニング結果
        ko_cols.txt                 KO 名リスト
"""

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.metrics import r2_score
from sklearn.model_selection import KFold
from sklearn.preprocessing import StandardScaler
from xgboost import XGBRegressor

import subprocess


def _default_output_dir():
    return subprocess.check_output(["new-trial-dir"], text=True).strip()


def _tune_xgb_with_optuna(X_tr, y_tr, inner_cv, n_trials, random_state, fold_idx):
    """Optuna (TPE) で内側 3-fold CV を使って XGBoost をチューニング"""
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    def objective(trial):
        model = XGBRegressor(
            n_estimators=trial.suggest_categorical("n_estimators", [100, 300, 500, 1000]),
            max_depth=trial.suggest_int("max_depth", 3, 8),
            learning_rate=trial.suggest_float("learning_rate", 0.01, 0.3, log=True),
            subsample=trial.suggest_float("subsample", 0.6, 1.0),
            colsample_bytree=trial.suggest_float("colsample_bytree", 0.6, 1.0),
            reg_alpha=trial.suggest_float("reg_alpha", 1e-4, 10.0, log=True),
            reg_lambda=trial.suggest_float("reg_lambda", 1e-4, 10.0, log=True),
            tree_method="hist",
            random_state=random_state,
            n_jobs=-1,
            verbosity=0,
        )
        scores = []
        for tr_idx, val_idx in inner_cv.split(X_tr):
            X_in, X_val = X_tr[tr_idx], X_tr[val_idx]
            y_in, y_val = y_tr[tr_idx], y_tr[val_idx]
            sc = StandardScaler().fit(X_in)
            m = clone(model)
            m.fit(sc.transform(X_in), y_in)
            scores.append(r2_score(y_val, m.predict(sc.transform(X_val))))
        return float(np.mean(scores))

    study = optuna.create_study(
        direction="maximize",
        sampler=optuna.samplers.TPESampler(seed=random_state + fold_idx),
    )
    study.optimize(objective, n_trials=n_trials, show_progress_bar=False)
    return study.best_params, study.best_value


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


def run_one_seed(seed, X, y, sids_arr, ko_cols, resp_col, n_trials, split_tsv_info):
    """1 seed 分の Nested CV を実行し、結果の dict を返す"""
    fold_arr, unique_folds = split_tsv_info

    inner_cv = KFold(n_splits=3, shuffle=True, random_state=seed)

    if fold_arr is not None:
        def _outer_cv_iter():
            for fi in unique_folds:
                te_idx = np.where(fold_arr == fi)[0]
                tr_idx = np.where(fold_arr != fi)[0]
                yield fi, tr_idx, te_idx
    else:
        outer_cv_kf = KFold(n_splits=5, shuffle=True, random_state=seed)

        def _outer_cv_iter():
            for fi, (tr_idx, te_idx) in enumerate(outer_cv_kf.split(sids_arr)):
                yield fi, tr_idx, te_idx

    all_preds = []
    all_r2_rows = []
    best_params_rows = []

    for fold_idx, tr_idx, te_idx in _outer_cv_iter():
        X_tr, y_tr = X[tr_idx], y[tr_idx]
        X_te, y_te = X[te_idx], y[te_idx]

        print(f"  [seed={seed}] Fold {fold_idx}: Optuna チューニング ({n_trials} trials)...")
        best_params, inner_r2 = _tune_xgb_with_optuna(
            X_tr, y_tr, inner_cv, n_trials, seed, fold_idx
        )
        print(f"  [seed={seed}] Fold {fold_idx}: 内側R²={inner_r2:.4f}, params={best_params}")
        best_params_rows.append({
            "seed": seed,
            "fold": fold_idx,
            "inner_cv_r2": float(inner_r2),
            "params": json.dumps(best_params),
        })

        sc = StandardScaler().fit(X_tr)
        clf = _build_xgb(best_params, seed)
        clf.fit(sc.transform(X_tr), y_tr)

        y_te_pred = clf.predict(sc.transform(X_te))
        r2 = r2_score(y_te, y_te_pred)
        print(f"  [seed={seed}] Fold {fold_idx}: R²={r2:.4f}")
        all_r2_rows.append({"seed": seed, "fold": fold_idx, "r2": float(r2)})

        for sid, yt, yp in zip(sids_arr[te_idx], y_te, y_te_pred):
            all_preds.append({
                "seed": seed,
                "fold": fold_idx,
                "sample_id": sid,
                "response_col": resp_col,
                "y_true": float(yt),
                "y_pred": float(yp),
            })

    overall_r2 = r2_score(
        [r["y_true"] for r in all_preds],
        [r["y_pred"] for r in all_preds],
    )
    print(f"  [seed={seed}] 全fold R²={overall_r2:.4f}")
    all_r2_rows.append({"seed": seed, "fold": "overall", "r2": float(overall_r2)})

    return all_preds, all_r2_rows, best_params_rows


def main():
    parser = argparse.ArgumentParser(
        description="KO profile × XGBoost Nested CV（複数 random seed、SHAP なし）"
    )
    parser.add_argument("--ko-profile-csv", required=True)
    parser.add_argument("--response-csv",   required=True,
                        help="レスポンス変数 CSV (sample_id 列必須)")
    parser.add_argument("--response-col",   default=None,
                        help="レスポンス列名 (省略時: sample_id 以外の最初の数値列)")
    parser.add_argument("--split-tsv",      default=None,
                        help="共有 fold split TSV (sample_id, fold 列。省略時: 内部 KFold)")
    parser.add_argument("--seeds",          type=int, nargs="+", default=[0, 1, 2, 3, 4],
                        help="実行する random seed のリスト (デフォルト: 0 1 2 3 4)")
    parser.add_argument("--output-dir",     default=None,
                        help="結果出力先 (default: output/{project_name}/{NNN}/)")
    parser.add_argument("--min-samples-ko", type=int, default=5,
                        help="KO 保有サンプル数の下限フィルタ (default: 5)")
    parser.add_argument("--n-trials",       type=int, default=50,
                        help="Optuna チューニング試行数 (default: 50)")
    args = parser.parse_args()

    if args.output_dir is None:
        args.output_dir = _default_output_dir()
    os.makedirs(args.output_dir, exist_ok=True)

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
        print(f"[xgb_seeds] レスポンス列を自動検出: '{resp_col}'")

    resp_dict = {r["sample_id"]: float(r[resp_col])
                 for _, r in resp_df.iterrows()
                 if not np.isnan(float(r[resp_col]))}

    profile_df = pd.read_csv(args.ko_profile_csv)
    profile_df["sample_id"] = profile_df["sample_id"].astype(str)
    profile_df = profile_df.set_index("sample_id")

    # ── サンプル & KO フィルタリング ───────────────────────────────
    common_sids = [s for s in profile_df.index if s in resp_dict]

    fold_arr = None
    unique_folds = None
    if args.split_tsv:
        split_df = pd.read_csv(args.split_tsv, sep="\t")
        split_df["sample_id"] = split_df["sample_id"].astype(str)
        split_dict = dict(zip(split_df["sample_id"], split_df["fold"].astype(int)))
        before = len(common_sids)
        common_sids = [s for s in common_sids if s in split_dict]
        print(f"[xgb_seeds] split-tsv 適用: {before} → {len(common_sids)} サンプル "
              f"({before - len(common_sids)} 件除外)")
        fold_arr = np.array([split_dict[s] for s in common_sids])
        unique_folds = sorted(set(fold_arr))

    ko_cols = [c for c in profile_df.columns
               if profile_df.loc[common_sids, c].sum() >= args.min_samples_ko]

    print(f"[xgb_seeds] サンプル: {len(common_sids)}  KO特徴量: {len(ko_cols)}")
    print(f"[xgb_seeds] Seeds: {args.seeds}")

    X = profile_df.loc[common_sids, ko_cols].values.astype(np.float32)
    y = np.array([resp_dict[s] for s in common_sids], dtype=np.float32)
    sids_arr = np.array(common_sids)

    # KO 名リストを保存
    Path(os.path.join(args.output_dir, "ko_cols.txt")).write_text("\n".join(ko_cols) + "\n")

    split_tsv_info = (fold_arr, unique_folds)

    # ── 全 seed ループ ──────────────────────────────────────────────
    all_preds_combined = []
    all_r2_combined = []
    best_params_combined = []

    for seed in args.seeds:
        print(f"\n[xgb_seeds] === Seed {seed} ===")
        preds, r2_rows, bp_rows = run_one_seed(
            seed, X, y, sids_arr, ko_cols, resp_col, args.n_trials, split_tsv_info
        )
        all_preds_combined.extend(preds)
        all_r2_combined.extend(r2_rows)
        best_params_combined.extend(bp_rows)

    # ── 結果保存 ────────────────────────────────────────────────────
    pred_df = pd.DataFrame(all_preds_combined)
    pred_df.to_csv(os.path.join(args.output_dir, "sample_predictions_xgb.csv"), index=False)

    r2_df = pd.DataFrame(all_r2_combined)
    r2_df.to_csv(os.path.join(args.output_dir, "r2_scores_xgb.csv"), index=False)

    bp_df = pd.DataFrame(best_params_combined)
    bp_df.to_csv(os.path.join(args.output_dir, "best_params_xgb.csv"), index=False)

    # ── seed 間サマリ ────────────────────────────────────────────────
    overall_rows = r2_df[r2_df["fold"] == "overall"].copy()
    overall_rows["r2"] = overall_rows["r2"].astype(float)
    print(f"\n[xgb_seeds] === seed 間サマリ ===")
    print(f"  R² mean ± std: {overall_rows['r2'].mean():.4f} ± {overall_rows['r2'].std():.4f}")
    print(f"  R² min / max:  {overall_rows['r2'].min():.4f} / {overall_rows['r2'].max():.4f}")
    print(f"\n[xgb_seeds] 完了: {args.output_dir}")


if __name__ == "__main__":
    main()

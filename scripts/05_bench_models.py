#!/usr/bin/env python3
"""
scripts/05_bench_models.py — KO profile × Lasso / Ridge / RandomForest / MLP ベンチマーク

embedding を使わず、KO 存在/不在バイナリ行列のみを特徴量として
Lasso / Ridge / RandomForest / MLP でレスポンス変数を予測する。

RF と MLP は Optuna (TPE) による Nested CV ハイパーパラメータチューニングを実施。
  外側: 5-fold CV（性能評価）
  内側: 3-fold CV（Optuna で R² 最大化）

INPUT:
    --ko-profile-csv  ko_profile.csv  (sample × KO バイナリ行列)
    --response-csv    レスポンス変数 CSV (sample_id 列 + 数値列1つ以上)
    --response-col    使用するレスポンス列名 (省略時は sample_id 以外の最初の数値列)
    --split-tsv       共有 fold split TSV (sample_id 列 + fold 列)
                      省略時: 内部 KFold(5, shuffle, random_state)
    --output-dir      結果出力先

OUTPUT:
    {output_dir}/sample_predictions_{model}.csv   (model ごと)
    {output_dir}/r2_scores.csv                    (全モデル × 全fold)
    {output_dir}/feature_importances.csv          (Lasso/Ridge/RF の KO 寄与度)
    {output_dir}/best_params_{rf,mlp}.csv         (Optuna チューニング結果)
"""

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LassoCV, RidgeCV
from sklearn.metrics import r2_score
from sklearn.model_selection import KFold
from sklearn.neural_network import MLPRegressor
from sklearn.preprocessing import StandardScaler

import subprocess

# Optuna でハイパーパラメータをチューニングするモデル
_OPTUNA_MODELS = {"rf", "mlp"}


def _default_output_dir():
    return subprocess.check_output(["new-trial-dir"], text=True).strip()


def _tune_with_optuna(X_tr, y_tr, model_type, inner_cv, n_trials, random_state, fold_idx):
    """Optuna (TPE) で内側 3-fold CV を使ってハイパーパラメータをチューニング"""
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    def objective(trial):
        if model_type == "rf":
            model = RandomForestRegressor(
                n_estimators=trial.suggest_categorical("n_estimators", [100, 200, 300, 500]),
                max_depth=trial.suggest_categorical("max_depth", [None, 5, 10, 20]),
                max_features=trial.suggest_categorical("max_features", ["sqrt", "log2", 0.3]),
                min_samples_leaf=trial.suggest_categorical("min_samples_leaf", [1, 2, 4, 8]),
                random_state=random_state,
                n_jobs=-1,
            )
        else:  # mlp
            n_layers = trial.suggest_int("n_layers", 1, 3)
            layer_size = trial.suggest_categorical("layer_size", [64, 128, 256])
            model = MLPRegressor(
                hidden_layer_sizes=tuple([layer_size] * n_layers),
                activation=trial.suggest_categorical("activation", ["relu", "tanh"]),
                alpha=trial.suggest_float("alpha", 1e-4, 1.0, log=True),
                learning_rate_init=trial.suggest_float("learning_rate_init", 1e-4, 1e-2, log=True),
                max_iter=1000,
                early_stopping=True,
                random_state=random_state,
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


def _build_tuned_model(model_type, best_params, random_state):
    """チューニング済みパラメータからモデルインスタンスを構築"""
    if model_type == "rf":
        return RandomForestRegressor(
            n_estimators=best_params["n_estimators"],
            max_depth=best_params["max_depth"],
            max_features=best_params["max_features"],
            min_samples_leaf=best_params["min_samples_leaf"],
            random_state=random_state,
            n_jobs=-1,
        )
    else:  # mlp
        n_layers = best_params["n_layers"]
        layer_size = best_params["layer_size"]
        return MLPRegressor(
            hidden_layer_sizes=tuple([layer_size] * n_layers),
            activation=best_params["activation"],
            alpha=best_params["alpha"],
            learning_rate_init=best_params["learning_rate_init"],
            max_iter=1000,
            early_stopping=True,
            random_state=random_state,
        )


def main():
    parser = argparse.ArgumentParser(
        description="KO profile × Lasso/Ridge/RF/MLP ベンチマーク"
    )
    parser.add_argument("--ko-profile-csv", required=True)
    parser.add_argument("--response-csv",  required=True,
                        help="レスポンス変数 CSV (sample_id 列必須)")
    parser.add_argument("--response-col",  default=None,
                        help="レスポンス列名 (省略時: sample_id 以外の最初の数値列)")
    parser.add_argument("--split-tsv",     default=None,
                        help="共有 fold split TSV (sample_id, fold 列。省略時: 内部 KFold)")
    parser.add_argument("--output-dir",    default=None,
                        help="結果出力先 (default: output/{project_name}/{NNN}/)")
    parser.add_argument("--model",          default="all",
                        choices=["lasso", "ridge", "rf", "mlp", "all"],
                        help="使用するモデル (default: all)")
    parser.add_argument("--min-samples-ko", type=int, default=5,
                        help="KO保有サンプル数の下限フィルタ (default: 5)")
    parser.add_argument("--random-state",   type=int, default=42)
    parser.add_argument("--n-estimators",   type=int, default=500,
                        help="Optuna 非使用時の RF 木の数 (default: 500)")
    parser.add_argument("--n-trials-rf",    type=int, default=50,
                        help="RF の Optuna チューニング試行数 (default: 50)")
    parser.add_argument("--n-trials-mlp",   type=int, default=80,
                        help="MLP の Optuna チューニング試行数 (default: 80)")
    parser.add_argument("--top-n-ko",       type=int, default=30,
                        help="feature_importances.csv に出力する上位KO数 (default: 30)")
    args = parser.parse_args()

    if args.output_dir is None:
        args.output_dir = _default_output_dir()
    os.makedirs(args.output_dir, exist_ok=True)

    # ── データ読み込み ──────────────────────────────────────────────
    resp_df = pd.read_csv(args.response_csv)
    resp_df["sample_id"] = resp_df["sample_id"].astype(str)

    # レスポンス列の決定（指定がなければ sample_id 以外の最初の数値列）
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
        print(f"[bench_models] レスポンス列を自動検出: '{resp_col}'")

    resp_dict = {r["sample_id"]: float(r[resp_col])
                 for _, r in resp_df.iterrows()
                 if not np.isnan(float(r[resp_col]))}

    profile_df = pd.read_csv(args.ko_profile_csv)
    profile_df["sample_id"] = profile_df["sample_id"].astype(str)
    profile_df = profile_df.set_index("sample_id")

    # ── サンプル & KO フィルタリング ───────────────────────────────
    common_sids = [s for s in profile_df.index if s in resp_dict]

    # split-tsv が指定された場合: そのサンプルに絞り込み、fold 番号を取得
    fold_arr = None
    if args.split_tsv:
        split_df = pd.read_csv(args.split_tsv, sep="\t")
        split_df["sample_id"] = split_df["sample_id"].astype(str)
        split_dict = dict(zip(split_df["sample_id"], split_df["fold"].astype(int)))
        before = len(common_sids)
        common_sids = [s for s in common_sids if s in split_dict]
        print(f"[bench_models] split-tsv 適用: {before} → {len(common_sids)} サンプル "
              f"({before - len(common_sids)} 件除外)")
        fold_arr = np.array([split_dict[s] for s in common_sids])

    ko_cols = [c for c in profile_df.columns
               if profile_df.loc[common_sids, c].sum() >= args.min_samples_ko]

    print(f"[bench_models] サンプル: {len(common_sids)}  KO特徴量: {len(ko_cols)}")

    X = profile_df.loc[common_sids, ko_cols].values.astype(np.float32)
    y = np.array([resp_dict[s] for s in common_sids], dtype=np.float32)

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
            result.append(("rf", None))   # Optuna で fold ごとに決定
        if model_arg in ("mlp", "all"):
            result.append(("mlp", None))  # Optuna で fold ごとに決定
        return result

    models_to_run = make_models(args.model)
    n_trials_map = {"rf": args.n_trials_rf, "mlp": args.n_trials_mlp}

    # 外側 CV: split-tsv の fold を使用 / なければ内部 KFold(5)
    # 内側は常に KFold(3) (Optuna ハイパーパラメータ探索用)
    inner_cv = KFold(n_splits=3, shuffle=True, random_state=args.random_state)
    sids_arr = np.array(common_sids)

    if fold_arr is not None:
        unique_folds = sorted(set(fold_arr))
        print(f"[bench_models] 共有 fold split 使用: {len(unique_folds)} folds "
              f"({sorted(set(fold_arr))})")

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

    all_r2_rows = []
    # 寄与度の累積は Lasso / Ridge / RF のみ（MLP は解釈困難なため省略）
    importance_accum = {
        name: np.zeros(len(ko_cols))
        for name, _ in models_to_run if name in ("lasso", "ridge", "rf")
    }
    fold_counts = {
        name: 0
        for name, _ in models_to_run if name in ("lasso", "ridge", "rf")
    }

    for model_name, clf_template in models_to_run:
        all_preds = []
        best_params_rows = []

        print(f"[bench_models] === {model_name.upper()} ===")

        for fold_idx, tr_idx, te_idx in _outer_cv_iter():
            X_tr, y_tr = X[tr_idx], y[tr_idx]
            X_te, y_te = X[te_idx], y[te_idx]

            if model_name in _OPTUNA_MODELS:
                n_tr = n_trials_map[model_name]
                print(f"  [{model_name}] Fold {fold_idx}: Optuna チューニング ({n_tr} trials)...")
                best_params, inner_r2 = _tune_with_optuna(
                    X_tr, y_tr, model_name, inner_cv, n_tr, args.random_state, fold_idx
                )
                print(f"  [{model_name}] Fold {fold_idx}: 内側R²={inner_r2:.4f}, params={best_params}")
                clf = _build_tuned_model(model_name, best_params, args.random_state)
                best_params_rows.append({
                    "fold": fold_idx,
                    "inner_cv_r2": float(inner_r2),
                    "params": json.dumps(best_params),
                })
            else:
                clf = type(clf_template)(**clf_template.get_params())

            sc = StandardScaler().fit(X_tr)
            clf.fit(sc.transform(X_tr), y_tr)

            y_te_pred = clf.predict(sc.transform(X_te))
            r2 = r2_score(y_te, y_te_pred)
            print(f"  [{model_name}] Fold {fold_idx}: R²={r2:.4f}")

            all_r2_rows.append({"model": model_name, "fold": fold_idx, "r2": float(r2)})

            for sid, yt, yp in zip(sids_arr[te_idx], y_te, y_te_pred):
                all_preds.append({
                    "model": model_name, "fold": fold_idx,
                    "sample_id": sid, "response_col": resp_col,
                    "y_true": float(yt), "y_pred": float(yp),
                })

            # ── 寄与度の収集 ───────────────────────────────────────
            if model_name == "rf":
                importance_accum[model_name] += clf.feature_importances_
                fold_counts[model_name] += 1
            elif model_name in ("lasso", "ridge"):
                importance_accum[model_name] += np.abs(clf.coef_)
                fold_counts[model_name] += 1

        pred_df = pd.DataFrame(all_preds)
        pred_df.to_csv(
            os.path.join(args.output_dir, f"sample_predictions_{model_name}.csv"), index=False)

        overall_r2 = r2_score(pred_df["y_true"], pred_df["y_pred"])
        print(f"  [{model_name}] 全fold R²={overall_r2:.4f}")
        all_r2_rows.append({"model": model_name, "fold": "overall", "r2": float(overall_r2)})

        # Optuna チューニング結果を保存
        if best_params_rows:
            bp_df = pd.DataFrame(best_params_rows)
            bp_df.to_csv(
                os.path.join(args.output_dir, f"best_params_{model_name}.csv"), index=False)
            print(f"  [{model_name}] best_params -> {args.output_dir}/best_params_{model_name}.csv")

    # ── R² スコアの保存 ────────────────────────────────────────────
    r2_df = pd.DataFrame(all_r2_rows)
    r2_df.to_csv(os.path.join(args.output_dir, "r2_scores.csv"), index=False)
    print(f"[bench_models] R² scores -> {args.output_dir}/r2_scores.csv")

    # ── 寄与度の保存（Lasso / Ridge / RF のみ）─────────────────────
    imp_df = pd.DataFrame({"ko": ko_cols})
    for model_name, _ in models_to_run:
        if model_name not in importance_accum:
            continue
        avg_imp = importance_accum[model_name] / max(fold_counts[model_name], 1)
        imp_df[f"importance_{model_name}"] = avg_imp

    imp_cols = [c for c in imp_df.columns if c.startswith("importance_")]
    imp_df["importance_sum"] = imp_df[imp_cols].sum(axis=1)
    imp_df = imp_df.sort_values("importance_sum", ascending=False).reset_index(drop=True)
    imp_df.to_csv(os.path.join(args.output_dir, "feature_importances.csv"), index=False)
    print(f"[bench_models] Feature importances -> {args.output_dir}/feature_importances.csv")

    print(f"[bench_models] 完了: {args.output_dir}")


if __name__ == "__main__":
    main()

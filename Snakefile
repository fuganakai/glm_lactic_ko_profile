# ============================================================
# Snakefile  —  KO profile パイプライン (スタンドアロン版)
#
# 入力: {genome_dir}/{sample}.fna
# 出力: Lasso / Ridge / RF / MLP による各レスポンス変数の予測
#
# 実行モード:
#   デフォルト:           内部 KFold(5) による CV
#   split_info_dir 指定時: 共有 fold split (seed 別) + seed 間集約サマリー
#
# 実行: pipeline.sh を使うこと
# ============================================================

configfile: "config/pipeline.yaml"

from pathlib import Path

_PROC = "data/glm_lactic_ko_profile/processed"

# ── filtered_samples.txt（pipeline.sh が事前に生成）────────────
_filtered = Path(f"{_PROC}/filtered_samples.txt")
SAMPLES = [s.strip() for s in _filtered.read_text().splitlines() if s.strip()] \
    if _filtered.exists() else []

# ── レスポンスデータセット: response_csv_dir/*.csv のステム名 ───
_resp_dir = Path(config["response_csv_dir"])
DATASETS = [p.stem for p in sorted(_resp_dir.glob("*.csv"))] \
    if _resp_dir.exists() else []

RESULTS = config["results_dir"]
TRIAL_DIR = config["trial_dir"]

# ── 共有 fold split モードの設定 ───────────────────────────────
_split_dir_str = config.get("split_info_dir", "")
_split_dir = Path(_split_dir_str) if _split_dir_str else Path("")
USE_EXTERNAL_SPLITS = bool(_split_dir_str) and _split_dir.exists()
SEEDS = config.get("seeds", list(range(40, 50)))  # デフォルト: 40〜49

# ── rule all の入力リストを Python で条件分岐して構築 ──────────
if USE_EXTERNAL_SPLITS:
    # 共有 fold split モード: seed 別 + summary
    _all_inputs = (
        expand(f"{RESULTS}/{{dataset}}/summary/r2_mean_std.csv",            dataset=DATASETS)
        + expand(f"{RESULTS}/{{dataset}}/summary/feature_importance_mean.csv", dataset=DATASETS)
        + expand(f"{RESULTS}/{{dataset}}/summary/sample_predictions_all.csv",  dataset=DATASETS)
        + expand(f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/r2_comparison.png",
                 dataset=DATASETS, seed=SEEDS)
        + expand(f"{RESULTS}/{{dataset}}/seed{{seed}}/shap_interaction_top_pairs.csv",
                 dataset=DATASETS, seed=SEEDS)
        + [f"{RESULTS}/figures/r2_all_datasets.png"]
    )
else:
    # デフォルトモード: 内部 KFold
    _all_inputs = (
        expand(f"{RESULTS}/{{dataset}}/r2_scores.csv",           dataset=DATASETS)
        + expand(f"{RESULTS}/{{dataset}}/feature_importances.csv",  dataset=DATASETS)
        + expand(f"{RESULTS}/{{dataset}}/figures/r2_comparison.png", dataset=DATASETS)
        + expand(f"{RESULTS}/{{dataset}}/shap_interaction_top_pairs.csv", dataset=DATASETS)
        + [f"{RESULTS}/figures/r2_all_datasets.png"]
    )


# visualize_ext ({dataset}/seed{seed}) は visualize ({dataset}) より優先
ruleorder: visualize_ext > visualize
# xgb_shap_ext ({dataset}/seed{seed}) は xgb_shap ({dataset}) より優先
ruleorder: xgb_shap_ext > xgb_shap


# ============================================================
# ゴール
# ============================================================
rule all:
    input: _all_inputs


# ============================================================
# Step 0: サンプルフィルタリング（ゲノム長のみ）
# ============================================================
rule filter_samples:
    output:
        filtered = f"{_PROC}/filtered_samples.txt"
    log:
        f"{TRIAL_DIR}/logs/00_filter_samples.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/00_filter_samples.py \
            --genome-dir     {config[genome_dir]} \
            --min-genome-len {config[min_genome_len]} \
            --output         {output.filtered} > {log} 2>&1
        """


# ============================================================
# Step 1: Prokka
# ============================================================
rule run_prokka:
    input:
        fna = lambda w: f"{config['genome_dir']}/{w.sample}.fna"
    output:
        faa = f"{_PROC}/prokka_out/{{sample}}/{{sample}}.faa"
    params:
        outdir = lambda w: f"{_PROC}/prokka_out/{w.sample}"
    log:
        f"{TRIAL_DIR}/logs/01_prokka/{{sample}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_prokka]}
        bash scripts/01_run_prokka.sh \
            --fna        {input.fna} \
            --sample     {wildcards.sample} \
            --output-dir {params.outdir} \
            --cpus       ${{NSLOTS:-1}} > {log} 2>&1
        """


# ============================================================
# Step 2: KoFamScan
# ============================================================
rule run_kofamscan:
    input:
        faa = f"{_PROC}/prokka_out/{{sample}}/{{sample}}.faa"
    output:
        txt = f"{_PROC}/kofamscan_out/{{sample}}.txt"
    log:
        f"{TRIAL_DIR}/logs/02_kofamscan/{{sample}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_kofam]}
        bash scripts/02_run_kofamscan.sh \
            --faa           {input.faa} \
            --sample        {wildcards.sample} \
            --kofamscan-dir {config[kofamscan_dir]} \
            --ko-list       {config[kofamscan_ko_list]} \
            --profiles      {config[kofamscan_profiles]} \
            --output        {output.txt} \
            --cpus          ${{NSLOTS:-1}} > {log} 2>&1
        """


# ============================================================
# Step 3: kofamscan 出力 → KO CSV
# ============================================================
rule kofamscan_to_csv:
    input:
        txt = f"{_PROC}/kofamscan_out/{{sample}}.txt"
    output:
        csv = f"{_PROC}/ko_annotations/{{sample}}_genome.csv"
    log:
        f"{TRIAL_DIR}/logs/03_kofamscan_to_csv/{{sample}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/03_kofamscan_to_csv.py \
            --input {input.txt} --output {output.csv} > {log} 2>&1
        """


# ============================================================
# Step 4: KO profile マトリクス作成
# ============================================================
rule make_ko_profile:
    input:
        ko_csvs = expand(f"{_PROC}/ko_annotations/{{sample}}_genome.csv", sample=SAMPLES)
    output:
        profile = f"{_PROC}/ko_profile.csv",
        ko_list = f"{_PROC}/ko_list.txt"
    params:
        ko_annot_dir = f"{_PROC}/ko_annotations"
    log:
        f"{TRIAL_DIR}/logs/04_make_ko_profile.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/04_make_ko_profile.py \
            --ko-annot-dir   {params.ko_annot_dir} \
            --min-samples-ko {config[min_samples_ko]} \
            --output-profile {output.profile} \
            --output-ko-list {output.ko_list} > {log} 2>&1
        """


# ============================================================
# Step 5a (デフォルト): 内部 KFold による予測
#   出力: {results_dir}/{dataset}/
# ============================================================
rule bench_models:
    input:
        ko_profile   = f"{_PROC}/ko_profile.csv",
        response_csv = lambda w: f"{config['response_csv_dir']}/{w.dataset}.csv"
    output:
        lasso           = f"{RESULTS}/{{dataset}}/sample_predictions_lasso.csv",
        ridge           = f"{RESULTS}/{{dataset}}/sample_predictions_ridge.csv",
        rf              = f"{RESULTS}/{{dataset}}/sample_predictions_rf.csv",
        mlp             = f"{RESULTS}/{{dataset}}/sample_predictions_mlp.csv",
        r2_scores       = f"{RESULTS}/{{dataset}}/r2_scores.csv",
        importances     = f"{RESULTS}/{{dataset}}/feature_importances.csv",
        prevalence      = f"{RESULTS}/{{dataset}}/ko_prevalence.csv",
        best_params_rf  = f"{RESULTS}/{{dataset}}/best_params_rf.csv",
        best_params_mlp = f"{RESULTS}/{{dataset}}/best_params_mlp.csv"
    log:
        f"{TRIAL_DIR}/logs/05_bench_models/{{dataset}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/05_bench_models.py \
            --ko-profile-csv {input.ko_profile} \
            --response-csv   {input.response_csv} \
            --output-dir     {RESULTS}/{wildcards.dataset} \
            --model          all \
            --random-state   {config[random_state]} \
            --n-estimators   {config[n_estimators]} \
            --n-trials-rf    {config[n_trials_rf]} \
            --n-trials-mlp   {config[n_trials_mlp]} > {log} 2>&1
        """


# ============================================================
# Step 5b (共有 fold split モード): seed × dataset ごとに実行
#   出力: {results_dir}/{dataset}/seed{seed}/
#   split_tsv: {split_info_dir}/{dataset}/{dataset}_5fold_seed{seed}.tsv
# ============================================================
rule bench_models_ext:
    input:
        ko_profile   = f"{_PROC}/ko_profile.csv",
        response_csv = lambda w: f"{config['response_csv_dir']}/{w.dataset}.csv",
        split_tsv    = lambda w: (
            f"{config['split_info_dir']}/{w.dataset}/"
            f"{w.dataset}_5fold_seed{w.seed}.tsv"
        )
    output:
        lasso           = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_lasso.csv",
        ridge           = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_ridge.csv",
        rf              = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_rf.csv",
        mlp             = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_mlp.csv",
        r2_scores       = f"{RESULTS}/{{dataset}}/seed{{seed}}/r2_scores.csv",
        importances     = f"{RESULTS}/{{dataset}}/seed{{seed}}/feature_importances.csv",
        prevalence      = f"{RESULTS}/{{dataset}}/seed{{seed}}/ko_prevalence.csv",
        best_params_rf  = f"{RESULTS}/{{dataset}}/seed{{seed}}/best_params_rf.csv",
        best_params_mlp = f"{RESULTS}/{{dataset}}/seed{{seed}}/best_params_mlp.csv"
    log:
        f"{TRIAL_DIR}/logs/05_bench_models_ext/{{dataset}}_seed{{seed}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/05_bench_models.py \
            --ko-profile-csv {input.ko_profile} \
            --response-csv   {input.response_csv} \
            --split-tsv      {input.split_tsv} \
            --output-dir     {RESULTS}/{wildcards.dataset}/seed{wildcards.seed} \
            --model          all \
            --random-state   {wildcards.seed} \
            --n-estimators   {config[n_estimators]} \
            --n-trials-rf    {config[n_trials_rf]} \
            --n-trials-mlp   {config[n_trials_mlp]} > {log} 2>&1
        """


# ============================================================
# Step 5c: seed 間集約サマリー
#   入力: bench_models_ext の全 seed 出力
#   出力: {results_dir}/{dataset}/summary/
# ============================================================
rule aggregate_seeds:
    input:
        r2_files = expand(
            f"{RESULTS}/{{dataset}}/seed{{seed}}/r2_scores.csv",
            seed=SEEDS,
            allow_missing=True,
        )
    output:
        r2_summary  = f"{RESULTS}/{{dataset}}/summary/r2_mean_std.csv",
        imp_summary = f"{RESULTS}/{{dataset}}/summary/feature_importance_mean.csv",
        pred_all    = f"{RESULTS}/{{dataset}}/summary/sample_predictions_all.csv"
    log:
        f"{TRIAL_DIR}/logs/07_aggregate_seeds/{{dataset}}.log"
    params:
        seeds = " ".join(str(s) for s in SEEDS)
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/07_aggregate_seeds.py \
            --results-dir {RESULTS}/{wildcards.dataset} \
            --seeds {params.seeds} > {log} 2>&1
        """


# ============================================================
# Step 8: 全データセット横断 R² 比較プロット
# ============================================================
rule visualize_all_datasets:
    input:
        r2_files = (
            expand(f"{RESULTS}/{{dataset}}/summary/r2_mean_std.csv", dataset=DATASETS)
            if USE_EXTERNAL_SPLITS else
            expand(f"{RESULTS}/{{dataset}}/r2_scores.csv", dataset=DATASETS)
        )
    output:
        fig = f"{RESULTS}/figures/r2_all_datasets.png"
    log:
        f"{TRIAL_DIR}/logs/08_visualize_all_datasets.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/08_visualize_all_datasets.py \
            --results-dir {RESULTS} \
            --output-dir  {RESULTS}/figures > {log} 2>&1
        """


# ============================================================
# Step 6a (デフォルト): 可視化
# ============================================================
rule visualize:
    input:
        r2_scores   = f"{RESULTS}/{{dataset}}/r2_scores.csv",
        importances = f"{RESULTS}/{{dataset}}/feature_importances.csv",
        prevalence  = f"{RESULTS}/{{dataset}}/ko_prevalence.csv",
        pred_lasso  = f"{RESULTS}/{{dataset}}/sample_predictions_lasso.csv",
        pred_ridge  = f"{RESULTS}/{{dataset}}/sample_predictions_ridge.csv",
        pred_rf     = f"{RESULTS}/{{dataset}}/sample_predictions_rf.csv",
        pred_mlp    = f"{RESULTS}/{{dataset}}/sample_predictions_mlp.csv"
    output:
        fig1 = f"{RESULTS}/{{dataset}}/figures/r2_comparison.png",
        fig2 = f"{RESULTS}/{{dataset}}/figures/pred_vs_actual.png",
        fig3 = f"{RESULTS}/{{dataset}}/figures/feature_importance_ranking.png",
        fig4 = f"{RESULTS}/{{dataset}}/figures/r2_cv_distribution.png",
        fig5 = f"{RESULTS}/{{dataset}}/figures/feature_importance_heatmap.png",
        fig6 = f"{RESULTS}/{{dataset}}/figures/prevalence_vs_importance.png",
        fig7 = f"{RESULTS}/{{dataset}}/figures/cumulative_importance.png"
    log:
        f"{TRIAL_DIR}/logs/06_visualize/{{dataset}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/06_visualize.py \
            --results-dir {RESULTS}/{wildcards.dataset} \
            --output-dir  {RESULTS}/{wildcards.dataset}/figures \
            --top-n-ko    {config[top_n_ko]} > {log} 2>&1
        """


# ============================================================
# Step 6b (共有 fold split モード): seed 別の可視化
# ============================================================
rule visualize_ext:
    input:
        r2_scores   = f"{RESULTS}/{{dataset}}/seed{{seed}}/r2_scores.csv",
        importances = f"{RESULTS}/{{dataset}}/seed{{seed}}/feature_importances.csv",
        prevalence  = f"{RESULTS}/{{dataset}}/seed{{seed}}/ko_prevalence.csv",
        pred_lasso  = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_lasso.csv",
        pred_ridge  = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_ridge.csv",
        pred_rf     = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_rf.csv",
        pred_mlp    = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_mlp.csv"
    output:
        fig1 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/r2_comparison.png",
        fig2 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/pred_vs_actual.png",
        fig3 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/feature_importance_ranking.png",
        fig4 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/r2_cv_distribution.png",
        fig5 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/feature_importance_heatmap.png",
        fig6 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/prevalence_vs_importance.png",
        fig7 = f"{RESULTS}/{{dataset}}/seed{{seed}}/figures/cumulative_importance.png"
    log:
        f"{TRIAL_DIR}/logs/06_visualize_ext/{{dataset}}_seed{{seed}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/06_visualize.py \
            --results-dir {RESULTS}/{wildcards.dataset}/seed{wildcards.seed} \
            --output-dir  {RESULTS}/{wildcards.dataset}/seed{wildcards.seed}/figures \
            --top-n-ko    {config[top_n_ko]} > {log} 2>&1
        """


# ============================================================
# Step 6c (デフォルト): XGBoost + SHAP 解析
# ============================================================
rule xgb_shap:
    input:
        ko_profile   = f"{_PROC}/ko_profile.csv",
        response_csv = lambda w: f"{config['response_csv_dir']}/{w.dataset}.csv"
    output:
        predictions      = f"{RESULTS}/{{dataset}}/sample_predictions_xgb.csv",
        r2_scores        = f"{RESULTS}/{{dataset}}/r2_scores_xgb.csv",
        best_params      = f"{RESULTS}/{{dataset}}/best_params_xgb.csv",
        ko_cols          = f"{RESULTS}/{{dataset}}/ko_cols.txt",
        shap_values      = f"{RESULTS}/{{dataset}}/shap_values_xgb.csv",
        shap_inter_raw   = f"{RESULTS}/{{dataset}}/shap_interaction_raw_xgb.npy",
        shap_inter_mean  = f"{RESULTS}/{{dataset}}/shap_interaction_mean_xgb.npy",
        shap_inter_top   = f"{RESULTS}/{{dataset}}/shap_interaction_top_pairs.csv"
    log:
        f"{TRIAL_DIR}/logs/06_xgb_shap/{{dataset}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/06_xgb_shap.py \
            --ko-profile-csv {input.ko_profile} \
            --response-csv   {input.response_csv} \
            --output-dir     {RESULTS}/{wildcards.dataset} \
            --min-samples-ko {config[min_samples_ko]} \
            --random-state   {config[random_state]} \
            --n-trials       {config[n_trials_xgb]} \
            --top-n-pairs    {config[top_n_pairs]} > {log} 2>&1
        """


# ============================================================
# Step 6d (共有 fold split モード): XGBoost + SHAP 解析（seed 別）
# ============================================================
rule xgb_shap_ext:
    input:
        ko_profile   = f"{_PROC}/ko_profile.csv",
        response_csv = lambda w: f"{config['response_csv_dir']}/{w.dataset}.csv",
        split_tsv    = lambda w: (
            f"{config['split_info_dir']}/{w.dataset}/"
            f"{w.dataset}_5fold_seed{w.seed}.tsv"
        )
    output:
        predictions      = f"{RESULTS}/{{dataset}}/seed{{seed}}/sample_predictions_xgb.csv",
        r2_scores        = f"{RESULTS}/{{dataset}}/seed{{seed}}/r2_scores_xgb.csv",
        best_params      = f"{RESULTS}/{{dataset}}/seed{{seed}}/best_params_xgb.csv",
        ko_cols          = f"{RESULTS}/{{dataset}}/seed{{seed}}/ko_cols.txt",
        shap_values      = f"{RESULTS}/{{dataset}}/seed{{seed}}/shap_values_xgb.csv",
        shap_inter_raw   = f"{RESULTS}/{{dataset}}/seed{{seed}}/shap_interaction_raw_xgb.npy",
        shap_inter_mean  = f"{RESULTS}/{{dataset}}/seed{{seed}}/shap_interaction_mean_xgb.npy",
        shap_inter_top   = f"{RESULTS}/{{dataset}}/seed{{seed}}/shap_interaction_top_pairs.csv"
    log:
        f"{TRIAL_DIR}/logs/06_xgb_shap_ext/{{dataset}}_seed{{seed}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/06_xgb_shap.py \
            --ko-profile-csv {input.ko_profile} \
            --response-csv   {input.response_csv} \
            --split-tsv      {input.split_tsv} \
            --output-dir     {RESULTS}/{wildcards.dataset}/seed{wildcards.seed} \
            --min-samples-ko {config[min_samples_ko]} \
            --random-state   {wildcards.seed} \
            --n-trials       {config[n_trials_xgb]} \
            --top-n-pairs    {config[top_n_pairs]} > {log} 2>&1
        """

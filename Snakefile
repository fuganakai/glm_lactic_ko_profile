# ============================================================
# Snakefile  —  KO profile パイプライン (スタンドアロン版)
#
# 入力: {genome_dir}/{sample}.fna
# 出力: Lasso / Ridge / RF / MLP による各レスポンス変数の予測
#
# 実行: pipeline.sh を使うこと
# ============================================================

configfile: "config/pipeline.yaml"

from pathlib import Path

# pipeline.sh が事前に生成した filtered_samples.txt を読み込む
# （pipeline.sh が 00_filter_samples.py を Snakemake より先に実行する）
# ※ filtered_samples.txt が存在しない場合は空リストで初期化（--dag 表示用）
_filtered = Path("data/filtered_samples.txt")
SAMPLES = [s.strip() for s in _filtered.read_text().splitlines() if s.strip()] \
    if _filtered.exists() else []

# response_csv_dir にある *.csv のステム名をデータセット名として使用
# 例: data/response_csvs/il12_reporter.csv → dataset = "il12_reporter"
_resp_dir = Path(config["response_csv_dir"])
DATASETS = [p.stem for p in sorted(_resp_dir.glob("*.csv"))] \
    if _resp_dir.exists() else []

RESULTS = config["results_dir"]

# ============================================================
# ゴール
# ============================================================
rule all:
    input:
        expand(f"{RESULTS}/{{dataset}}/sample_predictions_lasso.csv", dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/sample_predictions_ridge.csv", dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/sample_predictions_rf.csv",   dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/sample_predictions_mlp.csv",  dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/r2_scores.csv",               dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/feature_importances.csv",     dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/best_params_rf.csv",          dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/best_params_mlp.csv",         dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/r2_comparison.png",           dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/pred_vs_actual.png",          dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/feature_importance_ranking.png", dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/r2_cv_distribution.png",      dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/feature_importance_heatmap.png", dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/prevalence_vs_importance.png", dataset=DATASETS),
        expand(f"{RESULTS}/{{dataset}}/figures/cumulative_importance.png",    dataset=DATASETS)


# ============================================================
# Step 0: サンプルフィルタリング（ゲノム長のみ）
#   OUTPUT: data/filtered_samples.txt
# ============================================================
rule filter_samples:
    output:
        filtered = "data/filtered_samples.txt"
    log:
        "logs/00_filter_samples.log"
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
# Step 1: Prokka — ゲノムアノテーション (.fna → .faa)
#   INPUT : {genome_dir}/{sample}.fna
#   OUTPUT: data/prokka_out/{sample}/{sample}.faa
# ============================================================
rule run_prokka:
    input:
        fna = lambda w: f"{config['genome_dir']}/{w.sample}.fna"
    output:
        faa = "data/prokka_out/{sample}/{sample}.faa"
    log:
        "logs/01_prokka/{sample}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_prokka]}
        bash scripts/01_run_prokka.sh \
            --fna        {input.fna} \
            --sample     {wildcards.sample} \
            --output-dir data/prokka_out/{wildcards.sample} \
            --cpus       ${{NSLOTS:-1}} > {log} 2>&1
        """


# ============================================================
# Step 2: KoFamScan — KO アノテーション (.faa → .txt)
#   INPUT : data/prokka_out/{sample}/{sample}.faa
#   OUTPUT: data/kofamscan_out/{sample}.txt
# ============================================================
rule run_kofamscan:
    input:
        faa = "data/prokka_out/{sample}/{sample}.faa"
    output:
        txt = "data/kofamscan_out/{sample}.txt"
    log:
        "logs/02_kofamscan/{sample}.log"
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
# Step 3: kofamscan 出力 → KO アノテーション CSV
#   OUTPUT: data/ko_annotations/{sample}_genome.csv
# ============================================================
rule kofamscan_to_csv:
    input:
        txt = "data/kofamscan_out/{sample}.txt"
    output:
        csv = "data/ko_annotations/{sample}_genome.csv"
    log:
        "logs/03_kofamscan_to_csv/{sample}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/03_kofamscan_to_csv.py \
            --input {input.txt} --output {output.csv} > {log} 2>&1
        """


# ============================================================
# Step 4: KO profile マトリクス作成 (全サンプル集約)
#   OUTPUT: data/ko_profile.csv, data/ko_list.txt
# ============================================================
rule make_ko_profile:
    input:
        ko_csvs = expand("data/ko_annotations/{sample}_genome.csv", sample=SAMPLES)
    output:
        profile = "data/ko_profile.csv",
        ko_list = "data/ko_list.txt"
    log:
        "logs/04_make_ko_profile.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/04_make_ko_profile.py \
            --ko-annot-dir   data/ko_annotations \
            --min-samples-ko {config[min_samples_ko]} \
            --output-profile {output.profile} \
            --output-ko-list {output.ko_list} > {log} 2>&1
        """


# ============================================================
# Step 5: Lasso / Ridge / RandomForest / MLP 予測
#   データセットごとに実行 (wildcards.dataset = CSV のステム名)
#   OUTPUT: {results_dir}/{dataset}/...
# ============================================================
rule bench_models:
    input:
        ko_profile   = "data/ko_profile.csv",
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
        f"logs/05_bench_models/{{dataset}}.log"
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
# Step 6: 可視化
#   OUTPUT: {results_dir}/{dataset}/figures/*.png
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
        f"logs/06_visualize/{{dataset}}.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/06_visualize.py \
            --results-dir {RESULTS}/{wildcards.dataset} \
            --output-dir  {RESULTS}/{wildcards.dataset}/figures \
            --top-n-ko    {config[top_n_ko]} > {log} 2>&1
        """

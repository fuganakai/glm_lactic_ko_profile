# ============================================================
# Snakefile  —  KO profile パイプライン (スタンドアロン版)
#
# 入力: {genome_dir}/{sample}.fna
# 出力: Lasso / Ridge / RF による IL-12 予測
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
RESULTS = config["results_dir"]

# ============================================================
# ゴール
# ============================================================
rule all:
    input:
        f"{RESULTS}/sample_predictions_lasso.csv",
        f"{RESULTS}/sample_predictions_ridge.csv",
        f"{RESULTS}/sample_predictions_rf.csv",
        f"{RESULTS}/sample_predictions_mlp.csv",
        f"{RESULTS}/r2_scores.csv",
        f"{RESULTS}/feature_importances.csv",
        f"{RESULTS}/best_params_rf.csv",
        f"{RESULTS}/best_params_mlp.csv",
        f"{RESULTS}/figures/r2_comparison.png",
        f"{RESULTS}/figures/pred_vs_actual.png",
        f"{RESULTS}/figures/feature_importance_ranking.png",
        f"{RESULTS}/figures/r2_cv_distribution.png",
        f"{RESULTS}/figures/feature_importance_heatmap.png",
        f"{RESULTS}/figures/prevalence_vs_importance.png",
        f"{RESULTS}/figures/cumulative_importance.png"


# ============================================================
# Step 0: サンプルフィルタリング
#   OUTPUT: data/filtered_samples.txt
# ============================================================
rule filter_samples:
    input:
        il12_csv = config["il12_csv"]
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
            --il12-csv       {input.il12_csv} \
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
# Step 5: Lasso / Ridge / RandomForest 予測
#   OUTPUT: {results_dir}/sample_predictions_{lasso,ridge,rf}.csv
#           {results_dir}/r2_scores.csv
#           {results_dir}/feature_importances.csv
#           {results_dir}/ko_prevalence.csv
# ============================================================
rule bench_models:
    input:
        ko_profile = "data/ko_profile.csv",
        il12_csv   = config["il12_csv"]
    output:
        lasso           = f"{RESULTS}/sample_predictions_lasso.csv",
        ridge           = f"{RESULTS}/sample_predictions_ridge.csv",
        rf              = f"{RESULTS}/sample_predictions_rf.csv",
        mlp             = f"{RESULTS}/sample_predictions_mlp.csv",
        r2_scores       = f"{RESULTS}/r2_scores.csv",
        importances     = f"{RESULTS}/feature_importances.csv",
        prevalence      = f"{RESULTS}/ko_prevalence.csv",
        best_params_rf  = f"{RESULTS}/best_params_rf.csv",
        best_params_mlp = f"{RESULTS}/best_params_mlp.csv"
    log:
        f"logs/05_bench_models.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/05_bench_models.py \
            --ko-profile-csv {input.ko_profile} \
            --il12-csv       {input.il12_csv} \
            --output-dir     {RESULTS} \
            --model          all \
            --random-state   {config[random_state]} \
            --n-estimators   {config[n_estimators]} \
            --n-trials-rf    {config[n_trials_rf]} \
            --n-trials-mlp   {config[n_trials_mlp]} > {log} 2>&1
        """


# ============================================================
# Step 6: 可視化
#   OUTPUT: {results_dir}/figures/*.png
# ============================================================
rule visualize:
    input:
        r2_scores   = f"{RESULTS}/r2_scores.csv",
        importances = f"{RESULTS}/feature_importances.csv",
        prevalence  = f"{RESULTS}/ko_prevalence.csv",
        pred_lasso  = f"{RESULTS}/sample_predictions_lasso.csv",
        pred_ridge  = f"{RESULTS}/sample_predictions_ridge.csv",
        pred_rf     = f"{RESULTS}/sample_predictions_rf.csv",
        pred_mlp    = f"{RESULTS}/sample_predictions_mlp.csv"
    output:
        fig1 = f"{RESULTS}/figures/r2_comparison.png",
        fig2 = f"{RESULTS}/figures/pred_vs_actual.png",
        fig3 = f"{RESULTS}/figures/feature_importance_ranking.png",
        fig4 = f"{RESULTS}/figures/r2_cv_distribution.png",
        fig5 = f"{RESULTS}/figures/feature_importance_heatmap.png",
        fig6 = f"{RESULTS}/figures/prevalence_vs_importance.png",
        fig7 = f"{RESULTS}/figures/cumulative_importance.png"
    log:
        f"logs/06_visualize.log"
    shell:
        """
        source {config[conda_base]}/etc/profile.d/conda.sh
        conda activate {config[conda_env_ml]}
        python scripts/06_visualize.py \
            --results-dir {RESULTS} \
            --output-dir  {RESULTS}/figures \
            --top-n-ko    {config[top_n_ko]} > {log} 2>&1
        """

#!/bin/bash
# ============================================================
# scripts/01_run_prokka.sh — Prokkaによるゲノムアノテーション
#
# 使い方 (Snakemakeから呼ばれる):
#   bash scripts/01_run_prokka.sh \
#       --fna        {sample}.fna \
#       --sample     {sample_id} \
#       --output-dir data/processed/prokka_out/{sample} \
#       --cpus       ${NSLOTS:-1}
# ============================================================
set -euo pipefail

# --- 引数パース ---
FNA=""
SAMPLE=""
OUTPUT_DIR=""
CPUS=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --fna)        FNA="$2";        shift 2 ;;
        --sample)     SAMPLE="$2";     shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --cpus)       CPUS="$2";       shift 2 ;;
        *) echo "[ERROR] 不明なオプション: $1" >&2; exit 1 ;;
    esac
done

# --- バリデーション ---
if [[ -z "$FNA" || -z "$SAMPLE" || -z "$OUTPUT_DIR" ]]; then
    echo "[ERROR] --fna, --sample, --output-dir は必須です" >&2; exit 1
fi
if [[ ! -f "$FNA" ]]; then
    echo "[ERROR] FNAファイルが見つかりません: $FNA" >&2; exit 1
fi

# --- 実行 ---
echo "[prokka] 開始: ${SAMPLE}  (CPUs: ${CPUS})  $(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$OUTPUT_DIR"

prokka \
    --outdir  "$OUTPUT_DIR" \
    --prefix  "$SAMPLE" \
    --cpus    "$CPUS" \
    --quiet \
    --force \
    "$FNA"

# --- 出力確認 ---
if [[ ! -f "${OUTPUT_DIR}/${SAMPLE}.gff" ]]; then
    echo "[ERROR] prokka: GFFが生成されませんでした: ${OUTPUT_DIR}/${SAMPLE}.gff" >&2; exit 1
fi
if [[ ! -f "${OUTPUT_DIR}/${SAMPLE}.faa" ]]; then
    echo "[ERROR] prokka: FAAが生成されませんでした: ${OUTPUT_DIR}/${SAMPLE}.faa" >&2; exit 1
fi

echo "[prokka] 完了: ${SAMPLE}  $(date '+%Y-%m-%d %H:%M:%S')"

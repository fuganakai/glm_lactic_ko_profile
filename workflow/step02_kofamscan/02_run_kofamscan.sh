#!/bin/bash
# ============================================================
# scripts/02_run_kofamscan.sh — KofamScanによるKOアノテーション
#
# 使い方 (Snakemakeから呼ばれる):
#   bash scripts/02_run_kofamscan.sh \
#       --faa           {sample}.faa \
#       --sample        {sample_id} \
#       --kofamscan-dir /path/to/kofamscan/bin \
#       --ko-list       /path/to/ko_list \
#       --profiles      /path/to/profiles \
#       --output        {sample}.txt \
#       --cpus          ${NSLOTS:-1}
# ============================================================
set -euo pipefail

# --- 引数パース ---
FAA=""
SAMPLE=""
KOFAMSCAN_DIR=""
KO_LIST=""
PROFILES=""
OUTPUT=""
CPUS=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --faa)           FAA="$2";           shift 2 ;;
        --sample)        SAMPLE="$2";        shift 2 ;;
        --kofamscan-dir) KOFAMSCAN_DIR="$2"; shift 2 ;;
        --ko-list)       KO_LIST="$2";       shift 2 ;;
        --profiles)      PROFILES="$2";      shift 2 ;;
        --output)        OUTPUT="$2";        shift 2 ;;
        --cpus)          CPUS="$2";          shift 2 ;;
        *) echo "[ERROR] 不明なオプション: $1" >&2; exit 1 ;;
    esac
done

# --- バリデーション ---
for VAR in FAA SAMPLE KOFAMSCAN_DIR KO_LIST PROFILES OUTPUT; do
    if [[ -z "${!VAR}" ]]; then
        echo "[ERROR] --${VAR,,} は必須です" >&2; exit 1
    fi
done
if [[ ! -f "$FAA" ]]; then
    echo "[ERROR] FAAファイルが見つかりません: $FAA" >&2; exit 1
fi
if [[ ! -f "${KOFAMSCAN_DIR}/exec_annotation" ]]; then
    echo "[ERROR] kofamscanが見つかりません: ${KOFAMSCAN_DIR}/exec_annotation" >&2; exit 1
fi
if [[ ! -f "$KO_LIST" ]]; then
    echo "[ERROR] ko_listが見つかりません: $KO_LIST" >&2; exit 1
fi
if [[ ! -d "$PROFILES" ]]; then
    echo "[ERROR] profilesディレクトリが見つかりません: $PROFILES" >&2; exit 1
fi

# --- 出力ディレクトリ作成 ---
OUTPUT_DIR=$(dirname "$OUTPUT")
mkdir -p "$OUTPUT_DIR"

TMP_DIR="${OUTPUT_DIR}/.tmp_${SAMPLE}"
mkdir -p "$TMP_DIR"

echo "[kofamscan] 開始: ${SAMPLE}  (CPUs: ${CPUS})  $(date '+%Y-%m-%d %H:%M:%S')"

# --- config.yml を一時生成 ---
CONFIG_FILE="${TMP_DIR}/config.yml"
cat > "$CONFIG_FILE" <<EOF
ko_list: ${KO_LIST}
profile: ${PROFILES}
EOF

# --- 実行 ---
"${KOFAMSCAN_DIR}/exec_annotation" \
    --config  "$CONFIG_FILE" \
    --cpu     "$CPUS" \
    --tmp-dir "$TMP_DIR" \
    -o        "$OUTPUT" \
    "$FAA"

# --- 一時ファイル削除 ---
rm -rf "$TMP_DIR"

# --- 出力確認 ---
if [[ ! -f "$OUTPUT" ]]; then
    echo "[ERROR] kofamscan: 出力ファイルが生成されませんでした: $OUTPUT" >&2; exit 1
fi

RESULT_LINES=$(grep -vc '^#' "$OUTPUT" 2>/dev/null || echo 0)
echo "[kofamscan] 完了: ${SAMPLE}  ヒット数: ${RESULT_LINES}  $(date '+%Y-%m-%d %H:%M:%S')"

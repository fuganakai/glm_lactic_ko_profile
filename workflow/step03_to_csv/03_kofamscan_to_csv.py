#!/usr/bin/env python3
"""
scripts/03_kofamscan_to_csv.py — kofamscan出力TXTをKOアノテーションCSVに変換

INPUT:
    --input  {sample}.txt  (kofamscan出力)

OUTPUT:
    --output {sample}_genome.csv
    列: pieceid | KO | 閾値以上ornot
    ※ 閾値以上ornot: 'y' = kofamscanの閾値を超えたヒット (行頭に*印)
"""

import argparse
import os
import sys

import pandas as pd


def parse_kofamscan(txt_file: str) -> pd.DataFrame:
    """
    kofamscan出力を解析し、遺伝子ごとに最良KOを選択する。
    - 行頭 '*' = 閾値以上のヒット
    - 同一遺伝子に複数ヒットがある場合はスコア最高のものを採用
    """
    gene_data: dict[str, list] = {}

    with open(txt_file) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue

            parts = line.split()
            if len(parts) < 5:
                continue

            has_asterisk = line.strip().startswith("*")
            if has_asterisk:
                gene_id = parts[1]
                ko      = parts[2]
                score   = float(parts[4])
            else:
                gene_id = parts[0]
                ko      = parts[1]
                score   = float(parts[3])

            gene_data.setdefault(gene_id, []).append((ko, score, has_asterisk))

    results = []
    for gene_id, ko_list in gene_data.items():
        ko_list.sort(key=lambda x: x[1], reverse=True)
        best_ko, _, has_asterisk = ko_list[0]
        results.append({
            "pieceid":      gene_id,
            "KO":           best_ko,
            "閾値以上ornot": "y" if has_asterisk else "n",
        })

    return pd.DataFrame(results)


def main():
    parser = argparse.ArgumentParser(description="kofamscan TXT → KOアノテーション CSV")
    parser.add_argument("--input",  required=True, help="kofamscan出力 TXTファイル")
    parser.add_argument("--output", required=True, help="出力 CSVファイル")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"[ERROR] 入力ファイルが見つかりません: {args.input}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)

    sample_id = os.path.basename(args.input).replace(".txt", "")
    print(f"[kofamscan_to_csv] 開始: {sample_id}")

    df = parse_kofamscan(args.input)
    if df.empty:
        print(f"[WARNING] ヒットなし: {args.input}", file=sys.stderr)

    threshold_count = (df["閾値以上ornot"] == "y").sum() if not df.empty else 0
    print(f"  遺伝子数: {len(df)}  閾値以上: {threshold_count}")

    df.to_csv(args.output, index=False)
    print(f"[kofamscan_to_csv] 完了: {args.output}")


if __name__ == "__main__":
    main()

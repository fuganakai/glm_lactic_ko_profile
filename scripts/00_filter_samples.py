#!/usr/bin/env python3
"""
scripts/00_filter_samples.py — サンプルフィルタリング

genome_dir と il12_reporter.csv を照合し、両方にデータが存在するサンプルを
ゲノム配列長でフィルタリングして filtered_samples.txt を出力する。

フィルタリング条件:
    1. genome_dir/{sample}.fna が存在する
    2. il12_reporter.csv に sample_id が存在する（IL-12 測定値あり）
    3. .fna の総塩基長 >= min_genome_len (デフォルト: 160,000 bp)

INPUT:
    --genome-dir      {sample}.fna が入ったディレクトリ
    --il12-csv        IL-12 reporter CSV (sample_id 列を使用)
    --min-genome-len  最小ゲノム長 (bp, default: 160000)
    --output          出力ファイルパス (default: data/filtered_samples.txt)

OUTPUT:
    filtered_samples.txt  — フィルタ後のサンプルIDリスト (1行1ID)
"""

import argparse
import sys
from pathlib import Path

import pandas as pd


def genome_length(fna_path: Path) -> int:
    """FASTA ファイルの総塩基長を返す"""
    total = 0
    for line in fna_path.read_text().splitlines():
        if not line.startswith(">"):
            total += len(line.strip())
    return total


def main():
    parser = argparse.ArgumentParser(description="サンプルフィルタリング")
    parser.add_argument("--genome-dir",     required=True,
                        help="{sample}.fna が入ったディレクトリ")
    parser.add_argument("--il12-csv",       required=True,
                        help="IL-12 reporter CSV (sample_id 列必須)")
    parser.add_argument("--min-genome-len", type=int, default=160_000,
                        help="最小ゲノム長 (bp, default: 160000)")
    parser.add_argument("--output",         default="data/filtered_samples.txt",
                        help="出力ファイルパス (default: data/filtered_samples.txt)")
    args = parser.parse_args()

    genome_dir = Path(args.genome_dir)
    output_path = Path(args.output)

    # ── 1. genome_dir の .fna からサンプルセットを取得 ──────────────
    fna_files = {p.stem: p for p in sorted(genome_dir.glob("*.fna"))}
    print(f"[filter_samples] genome_dir のサンプル数: {len(fna_files)}")

    # ── 2. IL-12 CSV のサンプルセットを取得 ─────────────────────────
    il12_df = pd.read_csv(args.il12_csv)
    il12_ids = set(il12_df["sample_id"].astype(str))
    print(f"[filter_samples] IL-12 CSV のサンプル数: {len(il12_ids)}")

    # ── 3. 共通サンプル（両方にあるもの）──────────────────────────
    common = sorted(s for s in fna_files if s in il12_ids)
    only_fna   = [s for s in fna_files if s not in il12_ids]
    only_il12  = [s for s in il12_ids  if s not in fna_files]
    print(f"[filter_samples] 共通サンプル数: {len(common)}")
    if only_fna:
        print(f"  .fna のみ (IL-12なし): {len(only_fna)} 件 → 除外")
    if only_il12:
        print(f"  IL-12 のみ (.fnaなし): {len(only_il12)} 件 → 除外")

    # ── 4. ゲノム長フィルタリング ────────────────────────────────────
    passed = []
    failed = []
    for sid in common:
        length = genome_length(fna_files[sid])
        if length >= args.min_genome_len:
            passed.append(sid)
        else:
            failed.append((sid, length))

    if failed:
        print(f"[filter_samples] ゲノム長 < {args.min_genome_len:,} bp で除外: {len(failed)} 件")
        for sid, length in failed:
            print(f"  {sid}: {length:,} bp")

    print(f"[filter_samples] フィルタ後のサンプル数: {len(passed)}")

    if len(passed) == 0:
        print("[ERROR] フィルタ後にサンプルが0件になりました。"
              "--min-genome-len を確認してください。", file=sys.stderr)
        sys.exit(1)

    # ── 5. 出力 ─────────────────────────────────────────────────────
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(passed) + "\n")
    print(f"[filter_samples] 出力: {output_path}  ({len(passed)} サンプル)")


if __name__ == "__main__":
    main()

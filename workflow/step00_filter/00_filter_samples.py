#!/usr/bin/env python3
"""
scripts/00_filter_samples.py — サンプルフィルタリング

genome_dir の .fna ファイルを列挙し、ゲノム配列長でフィルタリングして
filtered_samples.txt を出力する。レスポンスCSVとの照合は行わない
（各データセットとの交差は 05_bench_models.py が担当する）。

フィルタリング条件:
    1. genome_dir/{sample}.fna が存在する
    2. .fna の総塩基長 >= min_genome_len (デフォルト: 160,000 bp)

INPUT:
    --genome-dir      {sample}.fna が入ったディレクトリ
    --min-genome-len  最小ゲノム長 (bp, default: 160000)
    --output          出力ファイルパス (default: data/filtered_samples.txt)

OUTPUT:
    filtered_samples.txt  — フィルタ後のサンプルIDリスト (1行1ID)
"""

import argparse
import sys
from pathlib import Path


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
    parser.add_argument("--min-genome-len", type=int, default=160_000,
                        help="最小ゲノム長 (bp, default: 160000)")
    parser.add_argument("--output",
                        default="data/glm_lactic_ko_profile/processed/filtered_samples.txt",
                        help="出力ファイルパス")
    args = parser.parse_args()

    genome_dir = Path(args.genome_dir)
    output_path = Path(args.output)

    # ── 1. genome_dir の .fna からサンプルセットを取得 ──────────────
    fna_files = {p.stem: p for p in sorted(genome_dir.glob("*.fna"))}
    print(f"[filter_samples] genome_dir のサンプル数: {len(fna_files)}")

    # ── 2. ゲノム長フィルタリング ────────────────────────────────────
    passed = []
    failed = []
    for sid, fna_path in fna_files.items():
        length = genome_length(fna_path)
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

    # ── 3. 出力 ─────────────────────────────────────────────────────
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(passed) + "\n")
    print(f"[filter_samples] 出力: {output_path}  ({len(passed)} サンプル)")


if __name__ == "__main__":
    main()

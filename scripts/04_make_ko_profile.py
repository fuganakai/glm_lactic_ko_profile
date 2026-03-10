#!/usr/bin/env python3
"""
scripts/04_make_ko_profile.py — KO統計 & KO profileマトリクス作成

INPUT:
    --ko-annot-dir   data/processed/ko_annotations/  ({sample}_genome.csv 群)
    --sample-list    sample_list.txt
    --min-samples-ko 5  (このサンプル数以上のKOのみ学習対象に含める)

OUTPUT:
    --output-profile  ko_profile.csv   (sample × KO バイナリ行列)
    --output-ko-list  ko_list.txt      (学習対象KO一覧)
"""

import argparse
import os
import sys
from collections import defaultdict
from pathlib import Path

import pandas as pd


def load_sample_list(path: str) -> list:
    return [s.strip() for s in Path(path).read_text().splitlines() if s.strip()]


def build_ko_maps(ko_annot_dir: str, sample_list: list) -> tuple:
    """
    Returns:
        ko_to_samples : KO → set(sample_id)
        sample_to_kos : sample_id → set(KO)
    """
    ko_to_samples  = defaultdict(set)
    sample_to_kos  = defaultdict(set)
    missing = []

    for sample_id in sample_list:
        csv_path = os.path.join(ko_annot_dir, f"{sample_id}_genome.csv")
        if not os.path.exists(csv_path):
            missing.append(sample_id)
            continue

        df = pd.read_csv(csv_path)
        df = df[df["閾値以上ornot"] == "y"]

        for ko in df["KO"].unique():
            ko_to_samples[ko].add(sample_id)
            sample_to_kos[sample_id].add(ko)

    if missing:
        print(f"[WARNING] KOファイルが見つからないサンプル: {len(missing)}件", file=sys.stderr)

    return ko_to_samples, sample_to_kos


def print_statistics(ko_to_samples: dict, min_samples_ko: int) -> None:
    total = len(ko_to_samples)
    trainable = sum(1 for s in ko_to_samples.values() if len(s) >= min_samples_ko)
    print(f"  Total unique KOs: {total}")
    print(f"  Trainable KOs (>= {min_samples_ko} samples): {trainable} / {total} ({trainable/total*100:.1f}%)")

    bins = [("<5", lambda n: n < 5), ("5-9", lambda n: 5 <= n <= 9),
            ("10-19", lambda n: 10 <= n <= 19), ("20-49", lambda n: 20 <= n <= 49),
            ("50-99", lambda n: 50 <= n <= 99), ("100-199", lambda n: 100 <= n <= 199),
            ("200+", lambda n: n >= 200)]
    counts = {label: sum(1 for s in ko_to_samples.values() if cond(len(s)))
              for label, cond in bins}
    print("  Sample count distribution:")
    for label, count in counts.items():
        print(f"    {label:>7}: {count:4d} KOs ({count/total*100:5.1f}%)")


def main():
    parser = argparse.ArgumentParser(description="KO profile マトリクス作成")
    parser.add_argument("--ko-annot-dir",   required=True)
    parser.add_argument("--sample-list",    required=True)
    parser.add_argument("--min-samples-ko", type=int, default=5)
    parser.add_argument("--output-profile", required=True)
    parser.add_argument("--output-ko-list", required=True)
    args = parser.parse_args()

    sample_list = load_sample_list(args.sample_list)
    print(f"[make_ko_profile] サンプル数: {len(sample_list)}")

    ko_to_samples, sample_to_kos = build_ko_maps(args.ko_annot_dir, sample_list)
    print_statistics(ko_to_samples, args.min_samples_ko)

    # 学習対象KOリスト
    trainable_kos = sorted(
        ko for ko, samples in ko_to_samples.items()
        if len(samples) >= args.min_samples_ko
    )

    # バイナリプロファイル行列
    rows = []
    for sample_id in sample_list:
        row = {"sample_id": sample_id}
        row.update({ko: int(ko in sample_to_kos[sample_id]) for ko in trainable_kos})
        rows.append(row)

    profile_df = pd.DataFrame(rows)

    os.makedirs(os.path.dirname(os.path.abspath(args.output_profile)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.output_ko_list)), exist_ok=True)

    profile_df.to_csv(args.output_profile, index=False)
    Path(args.output_ko_list).write_text("\n".join(trainable_kos) + "\n")

    print(f"[make_ko_profile] KO profile: {args.output_profile}  ({len(profile_df)} samples × {len(trainable_kos)} KOs)")
    print(f"[make_ko_profile] KO list:    {args.output_ko_list}  ({len(trainable_kos)} KOs)")


if __name__ == "__main__":
    main()

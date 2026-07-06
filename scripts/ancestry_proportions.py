#!/usr/bin/env python3
"""Turn a plink2 --score projection into ancestry proportions.

Reads the 1000G superpopulation centroids (from stage 00) and the sample's
projected top-4 PCs (plink2 .sscore), then scores the sample's distance to each
superpopulation centroid and converts those distances to proportions via a
softmax of the negative squared distance. Directional only — this is similarity
to reference populations, not literal admixture fractions.

Usage: ancestry_proportions.py <centroids.tsv> <sample_proj.sscore> <n_markers> <sample>
Stdlib only (the conda env has no numpy).
"""
import itertools
import math
import sys

SUPERPOP_ORDER = ["AFR", "AMR", "EAS", "EUR", "SAS"]


def main() -> None:
    cent_f, proj_f, nmark, sample = sys.argv[1:5]

    pops, cent = [], {}
    for line in open(cent_f):
        parts = line.split()
        if len(parts) < 5:
            continue
        pops.append(parts[0])
        cent[parts[0]] = [float(x) for x in parts[1:5]]

    # Sample's projected PC1-4 = .sscore columns 5-8 (0-indexed 4-7), first data row.
    rows = [ln.split() for ln in open(proj_f)][1:]
    s = [float(rows[0][i]) for i in range(4, 8)]

    def d2(a, b):
        return sum((a[k] - b[k]) ** 2 for k in range(4))

    # Bandwidth: half the mean pairwise centroid distance — adapts to the PC scale.
    pair = [math.sqrt(d2(cent[a], cent[b])) for a, b in itertools.combinations(pops, 2)]
    sigma = (sum(pair) / len(pair)) / 2 or 1.0

    w = {p: math.exp(-d2(s, cent[p]) / (2 * sigma * sigma)) for p in pops}
    total = sum(w.values()) or 1.0
    order = [p for p in SUPERPOP_ORDER if p in w] or pops

    print(f"# Ancestry estimate for {sample} — PCA projection onto 1000G ({nmark} markers)")
    print("# Directional only: the public 1000G panel (2,504 people) can't match")
    print("#   commercial databases; expect similar shape, not identical percentages.")
    print("# columns: " + " ".join(order))
    print(" ".join(f"{w[p] / total:.4f}" for p in order))


if __name__ == "__main__":
    main()

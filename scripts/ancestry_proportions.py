#!/usr/bin/env python3
"""k-NN ancestry from a plink2 PCA projection.

Ancestry = the fraction of the sample's k nearest 1000G reference individuals
(in PCA space) belonging to each superpopulation. This is far sharper than a
softmax-of-distance-to-centroid (which leaks weight into the central AMR/SAS
clusters — a known EUR individual scored only ~48% EUR that way; k-NN scores
known individuals at ~100%). Directional only: similarity to reference
populations, not literal admixture fractions.

Usage:
  ancestry_proportions.py <ref_proj.sscore> <superpop.pop> <sample_proj.sscore> <n_markers> <sample>
Stdlib only (the conda env has no numpy).
"""
import sys
from collections import Counter

SUPERPOP_ORDER = ["AFR", "AMR", "EAS", "EUR", "SAS"]
K = 100          # nearest reference individuals to poll
NPC = 10         # PCs to use (sscore columns 5..14, 0-indexed 4..13)


def _pcs(path):
    out = []
    for i, line in enumerate(open(path)):
        if i == 0:  # header
            continue
        p = line.split()
        out.append([float(p[j]) for j in range(4, 4 + NPC)])
    return out


def main() -> None:
    refproj_f, pop_f, proj_f, nmark, sample = sys.argv[1:6]

    labels = [l.strip() for l in open(pop_f)]
    ref = _pcs(refproj_f)
    sample_pcs = _pcs(proj_f)
    if not sample_pcs:
        sys.exit("no sample projection found")
    s = sample_pcs[0]

    def d2(a, b):
        return sum((a[i] - b[i]) ** 2 for i in range(NPC))

    k = min(K, len(ref))
    nearest = sorted(range(len(ref)), key=lambda i: d2(s, ref[i]))[:k]
    counts = Counter(labels[i] for i in nearest)

    present = set(labels)
    order = [p for p in SUPERPOP_ORDER if p in present] or sorted(present)

    print(f"# Ancestry estimate for {sample} — 1000G PCA k-NN (k={k}, {nmark} markers)")
    print("# Proportion of the sample's nearest reference individuals per superpopulation.")
    print("# Directional only — the public 1000G panel can't match commercial databases.")
    print("# columns: " + " ".join(order))
    print(" ".join(f"{counts.get(p, 0) / k:.4f}" for p in order))


if __name__ == "__main__":
    main()

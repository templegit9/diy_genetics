#!/usr/bin/env python3
"""Classify ClinVar Pathogenic / Likely-pathogenic variants into hereditary-
condition categories from zygosity + gene mode-of-inheritance.

  active    — likely expressed: homozygous pathogenic (any gene), hemizygous
              (X-linked male), or heterozygous in a DOMINANT gene.
  carrier   — dormant: one pathogenic copy of a RECESSIVE gene (family-planning
              relevance, not your own disease).
  uncertain — a single pathogenic copy where the gene's inheritance is unknown.

A gene with >=2 pathogenic hets (recessive or unknown mode) is flagged as a
possible COMPOUND HETEROZYGOTE and promoted to `active` — but phasing is not
performed, so it is only "possible" (the two variants may be on the same copy).

Reads a split-vep TSV on stdin (one row per variant/consequence):
    CHROM  POS  REF  ALT  GT  SYMBOL  CLNSIG  CLNDN
Usage: hereditary_conditions.py <gene_moi.tsv> <sample>
Stdlib only (the conda env has no numpy).
"""
import sys
from collections import defaultdict


def is_pathogenic(sig: str) -> bool:
    s = (sig or "").lower()
    # Catches "Pathogenic" and "Likely_pathogenic"; drops conflicting/benign.
    return "pathogenic" in s and "conflicting" not in s


def zygosity(gt: str) -> str:
    alleles = gt.replace("|", "/").split("/")
    alleles = [a for a in alleles if a != ""]
    if len(alleles) == 1:                       # haploid call (chrX/Y in males)
        return "hemi" if alleles[0] not in ("0", ".") else "ref"
    if len(alleles) < 2:
        return "ref"
    alt = [a for a in alleles if a not in ("0", ".")]
    if not alt:
        return "ref"
    if alleles[0] == alleles[1] and alleles[0] not in ("0", "."):
        return "hom"
    return "het"


def main() -> None:
    moi_f, sample = sys.argv[1:3]

    moi: dict[str, set] = {}
    try:
        for line in open(moi_f):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2 and p[1]:
                moi[p[0]] = set(p[1].split(","))
    except FileNotFoundError:
        pass

    records = []
    gene_hets: dict[str, list] = defaultdict(list)
    seen = set()
    for line in sys.stdin:
        f = line.rstrip("\n").split("\t")
        if len(f) < 8:
            continue
        chrom, pos, ref, alt, gt, gene, sig, dis = f[:8]
        if not is_pathogenic(sig):
            continue
        z = zygosity(gt)
        if z == "ref":
            continue
        key = (chrom, pos, ref, alt, gene)
        if key in seen:
            continue
        seen.add(key)
        records.append((chrom, pos, ref, alt, z, gene, sig, dis))
        if z == "het" and gene and gene != ".":
            gene_hets[gene].append(key)

    rows = []
    for chrom, pos, ref, alt, z, gene, sig, dis in records:
        modes = moi.get(gene, set())
        zlabel = {"hom": "homozygous", "hemi": "hemizygous", "het": "heterozygous"}[z]
        compound = z == "het" and len(gene_hets.get(gene, [])) >= 2

        if z in ("hom", "hemi"):
            cat = "active"
        elif "AD" in modes:
            cat = "active"
        elif modes and modes <= {"AR"}:
            cat = "active" if compound else "carrier"
        elif "XL" in modes:
            cat = "carrier"            # X-linked het: carrier (unknown sex)
        else:
            cat = "active" if compound else "uncertain"

        if compound:
            zlabel += " (possible compound het)"
        rows.append((cat, gene or ".", dis or ".", zlabel, sig, chrom, pos, ref, alt))

    print(f"# {sample} — HEREDITARY CONDITIONS (research-grade, NOT a diagnosis)")
    print("# active   = likely expressed (homozygous, hemizygous, or het in a dominant gene).")
    print("# carrier  = dormant: one recessive copy; relevant for family planning, not your health.")
    print("# uncertain= single copy, inheritance mode unknown. Penetrance varies; compound-het")
    print("#            calls are UNPHASED ('possible'). Confirm nothing without a genetic counselor.")
    print("category\tgene\tcondition\tzygosity\tsignificance\tCHROM\tPOS\tREF\tALT")
    order = {"active": 0, "carrier": 1, "uncertain": 2}
    for r in sorted(rows, key=lambda r: (order.get(r[0], 3), r[1])):
        print("\t".join(map(str, r)))


if __name__ == "__main__":
    main()

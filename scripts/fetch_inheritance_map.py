#!/usr/bin/env python3
"""Build a gene -> primary mode-of-inheritance map from Genomics England PanelApp.

PanelApp lists each gene once per panel, each with a mode of inheritance. A gene
can appear across many panels with mixed modes (e.g. CFTR is recessive for cystic
fibrosis but tagged dominant on some panels). Taking the UNION over-calls dominant
and would flag recessive carriers as "active", so we take the MAJORITY mode per
gene as its primary inheritance.

Writes TSV:  <gene>\t<primary AD|AR|XL>\t<all modes seen, comma-sep>
Usage: fetch_inheritance_map.py <out.tsv>
Stdlib only.
"""
import sys
import urllib.request
import json
from collections import defaultdict, Counter


# Authoritative overrides for well-established genes where PanelApp's cross-panel
# majority is wrong or missing. Applied AFTER the PanelApp fetch.
CURATED = {
    "HTT": "AD", "HBB": "AR", "HBA1": "AR", "HBA2": "AR", "HEXA": "AR",
    "SMN1": "AR", "PAH": "AR", "GBA": "AR", "GBA1": "AR", "GJB2": "AR",
    "CFTR": "AR", "BRCA1": "AD", "BRCA2": "AD", "LDLR": "AD", "APOB": "AD",
    "PCSK9": "AD", "MLH1": "AD", "MSH2": "AD", "MSH6": "AD", "PMS2": "AD",
    "APC": "AD", "TP53": "AD", "RB1": "AD", "VHL": "AD", "NF1": "AD",
    "NF2": "AD", "MEN1": "AD", "RET": "AD", "PTEN": "AD", "STK11": "AD",
    "FMR1": "XL", "DMD": "XL", "G6PD": "XL", "F8": "XL", "F9": "XL",
    "ATM": "AR", "MUTYH": "AR", "SERPINA1": "AR", "ATP7B": "AR", "PKD1": "AD",
    "PKD2": "AD", "FBN1": "AD", "LMNA": "AD", "MYH7": "AD", "MYBPC3": "AD",
    "KCNQ1": "AD", "SCN5A": "AD", "RYR2": "AD", "TTR": "AD", "HFE": "AR",
}


def simplify(s: str) -> set:
    s = (s or "").lower()
    out = set()
    if "biallelic" in s or "recessive" in s:
        out.add("AR")
    if "monoallelic" in s or "dominant" in s:
        out.add("AD")
    if "x-linked" in s or "x linked" in s:
        out.add("XL")
    return out


def main() -> None:
    out_path = sys.argv[1]
    counts: dict[str, Counter] = defaultdict(Counter)
    url = "https://panelapp.genomicsengland.co.uk/api/v1/genes/?page_size=1500"
    scanned = 0
    for _ in range(60):  # hard page cap
        if not url:
            break
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "diy-genetics"})
            data = json.load(urllib.request.urlopen(req, timeout=90))
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"PanelApp fetch stopped: {exc}\n")
            break
        for r in data.get("results", []):
            gene = (r.get("gene_data") or {}).get("gene_symbol") or r.get("entity_name")
            for m in simplify(r.get("mode_of_inheritance")):
                if gene:
                    counts[gene][m] += 1
        scanned += len(data.get("results", []))
        url = data.get("next")

    genes = set(counts) | set(CURATED)
    with open(out_path, "w") as f:
        for gene in sorted(genes):
            if gene in CURATED:
                primary = CURATED[gene]
                allmodes = ",".join(sorted(set(counts.get(gene, Counter())) | {primary}))
            else:
                primary = counts[gene].most_common(1)[0][0]   # majority mode
                allmodes = ",".join(sorted(counts[gene]))
            f.write(f"{gene}\t{primary}\t{allmodes}\n")

    sys.stderr.write(f"scanned {scanned} panel entries; wrote {len(counts)} genes to {out_path}\n")


if __name__ == "__main__":
    main()

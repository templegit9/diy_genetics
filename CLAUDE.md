# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A DIY whole-genome-sequencing project: the goal is to reproduce 23andMe-style ancestry and health output from raw sequenced DNA using a self-hosted, open-source bioinformatics pipeline. The repo currently contains one document — `diy-dna-sequencing-guide.md` — which is the **source of truth** for the intended architecture. There is no pipeline code yet; the primary build task is to turn the guide's Phase 5 into runnable scripts.

When working here, treat the guide as the spec. Keep it and any code you write in sync — if the pipeline diverges from the guide (different tool, different reference build, changed step order), update the guide in the same change.

## The pipeline architecture (from the guide)

The work is five sequential phases; only the last is code this repo owns:

1. **Order sequencing** — external vendor (Dante Labs / Sequencing.com), 30x WGS, download raw FASTQ/BAM/VCF.
2. **Local compute** — a dedicated LXC/VM (Proxmox), 32–64 GB RAM, 8+ cores, 500 GB–1 TB free per genome. Alignment is I/O- and memory-heavy; isolate it.
3. **Install tools** — all free/open-source (see below).
4. **Download reference data** — GRCh38, dbSNP, 1000 Genomes Phase 3 (GRCh38, PLINK2), ClinVar, SNPedia.
5. **Run the pipeline** — align → refine → call variants → annotate → estimate ancestry. **This is what gets scripted here** (bash or Nextflow).

### Pipeline stages (Phase 5) — the code to build

The intended end-to-end flow, which a `pipeline.sh` or Nextflow workflow should implement:

```
FASTQ ──bwa-mem2──▶ sorted BAM ──samtools──▶ mark dups + BQSR (dbSNP) ──GATK──▶ VCF
  VCF ──VEP/ANNOVAR × ClinVar──▶ annotated health variants
  VCF ──rsID-key──▶ PLINK ──project onto 1000G PCA──▶ ancestry
  VCF ──bcftools──▶ extract ~640k 23andMe SNP positions (optional)
```

Key implementation notes carried from the guide:
- Alignment: `bwa-mem2` (1–3x faster than original BWA-MEM), sort/index with `samtools`.
- Refine: mark duplicates, then **BQSR using dbSNP as known-sites**. This mirrors the clinical standard (single aligner + GATK HaplotypeCaller, F-score > 0.99 on benchmarks).
- Variant calling: **GATK4 HaplotypeCaller** is the default; **DeepVariant** is the drop-in alternative (better benchmarked SNP/indel accuracy). Support both if practical, GATK first.
- Ancestry: **PCA projection** (plink2) onto pre-learned 1000 Genomes superpopulation centroids, matched by **rsID** (build-agnostic — the 1000G panel is build 37, samples are GRCh38). ADMIXTURE was the original plan (guide's "projection mode"), but its 1.3.0 binary **segfaults on this CPU under WSL2** regardless of input, so the pipeline uses plink2 PCA instead.
- Reference build is **GRCh38** throughout — do not mix in GRCh37/hg19 references or the coordinates won't line up.

### Tooling

| Stage | Tool |
|---|---|
| Align | bwa-mem2 |
| BAM/VCF ops | samtools / bcftools |
| Variant calling | GATK4 HaplotypeCaller (DeepVariant alternative) |
| Ancestry prep | PLINK 1.9 + PLINK 2 |
| Ancestry estimate | plink2 PCA projection (ADMIXTURE 1.3.0 segfaults on this hardware) |
| Annotation | VEP or ANNOVAR |

## Constraints to respect when building

- **Not medical advice.** The guide is explicit that raw WGS health flags (ClinVar pathogenic hits) can be alarming without clinical context. Any health-annotation output must carry the guide's caveat and point to genetic-counselor consultation. Do not present pathogenic findings as diagnoses.
- **Ancestry precision is inherently limited** by the public 1000 Genomes panel (2,504 individuals) vs. 23andMe's proprietary millions. Don't claim parity; expect directionally similar results.
- **Data jurisdiction / portability** matters at Phase 1 — the pipeline is only viable with a vendor that hands over complete raw FASTQ/BAM/VCF.
- Reference datasets are large; the guide's plan is to pre-download them during the sequencing turnaround. Scripts should be resumable and not re-fetch existing references.

## Current state

Documentation only — `diy-dna-sequencing-guide.md`. Not a git repository. The open build task (from the guide's "Suggested Next Steps") is drafting the Phase 5 pipeline script.

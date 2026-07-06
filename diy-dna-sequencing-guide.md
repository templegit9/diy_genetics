# DIY Whole Genome Sequencing: A Self-Hosted Path to 23andMe-Style Insights

*A step-by-step technical guide covering sequencing vendor selection, homelab infrastructure, open-source bioinformatics tools, and reference datasets.*

---

## Overview

Getting 23andMe-style output from your own sequenced DNA is achievable, but it's a multi-phase project: order sequencing → build local compute infrastructure → install open-source bioinformatics tools → download reference datasets → run the alignment/variant-calling/annotation pipeline. This guide covers all five phases.

**Key reality check up front:** Your ancestry percentages won't match 23andMe's exactly even with a complete pipeline. 23andMe's precision comes from an in-house reference database of millions of customer genotypes; the public 1000 Genomes reference panel used here has only 2,504 individuals. Health variant flags from raw WGS data can also be alarming without clinical context — plan for how you'll handle unexpected pathogenic findings before you start annotating.

---

## Phase 1: Order the Sequencing

| Item | Recommendation | Cost (2026) | Notes |
|---|---|---|---|
| WGS kit | Dante Labs Genome Test or Sequencing.com bundle | 30x clinical-grade sequencing now runs under $500; expedited options run $1,399–$1,999 | Standard turnaround averages 5–8 weeks; budget-tier options take longer |
| Sample kit | Saliva or buccal swab (provided by vendor) | Included | No lab equipment needed on your end |
| Reports platform | Vendor's included portal (e.g., Dante's Genome Manager) | Included | Dante's plan includes 200+ clinical reports with lifetime updates as science advances |

### Vendor selection checklist
- Confirm CLIA/CAP/ISO 15189 lab accreditation and 30X minimum coverage.
- Verify you can download your complete raw FASTQ/BAM/VCF files.
- Check what jurisdiction processes your data and whether it's sold to third parties.
- **Note:** Nebula Genomics is no longer an option — its consumer service closed February 5, 2025.

---

## Phase 2: Local Compute & Storage Build

| Resource | Requirement | Rationale |
|---|---|---|
| Storage | 500 GB–1 TB free per genome | A 30x genome needs ~220 GB for FASTQ files plus temp space during processing; final storage footprint runs ~150 GB per sample including analysis outputs |
| RAM | 32–64 GB minimum for the processing container | GATK/BWA alignment and sorting are memory-intensive at whole-genome scale |
| CPU | Multi-core, 8+ threads ideal | BWA-MEM2 runs 1–3x faster than the original BWA-MEM, and GATK4's Spark tools are built to exploit parallel CPU cores |
| Container | Dedicated new LXC/VM | Isolate this from your existing containers — the disk I/O load during alignment is heavy |

---

## Phase 3: Software to Install (all free, open-source)

| Tool | Purpose | Source |
|---|---|---|
| bwa-mem2 | Align raw reads to the reference genome | GitHub: bwa-mem2 releases |
| samtools / bcftools | BAM sorting, indexing, VCF manipulation | GitHub: samtools/htslib |
| GATK4 | Variant calling (industry/clinical standard, Broad Institute) | Broad Institute GATK site |
| DeepVariant *(alternative to GATK)* | Variant calling — benchmarked with better SNP/indel accuracy than GATK, comparable to DRAGEN | Google Health, GitHub |
| PLINK 1.9 + PLINK 2 | Genotype format conversion, ancestry data prep | cog-genomics.org/plink |
| ADMIXTURE | DIY ancestry composition estimate | UCLA/Wisconsin bioinformatics site |
| VEP or ANNOVAR | Annotate variants with gene/clinical significance | Ensembl VEP / ANNOVAR |

---

## Phase 4: Reference Data to Download

| Dataset | Purpose | Source |
|---|---|---|
| GRCh38 reference genome | The template your reads align against | NCBI or Ensembl (GRCh38 FASTA) |
| dbSNP (known variant sites) | Base Quality Score Recalibration (BQSR) | NCBI dbSNP |
| 1000 Genomes Phase 3 (GRCh38, PLINK2 format) | Ancestry reference panel for ADMIXTURE | cog-genomics.org/plink/2.0/resources#1kg_phase3 |
| ClinVar VCF | Clinical significance annotations for health reports | NCBI ClinVar FTP |
| SNPedia dump (where accessible) | Broader trait/health literature links | SNPedia (this is the same database Promethease is built on) |

---

## Phase 5: The Pipeline, Step by Step

1. **Get raw data** — Download FASTQ (or BAM) files from your vendor's portal.
2. **Align** — `bwa-mem2` maps your reads to the GRCh38 reference, producing a sorted BAM via samtools.
3. **Refine** — Mark duplicates, then run Base Quality Score Recalibration (BQSR) using dbSNP as the known-sites reference. This mirrors the standard clinical sequencing workflow: a single aligner (BWA-MEM) paired with GATK HaplotypeCaller, which has demonstrated F-scores above 0.99 in benchmark datasets.
4. **Call variants** — Run GATK HaplotypeCaller (or DeepVariant) to produce your personal VCF file.
5. **Annotate for health** — Run VEP/ANNOVAR against ClinVar to flag clinically significant variants; cross-reference SNPedia for broader trait/health literature.
6. **Estimate ancestry** — Convert your VCF to PLINK binary format and project it against the 1000 Genomes reference panel to estimate ancestry proportions against pre-learned reference populations rather than computing everything from scratch.

   > **Implementation note:** the original plan was ADMIXTURE in "projection" mode, but the ADMIXTURE 1.3.0 binary segfaults on modern CPUs under WSL2 (both the conda build and the official static binary, on any input). The pipeline therefore uses **plink2 PCA projection** instead: it learns the 1000G PCA space + per-superpopulation centroids once, then projects your sample and scores its distance to each centroid. Markers are matched by **rsID** so a GRCh38 sample lines up with the build-37 1000G panel. Results are directional (similarity to reference populations), same caveat as ADMIXTURE.
7. **(Optional) 23andMe-format output** — Extract the ~640,000 SNP positions 23andMe tests from your VCF using bcftools, either for direct comparison or to upload to third-party interpretation tools like Genomelink or SelfDecode.

---

## Known Limitations

- **Ancestry precision gap:** Public reference panels (2,504 individuals in 1000 Genomes) can't match 23andMe's proprietary database of millions of customer genotypes — expect directionally similar but not identical ancestry breakdowns.
- **Emotional/clinical impact of raw findings:** One reviewer's WGS-based health report flagged a "very high genetic predisposition" to thyroid cancer and elevated dementia risk with no counselor involved to contextualize the finding. Decide in advance how you'll handle unexpected pathogenic variant flags — consider a genetic counselor consultation before deep-diving into ClinVar pathogenic hits solo.
- **Vendor turnaround and data jurisdiction vary** — confirm accreditation, raw data portability, and data-sharing policy before ordering.

---

## Suggested Next Steps

- [ ] Lock in a WGS vendor (compare Dante Labs vs. Sequencing.com pricing/turnaround directly)
- [ ] Provision the dedicated bioinformatics container/VM on Proxmox
- [ ] Pre-download reference datasets (GRCh38, dbSNP, 1000 Genomes, ClinVar) while awaiting sequencing turnaround
- [ ] Draft the actual pipeline script (bash or Nextflow) for the alignment → variant-calling → annotation workflow

*This document reflects publicly available vendor and tooling information as of mid-2026 and does not constitute medical advice. Consult a genetic counselor or physician for interpretation of any clinically significant findings.*

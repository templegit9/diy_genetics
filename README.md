# DIY Genetics Pipeline

A turnkey, self-hosted pipeline that turns raw whole-genome sequencing reads into
23andMe-style output: annotated health variants, an ancestry estimate, and an
optional 23andMe-format SNP export. Built from
[`diy-dna-sequencing-guide.md`](diy-dna-sequencing-guide.md), which is the spec.

> ## ⚠️ Not medical advice
> This pipeline produces **research-grade** output from raw sequencing data.
> Variant "pathogenic" flags from ClinVar can be alarming and are frequently
> misleading without clinical context and confirmatory testing. **Do not treat
> any output as a diagnosis.** Decide *before you run the health annotation* how
> you will handle unexpected findings, and consult a genetic counselor or
> physician to interpret anything clinically significant. Ancestry percentages
> are directional only — the public 1000 Genomes panel (2,504 individuals)
> cannot match a proprietary database of millions.

---

## What runs where

Everything from the LXC guest inward is automated. You provide: a Proxmox node
with disk, and paired-end FASTQ files downloaded from your sequencing vendor.

```
[Proxmox host]  provision an LXC  ──▶  [Debian/Ubuntu LXC]
                                          env/bootstrap-lxc.sh   (one time)
                                          scripts/00_download_references.sh (one time, ~days of downloads)
                                          ./run_pipeline.sh                  (per genome)
```

## Quickstart

1. **Provision the LXC** (on the Proxmox host). Copy and edit the documented
   template — it is intentionally not auto-run:
   ```bash
   cp env/provision-lxc.example.sh env/provision-lxc.sh
   # edit VMID / cores / RAM / disk / storage, then run on the Proxmox host:
   sudo bash env/provision-lxc.sh
   ```
   Recommended: 8+ cores, 32–64 GB RAM, ≥1 TB disk per genome.

2. **Bootstrap the toolchain** (inside the LXC):
   ```bash
   bash env/bootstrap-lxc.sh
   conda activate diy-genetics
   ```

3. **Configure** — edit [`config/pipeline.conf`](config/pipeline.conf): set
   `SAMPLE`, point `FASTQ_R1`/`FASTQ_R2` at your reads, pick `CALLER`
   (`gatk` default, or `deepvariant`), tune `THREADS`/`MEM_GB`.

4. **Download references** (one time, large — start during vendor turnaround):
   ```bash
   bash scripts/00_download_references.sh
   ```

5. **Run the pipeline**:
   ```bash
   ./run_pipeline.sh              # full run
   ./run_pipeline.sh --dry-run    # print the stage plan, execute nothing
   ./run_pipeline.sh --help
   ```

Re-running is safe: each stage skips work whose output already exists, so an
interrupted run resumes where it stopped.

## Pipeline stages

| Stage | Script | Does |
|---|---|---|
| 00 | `scripts/00_download_references.sh` | Fetch GRCh38, dbSNP, 1000G, ClinVar, chip BED; build BWA/faidx/dict indexes; learn ADMIXTURE reference clusters |
| 01 | `scripts/01_align.sh` | `bwa-mem2` align → sorted, indexed BAM |
| 02 | `scripts/02_refine.sh` | MarkDuplicates + BQSR (dbSNP known-sites) — **GATK path only** |
| 03 | `scripts/03_call_variants.sh` | GATK HaplotypeCaller **or** DeepVariant → `results/$SAMPLE.vcf.gz` |
| 04 | `scripts/04_annotate_health.sh` | VEP/ANNOVAR × ClinVar → annotated variants + caveat-wrapped report |
| 05 | `scripts/05_ancestry.sh` | VCF → PLINK → merge 1000G → ADMIXTURE projection → ancestry proportions |
| 06 | `scripts/06_export_23andme.sh` | Extract ~640k 23andMe chip positions (optional) |

The variant caller is swappable via `CALLER` in the config. GATK consumes the
BQSR'd BAM; DeepVariant consumes the deduped BAM directly and skips stage 02.
Both emit the same `results/$SAMPLE.vcf.gz`, so stages 04–06 don't care which ran.

## Layout

```
config/pipeline.conf     # all knobs
env/                     # LXC provisioning + toolchain bootstrap + conda env
scripts/lib.sh           # shared logging / preflight / resumability helpers
scripts/00..06_*.sh      # pipeline stages
run_pipeline.sh          # orchestrator
references/ data/ results/ logs/   # gitignored; created on first run
```

## Requirements

Installed by `env/bootstrap-lxc.sh` into a conda env: `bwa-mem2`, `samtools`,
`bcftools`, `gatk4`, `plink`/`plink2`, `admixture`, `ensembl-vep`; plus
`apptainer` for the DeepVariant container. See
[`env/environment.yml`](env/environment.yml).

---

*Reflects publicly available vendor/tooling information as of mid-2026. Not
medical advice — see a genetic counselor or physician for interpretation of any
clinically significant findings.*

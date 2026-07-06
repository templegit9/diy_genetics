#!/usr/bin/env bash
# =============================================================================
# 00_download_references.sh — fetch & prepare all reference data (GRCh38).
#
# One-time, large (~hundreds of GB), and slow — run during vendor turnaround.
# Fully resumable: existing files are skipped, indexes rebuilt only if missing.
#
# Produces, under $REF_DIR:
#   GRCh38/  reference FASTA + .fai + .dict + bwa-mem2 index
#   dbsnp/   dbSNP VCF (+ .tbi)        — BQSR known-sites
#   clinvar/ ClinVar VCF (+ .tbi)      — health annotation
#   1000g/   1000G Phase3 PLINK2 set   — ancestry panel + learned ADMIXTURE P
#   chip/    23andMe v5 positions BED  — stage 06 export
#   vep_cache/ (if ANNOTATOR=vep)      — VEP offline cache
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "00 download references"

require curl
[[ "${DRY_RUN}" == "1" ]] || require samtools bwa bwa-mem2 gatk plink2 tabix

# ---- reference source URLs (edit here if a mirror changes) -------------------
# GRCh38 primary assembly (no ALT contigs) — GENCODE mirror of the Ensembl build.
URL_GRCH38="https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_46/GRCh38.primary_assembly.genome.fa.gz"
# dbSNP build 156, GRCh38.
URL_DBSNP="https://ftp.ncbi.nih.gov/snp/archive/b156/VCF/GCF_000001405.40.gz"
URL_DBSNP_TBI="https://ftp.ncbi.nih.gov/snp/archive/b156/VCF/GCF_000001405.40.gz.tbi"
# ClinVar, GRCh38, weekly VCF.
URL_CLINVAR="https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz"
URL_CLINVAR_TBI="https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz.tbi"
# 1000 Genomes Phase 3, PLINK2 pgen (from the plink2 resources page).
# NOTE: this "phase 3" release is build 37 (GRCh37). The pipeline aligns to
# GRCh38, so the ancestry step (05) needs rsID-based matching or a liftover to
# use it correctly — see the ancestry caveat in the README. (Health annotation
# and the GPU variant-calling path do NOT use this dataset.)
URL_KG_PGEN="https://www.dropbox.com/s/y6ytfoybz48dc0u/all_phase3.pgen.zst?dl=1"
URL_KG_PVAR="https://www.dropbox.com/s/odlexvo8fummcvt/all_phase3.pvar.zst?dl=1"
URL_KG_PSAM="https://www.dropbox.com/scl/fi/haqvrumpuzfutklstazwk/phase3_corrected.psam?rlkey=0yyifzj2fb863ddbmsv4jkeq6&dl=1"

ensure_dir "${REF_DIR}"

# ---- 1. GRCh38 reference FASTA + indexes -----------------------------------
grch38_gz="${REF_DIR}/GRCh38/GRCh38.primary_assembly.genome.fa.gz"
if ! skip_if_done "${REF_FASTA}"; then
  download "${URL_GRCH38}" "${grch38_gz}"
  log "decompressing reference FASTA…"
  # bgzip-compatible tools want an uncompressed .fa for bwa-mem2/gatk indexing.
  run bash -c "gzip -dc '${grch38_gz}' > '${REF_FASTA}'"
fi
skip_if_done "${REF_FASTA}.fai"        || run samtools faidx "${REF_FASTA}"
skip_if_done "${REF_FASTA%.*}.dict"    || run gatk CreateSequenceDictionary -R "${REF_FASTA}"

# Classic BWA index (.amb/.ann/.bwt/.pac/.sa) — REQUIRED by NVIDIA Parabricks
# (pbrun germline/fq2bam reads <ref>.bwt). Low memory (~5.5 GB for the human
# genome), so it builds fine even where the bwa-mem2 index (~90 GB) cannot.
skip_if_done "${REF_FASTA}.bwt" || run bwa index "${REF_FASTA}"

# bwa-mem2 index writes several sidecar files; .bwt.2bit.64 is the sentinel.
# Building it for the human genome needs ~60-90 GB RAM. It is ONLY required for
# the CPU align path (stage 01, gatk/deepvariant callers). The GPU Parabricks
# path (03g) does its own alignment and does NOT need it — so a memory failure
# here is a warning, not a hard stop, and the rest of the references proceed.
if [[ "${SKIP_BWA_INDEX:-false}" == "true" ]]; then
  log_warn "SKIP_BWA_INDEX=true — not building the bwa-mem2 index. CPU align (stage 01,"
  log_warn "gatk/deepvariant callers) is unavailable until it's built; GPU Parabricks is unaffected."
elif ! skip_if_done "${REF_FASTA}.bwt.2bit.64"; then
  if ! run bwa-mem2 index "${REF_FASTA}"; then
    log_warn "bwa-mem2 index failed (needs ~60-90 GB RAM). CPU align (stage 01) will be"
    log_warn "unavailable until it is built (raise WSL memory, then re-run stage 00)."
    log_warn "The GPU Parabricks caller does NOT need this — continuing."
    rm -f "${REF_FASTA}".bwt.2bit.64 "${REF_FASTA}".0123 "${REF_FASTA}".amb \
          "${REF_FASTA}".ann "${REF_FASTA}".pac 2>/dev/null || true
  fi
fi

# ---- 2. dbSNP (BQSR known-sites) -------------------------------------------
# NCBI ships dbSNP (GCF_000001405.40 = GRCh38.p14) with RefSeq contig names
# (NC_0000..). BQSR needs contigs matching the reference (chr1..), so rename via
# the standard GRCh38 RefSeq->chr map for the 25 primary chromosomes. Unlisted
# alt/patch contigs keep their names and are simply ignored during BQSR.
dbsnp_raw="${REF_DIR}/dbsnp/GCF_000001405.40.gz"
refseq_map="${REF_DIR}/dbsnp/refseq2chr.tsv"
if ! skip_if_done "${DBSNP_VCF}"; then
  download "${URL_DBSNP}"     "${dbsnp_raw}"
  download "${URL_DBSNP_TBI}" "${dbsnp_raw}.tbi"
  ensure_dir "${REF_DIR}/dbsnp"
  run bash -c "printf 'NC_000001.11\tchr1\nNC_000002.12\tchr2\nNC_000003.12\tchr3\nNC_000004.12\tchr4\nNC_000005.10\tchr5\nNC_000006.12\tchr6\nNC_000007.14\tchr7\nNC_000008.11\tchr8\nNC_000009.12\tchr9\nNC_000010.11\tchr10\nNC_000011.10\tchr11\nNC_000012.12\tchr12\nNC_000013.11\tchr13\nNC_000014.9\tchr14\nNC_000015.10\tchr15\nNC_000016.10\tchr16\nNC_000017.11\tchr17\nNC_000018.10\tchr18\nNC_000019.10\tchr19\nNC_000020.11\tchr20\nNC_000021.9\tchr21\nNC_000022.11\tchr22\nNC_000023.11\tchrX\nNC_000024.10\tchrY\nNC_012920.1\tchrM\n' > '${refseq_map}'"
  log "renaming dbSNP contigs to GRCh38 chr names (large file, ~30 min)…"
  run bash -c "bcftools annotate --rename-chrs '${refseq_map}' '${dbsnp_raw}' -Oz -o '${DBSNP_VCF}'"
  run tabix -f -p vcf "${DBSNP_VCF}"
fi

# ---- 3. ClinVar (health annotation) ----------------------------------------
# ClinVar uses Ensembl-style contig names (1, 2, .. MT); rename to chr* to match
# the reference so VEP's custom ClinVar annotation lines up.
clinvar_raw="${REF_DIR}/clinvar/clinvar.raw.vcf.gz"
clinvar_map="${REF_DIR}/clinvar/ens2chr.tsv"
if ! skip_if_done "${CLINVAR_VCF}"; then
  download "${URL_CLINVAR}"     "${clinvar_raw}"
  download "${URL_CLINVAR_TBI}" "${clinvar_raw}.tbi"
  ensure_dir "${REF_DIR}/clinvar"
  run bash -c "{ for c in \$(seq 1 22) X Y; do printf '%s\tchr%s\n' \"\$c\" \"\$c\"; done; printf 'MT\tchrM\n'; } > '${clinvar_map}'"
  log "renaming ClinVar contigs to GRCh38 chr names…"
  run bash -c "bcftools annotate --rename-chrs '${clinvar_map}' '${clinvar_raw}' -Oz -o '${CLINVAR_VCF}'"
  run tabix -f -p vcf "${CLINVAR_VCF}"
fi

# ---- 4. 1000 Genomes Phase 3 panel (PLINK2) --------------------------------
kg_dir="${REF_DIR}/1000g"
ensure_dir "${kg_dir}"
if ! skip_if_done "${KG_PREFIX}.pgen" "${KG_PREFIX}.pvar" "${KG_PREFIX}.psam"; then
  download "${URL_KG_PGEN}" "${KG_PREFIX}.pgen.zst"
  download "${URL_KG_PVAR}" "${KG_PREFIX}.pvar.zst"
  download "${URL_KG_PSAM}" "${KG_PREFIX}.psam"
  log "decompressing 1000G pgen/pvar…"
  run bash -c "zstd -f -d '${KG_PREFIX}.pgen.zst' -o '${KG_PREFIX}.pgen' 2>/dev/null || plink2 --zst-decompress '${KG_PREFIX}.pgen.zst' > '${KG_PREFIX}.pgen'"
  run bash -c "zstd -f -d '${KG_PREFIX}.pvar.zst' -o '${KG_PREFIX}.pvar' 2>/dev/null || plink2 --zst-decompress '${KG_PREFIX}.pvar.zst' > '${KG_PREFIX}.pvar'"
fi

# ---- 5. Supervised ADMIXTURE reference (NON-FATAL: ancestry is secondary) ----
# Learn cluster allele freqs so stage 05 can *project* the personal sample.
# Wrapped in a function called with `|| log_warn` so a failure here does NOT
# block the essential VEP/chip steps below. NOTE: the 1000G "phase 3" panel is
# build 37; the ancestry step still needs an rsID/liftover fix for the GRCh38
# pipeline (see README) — this just prepares the reference clusters.
learn_admixture_reference() {
  if ! skip_if_done "${KG_POP}"; then
    log "building superpopulation label file from 1000G .psam (SuperPop column)…"
    # ADMIXTURE --supervised requires #distinct labels == K. Use the SuperPop
    # column (AFR/AMR/EAS/EUR/SAS = 5), NOT the last column (Population = 26).
    run bash -c "awk 'NR==1{for(i=1;i<=NF;i++)if(\$i==\"SuperPop\")c=i; next}{print \$c}' '${KG_PREFIX}.psam' > '${KG_POP}'"
  fi
  skip_if_done "${KG_ADMIX_P}" && return 0
  log "learning ADMIXTURE reference clusters (supervised, K=${ADMIXTURE_K}) — slow, one-time…"
  local ref_bed="${kg_dir}/ref_pruned"
  if ! skip_if_done "${ref_bed}.bed"; then
    # Key markers by the panel's native rsIDs (NOT chr:pos:ref:alt) so stage 05
    # can match a GRCh38 sample against this build-37 panel by rsID — positions
    # differ across builds, rsIDs don't. Drop duplicate IDs so --indep-pairwise
    # has unique keys. MAF + tight LD pruning bring the marker count down from
    # ~58M to a few hundred k, which is what ADMIXTURE can actually handle.
    # --indep-pairwise needs unique IDs. Fill ONLY missing ('.') IDs with
    # chr:pos:ref:alt (keeps real rsIDs, which stage 05 matches on), then drop
    # any variant whose ID still collides.
    run plink2 --pfile "${KG_PREFIX}" \
      --maf 0.05 --max-alleles 2 --snps-only \
      --set-missing-var-ids '@:#:$r:$a' --rm-dup exclude-all \
      --indep-pairwise 50 10 0.1 \
      --out "${kg_dir}/prune"
    # Cap at ~150k markers — plenty for 5-way superpopulation ADMIXTURE and keeps
    # the supervised learn to minutes rather than hours.
    run plink2 --pfile "${KG_PREFIX}" \
      --max-alleles 2 --snps-only \
      --set-missing-var-ids '@:#:$r:$a' --rm-dup exclude-all \
      --extract "${kg_dir}/prune.prune.in" \
      --thin-count 150000 --seed 42 \
      --make-bed --out "${ref_bed}"
  fi
  run cp "${KG_POP}" "${ref_bed}.pop"
  run bash -c "cd '${kg_dir}' && admixture --supervised -j${THREADS} '${ref_bed}.bed' ${ADMIXTURE_K}"
  run cp "${kg_dir}/ref_pruned.${ADMIXTURE_K}.P" "${KG_ADMIX_P}"
}
learn_admixture_reference || log_warn "ADMIXTURE reference prep failed — ancestry (stage 05) stays unavailable until the build-37/ID handling is fixed. Continuing to VEP/chip."

# ---- 6. 23andMe v5 chip positions (BED) ------------------------------------
if [[ "${RUN_23ANDME}" == "true" ]] && ! skip_if_done "${CHIP_BED}"; then
  ensure_dir "$(dirname "${CHIP_BED}")"
  log_warn "23andMe v5 chip BED not bundled (licensing). Provide it at: ${CHIP_BED}"
  log_warn "Format: tab-separated  chrom  start(0-based)  end  rsID  — one per SNP (~640k rows)."
  log_warn "Source options: an existing 23andMe raw export's positions, or a public v5 manifest."
  # Write a header stub so downstream skip logic and docs are clear.
  run bash -c "printf '# Provide 23andMe v5 positions here (chrom<TAB>start<TAB>end<TAB>rsID). Stage 06 is skipped until this exists.\n' > '${CHIP_BED}.MISSING'"
fi

# ---- 7. VEP offline cache (if using VEP) -----------------------------------
if [[ "${ANNOTATOR}" == "vep" ]] && ! skip_if_done "${VEP_CACHE_DIR}/.installed"; then
  ensure_dir "${VEP_CACHE_DIR}"
  if ! command -v vep_install >/dev/null 2>&1 && [[ "${DRY_RUN}" != "1" ]]; then
    log_warn "vep_install not found (ensembl-vep not installed) — skipping VEP cache."
    log_warn "Install it:  mamba install -n diy-genetics -c bioconda ensembl-vep  (or set ANNOTATOR=annovar)."
  else
    log "installing VEP GRCh38 offline cache (large, ~15GB)…"
    if run vep_install --AUTO cf --SPECIES homo_sapiens --ASSEMBLY GRCh38 \
         --CACHEDIR "${VEP_CACHE_DIR}" --NO_HTSLIB --QUIET; then
      # Only mark done if the cache actually materialised — a non-zero or
      # silently-failing install must NOT leave a false "ready" marker.
      if [[ "${DRY_RUN}" == "1" ]] || compgen -G "${VEP_CACHE_DIR}/homo_sapiens/*" >/dev/null; then
        run bash -c "touch '${VEP_CACHE_DIR}/.installed'"
        log_ok "VEP cache ready"
      else
        log_warn "vep_install reported success but no cache at ${VEP_CACHE_DIR}/homo_sapiens — not marking ready."
      fi
    else
      log_warn "vep_install failed; run manually or switch ANNOTATOR=annovar."
    fi
  fi
fi

log_ok "reference preparation complete (or dry-run planned)."

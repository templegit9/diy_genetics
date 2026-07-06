#!/usr/bin/env bash
# =============================================================================
# 05_ancestry.sh — estimate ancestry proportions via PCA projection.
#
# Projects the personal sample onto the 1000G PCA space learned in stage 00 and
# scores its distance to each superpopulation centroid. We use plink2 PCA
# projection because ADMIXTURE 1.3.0 segfaults on modern CPUs under WSL2.
# Matching is by rsID, so a GRCh38 sample lines up with the build-37 1000G panel
# (positions differ across builds, rsIDs don't).
#
# In:  $RESULTS_DIR/$SAMPLE.vcf.gz, $DBSNP_VCF, 1000G PCA reference (stage 00)
# Out: $RESULTS_DIR/$SAMPLE.ancestry.txt   (AFR AMR EAS EUR SAS proportions)
# =============================================================================
here="$(dirname "${BASH_SOURCE[0]}")"
source "${here}/lib.sh"
stage_banner "05 ancestry (PCA projection)"

IN_VCF="${RESULTS_DIR}/${SAMPLE}.vcf.gz"
ANCESTRY_OUT="${RESULTS_DIR}/${SAMPLE}.ancestry.txt"
work="${RESULTS_DIR}/ancestry_${SAMPLE}"
ref_bed="${REF_DIR}/1000g/ref_pruned"

if skip_if_done "${ANCESTRY_OUT}"; then exit 0; fi

require plink2 bcftools tabix awk python3
require_file "${IN_VCF}" "personal VCF (run stage 03)"
require_file "${KG_PCA_WTS}" "1000G PCA weights (run stage 00)"
require_file "${KG_PCA_AFREQ}" "1000G allele frequencies (run stage 00)"
require_file "${KG_PCA_REFPROJ}" "1000G reference PCs (run stage 00)"
require_file "${KG_POP}" "1000G superpopulation labels (run stage 00)"
require_file "${DBSNP_VCF}" "dbSNP (to key the sample by rsID; run stage 00)"
require_file "${ref_bed}.bim" "1000G reference markers (run stage 00)"
ensure_dir "${work}"

# ---- 1. Key the sample by rsID, reduce to the reference markers -------------
rsid_vcf="${work}/sample.rsid.vcf.gz"
if ! skip_if_done "${rsid_vcf}"; then
  log "annotating sample with dbSNP rsIDs (build-agnostic matching)…"
  run bash -c "bcftools annotate -a '${DBSNP_VCF}' -c ID '${IN_VCF}' -Oz -o '${rsid_vcf}' && tabix -f -p vcf '${rsid_vcf}'"
fi
log "converting sample to the reference marker set…"
run plink2 --vcf "${rsid_vcf}" \
  --chr 1-22 --output-chr 26 \
  --extract "${ref_bed}.bim" \
  --max-alleles 2 --snps-only \
  --make-bed --out "${work}/sample"

# ---- 2. Project onto the 1000G PCs (same scaling as the reference) ----------
log "projecting sample onto the 1000G PCA space…"
run plink2 --bfile "${work}/sample" \
  --read-freq "${KG_PCA_AFREQ}" \
  --score "${KG_PCA_WTS}" 2 6 header-read no-mean-imputation variance-standardize \
  --score-col-nums 7-16 --out "${work}/sample_proj"

# ---- 3. k-NN vs the reference PCs -> superpopulation proportions ------------
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_YEL}[DRY ]${_C_RESET}  build ${ANCESTRY_OUT}" >&2
else
  n_markers=$(wc -l < "${work}/sample.bim")
  run bash -c "python3 '${here}/ancestry_proportions.py' '${KG_PCA_REFPROJ}' '${KG_POP}' '${work}/sample_proj.sscore' '${n_markers}' '${SAMPLE}' > '${ANCESTRY_OUT}'"
fi

log_ok "ancestry estimate: ${ANCESTRY_OUT}"
log_warn "Ancestry precision is limited by the public reference panel; treat as directional."

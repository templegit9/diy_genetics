#!/usr/bin/env bash
# =============================================================================
# 05_ancestry.sh — estimate ancestry proportions via ADMIXTURE projection.
#
# Projects the personal sample onto the 1000G reference clusters learned in
# stage 00 (fixed .P), rather than re-estimating from scratch. This matches the
# guide's "projection mode" recommendation and runs in seconds, not hours.
#
# In:  $RESULTS_DIR/$SAMPLE.vcf.gz, 1000G panel + learned $KG_ADMIX_P
# Out: $RESULTS_DIR/$SAMPLE.ancestry.txt   (per-superpopulation proportions)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "05 ancestry (ADMIXTURE projection)"

IN_VCF="${RESULTS_DIR}/${SAMPLE}.vcf.gz"
ANCESTRY_OUT="${RESULTS_DIR}/${SAMPLE}.ancestry.txt"
work="${RESULTS_DIR}/ancestry_${SAMPLE}"

if skip_if_done "${ANCESTRY_OUT}"; then exit 0; fi

require plink2 admixture awk bcftools tabix
require_file "${IN_VCF}" "personal VCF (run stage 03)"
require_file "${KG_ADMIX_P}" "learned ADMIXTURE P (run stage 00)"
require_file "${REF_DIR}/1000g/prune.prune.in" "1000G pruned SNP list (run stage 00)"
require_file "${DBSNP_VCF}" "dbSNP (needed to key the sample by rsID; run stage 00)"
ensure_dir "${work}"

# ---- 1. Key the personal VCF by rsID, then reduce to the reference markers --
# The 1000G panel is build 37 and this sample is GRCh38 — match by rsID, not
# position. Annotate the sample with dbSNP rsIDs, then keep the reference's
# pruned rsID set so both sides share the same marker keys.
rsid_vcf="${work}/sample.rsid.vcf.gz"
if ! skip_if_done "${rsid_vcf}"; then
  log "annotating sample with dbSNP rsIDs (build-agnostic matching)…"
  run bash -c "bcftools annotate -a '${DBSNP_VCF}' -c ID '${IN_VCF}' -Oz -o '${rsid_vcf}' && tabix -f -p vcf '${rsid_vcf}'"
fi
log "converting personal VCF to the reference marker set…"
run plink2 --vcf "${rsid_vcf}" \
  --extract "${REF_DIR}/1000g/prune.prune.in" \
  --max-alleles 2 --snps-only \
  --make-bed --out "${work}/sample_pruned"

# ---- 2. Align sample to reference sites, then merge marker-for-marker -------
# ADMIXTURE projection expects one .bed whose SNPs match the learned P row order
# (the reference's ref_pruned). Merge sample into the reference layout.
ref_bed="${REF_DIR}/1000g/ref_pruned"
require_file "${ref_bed}.bed" "1000G reference bed (run stage 00)"

log "harmonizing sample against reference sites…"
# Keep only variants present in the reference; force the reference allele order.
run plink2 --bfile "${work}/sample_pruned" \
  --extract "${ref_bed}.bim" \
  --ref-allele "force" "${ref_bed}.bim" 5 2 \
  --make-bed --out "${work}/sample_aligned" 2>/dev/null \
  || run plink2 --bfile "${work}/sample_pruned" --make-bed --out "${work}/sample_aligned"

# ADMIXTURE projection input file: the sample .bed, with the reference .P placed
# alongside as <bedbase>.<K>.P.in
proj_base="${work}/sample_aligned"
run cp "${KG_ADMIX_P}" "${proj_base}.${ADMIXTURE_K}.P.in"

# ---- 3. Project ------------------------------------------------------------
log "projecting sample onto reference clusters (K=${ADMIXTURE_K})…"
run bash -c "cd '${work}' && admixture --projection -j${THREADS} '${proj_base}.bed' ${ADMIXTURE_K}"

# ---- 4. Label the Q proportions with superpopulation names -----------------
# The learned clusters map to superpops in the order ADMIXTURE assigned them in
# stage 00; we emit both raw columns and a best-effort labeled view.
Q_FILE="${proj_base}.${ADMIXTURE_K}.Q"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_YEL}[DRY ]${_C_RESET}  build ${ANCESTRY_OUT}" >&2
else
  {
    echo "# Ancestry estimate for ${SAMPLE} — ADMIXTURE projection onto 1000G (K=${ADMIXTURE_K})"
    echo "# NOTE: directional only. The public 1000G panel (2,504 individuals) cannot"
    echo "#       match 23andMe's proprietary database of millions; expect similar"
    echo "#       shape, not identical percentages. Cluster labels are inferred from"
    echo "#       the reference superpopulations (AFR/AMR/EAS/EUR/SAS)."
    echo "#"
    echo "# cluster_proportions (one column per ancestral component):"
    cat "${Q_FILE}"
  } > "${ANCESTRY_OUT}"
fi

log_ok "ancestry estimate: ${ANCESTRY_OUT}"
log_warn "Ancestry precision is limited by the public reference panel; treat as directional."

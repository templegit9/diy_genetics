#!/usr/bin/env bash
# =============================================================================
# 04_annotate_health.sh — annotate the personal VCF for clinical significance.
#
# Default annotator: Ensembl VEP with the ClinVar custom annotation.
# Alternative: ANNOVAR (set ANNOTATOR=annovar; requires a separate ANNOVAR
# install + humandb — documented, not auto-installed).
#
# In:  $RESULTS_DIR/$SAMPLE.vcf.gz, $CLINVAR_VCF, VEP cache
# Out: $RESULTS_DIR/$SAMPLE.annotated.vcf.gz
#      $RESULTS_DIR/$SAMPLE.health_report.tsv     (ClinVar hits, caveat-wrapped)
#
# ⚠️ Output is research-grade, NOT a diagnosis. The report is wrapped top and
#    bottom with a not-medical-advice caveat. See README.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "04 annotate health (${ANNOTATOR})"

IN_VCF="${RESULTS_DIR}/${SAMPLE}.vcf.gz"
ANNOT_VCF="${RESULTS_DIR}/${SAMPLE}.annotated.vcf.gz"
REPORT="${RESULTS_DIR}/${SAMPLE}.health_report.tsv"

require_file "${IN_VCF}" "personal VCF (run stage 03)"
require_file "${CLINVAR_VCF}" "ClinVar VCF (run stage 00)"
ensure_dir "${RESULTS_DIR}"

CAVEAT_TOP="\
# =============================================================================
# ${SAMPLE} — CLINICAL VARIANT REPORT  (research-grade, NOT a diagnosis)
# -----------------------------------------------------------------------------
# These are ClinVar-annotated variants from raw sequencing. A 'Pathogenic' flag
# here does NOT mean you have or will develop a condition: pathogenicity depends
# on zygosity, penetrance, phase, and confirmatory testing this pipeline does
# not perform. Raw WGS reports routinely surface alarming, low-quality, or
# non-actionable calls. Do NOT act on anything below without a genetic counselor
# or physician. If you have not decided how you'll handle an unexpected
# pathogenic finding, stop and decide that first.
# ============================================================================="

if skip_if_done "${ANNOT_VCF}" "${REPORT}"; then exit 0; fi

case "${ANNOTATOR}" in
  vep)
    require vep bcftools
    # Check the actual cache, not the (0-byte) marker — require_file uses -s and
    # would reject the empty marker even when the cache is fully present.
    if [[ "${DRY_RUN}" != "1" ]] && { [[ ! -d "${VEP_CACHE_DIR}/homo_sapiens" ]] || \
         [[ -z "$(ls -A "${VEP_CACHE_DIR}/homo_sapiens" 2>/dev/null)" ]]; }; then
      die "VEP cache not found (run stage 00). Expected ${VEP_CACHE_DIR}/homo_sapiens/<ver>_GRCh38/"
    fi
    log "annotating with VEP + ClinVar custom track…"
    # Redirection lives inside bash -c so DRY_RUN skips it atomically (an outer
    # '> file' would be opened by the shell even when run() is a no-op).
    run bash -c "
      vep \
        --input_file '${IN_VCF}' \
        --output_file STDOUT \
        --vcf --compress_output bgzip \
        --offline --cache --dir_cache '${VEP_CACHE_DIR}' \
        --assembly GRCh38 --fasta '${REF_FASTA}' \
        --fork '${THREADS}' \
        --custom '${CLINVAR_VCF},ClinVar,vcf,exact,0,CLNSIG,CLNDN' \
        --stats_file '${RESULTS_DIR}/${SAMPLE}.vep_stats.html' \
        > '${ANNOT_VCF}'
    "
    run tabix -f -p vcf "${ANNOT_VCF}" || true
    ;;

  annovar)
    require table_annovar.pl
    log_warn "ANNOVAR path requires humandb with clinvar built; see ANNOVAR docs."
    run table_annovar.pl "${IN_VCF}" "${ANNOVAR_DB:-humandb}" \
      -buildver hg38 -out "${RESULTS_DIR}/${SAMPLE}.annovar" \
      -remove -protocol refGene,clinvar_latest -operation g,f \
      -nastring . -vcfinput -polish
    run bash -c "bgzip -c '${RESULTS_DIR}/${SAMPLE}.annovar.hg38_multianno.vcf' > '${ANNOT_VCF}'"
    run tabix -f -p vcf "${ANNOT_VCF}" || true
    ;;

  *)
    die "unknown ANNOTATOR='${ANNOTATOR}' (expected 'vep' or 'annovar')"
    ;;
esac

# ---- Build the human-readable, caveat-wrapped ClinVar report ----------------
log "extracting ClinVar significance hits into a report…"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_YEL}[DRY ]${_C_RESET}  build ${REPORT}" >&2
else
  {
    echo "${CAVEAT_TOP}"
    printf 'CHROM\tPOS\tREF\tALT\tClinVar_Significance\tClinVar_Disease\n'
    # Pull ClinVar significance/disease out of the VEP CSQ (or ANNOVAR INFO).
    # Only emit rows that carry a ClinVar significance term.
    bcftools +split-vep -d -f '%CHROM\t%POS\t%REF\t%ALT\t%ClinVar_CLNSIG\t%ClinVar_CLNDN\n' \
      "${ANNOT_VCF}" 2>/dev/null \
      | awk -F'\t' '$5 != "" && $5 != "." { print }' \
      || echo "# (no ClinVar-significant variants extracted, or split-vep unavailable for this annotator)"
    echo ""
    echo "# END OF REPORT — reminder: research-grade, not a diagnosis. Consult a"
    echo "# genetic counselor or physician before acting on any variant above."
  } > "${REPORT}"
fi

log_ok "annotated VCF: ${ANNOT_VCF}"
log_ok "health report: ${REPORT}"
log_warn "This report is NOT medical advice. See a genetic counselor for interpretation."

#!/usr/bin/env bash
# =============================================================================
# 03_call_variants.sh — call variants with the configured backend.
#
# Dispatch on $CALLER:
#   gatk        -> GATK4 HaplotypeCaller on the BQSR'd BAM
#   deepvariant -> DeepVariant (Apptainer) on the deduped (markdup) BAM
#
# Both backends emit the SAME output so downstream stages are backend-agnostic:
#   Out: $RESULTS_DIR/$SAMPLE.vcf.gz (+ .tbi)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "03 call variants (${CALLER})"

OUT_VCF="${RESULTS_DIR}/${SAMPLE}.vcf.gz"
if skip_if_done "${OUT_VCF}" "${OUT_VCF}.tbi"; then exit 0; fi

require_file "${REF_FASTA}" "reference FASTA"
ensure_dir "${RESULTS_DIR}"

case "${CALLER}" in
  gatk)
    require gatk tabix
    BAM="${RESULTS_DIR}/${SAMPLE}.bqsr.bam"
    require_file "${BAM}" "BQSR BAM (run stage 02)"
    log "calling variants with GATK HaplotypeCaller…"
    run gatk --java-options "-Xmx${MEM_GB}g" HaplotypeCaller \
      -I "${BAM}" \
      -R "${REF_FASTA}" \
      -O "${OUT_VCF}" \
      --native-pair-hmm-threads "${THREADS}"
    # HaplotypeCaller writes a .tbi automatically; ensure it exists.
    [[ -s "${OUT_VCF}.tbi" ]] || run tabix -f -p vcf "${OUT_VCF}"
    ;;

  deepvariant)
    require apptainer tabix
    BAM="${RESULTS_DIR}/${SAMPLE}.markdup.bam"
    require_file "${BAM}" "markdup BAM (run stage 02)"
    SIF="${REF_DIR}/containers/deepvariant_${DV_VERSION}.sif"
    require_file "${SIF}" "DeepVariant image (run env/bootstrap-lxc.sh)"

    # Bind the directories DeepVariant needs to see, then run one_step.
    log "calling variants with DeepVariant ${DV_VERSION} (model=${DV_MODEL_TYPE})…"
    run apptainer exec \
      --bind "${REF_DIR}:${REF_DIR}" \
      --bind "${RESULTS_DIR}:${RESULTS_DIR}" \
      "${SIF}" /opt/deepvariant/bin/run_deepvariant \
        --model_type="${DV_MODEL_TYPE}" \
        --ref="${REF_FASTA}" \
        --reads="${BAM}" \
        --output_vcf="${OUT_VCF}" \
        --output_gvcf="${RESULTS_DIR}/${SAMPLE}.g.vcf.gz" \
        --num_shards="${THREADS}"
    [[ -s "${OUT_VCF}.tbi" ]] || run tabix -f -p vcf "${OUT_VCF}"
    ;;

  *)
    die "unknown CALLER='${CALLER}' (expected 'gatk' or 'deepvariant')"
    ;;
esac

log_ok "variant calls: ${OUT_VCF}"

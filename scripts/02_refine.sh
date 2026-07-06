#!/usr/bin/env bash
# =============================================================================
# 02_refine.sh — mark duplicates + Base Quality Score Recalibration (BQSR).
#
# GATK path only. When CALLER=deepvariant this stage is a no-op (DeepVariant
# is trained to work on the deduped BAM without BQSR) — the orchestrator skips
# it, but we also guard here so a direct invocation is safe.
#
# In:  $RESULTS_DIR/$SAMPLE.sorted.bam, $REF_FASTA, $DBSNP_VCF
# Out: $RESULTS_DIR/$SAMPLE.markdup.bam        (always, both callers use it)
#      $RESULTS_DIR/$SAMPLE.bqsr.bam           (GATK path only)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "02 refine (markdup + BQSR)"

IN_BAM="${RESULTS_DIR}/${SAMPLE}.sorted.bam"
MARKDUP_BAM="${RESULTS_DIR}/${SAMPLE}.markdup.bam"
BQSR_BAM="${RESULTS_DIR}/${SAMPLE}.bqsr.bam"
RECAL_TABLE="${RESULTS_DIR}/${SAMPLE}.recal.table"

require gatk samtools
require_file "${IN_BAM}" "sorted BAM (run stage 01)"
require_file "${REF_FASTA}" "reference FASTA"
ensure_dir "${RESULTS_DIR}"

java_mem="-Xmx${MEM_GB}g"

# ---- Mark duplicates (needed by BOTH callers) ------------------------------
if ! skip_if_done "${MARKDUP_BAM}" "${MARKDUP_BAM}.bai"; then
  log "marking duplicates…"
  run gatk --java-options "${java_mem}" MarkDuplicates \
    -I "${IN_BAM}" \
    -O "${MARKDUP_BAM}" \
    -M "${RESULTS_DIR}/${SAMPLE}.markdup.metrics.txt"
  run samtools index -@ "${THREADS}" "${MARKDUP_BAM}"
fi

# ---- BQSR (GATK path only) --------------------------------------------------
if [[ "${CALLER}" != "gatk" ]]; then
  log_ok "CALLER=${CALLER}; skipping BQSR (DeepVariant consumes markdup BAM directly)."
  exit 0
fi

require_file "${DBSNP_VCF}" "dbSNP known-sites (run stage 00)"

if skip_if_done "${BQSR_BAM}" "${BQSR_BAM}.bai"; then exit 0; fi

log "computing recalibration table (BQSR, dbSNP known-sites)…"
run gatk --java-options "${java_mem}" BaseRecalibrator \
  -I "${MARKDUP_BAM}" \
  -R "${REF_FASTA}" \
  --known-sites "${DBSNP_VCF}" \
  -O "${RECAL_TABLE}"

log "applying BQSR…"
run gatk --java-options "${java_mem}" ApplyBQSR \
  -I "${MARKDUP_BAM}" \
  -R "${REF_FASTA}" \
  --bqsr-recal-file "${RECAL_TABLE}" \
  -O "${BQSR_BAM}"

# ApplyBQSR emits a .bai automatically, but index defensively if missing.
[[ -s "${BQSR_BAM}.bai" || -s "${BQSR_BAM%.bam}.bai" ]] || run samtools index -@ "${THREADS}" "${BQSR_BAM}"

log_ok "analysis-ready BAM: ${BQSR_BAM}"

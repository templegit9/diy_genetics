#!/usr/bin/env bash
# =============================================================================
# 01_align.sh — align paired-end reads to GRCh38 with bwa-mem2, produce a
# coordinate-sorted, indexed BAM.
#
# In:  $FASTQ_R1, $FASTQ_R2, indexed $REF_FASTA
# Out: $RESULTS_DIR/$SAMPLE.sorted.bam (+ .bai)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "01 align (bwa-mem2)"

OUT_BAM="${RESULTS_DIR}/${SAMPLE}.sorted.bam"
if skip_if_done "${OUT_BAM}" "${OUT_BAM}.bai"; then exit 0; fi

require bwa-mem2 samtools
require_file "${FASTQ_R1}" "FASTQ R1"
require_file "${FASTQ_R2}" "FASTQ R2"
require_file "${REF_FASTA}" "reference FASTA"
require_file "${REF_FASTA}.bwt.2bit.64" "bwa-mem2 index (run stage 00)"

ensure_dir "${RESULTS_DIR}"

# @RG is mandatory for GATK downstream. Threads split across bwa and samtools;
# samtools sort gets a slice plus a per-thread memory budget.
sort_threads=$(( THREADS > 4 ? THREADS / 2 : 1 ))
rg="@RG\tID:${RG_ID}\tSM:${RG_SM}\tLB:${RG_LB}\tPL:${RG_PL}"

log "aligning ${SAMPLE} (${THREADS} threads)…"
# Pipe: bwa-mem2 -> samtools sort. `run` only wraps the outer bash -c so the
# pipeline (with its pipefail) executes as one unit and honors DRY_RUN.
run bash -c "
  set -o pipefail
  bwa-mem2 mem -t '${THREADS}' -R '${rg}' \
    '${REF_FASTA}' '${FASTQ_R1}' '${FASTQ_R2}' \
  | samtools sort -@ '${sort_threads}' -m 1G -o '${OUT_BAM}' -
"
run samtools index -@ "${THREADS}" "${OUT_BAM}"

log_ok "aligned BAM: ${OUT_BAM}"

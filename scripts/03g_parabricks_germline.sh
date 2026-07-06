#!/usr/bin/env bash
# =============================================================================
# 03g_parabricks_germline.sh — GPU-accelerated FASTQ -> VCF with NVIDIA Parabricks.
#
# `pbrun germline` does alignment (BWA-MEM) + mark-duplicates + BQSR +
# HaplotypeCaller in one GPU pass. When CALLER=parabricks this stage REPLACES
# the CPU stages 01/02/03 — the orchestrator wires that. Downstream stages
# 04/05/06 consume the same output contract:
#
#   In:  $FASTQ_R1, $FASTQ_R2, GATK-style $REF_FASTA (+ .fai + .dict), $DBSNP_VCF
#   Out: $RESULTS_DIR/$SAMPLE.vcf.gz (+ .tbi), $RESULTS_DIR/$SAMPLE.pb.bam
#
# Requires an NVIDIA GPU + Docker with the nvidia runtime, and the Parabricks
# image pulled from NGC (see env/wsl/bootstrap-wsl.sh).
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stage_banner "03g parabricks germline (GPU)"

OUT_VCF="${RESULTS_DIR}/${SAMPLE}.vcf.gz"
OUT_BAM="${RESULTS_DIR}/${SAMPLE}.pb.bam"
if skip_if_done "${OUT_VCF}" "${OUT_VCF}.tbi"; then exit 0; fi

require docker
require_file "${FASTQ_R1}" "FASTQ R1"
require_file "${FASTQ_R2}" "FASTQ R2"
require_file "${REF_FASTA}" "reference FASTA (run stage 00)"
require_file "${REF_FASTA}.fai" "reference .fai (run stage 00)"
require_file "${REF_FASTA%.fa}.dict" "sequence dictionary (run stage 00)"
require_file "${DBSNP_VCF}" "dbSNP known-sites (run stage 00)"
ensure_dir "${RESULTS_DIR}"

# ---- GPU preflight ----------------------------------------------------------
# Parabricks is GPU-only; fail early (and clearly) if no GPU is visible.
if [[ "${GPU_ENABLED}" != "false" && "${DRY_RUN}" != "1" ]]; then
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    die "no NVIDIA GPU visible (nvidia-smi failed). Parabricks needs a GPU; use CALLER=gatk for CPU."
  fi
  log "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
fi

# ---- assemble the docker + pbrun command ------------------------------------
# Identity bind-mounts (host path == container path) so every absolute path we
# pass to pbrun resolves unchanged inside the container — no path rewriting.
dv_args=(docker run --rm)
[[ "${GPU_ENABLED}" != "false" ]] && dv_args+=(--gpus "${PARABRICKS_GPUS}")
dv_args+=(
  -v "${REF_DIR}:${REF_DIR}"
  -v "${DATA_DIR}:${DATA_DIR}"
  -v "${RESULTS_DIR}:${RESULTS_DIR}"
  "${PARABRICKS_IMAGE}"
  pbrun germline
  --ref "${REF_FASTA}"
  --in-fq "${FASTQ_R1}" "${FASTQ_R2}"
  --knownSites "${DBSNP_VCF}"
  --out-bam "${OUT_BAM}"
  --out-variants "${OUT_VCF}"
  --num-gpus "${PARABRICKS_NUM_GPUS:-1}"
)
# 16 GB cards (RTX 5070 Ti) need low-memory mode for the memory-heavy steps.
[[ "${PARABRICKS_LOW_MEMORY}" == "true" ]] && dv_args+=(--low-memory)

log "running Parabricks germline (align+BQSR+HaplotypeCaller on GPU)…"
run "${dv_args[@]}"

# Parabricks writes a bgzipped VCF; ensure a tabix index exists for stage 04.
require docker  # (no-op reassert; tabix may live in the conda env instead)
if [[ "${DRY_RUN}" != "1" && ! -s "${OUT_VCF}.tbi" ]]; then
  if command -v tabix >/dev/null 2>&1; then
    run tabix -f -p vcf "${OUT_VCF}"
  else
    log_warn "tabix not found on PATH; index ${OUT_VCF} before stage 04 (annotation)."
  fi
fi

log_ok "GPU variant calls: ${OUT_VCF}"

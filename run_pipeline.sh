#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh — orchestrate the DIY genetics pipeline end to end.
#
# Runs the numbered stages in order, logging each to $LOG_DIR. Stages are
# individually resumable (they skip completed outputs), so re-running after an
# interruption continues where it stopped.
#
#   ./run_pipeline.sh              full run (align -> ancestry [+ 23andMe])
#   ./run_pipeline.sh --dry-run    print the plan, execute nothing
#   ./run_pipeline.sh --from 03    start at a given stage
#   ./run_pipeline.sh --only 04    run a single stage
#   ./run_pipeline.sh --help
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/scripts"

# ---- CLI parsing ------------------------------------------------------------
DRY_RUN=0
FROM=""
ONLY=""
usage() {
  # Print the header doc block (between the '# ===' borders), sans '# ' prefix.
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --from)    FROM="${2:?--from needs a stage number}"; shift 2 ;;
    --only)    ONLY="${2:?--only needs a stage number}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done
export DRY_RUN

# ---- load config so we know CALLER (affects which stages run) + LOG_DIR ------
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/pipeline.conf}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
# Don't create anything in dry-run — planning must be side-effect-free.
[[ "${DRY_RUN}" == "1" ]] || mkdir -p "${LOG_DIR}"

# ---- stage table ------------------------------------------------------------
# Each entry: "NN:script:description". Which stages run depends on CALLER:
#   parabricks -> 00, 03g (GPU germline replaces 01/02/03), 04, 05, 06
#   gatk/deepvariant -> 00, 01, 02, 03, 04, 05, 06
STAGES=(
  "00:00_download_references.sh:download & prepare references"
  "01:01_align.sh:align reads (bwa-mem2)"
  "02:02_refine.sh:markdup + BQSR"
  "03:03_call_variants.sh:call variants (${CALLER})"
  "03g:03g_parabricks_germline.sh:GPU germline FASTQ→VCF (parabricks)"
  "04:04_annotate_health.sh:annotate health (${ANNOTATOR})"
  "05:05_ancestry.sh:ancestry (ADMIXTURE)"
  "06:06_export_23andme.sh:23andMe export"
)

# Stage 00 is a one-time setup; the default run starts at alignment (01).
DEFAULT_START="01"

_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
banner() { echo "$(_c '1;36')╔══ DIY genetics pipeline ═══════════════════════════╗$(_c 0)"; }

should_run() {  # stage_number -> 0 run / 1 skip
  local n="$1"
  # --only wins.
  if [[ -n "${ONLY}" ]]; then [[ "${n}" == "${ONLY}" ]] && return 0 || return 1; fi
  # Respect --from; else default start.
  local start="${FROM:-${DEFAULT_START}}"
  [[ "${n}" < "${start}" ]] && return 1
  # GPU germline: Parabricks (03g) replaces the CPU align/refine/call stages.
  if [[ "${CALLER}" == "parabricks" ]]; then
    case "${n}" in
      01|02|03) return 1 ;;   # superseded by 03g
    esac
  elif [[ "${n}" == "03g" ]]; then
    return 1                  # 03g only runs for CALLER=parabricks
  fi
  # Skip BQSR stage entirely when DeepVariant is the caller.
  if [[ "${n}" == "02" && "${CALLER}" == "deepvariant" ]]; then
    # markdup still needed — 02 handles that and self-skips BQSR — so keep it.
    return 0
  fi
  # Skip 23andMe export when disabled.
  if [[ "${n}" == "06" && "${RUN_23ANDME}" != "true" ]]; then return 1; fi
  return 0
}

banner
echo "sample=${SAMPLE}  caller=${CALLER}  annotator=${ANNOTATOR}  dry_run=${DRY_RUN}"
[[ -n "${FROM}" ]] && echo "starting from stage ${FROM}"
[[ -n "${ONLY}" ]] && echo "running only stage ${ONLY}"
echo

start_ts="$(date +%s)"
for entry in "${STAGES[@]}"; do
  IFS=':' read -r num script desc <<< "${entry}"
  if ! should_run "${num}"; then
    printf '  %s∘ %s  %s (skipped)%s\n' "$(_c '2')" "${num}" "${desc}" "$(_c 0)"
    continue
  fi
  printf '%s▶ stage %s — %s%s\n' "$(_c '1;34')" "${num}" "${desc}" "$(_c 0)"
  logf="${LOG_DIR}/${SAMPLE}.stage${num}.log"
  if [[ "${DRY_RUN}" == "1" ]]; then
    # Dry-run: let the stage print its own [DRY] plan to the console.
    DRY_RUN=1 bash "${SCRIPTS}/${script}"
  else
    # Real run: tee stage output to a per-stage log.
    if ! bash "${SCRIPTS}/${script}" 2>&1 | tee "${logf}"; then
      echo "$(_c '1;31')✗ stage ${num} failed — see ${logf}$(_c 0)" >&2
      exit 1
    fi
  fi
  echo
done

elapsed=$(( $(date +%s) - start_ts ))
echo "$(_c '1;32')✓ pipeline complete in ${elapsed}s$(_c 0)"
echo "Results in: ${RESULTS_DIR}"
if [[ "${DRY_RUN}" != "1" ]]; then
  echo "  health report : ${RESULTS_DIR}/${SAMPLE}.health_report.tsv  (NOT medical advice)"
  echo "  ancestry      : ${RESULTS_DIR}/${SAMPLE}.ancestry.txt        (directional only)"
  [[ "${RUN_23ANDME}" == "true" ]] && echo "  23andMe export: ${RESULTS_DIR}/${SAMPLE}.23andme.txt"
fi

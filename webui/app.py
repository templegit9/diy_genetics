#!/usr/bin/env python3
"""
DIY genetics pipeline — web control panel (FastAPI).

Runs inside the same LXC as the pipeline. Lets you configure a run, launch
run_pipeline.sh in the background, tail its log live (Server-Sent Events), stop
it, and view rendered results (health report, ancestry, 23andMe export).

Single-user homelab tool. It shells out to the pipeline, so bind it to a
trusted network only. Set DIY_WEBUI_TOKEN to require a token on mutating calls.

Launch:  webui/run-webui.sh   (or: uvicorn app:app --host 0.0.0.0 --port 8080)
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import signal
import subprocess
import time
import zipfile
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    StreamingResponse,
)

# ---- paths ------------------------------------------------------------------
WEBUI_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = WEBUI_DIR.parent
CONFIG_FILE = PROJECT_ROOT / "config" / "pipeline.conf"
RUN_PIPELINE = PROJECT_ROOT / "run_pipeline.sh"
STATIC_DIR = WEBUI_DIR / "static"
STATE_FILE = WEBUI_DIR / "state.json"
RECENTS_FILE = WEBUI_DIR / "recents.json"

# Fields the UI exposes; exported as env overrides when launching the pipeline.
FORM_FIELDS = [
    "SAMPLE", "FASTQ_R1", "FASTQ_R2", "CALLER", "ANNOTATOR",
    "THREADS", "MEM_GB", "RUN_23ANDME", "ADMIXTURE_K",
]
# Extra conf vars we read (read-only) to locate outputs.
DERIVED_FIELDS = ["RESULTS_DIR", "LOG_DIR", "PROJECT_ROOT"]

# Superpopulation labels for K=5 ancestry (order matches stage 00's learn step).
SUPERPOPS = ["AFR", "AMR", "EAS", "EUR", "SAS"]

TOKEN = os.environ.get("DIY_WEBUI_TOKEN", "")

app = FastAPI(title="DIY Genetics Control Panel")

# The desktop app's WebView loads from a tauri:// origin and fetches this API
# cross-origin at http://localhost:8080, so the browser enforces CORS. Allow it
# (single-user, localhost-bound service). Without this the app reads every
# request as failed and shows the backend "stopped".
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---- run state (single active run) -----------------------------------------
_run: dict[str, Any] = {
    "proc": None,        # subprocess.Popen | None
    "logfile": None,     # Path | None
    "sample": None,
    "mode": None,        # "run" | "dry-run"
    "started": None,     # epoch seconds
}


# ---- config helpers ---------------------------------------------------------
def source_conf_vars(varnames: list[str]) -> dict[str, str]:
    """Source pipeline.conf in bash and echo the requested variables' resolved
    values (single source of truth). Falls back to {} if bash/conf unavailable."""
    script = "source '%s'; " % CONFIG_FILE + "".join(
        f'printf "%s=%s\\n" "{v}" "${{{v}}}"; ' for v in varnames
    )
    try:
        out = subprocess.run(
            ["bash", "-c", script],
            cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return {}
    conf: dict[str, str] = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            conf[k] = v
    return conf


def load_conf_defaults() -> dict[str, str]:
    return source_conf_vars(FORM_FIELDS + DERIVED_FIELDS)


def current_form() -> dict[str, str]:
    """Conf defaults overlaid with the last-used values from state.json."""
    conf = load_conf_defaults()
    form = {k: conf.get(k, "") for k in FORM_FIELDS}
    if STATE_FILE.exists():
        try:
            saved = json.loads(STATE_FILE.read_text())
            form.update({k: v for k, v in saved.items() if k in FORM_FIELDS})
        except Exception:
            pass
    return form


def results_dir() -> Path:
    return Path(load_conf_defaults().get("RESULTS_DIR", PROJECT_ROOT / "results"))


def log_dir() -> Path:
    return Path(load_conf_defaults().get("LOG_DIR", PROJECT_ROOT / "logs"))


# ---- auth -------------------------------------------------------------------
def check_token(request: Request) -> None:
    if TOKEN and request.headers.get("X-Auth-Token", "") != TOKEN:
        raise HTTPException(status_code=401, detail="bad or missing X-Auth-Token")


# ---- run lifecycle ----------------------------------------------------------
def is_running() -> bool:
    proc = _run["proc"]
    return proc is not None and proc.poll() is None


def current_stage(logfile: Path | None) -> str | None:
    """Scan the tail of the log for the last '▶ stage NN' marker."""
    if not logfile or not logfile.exists():
        return None
    stage = None
    try:
        for line in logfile.read_text(errors="replace").splitlines():
            if "▶ stage" in line:
                stage = line.split("▶ stage", 1)[1].strip()
    except Exception:
        return None
    return stage


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    html = STATIC_DIR / "index.html"
    return HTMLResponse(html.read_text())


@app.get("/guide", response_class=HTMLResponse)
@app.get("/guide.html", response_class=HTMLResponse)
def guide() -> HTMLResponse:
    return HTMLResponse((STATIC_DIR / "guide.html").read_text())


@app.get("/crashcourse", response_class=HTMLResponse)
@app.get("/crashcourse.html", response_class=HTMLResponse)
def crashcourse() -> HTMLResponse:
    return HTMLResponse((STATIC_DIR / "crashcourse.html").read_text())


@app.get("/api/config")
def api_config() -> dict[str, Any]:
    return {"form": current_form(), "auth_required": bool(TOKEN)}


@app.post("/api/run")
async def api_run(request: Request) -> JSONResponse:
    check_token(request)
    if is_running():
        raise HTTPException(status_code=409, detail="a run is already in progress")
    body = await request.json()
    overrides = {k: str(body.get(k, "")).strip() for k in FORM_FIELDS
                 if str(body.get(k, "")).strip() != ""}
    dry = bool(body.get("dry_run", False))
    sample = overrides.get("SAMPLE", "sample01")

    # Persist form for next visit.
    try:
        STATE_FILE.write_text(json.dumps(overrides, indent=2))
    except Exception:
        pass

    ldir = log_dir()
    ldir.mkdir(parents=True, exist_ok=True)
    logfile = ldir / f"webui_{sample}_{int(time.time())}.log"

    cmd = ["bash", str(RUN_PIPELINE)]
    if dry:
        cmd.append("--dry-run")

    env = os.environ.copy()
    env.update(overrides)
    # Force plain (non-TTY) logging so the stream has no ANSI escape codes.
    env["NO_COLOR"] = "1"

    # start_new_session -> own process group, so /api/stop can kill children too.
    logf = open(logfile, "w")
    proc = subprocess.Popen(
        cmd, cwd=str(PROJECT_ROOT), env=env,
        stdout=logf, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    _run.update(proc=proc, logfile=logfile, sample=sample,
                mode="dry-run" if dry else "run", started=time.time(), finished=None,
                plan=run_stage_plan(overrides.get("CALLER", "gatk"),
                                    overrides.get("RUN_23ANDME", "true")))
    return JSONResponse({"ok": True, "sample": sample,
                         "mode": _run["mode"], "logfile": logfile.name})


def run_stage_plan(caller: str, run_23andme: str) -> list[dict[str, str]]:
    """The stages this run will execute (00 is one-time setup, excluded)."""
    if caller == "parabricks":
        stages = [("03g", "GPU variant calling")]
    else:
        stages = [("01", "Align"), ("02", "Refine + BQSR"), ("03", "Call variants")]
    stages += [("04", "Health annotation"), ("05", "Ancestry")]
    if str(run_23andme).lower() == "true":
        stages.append(("06", "23andMe export"))
    return [{"id": s, "label": l} for s, l in stages]


@app.post("/api/stop")
async def api_stop(request: Request) -> dict[str, Any]:
    check_token(request)
    if not is_running():
        return {"ok": True, "note": "nothing running"}
    proc = _run["proc"]
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"stop failed: {exc}")
    return {"ok": True, "note": "SIGTERM sent to run"}


@app.get("/api/status")
def api_status() -> dict[str, Any]:
    proc = _run["proc"]
    running = is_running()
    rc = None if (proc is None or running) else proc.returncode
    stage = current_stage(_run["logfile"])
    plan = _run.get("plan") or []
    started = _run.get("started")
    # Freeze elapsed at completion so a finished run doesn't keep counting up.
    if not running and proc is not None and _run.get("finished") is None:
        _run["finished"] = time.time()
    end = time.time() if running else (_run.get("finished") or time.time())
    elapsed = int(end - started) if started else None

    # Current stage id = leading token of the "stage NN — ..." marker.
    stage_id = stage.split()[0] if stage else None
    idx = next((i for i, s in enumerate(plan) if s["id"] == stage_id), None)

    percent = None
    eta = None
    if plan:
        n = len(plan)
        if running and idx is not None:
            # coarse within-stage assumption (mid-stage); refines the ETA live.
            frac = (idx + 0.5) / n
            percent = round(frac * 100)
            if elapsed and frac > 0:
                eta = max(0, round(elapsed * (1 - frac) / frac))
        elif rc == 0:
            percent, eta = 100, 0
        elif rc is not None and idx is not None:
            percent = round((idx / n) * 100)

    return {
        "running": running,
        "returncode": rc,
        "sample": _run["sample"],
        "mode": _run["mode"],
        "stage": stage,
        "stage_id": stage_id,
        "started": started,
        "elapsed": elapsed,
        "plan": plan,
        "stage_index": idx,
        "percent": percent,
        "eta": eta,
    }


@app.get("/api/gpu")
def api_gpu() -> dict[str, Any]:
    """GPU status via nvidia-smi. Returns available=False off-GPU (e.g. dev Mac)."""
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,memory.total,memory.used,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8,
        )
    except Exception:
        return {"available": False}
    line = out.stdout.strip().splitlines()[0] if out.stdout.strip() else ""
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 4:
        return {"available": False}
    try:
        return {
            "available": True,
            "name": parts[0],
            "memory_total_mib": int(float(parts[1])),
            "memory_used_mib": int(float(parts[2])),
            "utilization_pct": int(float(parts[3])),
        }
    except ValueError:
        return {"available": False}


@app.get("/api/references")
def api_references() -> dict[str, Any]:
    """Report which reference datasets (stage 00 outputs) are present, so the UI
    can show download/prep progress and per-workflow readiness."""
    c = source_conf_vars(["REF_FASTA", "DBSNP_VCF", "CLINVAR_VCF", "KG_PREFIX",
                          "KG_POP", "KG_ADMIX_P", "CHIP_RSIDS", "VEP_CACHE_DIR"])
    fa = c.get("REF_FASTA", "")
    kg = c.get("KG_PREFIX", "")
    dict_path = (fa[:-3] + ".dict") if fa.endswith(".fa") else (fa + ".dict")
    vep = c.get("VEP_CACHE_DIR", "")

    def stat(p: str) -> dict[str, Any]:
        try:
            if p and os.path.isfile(p):
                return {"exists": True, "size": os.path.getsize(p)}
            # tolerate a still-downloading .part sibling as "in progress"
            if p and os.path.isfile(p + ".part"):
                return {"exists": False, "size": os.path.getsize(p + ".part"),
                        "in_progress": True}
        except OSError:
            pass
        return {"exists": False, "size": 0}

    spec = [
        ("GRCh38 reference FASTA", fa, "core"),
        ("FASTA index (.fai)", fa + ".fai" if fa else "", "core"),
        ("Sequence dictionary (.dict)", dict_path, "core"),
        ("BWA index (Parabricks)", fa + ".bwt" if fa else "", "core"),
        ("dbSNP known-sites", c.get("DBSNP_VCF", ""), "core"),
        ("ClinVar VCF", c.get("CLINVAR_VCF", ""), "annotation"),
        ("VEP cache", (vep + "/.installed") if vep else "", "annotation"),
        ("1000G panel (.pgen)", kg + ".pgen" if kg else "", "ancestry"),
        ("1000G panel (.pvar)", kg + ".pvar" if kg else "", "ancestry"),
        ("1000G panel (.psam)", kg + ".psam" if kg else "", "ancestry"),
        ("1000G population labels", c.get("KG_POP", ""), "ancestry"),
        ("ADMIXTURE learned clusters", c.get("KG_ADMIX_P", ""), "ancestry"),
        ("23andMe v5 chip rsIDs", c.get("CHIP_RSIDS", ""), "export"),
        ("bwa-mem2 index (optional, CPU align)", fa + ".bwt.2bit.64" if fa else "", "cpu"),
    ]
    items = [{"label": lbl, "path": p, "group": g, **stat(p)} for lbl, p, g in spec]
    have = {it["label"] for it in items if it["exists"]}

    def ok(labels: list[str]) -> bool:
        return all(l in have for l in labels)

    core = ["GRCh38 reference FASTA", "FASTA index (.fai)",
            "Sequence dictionary (.dict)", "BWA index (Parabricks)", "dbSNP known-sites"]
    ancestry = ["1000G panel (.pgen)", "1000G panel (.pvar)", "1000G panel (.psam)",
                "1000G population labels", "ADMIXTURE learned clusters"]
    readiness = {
        "GPU pipeline (Parabricks)": ok(core),
        "Health annotation": ok(["ClinVar VCF", "VEP cache"]),
        "Ancestry": ok(ancestry),
        "23andMe export": ok(["23andMe v5 chip rsIDs"]),
        "CPU align": ok(["bwa-mem2 index (CPU align only)"]),
    }
    return {"items": items, "readiness": readiness,
            "ready_count": len(have), "total": len(items)}


@app.get("/api/logs/stream")
async def api_logs_stream() -> StreamingResponse:
    """Server-Sent Events: stream the current run's log from the top, following
    until the process exits."""
    logfile: Path | None = _run["logfile"]

    async def gen():
        if not logfile:
            yield "event: end\ndata: no run started yet\n\n"
            return
        # Wait briefly for the file to appear.
        for _ in range(50):
            if logfile.exists():
                break
            await asyncio.sleep(0.1)
        if not logfile.exists():
            yield "event: end\ndata: log file not found\n\n"
            return
        with logfile.open("r", errors="replace") as fh:
            while True:
                line = fh.readline()
                if line:
                    # SSE frames: strip trailing newline, escape none needed.
                    yield f"data: {line.rstrip(chr(10))}\n\n"
                    continue
                # EOF: if the process ended, drain once more then stop.
                if not is_running():
                    tail = fh.readline()
                    while tail:
                        yield f"data: {tail.rstrip(chr(10))}\n\n"
                        tail = fh.readline()
                    rc = _run["proc"].returncode if _run["proc"] else None
                    yield f"event: end\ndata: exit {rc}\n\n"
                    return
                await asyncio.sleep(0.5)

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


# ---- results ----------------------------------------------------------------
def _parse_health(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    header: list[str] | None = None
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if header is None:
            header = cols
            continue
        rows.append(dict(zip(header, cols)))
        if len(rows) >= 1000:  # cap for the UI
            break
    return rows


def _parse_ancestry(path: Path) -> dict[str, Any]:
    proportions: list[float] = []
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        try:
            proportions = [float(x) for x in parts]
            break  # first data line = the sample's Q row
        except ValueError:
            continue
    labels = SUPERPOPS[:len(proportions)] if len(proportions) == len(SUPERPOPS) \
        else [f"pop{i+1}" for i in range(len(proportions))]
    return {"labels": labels, "proportions": proportions,
            "labeled": len(proportions) == len(SUPERPOPS)}


@app.get("/api/results")
def api_results(sample: str | None = None) -> dict[str, Any]:
    rdir = results_dir()
    s = sample or (_run["sample"] or current_form().get("SAMPLE", "sample01"))
    health = rdir / f"{s}.health_report.tsv"
    ancestry = rdir / f"{s}.ancestry.txt"
    chip = rdir / f"{s}.23andme.txt"
    hereditary = rdir / f"{s}.hereditary.tsv"
    out: dict[str, Any] = {"sample": s, "files": {}}
    for key, p in (("health", health), ("ancestry", ancestry), ("chip", chip),
                   ("hereditary", hereditary)):
        out["files"][key] = {"name": p.name, "exists": p.exists(),
                             "size": p.stat().st_size if p.exists() else 0}
    out["health_rows"] = _parse_health(health) if health.exists() else []
    out["ancestry"] = _parse_ancestry(ancestry) if ancestry.exists() else None
    out["hereditary"] = _parse_hereditary(hereditary) if hereditary.exists() else None
    return out


def _parse_hereditary(path: Path) -> dict[str, list]:
    """Group the hereditary.tsv rows by category (active/carrier/uncertain)."""
    groups: dict[str, list] = {"active": [], "carrier": [], "uncertain": []}
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#") or line.startswith("category\t"):
            continue
        p = line.split("\t")
        if len(p) < 5:
            continue
        groups.setdefault(p[0], []).append({
            "gene": p[1], "condition": p[2].replace("_", " ").replace("&", "; "),
            "zygosity": p[3], "significance": p[4].replace("_", " "),
        })
    return groups


@app.get("/api/download")
def api_download(name: str) -> FileResponse:
    """Download a result file by basename, confined to the results dir."""
    rdir = results_dir().resolve()
    target = (rdir / Path(name).name).resolve()
    if rdir not in target.parents or not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    return FileResponse(target, filename=target.name)


# ---- Saved analyses (.diyg) -------------------------------------------------
# A .diyg is a zip bundle of one run: analysis.json (config + metadata) plus the
# sample's result files and stage logs, so an analysis can be reopened later
# with its config and outputs intact.

def _analysis_members(sample: str) -> list[tuple[str, Path]]:
    """(arcname, path) for every file belonging to `sample` — results + logs.

    Intermediates that are large and reproducible (BAM, per-chrom temp) are
    skipped; the VCFs, reports, exports, logs and QC html are kept.
    """
    rdir, ldir = results_dir(), log_dir()
    members: list[tuple[str, Path]] = []
    for p in sorted(rdir.glob(f"{sample}.*")):
        if p.is_file() and p.suffix not in (".bam", ".bai") and not p.name.endswith(".pb.bam"):
            members.append((f"results/{p.name}", p))
    for p in sorted(ldir.glob(f"{sample}.stage*.log")):
        if p.is_file():
            members.append((f"logs/{p.name}", p))
    return members


@app.post("/api/analysis/save")
async def api_analysis_save(request: Request) -> dict[str, Any]:
    check_token(request)
    body = await request.json()
    sample = str(body.get("sample", "")).strip()
    dest = str(body.get("path", "")).strip()
    if not sample or not dest:
        raise HTTPException(status_code=400, detail="sample and path required")
    if not dest.endswith(".diyg"):
        dest += ".diyg"
    members = _analysis_members(sample)
    if not members:
        raise HTTPException(status_code=404, detail=f"no results found for sample '{sample}' — run the pipeline first")
    manifest = {
        "diyg_version": 1,
        "app": "DIY Genetics",
        "sample": sample,
        "created": int(time.time()),
        "config": current_form(),
        "files": [arc for arc, _ in members],
    }
    dest_path = Path(dest)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(dest_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("analysis.json", json.dumps(manifest, indent=2))
        for arc, p in members:
            z.write(p, arc)
    _record_recent(str(dest_path))
    return {"ok": True, "path": str(dest_path), "name": dest_path.stem, "sample": sample,
            "files": len(members), "size": dest_path.stat().st_size}


@app.post("/api/analysis/open")
async def api_analysis_open(request: Request) -> dict[str, Any]:
    check_token(request)
    body = await request.json()
    src = str(body.get("path", "")).strip()
    if not src or not Path(src).exists():
        raise HTTPException(status_code=400, detail="analysis file not found")
    rdir, ldir = results_dir(), log_dir()
    rdir.mkdir(parents=True, exist_ok=True)
    ldir.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(src) as z:
            manifest = json.loads(z.read("analysis.json"))
            for info in z.infolist():
                if info.is_dir():
                    continue
                name = info.filename
                if name.startswith("results/"):
                    target = rdir / Path(name).name
                elif name.startswith("logs/"):
                    target = ldir / Path(name).name
                else:
                    continue
                with z.open(info) as fsrc, open(target, "wb") as fdst:
                    shutil.copyfileobj(fsrc, fdst)
    except (zipfile.BadZipFile, KeyError) as exc:
        raise HTTPException(status_code=400, detail=f"not a valid .diyg file: {exc}")
    config = manifest.get("config", {})
    try:
        STATE_FILE.write_text(json.dumps(config, indent=2))
    except Exception:
        pass
    _record_recent(src)
    return {"ok": True, "sample": manifest.get("sample"), "name": Path(src).stem,
            "path": src, "config": config, "created": manifest.get("created")}


def _record_recent(path: str) -> None:
    """Prepend a .diyg path to the recents list (deduped, newest first, capped)."""
    try:
        items = json.loads(RECENTS_FILE.read_text()) if RECENTS_FILE.exists() else []
    except Exception:
        items = []
    items = [it for it in items if it.get("path") != path]
    items.insert(0, {"path": path, "name": Path(path).stem, "ts": int(time.time())})
    try:
        RECENTS_FILE.write_text(json.dumps(items[:10], indent=2))
    except Exception:
        pass


@app.get("/api/analysis/recents")
def api_analysis_recents() -> dict[str, Any]:
    try:
        items = json.loads(RECENTS_FILE.read_text()) if RECENTS_FILE.exists() else []
    except Exception:
        items = []
    # Drop entries whose file no longer exists so the menu stays truthful.
    items = [it for it in items if it.get("path") and Path(it["path"]).exists()]
    return {"recents": items}

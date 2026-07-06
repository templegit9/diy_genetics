# DIY Genetics — native desktop app (Tauri v2)

A thin native Windows shell around the pipeline control panel. It renders the
existing web UI (`webui/static/index.html`) in a native window and manages the
pipeline backend, which runs as a FastAPI service **inside WSL2**. The frontend
talks to that service at `http://localhost:8080`; the Rust layer only handles
the WSL-specific lifecycle (list distros, start/stop the backend service).

```
Tauri window (WebView2)  ──►  webui/static/index.html
      │  invoke start_backend / stop_backend / wsl_info
      ▼
wsl.exe -d Ubuntu-24.04  ──►  uvicorn app:app (webui) on 0.0.0.0:8080
```

## Prerequisites (on the Windows workstation — the build host)

- The WSL2 backend already set up (`env/wsl/setup-wsl.ps1`) with the
  `diy-genetics` conda env and the repo at `~/diy_genetics`.
- **Rust** (via <https://rustup.rs>) and **Node.js**.
- **WebView2 runtime** (preinstalled on Windows 11).
- MSVC build tools (Visual Studio Build Tools with the C++ workload).

## Build

```powershell
cd app
npm install
npm run tauri build       # produces the .msi + NSIS .exe under src-tauri/target/release/bundle/
```

Dev mode (hot-reload the shell):

```powershell
npm run tauri dev
```

## Icons

Regenerate from the source SVG after changing it:

```powershell
npm run tauri icon        # runs: tauri icon src-tauri/icon.svg
```

## How the frontend adapts

`webui/static/index.html` is shared by the browser and the app:
- In a **browser** (served by FastAPI): API calls are same-origin.
- In the **Tauri app**: `window.__TAURI__` is present (`withGlobalTauri: true`),
  so API calls target `http://localhost:8080` (allowed by the CSP in
  `tauri.conf.json`), and the **Start backend** button invokes the Rust
  `start_backend` command to launch uvicorn in WSL.

## Configuration knobs

- Target distro / repo path: `WSL_DISTRO` and `WSL_REPO` constants at the top of
  the `<script>` in `webui/static/index.html` (default `Ubuntu-24.04`,
  `~/diy_genetics`).
- Backend port: `8080` (uvicorn HOST/PORT in `webui/run-webui.sh`; must match the
  CSP `connect-src` and the `API` base in the frontend).

## Notes

- This project must be **built on Windows** — the bioinformatics toolchain and
  the GPU (Parabricks) run in WSL2, and the `.msi`/WebView2 target is Windows.
  `cargo check`/`build` will not work from macOS/Linux for this app.
- The Rust commands shell out to `wsl.exe`; they are no-ops off Windows.

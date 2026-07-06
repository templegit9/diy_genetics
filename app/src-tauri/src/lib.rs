//! DIY Genetics — Tauri v2 native shell.
//!
//! Thin desktop wrapper: renders the existing web control panel (webui/static)
//! and manages the pipeline backend, which runs as a FastAPI/uvicorn service
//! INSIDE a WSL2 distro. The frontend talks to that service at
//! http://localhost:8080 (WSL2 forwards localhost to Windows).
//!
//! The backend is spawned as a PERSISTENT child process (uvicorn in the
//! foreground of a wsl.exe session) that the app holds for its lifetime. Keeping
//! that wsl.exe session alive also keeps the WSL distro from idling out and
//! killing the service — a fire-and-forget/nohup launch does NOT survive that.

use std::process::{Child, Command};
use std::sync::Mutex;

/// Holds the running backend child so it persists and can be stopped.
struct Backend(Mutex<Option<Child>>);

/// Decode wsl.exe output, which is UTF-16LE on Windows.
fn decode_wsl(bytes: &[u8]) -> String {
    if bytes.len() >= 2 && bytes.len() % 2 == 0 && bytes[1] == 0 {
        let u16s: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16_lossy(&u16s)
    } else {
        String::from_utf8_lossy(bytes).to_string()
    }
}

/// Report installed WSL distros and whether the target one is present.
#[tauri::command]
fn wsl_info(distro: String) -> Result<serde_json::Value, String> {
    let out = Command::new("wsl.exe")
        .args(["-l", "-q"])
        .output()
        .map_err(|e| format!("wsl.exe not available: {e}"))?;
    let text = decode_wsl(&out.stdout);
    let distros: Vec<String> = text
        .replace('\u{0}', "")
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let present = distros.iter().any(|d| d == &distro);
    Ok(serde_json::json!({ "distros": distros, "present": present, "target": distro }))
}

/// Start the FastAPI control-panel service inside the WSL distro as a persistent
/// child. No-op if one is already running under this app.
#[tauri::command]
fn start_backend(
    distro: String,
    repo_path: String,
    state: tauri::State<Backend>,
) -> Result<String, String> {
    let mut guard = state.0.lock().map_err(|e| e.to_string())?;
    if let Some(child) = guard.as_mut() {
        if matches!(child.try_wait(), Ok(None)) {
            return Ok("already running".into());
        }
    }
    // exec so the wsl.exe session's process IS uvicorn (foreground); the app
    // holding this child keeps the distro alive.
    let inner = format!(
        "cd {repo} && mkdir -p logs && source ~/miniforge3/etc/profile.d/conda.sh && \
         conda activate diy-genetics && \
         exec env HOST=0.0.0.0 PORT=8080 bash webui/run-webui.sh >> logs/webui.out 2>&1",
        repo = repo_path
    );
    let child = Command::new("wsl.exe")
        .args(["-d", &distro, "--", "bash", "-lic", &inner])
        .spawn()
        .map_err(|e| format!("failed to launch wsl: {e}"))?;
    *guard = Some(child);
    Ok("starting".into())
}

/// Stop the control-panel service (kill the child + any uvicorn in the distro).
#[tauri::command]
fn stop_backend(distro: String, state: tauri::State<Backend>) -> Result<String, String> {
    if let Ok(mut guard) = state.0.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
        }
    }
    let _ = Command::new("wsl.exe")
        .args([
            "-d", &distro, "--", "bash", "-lic",
            "pkill -f 'uvicorn app:app' || true",
        ])
        .output();
    Ok("stopped".into())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Backend(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            wsl_info,
            start_backend,
            stop_backend
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

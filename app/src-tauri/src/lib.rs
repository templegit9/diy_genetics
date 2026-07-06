//! DIY Genetics — Tauri v2 native shell.
//!
//! Thin desktop wrapper: renders the existing web control panel (webui/static)
//! and manages the pipeline backend, which runs as a FastAPI/uvicorn service
//! INSIDE a WSL2 distro. The frontend talks to that service at
//! http://localhost:8080 (WSL2 forwards localhost to Windows); these commands
//! only handle the WSL-specific lifecycle the browser can't do itself.

use std::process::Command;

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

/// Start the FastAPI control-panel service inside the WSL distro.
/// uvicorn is nohup'd into the background so it persists after this returns.
#[tauri::command]
fn start_backend(distro: String, repo_path: String) -> Result<String, String> {
    let inner = format!(
        "cd {repo} && mkdir -p logs && \
         nohup ~/miniforge3/bin/conda run --no-capture-output -n diy-genetics \
         env HOST=0.0.0.0 PORT=8080 bash webui/run-webui.sh > logs/webui.out 2>&1 & \
         sleep 1 && echo started",
        repo = repo_path
    );
    let out = Command::new("wsl.exe")
        .args(["-d", &distro, "--", "bash", "-lic", &inner])
        .output()
        .map_err(|e| format!("failed to launch wsl: {e}"))?;
    if out.status.success() {
        Ok(decode_wsl(&out.stdout).trim().to_string())
    } else {
        Err(decode_wsl(&out.stderr))
    }
}

/// Stop the control-panel service inside the WSL distro.
#[tauri::command]
fn stop_backend(distro: String) -> Result<String, String> {
    let out = Command::new("wsl.exe")
        .args([
            "-d", &distro, "--", "bash", "-lic",
            "pkill -f 'uvicorn app:app' && echo stopped || echo none",
        ])
        .output()
        .map_err(|e| format!("failed to run wsl: {e}"))?;
    Ok(decode_wsl(&out.stdout).trim().to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            wsl_info,
            start_backend,
            stop_backend
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

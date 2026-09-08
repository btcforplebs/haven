//! Shared helpers for the probe binaries.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use fips_bridge_core::EndpointOptions;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Loads the nsec from `path` if it exists, otherwise generates one and
/// writes it there (creating parent directories as needed) so the SAME
/// identity — and therefore the same npub — comes back on the next launch.
pub fn load_or_create_nsec(path: &PathBuf) -> Result<String> {
    if path.exists() {
        let nsec = std::fs::read_to_string(path)
            .with_context(|| format!("reading nsec file {}", path.display()))?;
        let nsec = nsec.trim().to_string();
        anyhow::ensure!(!nsec.is_empty(), "nsec file {} is empty", path.display());
        return Ok(nsec);
    }

    let nsec = EndpointOptions::generate_nsec();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating directory {}", parent.display()))?;
    }
    // create_new + mode(0o600) up front closes the write-then-chmod window
    // (no 0644 gap) and refuses to clobber a file that appeared between the
    // exists() check above and this write.
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .with_context(|| format!("creating nsec file {}", path.display()))?;
        file.write_all(nsec.as_bytes())
            .with_context(|| format!("writing nsec file {}", path.display()))?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, &nsec)
            .with_context(|| format!("writing nsec file {}", path.display()))?;
    }
    Ok(nsec)
}

/// Deterministic non-repeating payload, so truncation or a duplicated block
/// cannot accidentally produce a matching hash.
pub fn build_payload(len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len);
    let mut state: u32 = 0x9E3779B9;
    while out.len() < len {
        state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        out.extend_from_slice(&state.to_le_bytes());
    }
    out.truncate(len);
    out
}

pub fn sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// A plain HTTP/1.1 origin standing in for the embedded Go relay + Blossom
/// server. Supports full GET, byte ranges, and a `101` upgrade so the relay's
/// WSS path is exercised too.
pub async fn origin_server(listener: TcpListener, blob: Arc<Vec<u8>>) {
    loop {
        let Ok((mut stream, _)) = listener.accept().await else {
            return;
        };
        let blob = blob.clone();
        tokio::spawn(async move {
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let Ok(n) = stream.read(&mut chunk).await else {
                    return;
                };
                if n == 0 {
                    return;
                }
                buf.extend_from_slice(&chunk[..n]);
                if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            let lower = String::from_utf8_lossy(&buf).to_lowercase();

            if lower.contains("upgrade: websocket") {
                let _ = stream
                    .write_all(
                        b"HTTP/1.1 101 Switching Protocols\r\n\
                          Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
                    )
                    .await;
                // Echo every post-upgrade message until the client disconnects,
                // not just one — a held-connection test (pings over minutes)
                // needs the origin to keep the pipe open, not close after the
                // first reply.
                let mut post = [0u8; 256];
                loop {
                    let Ok(n) = stream.read(&mut post).await else { return };
                    if n == 0 {
                        return;
                    }
                    if stream.write_all(&post[..n]).await.is_err() {
                        return;
                    }
                    if stream.flush().await.is_err() {
                        return;
                    }
                }
            }

            if let Some(range) = lower.split("range: bytes=").nth(1) {
                let spec = range.split("\r\n").next().unwrap_or("");
                let mut parts = spec.split('-');
                let start: usize = parts.next().unwrap_or("0").trim().parse().unwrap_or(0);
                let end: usize = parts
                    .next()
                    .unwrap_or("")
                    .trim()
                    .parse()
                    .unwrap_or(blob.len().saturating_sub(1));
                let end = end.min(blob.len().saturating_sub(1));
                if start <= end {
                    let slice = &blob[start..=end];
                    let header = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\n\
                         Content-Range: bytes {}-{}/{}\r\nContent-Length: {}\r\n\
                         Accept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                        start,
                        end,
                        blob.len(),
                        slice.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(slice).await;
                    let _ = stream.flush().await;
                    return;
                }
            }

            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                 Content-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                blob.len()
            );
            let _ = stream.write_all(header.as_bytes()).await;
            let _ = stream.write_all(&blob).await;
            let _ = stream.flush().await;
        });
    }
}

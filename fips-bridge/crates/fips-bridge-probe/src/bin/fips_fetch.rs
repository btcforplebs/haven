//! Consumer half of the two-host test. Pairs with `fips_serve` running on a
//! second machine: connects to its npub, re-exposes its origin on a loopback
//! port, and runs the checks the gate cares about — full GET (sha256'd),
//! byte range, and an optionally-held WebSocket upgrade with drop counting.
//!
//! Usage: fips_fetch --npub <provider npub> [--mib 20] [--sha256 <hex>]
//!                    [--hold-secs 300] [--port <fixed ingress port>]
//!
//! Prints one JSON line per check on stdout so a session log can be built by
//! piping to a file, plus the consumer's public IP so a run can be checked
//! against the provider's logged IP (same public IP on both sides means the
//! internet path was never actually exercised).

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use fips_bridge_core::proxy::Ingress;
use fips_bridge_core::{bind_endpoint, EndpointOptions, FipsQuic};
use fips_bridge_probe::sha256;
use fips_endpoint::PeerIdentity;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const SCOPE: &str = "nostr-vault-fips";

struct Args {
    npub: String,
    mib: usize,
    expected_sha256: Option<String>,
    hold_secs: u64,
    port: Option<u16>,
}

fn parse_args() -> Result<Args> {
    let mut npub = None;
    let mut mib: usize = 20;
    let mut expected_sha256 = None;
    let mut hold_secs: u64 = 0;
    let mut port = None;

    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--npub" => npub = Some(it.next().context("--npub requires a value")?),
            "--mib" => mib = it.next().context("--mib requires a value")?.parse()?,
            "--sha256" => expected_sha256 = Some(it.next().context("--sha256 requires a value")?),
            "--hold-secs" => hold_secs = it.next().context("--hold-secs requires a value")?.parse()?,
            "--port" => port = Some(it.next().context("--port requires a value")?.parse()?),
            other => anyhow::bail!("unrecognized argument: {other}"),
        }
    }

    Ok(Args {
        npub: npub.context("--npub is required")?,
        mib,
        expected_sha256,
        hold_secs,
        port,
    })
}

/// One line of the machine-readable check log.
fn emit(check: &str, ok: bool, extra: &str) {
    let status = if ok { "pass" } else { "fail" };
    println!(
        "{{\"check\":\"{check}\",\"status\":\"{status}\",{extra}}}"
    );
}

/// Best-effort public IP via curl (matches how the rest of the test plan
/// checks it). Non-fatal: a run should not die just because this failed.
fn public_ip() -> String {
    for url in ["https://ifconfig.me", "https://api.ipify.org", "https://icanhazip.com"] {
        let ip = std::process::Command::new("curl")
            .args(["-s", "--max-time", "5", url])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        if let Some(ip) = ip {
            return ip;
        }
    }
    "unknown".to_string()
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = parse_args()?;

    let ip = public_ip();
    println!("consumer public IP: {ip}");
    println!("provider npub      : {}", args.npub);

    // A fresh identity every run (consumer doesn't need to be re-findable),
    // but NOT ephemeral()'s local_rendezvous(true): that binds 127.0.0.1:21211
    // exclusively, which the provider also wants on the same host, and on the
    // real off-LAN gate it would let a local-composition path stand in for
    // the internet path the test is supposed to be exercising.
    let consumer = bind_endpoint(EndpointOptions::with_identity(
        EndpointOptions::generate_nsec(),
        SCOPE,
    ))
    .await?;
    let quic = Arc::new(FipsQuic::new(consumer).await?);

    let peer = PeerIdentity::from_pubkey(
        fips_endpoint::decode_npub(&args.npub).context("decode provider npub")?,
    );

    let bind_addr = args
        .port
        .map(|p| format!("127.0.0.1:{p}"))
        .unwrap_or_else(|| "127.0.0.1:0".to_string());
    let listener = TcpListener::bind(&bind_addr).await?;
    let ingress_addr = listener.local_addr()?;
    let ingress = Ingress::new(quic, peer);
    {
        let ingress = ingress.clone();
        tokio::spawn(async move { ingress.serve(listener).await });
    }
    println!("consumer loopback origin: http://{ingress_addr}\n");

    // Peering (real discovery/NAT-traversal on a two-host run, not just
    // in-process handshake) can take longer than a fixed short sleep covers,
    // so retry the first connection instead of failing on a cold peer.
    let mut failures = Vec::new();
    let started = Instant::now();
    let (status, body) = retry_connect(|| http_get(ingress_addr, "/blob", &[]), Duration::from_secs(20)).await?;
    let elapsed = started.elapsed().as_secs_f64().max(0.000_001);
    let got_sha256 = sha256(&body);
    let mib_s = body.len() as f64 / 1024.0 / 1024.0 / elapsed;
    let sha_ok = args
        .expected_sha256
        .as_ref()
        .map(|want| want.eq_ignore_ascii_case(&got_sha256))
        .unwrap_or(true);
    let ok = status == 200 && body.len() == args.mib * 1024 * 1024 && sha_ok;
    if !ok {
        failures.push("full GET");
    }
    println!(
        "[1] full GET: status={status} bytes={} sha256={got_sha256} elapsed={elapsed:.2}s ({mib_s:.1} MiB/s)",
        body.len()
    );
    emit(
        "full_get",
        ok,
        &format!(
            "\"status\":{status},\"bytes\":{},\"sha256\":\"{got_sha256}\",\"mib_per_s\":{mib_s:.2}",
            body.len()
        ),
    );

    // 2. Byte-range GET.
    let (status, body) = http_get(ingress_addr, "/blob", &[("Range", "bytes=0-1023")]).await?;
    let ok = status == 206 && body.len() == 1024;
    if !ok {
        failures.push("range GET");
    }
    println!("[2] range GET: status={status} bytes={}", body.len());
    emit("range_get", ok, &format!("\"status\":{status},\"bytes\":{}", body.len()));

    // 3. WebSocket-style upgrade, optionally held with periodic pings,
    //    reconnecting (and counting) on any drop.
    let mut drops = 0u32;
    let mut pings = 0u32;
    let hold = Duration::from_secs(args.hold_secs);
    let deadline = Instant::now() + hold;
    let mut stream = ws_upgrade(ingress_addr).await?;
    println!("[3] upgrade: connected, holding for {}s", args.hold_secs);
    loop {
        if Instant::now() >= deadline {
            break;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        let wait = remaining.min(Duration::from_secs(30));
        tokio::time::sleep(wait).await;
        if Instant::now() >= deadline {
            break;
        }
        pings += 1;
        match ping(&mut stream).await {
            Ok(()) => {}
            Err(_) => {
                drops += 1;
                match ws_upgrade(ingress_addr).await {
                    Ok(s) => stream = s,
                    Err(e) => {
                        println!("    reconnect failed: {e}");
                        break;
                    }
                }
            }
        }
    }
    let ok = args.hold_secs == 0 || drops == 0;
    if !ok {
        failures.push("upgrade hold");
    }
    println!("    pings={pings} drops={drops}");
    emit("upgrade_hold", ok, &format!("\"hold_secs\":{},\"pings\":{pings},\"drops\":{drops}", args.hold_secs));

    println!("\n--- verdict ---");
    if failures.is_empty() {
        println!("  PASS");
    } else {
        println!("  FAIL: {failures:?}");
    }

    if !failures.is_empty() {
        bail!("{} check(s) failed", failures.len());
    }
    Ok(())
}

/// Retries `f` with a short backoff until it succeeds or `budget` elapses.
/// Covers real peer discovery/NAT-traversal latency on a two-host run, which
/// a single fixed sleep before the first request cannot reliably bound.
async fn retry_connect<F, Fut, T>(mut f: F, budget: Duration) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let deadline = Instant::now() + budget;
    let mut delay = Duration::from_millis(200);
    loop {
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) if Instant::now() < deadline => {
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(2));
                let _ = e;
            }
            Err(e) => return Err(e).context("peer did not become reachable within budget"),
        }
    }
}

async fn ping(stream: &mut TcpStream) -> Result<()> {
    stream.write_all(b"PING").await?;
    let mut buf = [0u8; 16];
    let n = stream.read(&mut buf).await?;
    anyhow::ensure!(n > 0, "connection closed");
    Ok(())
}

async fn ws_upgrade(addr: SocketAddr) -> Result<TcpStream> {
    let mut stream = TcpStream::connect(addr).await?;
    stream
        .write_all(
            b"GET /ws HTTP/1.1\r\nHost: fips.local\r\n\
              Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        )
        .await?;
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut byte).await?;
        anyhow::ensure!(n > 0, "connection closed before upgrade completed");
        head.push(byte[0]);
    }
    let status = parse_status(&String::from_utf8_lossy(&head));
    anyhow::ensure!(status == 101, "expected 101, got {status}");
    Ok(stream)
}

async fn http_get(addr: SocketAddr, path: &str, extra: &[(&str, &str)]) -> Result<(u16, Vec<u8>)> {
    let mut stream = TcpStream::connect(addr).await?;
    let mut request = format!("GET {path} HTTP/1.1\r\nHost: fips.local\r\n");
    for (k, v) in extra {
        request.push_str(&format!("{k}: {v}\r\n"));
    }
    request.push_str("Connection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).await?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await?;
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .context("no header terminator in response")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let body = raw[split + 4..].to_vec();
    Ok((parse_status(&head), body))
}

fn parse_status(head: &str) -> u16 {
    head.lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse().ok())
        .unwrap_or(0)
}

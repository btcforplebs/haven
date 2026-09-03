//! Two-host mode for the datagram probe in `main.rs`.
//!
//! `main.rs` pairs two identities in-process via `local_rendezvous`, which
//! cannot fragment or lose a packet by construction — it proves the API
//! ceiling, not the single-fragment limit real paths care about. This binary
//! is the same LADDER walk split across two machines: a provider that
//! registers the service port and echoes back whatever it receives, and a
//! consumer that sends the ladder and times out waiting for each echo.
//!
//! Usage:
//!   provider (Mac mini): mtu_probe --serve --nsec-file ~/fips/mtu-nsec
//!   consumer (laptop)  : mtu_probe --npub <provider npub>
//!
//! `--serve` reuses the same persisted-identity recipe as `fips_serve` so the
//! provider's npub survives a restart; the consumer's identity is fresh every
//! run, matching `fips_fetch`.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result};
use fips_bridge_core::{bind_endpoint, EndpointOptions};
use fips_bridge_probe::load_or_create_nsec;
use fips_endpoint::{FipsEndpointServiceDatagram, PeerIdentity};

const SCOPE: &str = "nostr-vault-fips";

/// Service port both ends agree on, same as the in-process probe.
const SERVICE_PORT: u16 = 4000;

/// Same decision-zone sizes as `main.rs`'s in-process LADDER.
const LADDER: &[usize] = &[
    64, 512, 1_000, 1_200, 1_242, 1_300, 1_362, 1_400, 1_500, 2_000, 8_192, 32_768,
];

enum Mode {
    Serve { nsec_file: Option<PathBuf> },
    Fetch { npub: String },
}

fn parse_args() -> Result<Mode> {
    let mut serve = false;
    let mut nsec_file = None;
    let mut npub = None;

    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--serve" => serve = true,
            "--nsec-file" => nsec_file = Some(PathBuf::from(it.next().context("--nsec-file requires a path")?)),
            "--npub" => npub = Some(it.next().context("--npub requires a value")?),
            other => anyhow::bail!("unrecognized argument: {other}"),
        }
    }

    if serve {
        Ok(Mode::Serve { nsec_file })
    } else {
        Ok(Mode::Fetch {
            npub: npub.context("--npub is required in consumer mode (or pass --serve)")?,
        })
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    match parse_args()? {
        Mode::Serve { nsec_file } => serve(nsec_file).await,
        Mode::Fetch { npub } => fetch(npub).await,
    }
}

/// Registers the service port and echoes every datagram back to its sender
/// on the same port, so the consumer can tell delivery from loss without any
/// side channel between the two machines.
async fn serve(nsec_file: Option<PathBuf>) -> Result<()> {
    let options = match &nsec_file {
        Some(path) => {
            let nsec = load_or_create_nsec(path)?;
            EndpointOptions::with_identity(nsec, SCOPE)
        }
        None => EndpointOptions::with_identity(EndpointOptions::generate_nsec(), SCOPE),
    };

    let endpoint = bind_endpoint(options).await?;
    let receiver = endpoint
        .register_service_receiver(SERVICE_PORT)
        .await
        .context("register_service_receiver")?;

    println!("\n=========================================================");
    println!(" mtu_probe provider ready");
    println!("=========================================================");
    println!(" npub    : {}", endpoint.npub());
    println!(" address : {}", endpoint.address());
    println!(" identity: {}", identity_note(&nsec_file));
    println!("---------------------------------------------------------");
    println!(" Paste the npub into the consumer's --npub. Echoing until");
    println!(" interrupted.");
    println!("=========================================================\n");

    let mut buf: Vec<FipsEndpointServiceDatagram> = Vec::with_capacity(4);
    loop {
        match receiver.recv_batch_into(&mut buf, 4).await {
            Some(_) => {
                for datagram in buf.drain(..) {
                    let len = datagram.data.len();
                    let payload = datagram.data.as_slice().to_vec();
                    let _ = endpoint
                        .send_datagram(datagram.source_peer, SERVICE_PORT, datagram.source_port, payload)
                        .await;
                    println!("  echoed {len} bytes");
                }
            }
            None => anyhow::bail!("service receiver closed"),
        }
    }
}

fn identity_note(nsec_file: &Option<PathBuf>) -> String {
    match nsec_file {
        Some(path) => format!("persisted at {}", path.display()),
        None => "ephemeral (fresh every launch — pass --nsec-file to persist)".to_string(),
    }
}

/// Walks the ladder against `npub`, printing the same size/result table as
/// the in-process probe, then the largest single-fragment payload actually
/// delivered — the number the two-host gate checks against the 1200-byte
/// QUIC floor.
async fn fetch(npub: String) -> Result<()> {
    let consumer = bind_endpoint(EndpointOptions::with_identity(
        EndpointOptions::generate_nsec(),
        SCOPE,
    ))
    .await?;
    let receiver = consumer
        .register_service_receiver(SERVICE_PORT)
        .await
        .context("register_service_receiver")?;

    let peer = PeerIdentity::from_pubkey(fips_endpoint::decode_npub(&npub).context("decode provider npub")?);

    println!("consumer npub: {}\n", consumer.npub());
    println!("waiting for peering (canary, 30s budget)...");
    let mut peered = false;
    for attempt in 0..60 {
        let _ = consumer
            .send_datagram(peer.clone(), SERVICE_PORT, SERVICE_PORT, vec![0u8; 64])
            .await;
        if recv_one(&receiver, Duration::from_millis(500)).await.is_some() {
            println!("  peered after {} attempt(s)\n", attempt + 1);
            peered = true;
            break;
        }
    }
    if !peered {
        anyhow::bail!("not peered — provider unreachable within 30s budget");
    }
    // Drain the canary echo so it can't be misread as the first rung.
    while recv_one(&receiver, Duration::from_millis(50)).await.is_some() {}

    println!("{:>8}  {:>8}  {}", "size", "result", "note");
    println!("{:->8}  {:->8}  {:->40}", "", "", "");

    let mut largest_delivered = 0usize;
    for &size in LADDER {
        let payload = vec![0xABu8; size];
        if let Err(e) = consumer.send_datagram(peer.clone(), SERVICE_PORT, SERVICE_PORT, payload).await {
            println!("{size:>8}  {:>8}  send rejected: {e}", "REJECT");
            continue;
        }

        match recv_one(&receiver, Duration::from_secs(5)).await {
            Some(d) => {
                let got = d.data.len();
                if got == size {
                    largest_delivered = largest_delivered.max(size);
                    println!("{size:>8}  {:>8}  ", "ok");
                } else {
                    println!("{size:>8}  {:>8}  SIZE MISMATCH: got {got} bytes", "ok");
                }
            }
            None => println!("{size:>8}  {:>8}  no echo within 5s", "LOST"),
        }
    }

    println!("\n--- results ---");
    println!("  Largest delivered: {largest_delivered} bytes");
    println!("\n--- verdict ---");
    if largest_delivered >= 1_200 {
        println!("  PASS: >=1200-byte single-fragment datagrams cross this path.");
    } else {
        println!("  FAIL: could not deliver 1200 bytes single-fragment.");
        println!("  quinn cannot run below its 1200-byte floor on this path.");
    }

    Ok(())
}

async fn recv_one(
    receiver: &fips_endpoint::FipsEndpointServiceReceiver,
    timeout: Duration,
) -> Option<FipsEndpointServiceDatagram> {
    let mut buf: Vec<FipsEndpointServiceDatagram> = Vec::with_capacity(4);
    match tokio::time::timeout(timeout, receiver.recv_batch_into(&mut buf, 4)).await {
        Ok(Some(_)) => buf.into_iter().next(),
        _ => None,
    }
}

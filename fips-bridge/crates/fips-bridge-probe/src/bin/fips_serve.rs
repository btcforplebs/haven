//! Mac-side provider for the two-host test.
//!
//! Serves a known blob over the FIPS mesh and prints the npub the consumer needs.
//! Pair this with the iOS probe app (or another machine) to get the measurement
//! that in-process testing structurally cannot produce: real RTT, real NAT
//! traversal, real packet loss, and — the number that actually decides the
//! transport — whether datagrams survive unfragmented on a real path.
//!
//! Usage:  cargo run --release --bin fips_serve -- --nsec-file ~/fips/nsec --mib 20
//!         FIPS_BLOB_MIB=20 cargo run --release --bin fips_serve
//!
//! `--nsec-file <path>` makes the npub survive a restart: the nsec is
//! generated once and persisted there, then reloaded on every subsequent
//! launch. Without it, a fresh identity is minted every run (fine for a
//! quick smoke, useless for the restart-recovery check the gate cares about).

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use fips_bridge_core::proxy::egress;
use fips_bridge_core::{bind_endpoint, EndpointOptions, FipsQuic};
use fips_bridge_probe::{build_payload, load_or_create_nsec, origin_server, sha256};
use tokio::net::TcpListener;

const SCOPE: &str = "nostr-vault-fips";

struct Args {
    nsec_file: Option<PathBuf>,
    mib: usize,
    local_rendezvous: bool,
}

fn parse_args() -> Result<Args> {
    let mut nsec_file = None;
    let mut mib: usize = std::env::var("FIPS_BLOB_MIB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8);
    let mut local_rendezvous = false;

    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--nsec-file" => {
                let path = it.next().context("--nsec-file requires a path")?;
                nsec_file = Some(PathBuf::from(path));
            }
            "--mib" => {
                let v = it.next().context("--mib requires a value")?;
                mib = v.parse().context("--mib must be an integer")?;
            }
            "--local-rendezvous" => local_rendezvous = true,
            other => anyhow::bail!("unrecognized argument: {other}"),
        }
    }

    Ok(Args {
        nsec_file,
        mib,
        local_rendezvous,
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = parse_args()?;

    let (options, identity_note) = match &args.nsec_file {
        Some(path) => {
            let nsec = load_or_create_nsec(path)?;
            let opts = EndpointOptions::with_identity(nsec, SCOPE).local_rendezvous(args.local_rendezvous);
            (opts, format!("persisted at {}", path.display()))
        }
        None => (
            // ephemeral() already turns local_rendezvous on; --local-rendezvous
            // is a no-op here and only matters on the --nsec-file path above.
            EndpointOptions::ephemeral(SCOPE),
            "ephemeral (fresh every launch — pass --nsec-file to persist)".to_string(),
        ),
    };

    let blob = Arc::new(build_payload(args.mib * 1024 * 1024));
    let digest = sha256(&blob);

    let origin = TcpListener::bind("127.0.0.1:0").await?;
    let origin_addr = origin.local_addr()?;
    {
        let blob = blob.clone();
        tokio::spawn(async move { origin_server(origin, blob).await });
    }

    let endpoint = bind_endpoint(options).await?;
    let npub = endpoint.npub().to_string();
    let address = endpoint.address().to_ipv6().to_string();

    let quic = Arc::new(FipsQuic::new(endpoint).await?);
    {
        let quic = quic.clone();
        tokio::spawn(async move {
            let _ = egress::serve(quic, origin_addr).await;
        });
    }

    println!("\n=========================================================");
    println!(" FIPS provider ready");
    println!("=========================================================");
    println!(" npub     : {npub}");
    println!(" address  : {address}");
    println!(" identity : {identity_note}");
    println!(" blob     : {} MiB", args.mib);
    println!(" sha256   : {digest}");
    println!("---------------------------------------------------------");
    println!(" Paste the npub into the iOS probe app, or run the");
    println!(" consumer on another machine. Serving until interrupted.");
    println!("=========================================================\n");

    // Serve until killed.
    std::future::pending::<()>().await;
    Ok(())
}

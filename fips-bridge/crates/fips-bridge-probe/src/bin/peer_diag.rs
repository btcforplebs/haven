//! Peering diagnostic for the two-host gate.
//!
//! Consumer: `peer_diag --npub <provider> [--secs N] [--bootstrap <npub>=<host:port>]...`
//! Provider: `peer_diag --serve --nsec-file <path> [--bootstrap <npub>=<host:port>]...`
//!
//! `--bootstrap` adds a publicly reachable FIPS transit node as an
//! auto-connect peer (the same trick nostr-vpn uses with its two built-in
//! seeds): an authenticated route to a transit node is what lets fips-core
//! forward the NAT-traversal offer, which two NAT'd nodes cannot exchange
//! on their own (see node/lifecycle/nostr.rs "Deferring NAT traversal until
//! an authenticated FIPS signaling route exists").
use std::path::PathBuf;
use std::time::{Duration, Instant};
use anyhow::{Context, Result};
use fips_bridge_core::{bind_endpoint, EndpointOptions};
use fips_bridge_probe::load_or_create_nsec;
use fips_endpoint::{ConnectPolicy, PeerAddress, PeerConfig};
use fips_endpoint::{FipsEndpoint, FipsEndpointServiceDatagram, PeerIdentity};

const SCOPE: &str = "nostr-vault-fips";
const PORT: u16 = 4000;

struct Args { serve: bool, nsec_file: Option<PathBuf>, npub: Option<String>, secs: u64, bootstrap: Vec<(String, String)>, peers: Vec<String> }

fn parse() -> Result<Args> {
    let mut a = Args { serve: false, nsec_file: None, npub: None, secs: 180, bootstrap: vec![], peers: vec![] };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--serve" => a.serve = true,
            "--nsec-file" => a.nsec_file = Some(PathBuf::from(it.next().context("--nsec-file path")?)),
            "--npub" => a.npub = Some(it.next().context("--npub value")?),
            "--secs" => a.secs = it.next().context("--secs value")?.parse()?,
            "--peer" => a.peers.push(it.next().context("--peer npub")?),
            "--bootstrap" => {
                let v = it.next().context("--bootstrap npub=host:port")?;
                let (n, addr) = v.split_once('=').context("--bootstrap wants npub=host:port")?;
                a.bootstrap.push((n.to_string(), addr.to_string()));
            }
            other => anyhow::bail!("unrecognized argument: {other}"),
        }
    }
    Ok(a)
}

async fn apply_peers(ep: &FipsEndpoint, a: &Args) -> Result<()> {
    let mut peers = Vec::new();
    for (npub, addr) in &a.bootstrap {
        peers.push(PeerConfig { npub: npub.clone(), addresses: vec![PeerAddress::new("udp", addr.clone())], connect_policy: ConnectPolicy::AutoConnect, ..PeerConfig::default() });
    }
    for npub in a.peers.iter().chain(a.npub.iter()) {
        peers.push(PeerConfig { npub: npub.clone(), addresses: vec![], connect_policy: ConnectPolicy::AutoConnect, ..PeerConfig::default() });
    }
    if peers.is_empty() { return Ok(()); }
    let outcome = ep.update_peers(peers).await.context("update_peers")?;
    println!("update_peers: {outcome:?}");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let a = parse()?;
    let nsec = match &a.nsec_file { Some(p) => load_or_create_nsec(p)?, None => EndpointOptions::generate_nsec() };
    let ep = bind_endpoint(EndpointOptions::with_identity(nsec, SCOPE)).await?;
    let rx = ep.register_service_receiver(PORT).await.context("register")?;
    println!("me {}  udp {:?}", ep.npub(), ep.bound_udp_listen_addrs().await);
    apply_peers(&ep, &a).await?;
    let start = Instant::now();
    let mut last = Instant::now() - Duration::from_secs(10);
    if a.serve {
        println!("serving echo on port {PORT} (ctrl-c to stop)");
        let mut buf: Vec<FipsEndpointServiceDatagram> = Vec::new();
        loop {
            if let Ok(Some(_)) = tokio::time::timeout(Duration::from_secs(2), rx.recv_batch_into(&mut buf, 8)).await {
                for d in buf.drain(..) {
                    let n = d.data.len();
                    let _ = ep.send_datagram(d.source_peer, PORT, d.source_port, d.data.as_slice().to_vec()).await;
                    println!("t+{:>4}s echoed {n} bytes", start.elapsed().as_secs());
                }
            }
            if last.elapsed() >= Duration::from_secs(30) { last = Instant::now(); report(&ep, start).await; }
        }
    }
    let npub = a.npub.clone().context("--npub required unless --serve")?;
    let peer = PeerIdentity::from_pubkey(fips_endpoint::decode_npub(&npub).context("npub")?);
    let (mut sent, mut got) = (0u32, 0u32);
    while start.elapsed() < Duration::from_secs(a.secs) {
        let r = ep.send_datagram(peer.clone(), PORT, PORT, vec![1u8; 64]).await;
        sent += 1;
        if let Err(e) = &r { if sent % 10 == 1 { println!("t+{:>3}s send err: {e}", start.elapsed().as_secs()); } }
        let mut buf: Vec<FipsEndpointServiceDatagram> = Vec::new();
        if let Ok(Some(_)) = tokio::time::timeout(Duration::from_secs(2), rx.recv_batch_into(&mut buf, 4)).await {
            got += buf.len() as u32;
            println!("t+{:>3}s ECHO ({} bytes) sent={sent} got={got}", start.elapsed().as_secs(), buf[0].data.len());
            if got >= 5 { break; }
        }
        if last.elapsed() >= Duration::from_secs(10) { last = Instant::now(); print!("sent={sent} got={got} "); report(&ep, start).await; }
    }
    println!("done sent={sent} got={got} after {}s", start.elapsed().as_secs());
    Ok(())
}

async fn report(ep: &FipsEndpoint, start: Instant) {
    match ep.peers().await {
        Ok(ps) => { println!("t+{:>3}s peers={}", start.elapsed().as_secs(), ps.len()); for p in ps { println!("      {p:?}"); } }
        Err(e) => println!("t+{:>3}s peers() err {e}", start.elapsed().as_secs()),
    }
}

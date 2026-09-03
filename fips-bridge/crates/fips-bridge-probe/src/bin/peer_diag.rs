//! Peering diagnostic: bind, register the service, then for N seconds send a
//! canary every 2s and print the endpoint's own view of the peer every 10s.
use std::time::{Duration, Instant};
use anyhow::{Context, Result};
use fips_bridge_core::{bind_endpoint, EndpointOptions};
use fips_endpoint::{FipsEndpointServiceDatagram, PeerIdentity};

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let npub = args.get(0).context("usage: peer_diag <npub> [secs]")?.clone();
    let secs: u64 = args.get(1).map(|s| s.parse()).transpose()?.unwrap_or(180);
    let ep = bind_endpoint(EndpointOptions::with_identity(EndpointOptions::generate_nsec(), "nostr-vault-fips")).await?;
    let rx = ep.register_service_receiver(4000).await.context("register")?;
    let peer = PeerIdentity::from_pubkey(fips_endpoint::decode_npub(&npub).context("npub")?);
    println!("me {}  udp {:?}", ep.npub(), ep.bound_udp_listen_addrs().await);
    let start = Instant::now();
    let mut last_report = Instant::now() - Duration::from_secs(10);
    let mut sent = 0u32; let mut got = 0u32;
    while start.elapsed() < Duration::from_secs(secs) {
        let r = ep.send_datagram(peer.clone(), 4000, 4000, vec![1u8; 64]).await;
        sent += 1;
        if let Err(e) = &r { if sent % 5 == 1 { println!("t+{:>3}s send err: {e}", start.elapsed().as_secs()); } }
        let mut buf: Vec<FipsEndpointServiceDatagram> = Vec::new();
        if let Ok(Some(_)) = tokio::time::timeout(Duration::from_secs(2), rx.recv_batch_into(&mut buf, 4)).await {
            got += buf.len() as u32;
            println!("t+{:>3}s ECHO received ({} bytes) sent={sent} got={got}", start.elapsed().as_secs(), buf[0].data.len());
            if got >= 3 { break; }
        }
        if last_report.elapsed() >= Duration::from_secs(10) {
            last_report = Instant::now();
            match ep.peers().await {
                Ok(ps) => { println!("t+{:>3}s peers={} sent={sent} got={got}", start.elapsed().as_secs(), ps.len()); for p in ps { println!("      {p:?}"); } }
                Err(e) => println!("t+{:>3}s peers() err {e}", start.elapsed().as_secs()),
            }
        }
    }
    println!("done sent={sent} got={got} after {}s", start.elapsed().as_secs());
    Ok(())
}

//! `quinn::AsyncUdpSocket` implemented over `fips-endpoint` service datagrams.
//!
//! This is the one genuinely novel piece of the bridge. Everything else is
//! conventional plumbing; this is where QUIC stops believing it is talking to a
//! UDP socket.
//!
//! Shape: the trait's `try_send`/`poll_recv` are synchronous, but the FIPS API
//! is async. So each direction gets a channel plus a pump task, and the sync
//! trait methods only ever touch the channel. Nothing here blocks.
//!
//! Backpressure is real rather than papered over with an unbounded channel: a
//! full outbound channel surfaces as `WouldBlock`, and the pump wakes the
//! registered `UdpPoller` after every send. An unbounded channel would have been
//! three lines shorter and would have turned a stalled peer into unbounded
//! memory growth.

use std::io::{self, IoSliceMut};
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::task::{Context, Poll, Waker};

use fips_endpoint::{
    FipsEndpoint, FipsEndpointServiceDatagram, FipsEndpointServiceReceiver, PeerIdentity,
};
use quinn::udp::{RecvMeta, Transmit};
use quinn::{AsyncUdpSocket, UdpPoller};
use tokio::sync::mpsc;

use super::addr_map::{AddrMap, QUIC_ADDR_PORT};

/// Bounded so a stalled peer applies backpressure instead of consuming memory.
const OUTBOUND_CAPACITY: usize = 1024;
const INBOUND_CAPACITY: usize = 1024;
/// Datagrams drained per `recv_batch_into` call.
const RECV_BATCH: usize = 32;

/// Distinguishes RNG seeds between sockets in the same process.
static SERVICE_SEED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);

type Outbound = (PeerIdentity, Vec<u8>);
type Inbound = (SocketAddr, Vec<u8>);

/// Synthetic outbound packet loss, in parts per thousand.
///
/// An in-process run has no loss and no fragmentation, so QUIC's recovery path
/// would otherwise go completely untested until two-host testing. This lets us
/// exercise it now. Set `FIPS_BRIDGE_LOSS_PERMILLE=30` for 3%.
fn configured_loss_permille() -> u32 {
    std::env::var("FIPS_BRIDGE_LOSS_PERMILLE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

/// Where the synthetic loss is applied.
///
/// This distinction is the whole point, and getting it wrong is why the roadmap
/// §5 loss table reads green at 10% loss while the transport has an unresolved
/// fragmentation problem.
///
/// `Packet` drops the whole QUIC packet before it reaches `send_datagram` — it
/// sits *above* FIPS, so one drop is one lost QUIC packet no matter how many
/// fragments FIPS would have split it into. That models a link that loses whole
/// datagrams, which is not the link we have.
///
/// `Fragment` accounts for what FIPS actually does below us. A QUIC packet
/// larger than the single-fragment budget is split, reassembly is all-or-nothing
/// with no per-fragment retransmit (`dataplane/direct_transport.rs`), so the
/// packet survives only if *every* fragment survives: `(1-p)^n`. At the default
/// 1280 underlay MTU every floor-sized QUIC packet is n=2, so 3% link loss
/// becomes ~5.9% as quinn sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LossMode {
    Packet,
    Fragment,
}

/// `FIPS_BRIDGE_LOSS_MODE=fragment` to model per-fragment loss.
///
/// Defaults to `Fragment`, because that is what the wire does. `packet` is kept
/// so the older, more optimistic loss-table numbers remain reproducible for
/// comparison rather than being silently rewritten.
fn configured_loss_mode() -> LossMode {
    match std::env::var("FIPS_BRIDGE_LOSS_MODE").ok().as_deref() {
        Some("packet") => LossMode::Packet,
        _ => LossMode::Fragment,
    }
}

/// Underlay UDP MTU assumed when modelling fragmentation.
///
/// Must track whatever `transports.udp.mtu` is actually configured; it is read
/// from the same env override so a probe run cannot drift from the endpoint.
fn configured_underlay_mtu() -> u16 {
    std::env::var("FIPS_BRIDGE_UNDERLAY_MTU")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(super::mtu::DEFAULT_UNDERLAY_UDP_MTU)
}

#[derive(Debug)]
pub struct FipsUdpSocket {
    local: SocketAddr,
    map: Arc<AddrMap>,
    out_tx: mpsc::Sender<Outbound>,
    in_rx: StdMutex<mpsc::Receiver<Inbound>>,
    writable: Arc<WritableWaker>,
    loss_permille: u32,
    loss_mode: LossMode,
    underlay_mtu: u16,
    rng: AtomicU64,
}

impl FipsUdpSocket {
    /// xorshift64 — not cryptographic, and does not need to be. It only has to
    /// spread drops out so we aren't losing a periodic pattern.
    fn next_random(&self) -> u64 {
        let mut x = self.rng.load(Ordering::Relaxed);
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng.store(x, Ordering::Relaxed);
        x
    }

    /// Roll once per fragment, not once per QUIC packet.
    ///
    /// FIPS reassembly is all-or-nothing, so losing any one fragment loses the
    /// whole packet. Rolling `n` times reproduces that `(1-p)^n` survival curve
    /// instead of the flat `1-p` the packet-level injector reports.
    fn should_drop(&self, payload_len: usize) -> bool {
        if self.loss_permille == 0 {
            return false;
        }
        let rolls = match self.loss_mode {
            LossMode::Packet => 1,
            LossMode::Fragment => super::mtu::fragments_for(payload_len, self.underlay_mtu),
        };
        for _ in 0..rolls {
            if self.next_random() % 1000 < self.loss_permille as u64 {
                return true;
            }
        }
        false
    }
}

impl FipsUdpSocket {
    /// Wire a bound endpoint and a registered service receiver into something
    /// quinn will accept. Spawns one pump task per direction; both exit when the
    /// endpoint shuts down.
    pub fn new(
        endpoint: Arc<FipsEndpoint>,
        receiver: FipsEndpointServiceReceiver,
        service_port: u16,
        local_ipv6: Ipv6Addr,
        map: Arc<AddrMap>,
    ) -> Arc<Self> {
        let (out_tx, mut out_rx) = mpsc::channel::<Outbound>(OUTBOUND_CAPACITY);
        let (in_tx, in_rx) = mpsc::channel::<Inbound>(INBOUND_CAPACITY);
        let writable = Arc::new(WritableWaker::default());

        // Outbound pump: channel -> FIPS.
        {
            let endpoint = endpoint.clone();
            let writable = writable.clone();
            tokio::spawn(async move {
                while let Some((peer, payload)) = out_rx.recv().await {
                    if let Err(e) = endpoint
                        .send_datagram(peer, service_port, service_port, payload)
                        .await
                    {
                        // A send failure is a lost packet, not a dead socket.
                        // QUIC's loss recovery is what handles it.
                        tracing::debug!("fips send_datagram failed: {e}");
                    }
                    // Capacity just freed — let any blocked writer retry.
                    writable.wake();
                }
            });
        }

        // Inbound pump: FIPS -> channel.
        {
            let map = map.clone();
            tokio::spawn(async move {
                let mut batch: Vec<FipsEndpointServiceDatagram> = Vec::with_capacity(RECV_BATCH);
                loop {
                    batch.clear();
                    if receiver.recv_batch_into(&mut batch, RECV_BATCH).await.is_none() {
                        break; // endpoint closed
                    }
                    for datagram in batch.drain(..) {
                        // Learn the peer, so a later try_send to this address
                        // resolves without any explicit registration step.
                        let addr = map.insert(datagram.source_peer.clone());
                        // into_vec() rather than a copy: we own the datagram.
                        if in_tx.send((addr, datagram.data.into_vec())).await.is_err() {
                            return; // socket dropped
                        }
                    }
                }
            });
        }

        Arc::new(Self {
            local: SocketAddr::new(IpAddr::V6(local_ipv6), QUIC_ADDR_PORT),
            map,
            out_tx,
            in_rx: StdMutex::new(in_rx),
            writable,
            loss_permille: configured_loss_permille(),
            loss_mode: configured_loss_mode(),
            underlay_mtu: configured_underlay_mtu(),
            // Seeded per-socket so the two ends of a test don't drop in lockstep.
            rng: AtomicU64::new(0x2545F4914F6CDD1D ^ (SERVICE_SEED.fetch_add(1, Ordering::Relaxed) as u64).wrapping_mul(0x9E3779B97F4A7C15)),
        })
    }
}

impl AsyncUdpSocket for FipsUdpSocket {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        Box::pin(FipsPoller {
            writable: self.writable.clone(),
            sender: self.out_tx.clone(),
        })
    }

    fn try_send(&self, transmit: &Transmit<'_>) -> io::Result<()> {
        let Some(peer) = self.map.lookup(&transmit.destination) else {
            // Unknown destination. Dropping is correct rather than fatal: QUIC
            // treats it as loss and retransmits, and the map populates as soon
            // as the peer is registered or sends to us.
            tracing::debug!("no FIPS peer for {}", transmit.destination);
            return Ok(());
        };

        if self.should_drop(transmit.contents.len()) {
            // Report success: to QUIC this is indistinguishable from a datagram
            // lost in the network, which is exactly what we're simulating.
            return Ok(());
        }

        match self.out_tx.try_send((peer, transmit.contents.to_vec())) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => Err(io::ErrorKind::WouldBlock.into()),
            Err(mpsc::error::TrySendError::Closed(_)) => {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "fips bridge stopped"))
            }
        }
    }

    fn poll_recv(
        &self,
        cx: &mut Context<'_>,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        if bufs.is_empty() || meta.is_empty() {
            return Poll::Ready(Ok(0));
        }

        let mut rx = self.in_rx.lock().unwrap();
        match rx.poll_recv(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(None) => Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "fips bridge stopped",
            ))),
            Poll::Ready(Some((addr, data))) => {
                let n = data.len().min(bufs[0].len());
                bufs[0][..n].copy_from_slice(&data[..n]);
                meta[0] = RecvMeta {
                    addr,
                    len: n,
                    stride: n,
                    ecn: None,
                    dst_ip: None,
                };
                Poll::Ready(Ok(1))
            }
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.local)
    }

    /// No GSO through FIPS — each datagram is its own service datagram.
    fn max_transmit_segments(&self) -> usize {
        1
    }

    fn max_receive_segments(&self) -> usize {
        1
    }

    /// FIPS *does* fragment internally, but that path is all-or-nothing with no
    /// per-fragment retransmit, so we tell quinn the opposite deliberately:
    /// keep packets inside one fragment and never lean on reassembly.
    fn may_fragment(&self) -> bool {
        false
    }
}

/// Stores the single waker interested in write-readiness.
#[derive(Debug, Default)]
struct WritableWaker {
    waker: StdMutex<Option<Waker>>,
}

impl WritableWaker {
    fn register(&self, waker: &Waker) {
        *self.waker.lock().unwrap() = Some(waker.clone());
    }

    fn wake(&self) {
        if let Some(waker) = self.waker.lock().unwrap().take() {
            waker.wake();
        }
    }
}

#[derive(Debug)]
struct FipsPoller {
    writable: Arc<WritableWaker>,
    sender: mpsc::Sender<Outbound>,
}

impl UdpPoller for FipsPoller {
    fn poll_writable(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.writable.register(cx.waker());
        // Re-check *after* registering. Without this, capacity freed between
        // try_send returning WouldBlock and this registration would be missed,
        // and the connection would hang until some unrelated send woke it.
        if self.sender.capacity() > 0 {
            Poll::Ready(Ok(()))
        } else {
            Poll::Pending
        }
    }
}

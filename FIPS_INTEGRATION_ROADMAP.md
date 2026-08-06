# FIPS-Native Media & Relay for Nostr Vault

**Serving Nostr Vault's relay and Blossom media over the FIPS mesh — no public IP, no domain,
no TLS certificate, no port forwarding.**

*Rewritten 2026-07-27 against `fips-endpoint` 0.4.45 / upstream `fips` v0.4.1. The May 2026
version of this document was written against FIPS v0.2.0 and was wrong in ways that would
have sent the implementation down a dead end — see §1.*

---

## 0. TL;DR

Nostr Vault already runs an embedded Go relay that serves **both** Nostr (WSS) and Blossom
media on a single HTTP port. FIPS gives identity-based addressing, where a node's npub *is*
its address.

We embed the `fips-endpoint` crate directly in the app — no system TUN, no VPN profile, no
NetworkExtension entitlement — and bridge it to the existing relay with a loopback HTTP
proxy. macOS and Android become 24/7 providers; iOS consumes, and can host only in an
explicit kiosk mode.

Because relay and Blossom already share one port, **one byte-transparent proxy covers both,
with zero changes to the Go relay.**

---

## 1. What the previous version of this document got wrong

Both errors pointed at an architecture that cannot be built.

**"`fips-endpoint` has no stable FFI — that's the critical-path blocker."**
It was never the blocker. `fips-endpoint` is published on crates.io, at 0.4.45 as of
2026-07-27, and exposes exactly the embedded API we need. The old plan proposed asking
upstream for `fips_endpoint_dial_tcp` and similar; no such request is needed, and no such
function is coming, because the API is datagram-based by design.

**"A userspace tunnel means no NetworkExtension entitlement is needed."**
False for upstream `jmcorgan/fips`. That project is a TUN/IP **daemon** — `src/upper/tun.rs`
creates a real network interface, `fips-gateway` is `#[cfg(target_os = "linux")]`, and there
is no iOS support at all. mmalmi's nostr-vpn confirms it from the other direction: its iOS
app ships a `PacketTunnelProvider.swift` with the `packet-tunnel-provider` entitlement,
precisely because the TUN model requires it.

The route through is **not** upstream `fips`. It is `fips-endpoint`, whose builder exposes
`without_system_tun()`.

A third correction, less severe but load-bearing: the old plan's `FIPSURLProtocol` shim
cannot work on Apple platforms. See §4.

---

## 2. The transport

### 2.1 `fips-endpoint` is datagram-only

There is no TCP or stream abstraction anywhere in the crate. The surface we use:

```rust
FipsEndpoint::builder()
    .identity_nsec(nsec)
    .discovery_scope(scope)
    .config(config)            // transports, MTU, discovery relays
    .without_system_tun()      // the whole reason embedding is possible
    .bind().await?;

endpoint.register_service_receiver(port).await?;   // 256-258 reserved by FIPS
endpoint.send_datagram(peer, src_port, dst_port, payload).await?;
receiver.recv_batch_into(&mut buf, max).await;
```

Also useful: built-in Nostr-mediated discovery (kind 37195 adverts), `RecentPeersFileStore`
for restart-safe peer reuse, `update_relays()`, and `ingest_nostr_event()`.

### 2.2 Datagram sizing — measured, not assumed

`crates/fips-bridge-probe` measures this directly. Result on 0.4.45:

```
API accepted up to:  65525 bytes
65526 bytes       ->  rejected: ServiceDatagramTooLarge { len: 65526, max: 65525 }
```

which matches `fips-core`'s `fsp_service_datagram_max_body_len() = u16::MAX - 6 - 4`.

**That ceiling is a trap, not a licence.** FIPS fragments internally
(`dataplane/direct_transport.rs`: 128 fragments max, 72 KB reassembly, 2000 ms TTL), and
reassembly is all-or-nothing with **no per-fragment retransmit**. A 64 KB datagram at the
default 1280-byte UDP MTU is ~54 fragments; at 1% packet loss that datagram fails ~42% of the
time. It looks flawless on a LAN and collapses on cellular, and it degrades *silently* rather
than erroring.

So the working unit is one MTU:

```
1280 − 12 (FSP outer) − 16 (AEAD tag) − 6 (inner hdr) − 4 (port hdr) ≈ 1242 bytes usable
```

QUIC's floor is 1200 (RFC 9000 anti-amplification; quinn's `min_mtu` will not go lower).
~42 bytes of margin is too thin to ship, so we raise `transports.udp.mtu` to 1400 via
`.config()` for ~1362 usable bytes — matching FIPS's own TCP and WebSocket defaults.

### 2.3 Stream layer: QUIC via quinn

Rejected alternatives: a hand-rolled mini-TCP (the hard part is congestion control, and the
headline case is video over cellular — bad CC is a permanent quality ceiling, not a fixable
bug); smoltcp (synthesizes IPv6+TCP headers for ~60 bytes/packet of waste, Reno-class CC, no
multiplexing); application-level chunked ARQ (reinvents CC, useless for bidirectional WSS).

**`fips-tcp` / `fips-tcp-endpoint` 0.2.0 — evaluated 2026-08-06, rejected.** An earlier version
of this document did not consider it, which was an omission: it is published on crates.io, rides
FIPS service datagrams exactly as we need, and nostr-vpn runs it in production
(`crates/nostr-vpn-core/src/fips_control_tcp.rs`, 863 lines, taking nothing but an
`Arc<FipsEndpoint>`). Adopting it would have deleted `transport/{udp_socket,quic,tls}.rs` and
made the MTU question moot.

Reading the source settles it against us. `fips-tcp-0.2.0/src/reno.rs` is textbook TCP Reno —
slow start, AIMD (`cwnd += mss²/cwnd`), fast recovery, `cwnd = mss` on RTO — over an RFC
6298-style estimator in `rtt.rs`. There is **no SACK** and **no pacing** anywhere in the crate,
and the default MSS is 1024. That is precisely the "Reno-class CC" we rejected smoltcp for, with
the additional problem that without selective ack a single loss costs a full recovery cycle
rather than one retransmit.

For bulk relay traffic that would be fine. For the headline case — video over cellular, where
loss is bursty and non-congestive — Reno without SACK or pacing collapses the window on signal
variation that BBR rides through. We keep quinn. The cost is the SPKI-pinning work in this
section and the tighter MTU budget in §2.2, both of which are accepted deliberately.

This is not a criticism of `fips-tcp`: nostr-vpn uses it to carry control records, not media, and
Reno is a reasonable choice for that. Revisit if it gains BBR or SACK.

We run **quinn over a custom `AsyncUdpSocket`** backed by FIPS service datagrams. That buys
ordered reliable multiplexed streams, BBR congestion control, and keepalive. Configure
`initial_mtu = 1200`, `min_mtu = 1200`, `mtu_discovery_config = None` (FIPS owns PMTU). Use
rustls with **`ring`**, not `aws-lc-rs` — the latter needs cmake and a C toolchain per target
and is a known pain on `aarch64-apple-ios-sim` and the Android NDK.

QUIC's certificate check is redundant here, since FIPS already authenticates `source_peer`
via Noise IK. Rather than disabling verification outright, derive a self-signed cert from the
FIPS nsec and pin its SPKI hash to the peer's npub.

### 2.4 The bridge never parses HTTP

`init.go:505-545` mounts Blossom onto `outboxRelay`, and `cshared.go` routes everything
through `dynamicRelayHandler` on one listener. So the bridge is a byte-transparent
**TCP↔QUIC-bidi-stream splice** — `copy_bidirectional` at each end, one QUIC stream per TCP
connection.

Keep-alive, byte ranges, chunked encoding, the WSS `101 Switching Protocols` upgrade, and
WebSocket frames all pass through as opaque bytes. **The relay scope comes free the moment
media works**, and the Go relay needs no changes at all.

```
Consumer                                              Provider (Mac / Android)
────────                                              ────────────────────────
URLSession / AVAsset / Coil / ExoPlayer               Go relay + Blossom
   │ TCP                                                 ▲ TCP
   ▼                                                     │
127.0.0.1:<peerPort> ──accept──┐         ┌──connect── 127.0.0.1:3355
                               │         │
                        open bidi ─────► accept bidi
                          ┌────┴─────────┴────┐
                          │ QUIC (quinn)      │  ordered, reliable, BBR
                          │ over FIPS datagrams│
                          └───────────────────┘
                                   │
                    fips-endpoint service port (authenticated)
```

---

## 3. Platform roles

| Platform | Serves over FIPS? | Why |
|---|---|---|
| **macOS** | Yes, 24/7 | Desktop process, no suspension. Developer-ID distributed, so no App Store review. |
| **Android** | Yes, 24/7 | The relay already runs in a foreground service; the endpoint lives in the same service. |
| **iOS** | Consumer by default; opt-in kiosk host | Apps are suspended in the background, so the endpoint dies the moment the app leaves the foreground. |

An iOS-only user cannot casually host — they need a Mac or Android device as their provider.
**Android is therefore what delivers the goal for users who own no Mac**, and is sequenced
ahead of iOS.

Do **not** use background-audio/VoIP/location modes to keep the iOS socket alive. That is an
App Store rejection and a battery disaster.

### 3.1 iOS kiosk host mode

A foregrounded iOS device that never sleeps is never suspended, so it *can* host — an old
iPhone or iPad on a charger is a legitimate home server. The app enforces it itself with
`UIApplication.shared.isIdleTimerDisabled = true` (App Store-legitimate; navigation and video
apps use it routinely).

It stays opt-in and off by default because: any app switch kills it instantly, with no
graceful degradation; jetsam is a live risk given the app's existing ~1 GB resident footprint
plus the Go runtime plus tokio/quinn/rustls; and screen-on 24/7 means heat, battery wear and
OLED burn-in.

Consequently, kind-10063 advertisement is gated on **opt-in plus sustained uptime** (~10
minutes continuous), a Mac or Android provider should appear in the same list as a fallback,
and the UI warns when host mode runs unplugged.

---

## 4. Client-side addressing

### 4.1 Why `URLProtocol` cannot work on Apple

- `Views/Components/RetryableAsyncImage.swift:38` falls back to bare SwiftUI `AsyncImage`,
  which uses an internal session and cannot be intercepted.
- All video and audio goes through `AVURLAsset` (`VideoPlaybackService.swift:248`,
  `MediaCacheService.swift:751/778`, `AudioPlayerView.swift:103`). AVFoundation does its own
  CFNetwork I/O below the URLProtocol layer. The only sanctioned hook is
  `AVAssetResourceLoaderDelegate`, which means hand-implementing byte-range serving per media
  type.
- ~10 separately-constructed `URLSession`s would each need `protocolClasses` wired.

### 4.2 Loopback proxy, port-per-peer

ATS is `NSAllowsArbitraryLoads: True` in both `HavenApp-iOS/Info.plist` and
`HavenApp/App/Info.plist`, so the proxy serves **plain HTTP** — no cert, no trust delegate.

Addressing is **one loopback listener per remote npub**, LRU-bounded (~32) so a hostile feed
cannot exhaust file descriptors. Path-prefix routing was rejected: it breaks on relative
`Location:` headers and on Blossom BUD-02 descriptors that embed self-referential URLs, and it
mangles the sha256 path shape Go's blob regex depends on (`init.go:686`). Host-header routing
was rejected because after rewriting to `127.0.0.1` every client sends `Host: 127.0.0.1`.

**Persist the npub→port map to disk.** `MediaCacheService`'s disk cache keys on `hash(url:)`
and Coil's does the same; shuffling ports across launches silently invalidates every cached
FIPS blob.

### 4.3 Two consequences of rewriting to 127.0.0.1

**Helpful:** the http→https force-upgrade at `BlossomService.swift:395-400, 627-633,
1084-1091` becomes automatically correct, because `isLocalhost` and `isLocalNetworkHost`
already match `127.0.0.1` — provided the rewrite happens at config-read time, before those
functions see the URL.

**Dangerous:** `MediaCacheService.isLocalURL:869` also matches `127.0.0.1`, and
`fetchData:519-527` uses it to **bypass the disk cache entirely**. That is right for the local
relay's own blobs and catastrophic for a remote peer's blobs pulled over the mesh. Gate it on
`url.port == config.relayPort`. This is the single most likely bug to ship unnoticed — it
shows up as "FIPS video re-downloads on every scroll", never as an error.

---

## 5. Phases

| Phase | Scope | Status |
|---|---|---|
| **0a** | Rust-only spike: datagram probe, `AsyncUdpSocket`, quinn, loopback e2e, loss testing, six cross-compile targets | Probe landed; rest in progress |
| **0b** | Rewrite these docs against reality | This document |
| **1** | macOS, both roles. Build scripts, Xcode wiring, `FIPSBridgeService`, settings, URL rewriting | |
| **2** | Android, both roles, endpoint owned by the existing relay foreground service | |
| **3** | iOS consumer, then opt-in kiosk host | |
| **4** | kind-10063 read path — resolve blobs by sha256 against other users' server lists | |

Phase 0a's exit gate: 20 MB at ≥3 MB/s on LAN and ≥500 KB/s at 3% simulated loss. Below that,
stop before touching Xcode; the fallback is FIPS's WebSocket transport rather than UDP.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| Silent fragmentation collapse — oversize datagrams pass on LAN, fail on cellular | Never exceed one MTU; raise `transports.udp.mtu` to 1400; loss-test in Phase 0a |
| `fips-endpoint` churn — 45 releases on 0.4.x; 0.3→0.4 replaced the entire send/recv model | Pin `=0.4.45`, commit `Cargo.lock`, vendor the crate, confine calls to two files |
| Wire-protocol churn — provider and consumer must update together or silently cannot talk | Show the FIPS version in Settings; log an explicit mismatch |
| `isLocalURL` cache bypass | Gate on `url.port == relayPort`; verify blobs reach the disk cache during device testing |
| iOS kiosk vanishes on any app switch | Opt-in, off by default, uptime-gated advertisement, clearnet fallback in the same 10063 list |
| Jetsam under memory pressure | Do the deferred Instruments pass *before* shipping kiosk mode; small tokio worker pool |
| Build fragility — a third toolchain atop Go + Xcode + NDK | All six cross-compile targets green in CI during Phase 0a |
| Binary size / cold start | `lto="thin"`, `codegen-units=1`, `strip`; keep `FipsBridgeStart` off the launch path |
| Battery — always-on UDP keeps the radio awake | iOS foreground-only with a 30 s teardown, default off; Android tied to the FGS, measure Doze |
| `local_rendezvous()` binds 127.0.0.1:21211 exclusively | Contends with a co-installed nostr-vpn Mac app; falls back to an ephemeral socket, but test it |
| App Store review | No NetworkExtension entitlement, no system-wide routing. Frame as in-process peer-to-peer transport; never say "VPN". Check export compliance — Noise + QUIC may change `ITSAppUsesNonExemptEncryption` |
| `.fips` is unreachable by non-FIPS clients | `activeBlossomMirrors` already appends it last (clearnet-first, BUD-14). Gate publishing on at least one clearnet mirror also being present |

---

## 7. References

- **fips-endpoint** — https://crates.io/crates/fips-endpoint · https://docs.rs/fips-endpoint
- **FIPS (upstream daemon)** — https://github.com/jmcorgan/fips
- **nostr-vpn** — https://github.com/mmalmi/nostr-vpn
- **Blossom / BUD-03 (kind 10063)** — https://github.com/hzrd149/blossom
- **RFC 9000 §14** (QUIC datagram size floor) — https://www.rfc-editor.org/rfc/rfc9000
- **quinn** — https://docs.rs/quinn

Implementation detail for the bridge crate itself lives in `FIPS_FFI_PLAN.md`.

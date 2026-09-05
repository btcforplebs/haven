//! QUIC over the FIPS mesh.

pub mod addr_map;
pub mod mtu;
pub mod quic;
pub mod tls;
pub mod udp_socket;

pub use addr_map::AddrMap;
pub use mtu::{
    fragments_for, quic_fits_single_fragment, single_fragment_budget, DEFAULT_UNDERLAY_UDP_MTU,
    LAN_UNDERLAY_UDP_MTU, QUIC_MIN_MTU, SERVICE_DATAGRAM_OVERHEAD,
};
pub use quic::{FipsQuic, SERVICE_PORT};
pub use udp_socket::FipsUdpSocket;

# FPGA Market Data Pipeline

A complete, hand-written network and market-data processing stack in Verilog — raw Ethernet
framing through NASDAQ TotalView-ITCH 5.0 decoding, a live order book, and per-price-level depth
aggregation — running on a Digilent Arty A7-100T (Xilinx XC7A100T). No soft-core processor, no
vendor networking IP: every layer (Ethernet MAC, ARP, IPv4/UDP, ITCH decoding, order book, depth
aggregation) is purpose-built RTL, motivated by the latency-sensitivity of the high-frequency
trading domain this project targets.

Every module is verified in simulation against hand-built test vectors, then validated again on
real hardware against unmodified, real-world traffic — Windows-generated ARP requests, UDP
packets from a companion Python toolchain, and, for the final stage, a real NASDAQ TotalView-ITCH
trading session (INTC, market-by-order) sourced through Databento and cross-checked against an
independent Python reference implementation.

## Highlights

- **46.55% latency reduction** (18.51 &micro;s &rarr; 9.90 &micro;s measured end-to-end round trip)
  through four incrementally hardware-validated transmit-datapath optimizations, each re-verified
  at 1000-packet scale with zero correctness regressions before acceptance.
- **Two independently verified price-level aggregation architectures** — a CAM keyed by
  (side, price), and a direct-mapped Block-RAM-backed table built to address a real, quantitatively
  demonstrated capacity limit the CAM has at deployed scale. Once correctly mapped to real Block
  RAM, the BRAM design is both **smaller in LUTs** (3868 vs. 4115) and **32&times; larger in
  capacity** (1024 vs. 32 price levels/side) than the CAM baseline.
- **Validated against real exchange data**, not just synthetic test vectors: a real NASDAQ
  TotalView-ITCH session replayed through the full hardware pipeline matches an independent
  Python reference exactly, share-for-share, across every resulting price level.
- A documented debugging record: several real hardware-only bugs (a clock-domain-crossing signal
  loss, a synthesis-only multiple-driver violation invisible to simulation, a stale module
  definition that silently replaced a verified one, a redelivered-duplicate-order-reference bug,
  and a synthesis attribute explicitly rejected by the toolchain) were found, root-caused, and
  fixed — see the project paper for the full case studies.

## Architecture

| Layer | Module(s) | Function |
|---|---|---|
| Physical/MAC | `eth_mac_rx_nibble`, `eth_mac_tx_nibble`, `crc32_check`/`Crc32_gen`, `nibble_to_byte`, `byte_to_nibble` | MII-level framing, preamble/SFD handling, CRC32 generation and checking |
| Clock domain crossing | `async_fifo`, `sync_2ff`, `rx_frame_cdc`, `gray_code_conv` | Bridges the PHY clock domains to the system clock domain, carrying frame-boundary markers alongside data |
| Address Resolution | `arp_responder`, `arp_reply_framer` | Answers ARP requests for the board's configured IP address |
| Network/Transport | `ip_udp_rx_parser`, `ip_udp_tx_builder`, `udp_tx_framer`, `udp_echo_responder` | IPv4 header validation and checksum verification, UDP payload extraction/generation |
| Latency instrumentation | `latency_probe` | Free-running cycle counter with 5 timestamp capture points spanning a full request/reply round trip |
| Market data | `itch_decoder` | NASDAQ TotalView-ITCH 5.0 message framing and field decode |
| Application state | `orderbook` | CAM-based live order book, keyed by ITCH order reference number |
| Depth aggregation | `price_level_book`, `price_level_book_bram` | Per-price-level depth-of-book aggregation, in two independently verified architectures |

Each top-level test (`rtl/top_*.v`) instantiates the subset of this stack relevant to what it's
validating, reusing every already-proven module unchanged — later top-levels (ITCH decoding,
both depth-aggregation variants) reuse the identical MAC/CDC/ARP/UDP chain proven in the
IPv4/UDP phase without modification.

## Repo layout

```
rtl/          Synthesizable Verilog sources (36 files)
sim/          Testbenches (21 files, one per unit-tested module plus the
              CAM-vs-BRAM stress-test comparison)
constraints/  Per-top-level .xdc pin/timing constraints (11 files)
ip/           Xilinx IP core configs (.xci) for the clocking wizard and ILA
```

This is a curated export of sources, not a Vivado project folder — `.xpr`, `.cache`, `.gen`,
`.ip_user_files`, `.runs`, `.sim`, and `.hw` are intentionally excluded (regenerable, and
hundreds of MB of churn-prone generated content). See `REPO_NOTES.md` for the full reasoning
behind every non-obvious file choice.

## Performance

| Stage | Change | Avg. total latency |
|---|---|---|
| Baseline | Full-frame TX prefetch | 18,514.68 ns |
| Cut-through | Elastic buffer; overlap FIFO drain with MAC transmission | 11,075.16 ns |
| True EOF | Latency endpoint moved to true frame completion (not end-of-IFG) | 10,115.17 ns |
| Start threshold | TX start threshold reduced to 1 buffered byte | 9,994.31 ns |
| Speculative launch | Preamble transmission begins before first data byte is locally available | 9,895.20 ns |

Every stage was independently reproduced across multiple 1000-packet hardware runs, with zero
MAC errors, zero FIFO overflows/underruns, and 1000/1000 valid replies, before being accepted.

| Resource | CAM (`price_level_book.v`) | BRAM (`price_level_book_bram.v`) |
|---|---|---|
| Slice LUTs | 4115 | 3868 |
| Block RAM Tile | 1 | 5 |
| Price levels per side | 32 | 1024 |

## Author

Yvonne Bao

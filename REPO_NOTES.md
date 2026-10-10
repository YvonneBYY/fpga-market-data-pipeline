# Repo curation notes

This directory is a curated export of the Vivado project (`UART_module.xpr`), not the project
folder itself. Vivado's generated directories (`.cache`, `.gen`, `.ip_user_files`, `.runs`,
`.sim`, `.hw`, and the `.xpr` itself) are intentionally excluded -- they're fully regenerable
and add ~270MB of churn-prone binary/generated content that doesn't belong in version control.
To reopen this as a live Vivado project: create a new project targeting the XC7A100T
(Arty A7-100T), add everything in `rtl/` and `ip/` as design sources, everything in `sim/` as
simulation sources, and add the constraint file matching whichever `top_*` module you're
building as the active constraint set.

## Files resolved during curation

The original `sources_1/new` folder contained several pairs of files defining the *same*
Verilog module name -- harmless to Vivado (it just uses whichever one it parses last) but
confusing and risky to leave in a public repo. These were resolved as follows:

- **`order_book.v` vs `orderbook.v`** -- both defined `module order_book`. `orderbook.v` is the
  newer file and is what has actually been synthesizing in recent builds; kept as `orderbook.v`,
  `order_book.v` dropped. (Note: project documentation and some top-level comments refer to this
  module as "order_book" by convention -- the filename doesn't match the module name's usual
  spelling, worth reconciling in a follow-up pass.)
- **`ip_udp_rx_parser.v` vs `ip_udp_rx_parser_debug.v`** -- `ip_udp_rx_parser_debug.v` contained
  the entire original module commented out, followed by a second active definition with extra
  debug pulse outputs (the same "silent debug variant" pattern documented as a case study for a
  different file in the project paper, recurring here undocumented). Confirmed via the most
  recent synthesis logs that this debug variant is what has actually been synthesizing. Kept and
  **renamed to `ip_udp_rx_parser.v`** so the canonical filename doesn't carry a `_debug` suffix.
  The old clean (but stale) `ip_udp_rx_parser.v` was dropped.
- **Four `top_latency_test*.v` files** (`top_latency_test.v`, `..._frame_arbitrator.v`,
  `..._stage_counters.v`, `..._tx_cuthrough.v`) all defined the same `top_latency_test` module --
  successive, self-contained snapshots from the four-stage latency optimization effort. Only
  `top_latency_test_tx_cuthrough.v` is fully self-contained (it inlines `sync_fifo_simple` and
  `tx_frame_arbiter` itself) and matches the final "true frame-end" measurement described in the
  project paper. Kept and **renamed to `top_latency_test.v`**; the other three, plus the
  now-redundant standalone `tx_frame_arbitrator.v`, were dropped.
- **`tb_stress_comparison.v`** was filed under Vivado's design-source fileset by mistake (it's a
  testbench -- `$display`/`$finish`, no synthesizable top). Moved to `sim/`.
- **`order_book_tb.v`** (a second, separate testbench that also exercised the dropped
  `order_book.v`) was removed to match. The kept testbench, `orderbook_tb.v`, already
  instantiates the `order_book` module as defined in the kept `orderbook.v`, so no retargeting
  was needed.
- **`top_latency_text.xdc`** (typo in the original filename) renamed to `top_latency_test.xdc`.

If any of the above calls were wrong for your intent, the dropped files are still in the
original `UART_module.srcs/sources_1/new` and `sim_1/new` folders and can be restored.

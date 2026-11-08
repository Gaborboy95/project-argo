# LIVI iAP2 link engine

Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI).

Source: `f-io/LIVI`, revision
`bfbea31ee624ddce84bfa96ce49d4663e6cdeca7`,
`native/crates/iap2-link/src/lib.rs` and `tests/engine.rs`.
These two source files are retained without changes. The local Cargo manifest
only replaces the upstream workspace edition with its resolved value and adds
explicit package attribution. `LICENSE`, `NOTICE` and source SPDX notices are
retained. This crate is GPL-3.0-or-later, including the attribution term in NOTICE.

Argo uses the engine for Bluetooth iAP2 acknowledgement windows, retransmission,
and sequence recovery; its existing wired transport remains separate.

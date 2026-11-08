# Link physical MFi compatibility service

Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI).

This independent build workspace adapts the GPL-3.0-or-later `iap2-mfi` and
`livi-net` components from LIVI revision
`bfbea31ee624ddce84bfa96ce49d4663e6cdeca7`. See LICENSE, NOTICE and
SOURCE-CHANGES.patch. The physical-only wrapper uses the original TCP protocol
and USB-link client filter. Authentication remains in the real I2C coprocessor.

On the tested i.MX6ULL/IW416 Link, stock 10.4.0 firmware returned a valid 945-byte
PKCS#7 certificate once after a power cycle, then repeatedly reported the corrupt
length 40113. Reading and discarding one byte from the immutable protocol-major
register before reselecting the actual register prevented that failure. Eight
consecutive certificate reads and a real iPhone's MFi authentication succeeded
with the RAM prototype. The user subsequently confirmed wireless CarPlay video,
taps and map dragging. This demonstrates the workaround; it does not identify
the underlying kernel or electrical cause. Acceptance after permanent firmware
installation is recorded separately.

Each retry reselects the register and repeats the entire transaction. Short reads
never continue at a shifted device offset. Certificate and signature lengths are
bounded before allocation. The file/software authentication backend is omitted.

Build and check from this directory:

```sh
cargo test --locked --offline --workspace
cargo clippy --locked --offline --workspace --all-targets -- -D warnings
rustup target add armv7-unknown-linux-musleabihf
```

Cross-build with the bundled `rust-lld` in the active toolchain:

```sh
RUSTFLAGS="-C linker=$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld" \
  cargo build --locked --offline --release -p argo-mfi-physical \
  --target armv7-unknown-linux-musleabihf
```

The tested board uses bus 1, chip address 0x11 and no separately controlled MFi
power GPIO. Its firmware invocation is:

```sh
argo-mfi-physical --bus 1 --power-gpio -1 --bind 0.0.0.0:5000 \
  --state /tmp/livi/mfi
```

`--state` publishes the firmware's existing generation marker only after querying
the real coprocessor. It is optional for isolated RAM tests. The marker is replaced
atomically; no certificate, challenge or signature is written or logged. Version
0.1.1 adds this boot metadata to the initially tested 0.1.0 RAM prototype.

Firmware packaging starts from the verified official rootfs, preserves its kernel
and original multicall binary, and adds this separate service, its complete source,
LICENSE/NOTICE and an explicit custom-build marker. Use the official model-matched
rescue updater; a host application startup never uploads or flashes this code.

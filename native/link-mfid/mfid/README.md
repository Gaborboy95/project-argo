# Physical MFi priming experiment

Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI).

This source-only scratch workspace copies `native/crates/iap2-mfi` and
`native/crates/livi-net` from upstream revision
`bfbea31ee624ddce84bfa96ce49d4663e6cdeca7`. The workspace [LICENSE](../LICENSE)
and [NOTICE](../NOTICE), including LIVI's attribution term, remain applicable.
The physical I2C implementation is being modified locally to investigate
register-read priming and bounded certificate handling. This new thin wrapper
uses the existing `iap2_mfi::server::listen` wire protocol and USB-link client
filter; it does not introduce another authentication protocol.

The hypothesis under investigation is that reading the physical coprocessor's
protocol-major register immediately before its certificate length/data registers
avoids the observed stale first byte in a register receive after a long certificate transfer. This is an experiment,
not established firmware or phone acceptance. Parser/unit checks and successful
cross-compilation do not prove certificate validity, challenge signing, CarPlay
pairing, or a working phone session. Any limited physical read result must be
reported separately from end-to-end authentication.

## Runtime contract

Package and binary: `argo-mfi-physical`.

All run arguments are mandatory and space-separated:

```text
argo-mfi-physical --bus <u32> --power-gpio <i32> --bind <SocketAddr>
```

The parser rejects unknown, missing, duplicate and invalid arguments. `--help`
(or `-h`) and `--version` are standalone read-only commands; they do not open I2C,
touch GPIO or bind a socket. A negative power GPIO, such as explicit `-1`, leaves
the current power line untouched. Nonnegative values request the copied physical
power-line behavior. No bus, GPIO or bind address is guessed.

Run mode binds the explicit socket first, then calls only
`I2cCoprocessor::open(bus, power_gpio)` and `server::listen(listener, chip)`.
Opening the physical chip may touch its I2C registers and, with a nonnegative
GPIO, its power line. A missing/unreadable chip is an error: there is no file,
`NoCoprocessor`, simulated certificate or software-signature fallback. The wrapper
never logs certificate, challenge or signature bytes. Upstream `from_usb` admission
remains enabled; choosing a bind address does not bypass its USB-link filter.

No command here installs firmware, stops the existing daemon, writes flash,
or authorizes replacing a service. Hardware invocation and any RAM-only test
replacement must be coordinated separately with the physical device owner.

## Build and parser checks

From the scratch workspace root, after the parent I2C source work is complete:

```sh
cargo test --locked --offline --workspace
cargo clippy --locked --offline --workspace --all-targets -- -D warnings
RUSTFLAGS='-C linker=/home/phaeton/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld' cargo build --locked --offline --release -p argo-mfi-physical --target armv7-unknown-linux-musleabihf
```

The wrapper's unit tests exercise argument parsing only and never invoke `run`.
Use the already-provisioned target/linker configuration; this wrapper adds no
Rust target installation, system dependencies or device access to the build.
The resulting target binary is
`target/armv7-unknown-linux-musleabihf/release/argo-mfi-physical`.

## Modified physical read path

Each register read first selects immutable `REG_PROTOCOL_MAJOR` (0x02), reads
and discards one byte, reselects the actual register and issues one full-size
read. A failed or short receive retries this entire sequence; it does not
continue a partially consumed register with `read_exact`. Address probing uses
the same priming sequence once per candidate per probe iteration.

The retry budget is two seconds, including retry waits. It stops another
transaction from starting after expiry, but cannot preempt an in-progress
blocking kernel I2C syscall; the kernel adapter timeout is unchanged.
Certificate lengths must be 1–4096 bytes and signatures 1–512 bytes before any
data-register selection, allocation or receive. Invalid lengths return the
existing remote error status. No chip signing/control behavior or persistent
configuration is changed by priming. The optional file backend is omitted
from this physical-only scratch package; runtime commands always use the real
I2C coprocessor.

The workspace pins libc 0.2.189, already available on the build host, rather than
the larger upstream workspace's 1.0.0-alpha.5. The bundled LICENSE and NOTICE
remain unchanged. `SOURCE-CHANGES.patch` records the physical crate changes
against the pinned reference; the wrapper and isolated workspace manifests are
new. `build-manifest.json` records the candidate binary and source checksums.

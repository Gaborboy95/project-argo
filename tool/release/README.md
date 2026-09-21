# Standard runtime build and package validation

The standard runtime is one matched `argo-runtime` Debian 13 amd64 package.
Splitting the native view, Flutter AOT, IHS, Veloce and receiver pieces would add
version combinations without independent supported upgrade boundaries. Surround
is not a dependency and is not packaged here.

`standard-release.json` is the authoritative input definition. It pins Argo,
public Veloce base plus a checked patch, Flutter version and commit, the matching
AOT engine archive/library/header, Rust component archives, IHS source/patch,
platform-view header, native contracts and explicit runtime dependencies. The
IHS build uses the engine's exact embedder header. Cargo and Pub lockfiles remain
part of the pinned Argo source; no dependency upgrade occurs during the build.

## Build

With Docker available, from the Argo repository:

```sh
docker build -f tool/release/Dockerfile -t argo-standard-builder .
mkdir -p build/debian-builder
docker run --rm -v "$PWD:/source:ro" -v "$PWD/build/debian-builder:/workspace" argo-standard-builder
```

The recipe pins the Debian image digest and Debian snapshot. Docker/Podman were
absent, so validation used the Bubblewrap entry point below with a disposable
Debian root provisioned from those same inputs and build dependencies. Two fresh
workspaces, each with empty Flutter/Pub/Cargo caches and no private surround
checkout, produced byte-for-byte identical Standard 3 packages. The Docker engine
entry point itself was not executed. Builder package inventory is retained.

Equivalent entry point in a provisioned disposable builder:

```sh
python3 tool/release/build-standard.py --source "$PWD" --work /workspace/fresh-build
```

Use a fresh work directory. The source argument is an Argo Git repository
containing the pinned revision. The builder archives that revision, fetches only
public dependencies without a private surround checkout, verifies input hashes,
builds both native views with surround disabled, runs their contract tests,
collects notices and packages the runtime. Never use this script as a target
installer. The target does not require compilers, SDKs, source trees or network
access by package scripts.

The Flutter version tag is fetched and checked against the pinned commit: a
commit-only shallow checkout reports an unknown SDK version and fails Pub's
minimum-Flutter constraint. No floating branch is used.

## Install and launch on a target

After transferring the `.deb` and its checksum file to a Debian 13 amd64 target:

```sh
sha256sum -c argo-runtime_1.0.0~standard.3_amd64.deb.sha256
# Stop an existing Argo session before upgrading its immutable runtime assets:
systemctl --user stop argo-standard.target
sudo apt install ./argo-runtime_1.0.0~standard.3_amd64.deb
argoctl doctor --json
argo-session
# Stop the complete desktop session:
systemctl --user stop argo-standard.target
```

These are target instructions; this work did not install packages on the host.
`apt` resolves Debian dependencies; the package has no maintainer scripts that
compile, download, enable services or change device permissions. The desktop
entry starts `argo-standard.target` explicitly, which starts the app and two
receivers as the desktop user. It is not automatically enabled at login.
`argo` also launches the app directly for diagnostics. A graphical Wayland
session, working audio services and suitable device access remain target
prerequisites. Phone identity/provisioning is not fabricated by packaging.

Optional per-user runtime environment belongs in
`~/.config/project-argo/runtime.env`, read by the three user services. For example,
AA identity file settings can be supplied using `ARGO_ANDROID_AUTO_CERT_FILE`
and `ARGO_ANDROID_AUTO_KEY_FILE`. The package never creates or replaces them.
Do not run the app or receivers as root.

The package owns `/usr/lib/argo/runtime`, launchers, user unit definitions,
desktop entry and documentation. Runtime assets use private RUNPATH and wrapper
paths; no developer-built graphics library is placed in a generic system library
directory. Native asset manifests reference the fixed installed private library
directory. Package removal and purge preserve every per-user data directory.
Purge is not a user-data reset operation.

## Isolated lifecycle validation

`debian-test-root.py --output PATH` creates a disposable root from the pinned
official Debian OCI manifest, verifying every downloaded config/layer digest.
It does not install anything on the host. A locally extracted PRoot binary can
run package tools in that root; the validation uses only DNS and null/random
device binds, without host service sockets, home directories or hardware.
Create a root-local `usr/sbin/policy-rc.d` returning 101 before dependency install
to suppress starts. Give the root package tools their normal system PATH.

After installing runtime dependencies in the disposable root, run:

```sh
python3 tool/release/test-lifecycle.py \
  --root /disposable/debian-root \
  --proot /tools/proot/usr/bin/proot \
  --proot-library /tools/proot/usr/lib/x86_64-linux-gnu \
  --previous /artifacts/argo-runtime_1.0.0~standard.2_amd64.deb \
  --package /artifacts/argo-runtime_1.0.0~standard.3_amd64.deb \
  --log /artifacts/lifecycle.log
```

This checks fresh install, reinstall, real package-version upgrade, remove,
install again, purge with retained user state, truncated archive rejection,
package integrity, native loading, installed launcher help, a single shared IHS
library instance and the absence of development tools. The
separate initial empty-root `dpkg -i` test must fail specifically for missing
dependencies before resolving them with `apt`. `lifecycle.json` records completed
checks. PRoot has limitations translating modern access checks and resolving
`$ORIGIN` without a guest `/proc/self/exe`. Read-only integrity, native execution
and loader checks therefore run in Bubblewrap with the disposable root and its
own proc mount, without developer library variables or writable host paths.
These are package and loader checks, not graphical or physical acceptance.

`dpkg-shlibdeps` supplies ELF dependencies. The release definition additionally
lists GStreamer plugins, PipeWire/WirePlumber, BlueZ/NetworkManager, usbmuxd and
EGL/Vulkan libraries that runtime discovery may load without ELF linkage.
Debian provides graphics drivers for the target GPU; this package does not bundle
or certify a GPU driver. Python is used by `argoctl`, not as a build environment.

## Evidence and remaining release work

The artifact directory contains logs, package checksums, Debian root provenance,
builder package inventory and an implementation report. Two independent clean
compilations in the same pinned Debian root produced identical complete packages.
This does not establish reproducibility across different hosts or toolchains.
Compare independent outputs with:

```sh
python3 tool/release/compare-builds.py FIRST.deb SECOND.deb --output comparison.json
```

Checksums are integrity checks, not release signatures.

Notices include Flutter engine notices, Dart package licenses, Rust metadata and
license files, IHS third-party notices and supplemental ImGui/Apache text. Argo
and Veloce currently lack root license files; the inventory explicitly records
that unresolved publication gap. These are development runtime packages, not a
claim of a publicly redistributable, signed or physically accepted release.


Without Docker, `run-debian-builder.py --root ROOT --workspace FRESH --source REPO`
runs the same builder through Bubblewrap in a provisioned Debian 13 filesystem.
Provision ROOT from the pinned OCI manifest using `debian-test-root.py`, then use
PRoot to install the exact Dockerfile build dependency list from its fixed Debian
snapshot. Keep a root-local `policy-rc.d` returning 101 while provisioning. This
requires no host package installation. The runner mounts ROOT read-only, binds
only the Argo source and a fresh writable workspace, and shares networking for
public downloads. Private surround sources, host homes, hardware and service
sockets are absent. `HOME`, Pub and Cargo directories start empty; all artifacts
are written under FRESH. Two runs use the same namespace paths to permit a direct
reproducibility comparison. C/C++ and Rust builds remap source paths.

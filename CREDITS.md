# Credits

## LIVI / f-io

Argo's CarPlay and LIVI Link integration was heavily informed by
**LIVI – Linux In-Vehicle Infotainment**, developed by **f-io / Lasse Heitgres**.

LIVI provided invaluable reference work for native CarPlay, iAP2, MFi integration
and LIVI Link interoperability. Thank you to f-io and the LIVI contributors for
making this work available to the community.

Upstream project: [f-io/LIVI](https://github.com/f-io/LIVI).
Vendored Link/iAP2 reference revision: `bfbea31ee624ddce84bfa96ce49d4663e6cdeca7`
(`10.5.0-dev`, Rust; reviewed 2026-11-07). Original protocol research:
`a23dc0c5fcdb6d069c679eddfd73298e58f44783` (`9.0.0`).
LIVI is GPL-3.0-or-later, copyright 2025–2026 Lasse Heitgres, with the attribution
term recorded in its `NOTICE`.

**Based on LIVI by Lasse Heitgres (https://github.com/f-io/LIVI)**

The wireless CarPlay integration includes the upstream `iap2-link` engine and
its tests at the exact revision above, under
[`native/carplay/vendor/livi-iap2-link`](native/carplay/vendor/livi-iap2-link).
Its copyright, full GPL license, additional notice and file provenance are
retained. The native `argo-carplay` component is GPL-3.0-or-later; distributions
include its notices and corresponding native source. The other adapters use
source-informed protocol research and synthetic interoperability fixtures.

The physical Link firmware compatibility service in
[`native/link-mfid`](native/link-mfid) also includes adapted upstream `iap2-mfi`
and `livi-net` sources from that revision. It preserves the real authentication
coprocessor and USB-client admission. Its GPL license, notice and complete
corresponding source accompany the patched firmware.
See the
[architecture and provenance review](docs/carplay-livi-review.md).

Media metadata, consumer-HID playback controls, artwork and native Opus audio were additionally
reviewed against the current Rust LIVI implementation at
[`34ae05e14df68f12d06cde0589f27d6d5b449ddb`](https://github.com/f-io/LIVI/tree/34ae05e14df68f12d06cde0589f27d6d5b449ddb)
(2026-11-08). This does not change the pinned vendored Link engine revision above.
The Android Auto adapter encodes these protocol references independently; the
CarPlay implementation remains within its existing GPL component.

This acknowledgement does not imply endorsement of Argo by f-io or LIVI.

## Open Headunit

Android Auto portrait density fitting was informed by
[Open Headunit's measured navigation-touch compatibility research](https://github.com/andreknieriem/open-headunit/commit/ec6cb51655fe9b210dfaa707d7ff3c8b1fb9ed39),
including `AnnouncedDensityPolicy.kt` and its 730-dp width heuristic. Argo implements
the geometry-dependent limit independently; no Open Headunit source or assets are
bundled. This heuristic does not establish a Google requirement or guarantee.

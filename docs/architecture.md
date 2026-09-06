# Architecture and extending Argo

The [root overview](../README.md) describes current scope; the source map below
is the implementation authority, not a promise that every abstraction has a
hardware backend.

## Composition and ownership

[main.dart](../lib/main.dart) passes `Platform.environment` to the application
runner. [bootstrap.dart](../lib/app/bootstrap.dart) selects runtime mode, discovers
external bundles, registers generic/external profiles, loads settings, starts
Veloce/CAN, then composes power, audio, projection, simulation and modules.
[ServiceRegistry](../lib/core/services/service_registry.dart) is a typed reference
map: duplicate registrations and missing dependencies fail. It does not dispose
services. Feature constructors receive application-facing contracts rather than
opening native libraries or reading environment variables.

[AppLifecycleCoordinator](../lib/core/lifecycle/app_lifecycle_coordinator.dart)
owns startup rollback and idempotent shutdown: stop activity, persist state,
release resources, with reverse registration order within a phase. Cleanup
continues after individual failures. Veloce shuts down CAN delivery before plugin
unload, storage and signal-bus release. The process owns services; widgets own
subscriptions/controllers local to their presentation.

[AppModuleRegistry](../lib/app/navigation/app_module_registry.dart) and
[app_modules.dart](../lib/app/navigation/app_modules.dart) define Home, Vehicle,
Climate, Parking, Media and Settings. The shell retains pages in an IndexedStack.
Navigation away is not disposal. ProjectionInputScope explicitly communicates
input ownership; hiding projection, replacing a session/stream and changing
presentation geometry cancel accepted gestures. Expanded mode reuses the native
view through stable widget ownership rather than opening another session.

## Three different kinds of state

- Typed application settings: persisted user requests/navigation in a versioned
  JSON file; see [configuration](configuration.md). Secrets are not settings.
- Live state: vehicle samples, projection sessions/streams, audio focus, host
  capabilities and diagnostics. A saved request does not override measured
  backend availability or establish that an operation was applied.
- Plugin storage: Veloce's owner-scoped SQLite values and optional structured
  reload state. It is not Argo's settings service or a credential store.

## Vehicle, audio and power boundaries

`VehicleDataService` exposes typed normalized signals to features.
[VeloceVehicleDataService](../lib/integrations/veloce/veloce_vehicle_data_service.dart)
adapts Veloce's bus, which records source identity, timestamps and sequence.
`VehicleSignals` defines the small catalog Argo currently consumes. Raw CAN is
separate: Linux SocketCAN is a worker-owned native socket, with logical-bus
filtering and bounded subscriber delivery. External Lua decoders turn synthetic
or vehicle-specific frames into normalized signals. Public feature code must
not know arbitration IDs, DBC layout or private vehicle protocols.

`vehicle.json` discovery selects profile/capabilities and the default plugin root.
Declaring a capability does not install a transport or implement a feature.
[Integration documentation](vehicle-integrations.md) defines the exact schema and
source authorization for the host event bridges.

AudioService owns requested preferences, source/focus policy and backend-neutral
capability state. The real PipeWire adapter invokes `wpctl` for default-sink
volume/mute only. Native AA audio is a separate daemon GStreamer/PipeWire data
path; Dart sends focus/gain metadata, never PCM. Disabling Argo's master-control
backend does not disable daemon PCM playback. Host power requests pass through a
narrow authorized bridge, flush settings and quiesce transport. Suspend return
recreates the transport delegate while logical subscriptions/runtime survive;
physical wake is a host responsibility. Simulation alone does not disable real
power/audio adapters: select disabled explicitly.

## Projection contract

```text
Flutter features → ProjectionService → backend → bounded Unix control IPC
                                               ↓
                                      Rust argo-projectiond
                                      USB / AA / TLS / channels
                                       ├─ PCM → native GStreamer → PipeWire
                                       └─ H.264 → native media socket
                                                    ↓
                                  C++ GStreamer → BGRx appsink → IHS submit
```

Control IPC v2 has a 12-byte header, 64 KiB maximum payload and a 256 KiB Dart
receive-buffer bound. Device/session descriptors, commands, readiness/capabilities, revisioned
preferences and gains use it; encoded video and decoded frame bytes do not.
Identity paths and material never travel in client IPC; the daemon exclusively
loads them from its environment. The native video feed is separately framed/bounded. Argo connects to an already
running daemon and does not provide automatic daemon respawn supervision.

The shared presentation path is:

```text
ProjectionView → IhsProjectionSurface → PlatformViewLink
               → PlatformViewSurface → PlatformViewLayer(native view ID)
```

The [registry loader](../lib/integrations/projection/ihs_projection_view_registry.dart)
registers `argo.projection.view` before widget creation. The
[IHS controller](../lib/features/projection/ihs_projection_surface.dart) sends
one stable ID, initial logical width/height and StandardMessageCodec parameters
over `flutter/platform_views`; successful channel completion precedes link
notification. Resize remains logical; source buffer dimensions are independent.
Dispose waits for pending creation and sends native disposal once. Unavailable
channels produce an error surface, including on unsupported GTK hosts.

IHS registers an `ICompositorSurface` and replies with the native platform-view
ID. It does not register a Flutter external texture for this path. That ID, a GL
texture name, DMA-BUF fd and Flutter external-texture ID are not interchangeable.
The old AndroidView texture path is not the current implementation. The layer
regression inspects PlatformViewLayer and rejects TextureLayer presentation.
Input is sent only by ProjectionView's mapped Listener; platform controller touch
dispatch is deliberately a no-op. Rendering and input share fitted geometry;
content insets are removed once, safe insets remain metadata, and logical
pointer coordinates are not blindly multiplied by DPR.

The [native view](../native/projection/argo-projection-view/src/projection_view.cpp)
negotiates IHS kind/format support, decodes/converts with GStreamer and exports
fresh GBM RGB allocations. This is not a zero-copy decode claim. The renderer
diagnostic substitutes only the native source, using the same appsink/callback
and submission/lifecycle path. Existing modifier and release ownership behavior
is documented in the [runbook](../tool/projection/README.md).

## Adding a feature or service

1. Define an application-facing contract/model in `lib/core/` when shared across
   features; implement platform details in `lib/integrations/`.
2. Compose the implementation in `lib/app/`, register its dependencies explicitly
   before consumers, and immediately register lifecycle cleanup after acquisition.
   Handle rollback if later startup fails; ServiceRegistry alone is not ownership.
3. Add a module descriptor to `app_modules.dart` and inject dependencies through
   its builder. Give the module a stable ID, and account for IndexedStack retention
   when stopping input, timers or subscriptions.
4. Add focused behavior tests alongside the existing core/integration/feature
   tests. Preserve dependency-boundary tests and graceful unsupported behavior.

For a typed setting, add a validated `SettingKey<T>` with stable ID, default,
serializer/deserializer to `AppSettingKeys.createSchema()`. Use SettingsService
rather than direct JSON writes. Specify when consumers apply it, include backend
capability checks, test a meaningful invalid/persistence case, and update the
configuration table. Do not equate saving with applying an unsupported setting.

For a normalized signal, add a typed decoder/key to
[VehicleSignals](../lib/core/vehicle/vehicle_signals.dart), document unit/range and
unknown semantics, consume through VehicleDataService, and publish from an
external decoder or synthetic scenario. Keep bus IDs outside public features.
For a new backend, implement the existing core interface and capability reporting,
select it only at composition, and test its selection/error boundary with fakes.
No platform package should leak into feature widgets.

## Adding a host-facing Veloce bridge

For asynchronous commands, follow `VehicleAudioControlBridge` or
`HostPowerRequestBridge`: subscribe under an owned host ID, use fixed topics,
validate the runtime-provided source and active generation/bundle provenance,
invoke a narrow service operation and cancel subscriptions on shutdown. Never
accept arbitrary shell commands or a self-declared plugin ID from payload data.

For a genuinely new Lua API, the sibling Veloce core exposes
`PluginApiNamespace`, `PluginApiMethod`, `PluginApiRegistry` and a capability
catalog/manager. Add only the required capability and namespace in Argo's runtime
composition before plugins load; keep the catalog/manager consistent with the
registry and manifest loader/parser. Preserve the default manager's generation-aware
permission checks when adding namespaces; replacing the entire API registry needs
explicit equivalent checks. `PluginApiCall` carries plugin/generation identity and validated
structured arguments. Handlers are synchronous; asynchronous work must return
an ID and deliver completion through an owned event/callback. Resource cleanup
must respect generation replacement. This is an extension recipe, not an API
already exposed by Argo. Read the matching sibling
`packages/veloce_lua_core/lib/src/api/plugin_api_registry.dart` before extending it.

Veloce's UI extension registries and Flutter renderer package do not automatically
create Argo tabs/settings/widgets. Argo depends on core/native, not
`veloce_lua_flutter`, and does not render those extension registries. Adding that
UI would be separate work, not merely a Lua manifest permission.

## Projection configuration ownership (IPC v2)

Argo's ProjectionSettingsService persists the existing typed preferences; its
optional ProjectionConfigurationBackend exposes daemon metadata independently
of video/audio availability. The Settings card remains usable as a status view
when identity is missing. No Flutter certificate parser or identity validator
remains, and inherited identity environment variables are ignored by Dart.

The daemon admits one control client at a time with a connection-owned permit.
Hello is empty; v1 headers and nonempty legacy hello payloads are rejected rather
than reinterpreted. Requests must have strictly increasing per-connection u32
revisions. Invalid requests leave pending and active configurations intact.
Replies carry the revision; Dart ignores stale acknowledgements. Session-state
notifications use the same ordered bounded connection and report the current
frozen configuration, not a settings-file echo.

Wire header remains big-endian magic/version/kind/payload-length (12 bytes).
Strings are u16 byte length followed by UTF-8. A display value is width:u16,
height:u16, DPI:u16, FPS:u8, driver:u8 (0 left, 1 right).

| Kind | Payload |
|---|---|
| 1 hello | Empty, client request/server acknowledgement. |
| 9 capabilities | Readiness:u8 (0 ready, 1 missing identity, 2 invalid identity, 3 backend failure), message:string; resolution count:u8 then u16 pairs; FPS count:u8 then u8 values; min/max DPI:u16; default display; audio count:u8 then role:u8, rate:u16, bits:u8, channels:u8. |
| 28 configure | Client revision:u32 and display. No secrets or paths. |
| 10 configuration | Revision:u32, accepted:u8, reason:string, validated next display, active session ID:string; active display follows only for a nonempty ID. Revision 0 is initial state. Session changes can notify at the last processed revision. |
| 5 audio stream | Existing session/stream IDs, role/active/focus, then selected PCM rate:u16, bits:u8, channels:u8. |

Other message kinds preserve their existing bounded control responsibilities.
The shared hex fixture in `test/fixtures/projection/ipc_v2_capabilities.hex` is
checked by both Dart and Rust. Rebuild both sides; do not mix v1/v2 bundles.

HostControl serializes request selection and session freezing through its watch
state. The USB worker freezes before version negotiation; post-version TLS uses
that same display snapshot. The session guard clears active selection even when
its future is cancelled. Standalone sessions use validated defaults and never
adopt a later client request in place. AA discovery, native audio construction
and session metadata use the same fixed AudioFormat catalog. Playback pipelines,
wire channel IDs/order, TLS compatibility, input mapping and native rendering
are unchanged; only native endpoint resolution was adjusted.

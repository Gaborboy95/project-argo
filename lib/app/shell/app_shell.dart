import 'dashboard_geometry.dart';
import 'dashboard_dock.dart';
import 'dashboard_media_strip.dart';
import 'dashboard_climate.dart';
import '../../core/audio/audio_service.dart';
import '../../core/media/media_session_service.dart';
import '../../core/runtime/argo_runtime_mode.dart';
import 'argo_background.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/settings/app_setting_keys.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_types.dart';
import '../../features/projection/projection_page.dart';
import '../../core/settings/settings_service.dart';
import '../argo_environment.dart';
import '../../features/projection/projection_input_scope.dart';
import '../../features/projection/projection_presentation_scope.dart';
import '../navigation/app_module.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.environment});

  final ArgoEnvironment environment;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _selectedIndex;
  ProjectionService? _projection;
  StreamSubscription<ProjectionSnapshot>? _projectionSubscription;
  ProjectionSnapshot? _previous;
  String? _waitingSession, _activationError;
  bool _activating = false;
  String? _activatingSession, _queuedHomeSession;
  int _requestedAfterRevision = 0;
  int _navigationEpoch = 0;
  bool get _home =>
      widget.environment.moduleRegistry.modules[_selectedIndex].id == 'home';
  bool _mediaVisible = true, _apps = false;
  double _climate = 0;
  double? _volume;
  bool get _modal => _apps || _climate > 0;
  final _contentKey = GlobalKey();

  SettingsService get _settings =>
      widget.environment.services.get<SettingsService>();

  @override
  void initState() {
    super.initState();
    final modules = widget.environment.moduleRegistry.modules;
    final storedId = _settings.get(AppSettingKeys.lastModule);
    final storedIndex = modules.indexWhere((module) => module.id == storedId);
    final homeIndex = modules.indexWhere((module) => module.id == 'home');
    _selectedIndex = storedIndex >= 0
        ? storedIndex
        : homeIndex >= 0
        ? homeIndex
        : 0;
    if (widget.environment.services.contains<ProjectionService>()) {
      _projection = widget.environment.services.get<ProjectionService>();
      _previous = _projection!.current;
      _projectionSubscription = _projection!.changes.listen(_onProjection);
      if (_home) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _home) _resumeHome();
        });
      }
    }
  }

  void _onProjection(ProjectionSnapshot snapshot) {
    final session = selectedProjectionSession(snapshot);
    final previous = _previous?.sessions
        .where((s) => s.id == session?.id)
        .firstOrNull;
    _previous = snapshot;
    final hostReturn =
        session != null &&
        previous != null &&
        session.hostReturnRevision > previous.hostReturnRevision;
    // Phone Exit is explicit navigation intent even during a pending resume.
    // Presentation snapshots can lag the phone's focus request.
    if (_home && hostReturn) {
      debugPrint(
        'Argo projection presentation: phone host-return revision=${session.hostReturnRevision}',
      );
      _returnToHost(phoneRequested: true);
      return;
    }
    if (_waitingSession != session?.id) _waitingSession = null;
    if (_waitingSession != null &&
        projectionVideoUsable(session) &&
        mainProjectionStream(session)!.presentationRevision >
            _requestedAfterRevision) {
      _waitingSession = null;
    }
    if (mounted) setState(() {});
  }

  void _resumeHome() {
    if (!_home) return;
    final session = selectedProjectionSession(_projection!.current);
    if (session == null || session.state == ProjectionSessionState.connecting) {
      return;
    }
    if (_activating) {
      // Coalesce the same request; serialize an explicit Home action targeting
      // a replacement session behind the old write, never run both in parallel.
      if (_activatingSession != session.id) _queuedHomeSession = session.id;
      return;
    }
    debugPrint('Argo projection presentation: explicit Home activation');
    final epoch = _navigationEpoch;
    setState(() {
      _activating = true;
      _activatingSession = session.id;
      _activationError = null;
      _waitingSession = session.id;
      _requestedAfterRevision =
          mainProjectionStream(session)?.presentationRevision ?? 0;
    });
    unawaited(
      _projection!
          .activate(session.id)
          .catchError((Object error) {
            if (mounted &&
                _home &&
                epoch == _navigationEpoch &&
                selectedProjectionSession(_projection!.current)?.id ==
                    session.id) {
              setState(
                () => _activationError = 'Could not resume projection: $error',
              );
            }
          })
          .whenComplete(() {
            _activating = false;
            _activatingSession = null;
            final queued = _queuedHomeSession;
            _queuedHomeSession = null;
            if (mounted &&
                _home &&
                queued != null &&
                selectedProjectionSession(_projection!.current)?.id == queued) {
              _resumeHome();
            }
          }),
    );
  }

  void _returnToHost({bool phoneRequested = false}) {
    final index = widget.environment.moduleRegistry.modules.indexWhere(
      (m) => m.id == 'media',
    );
    if (index >= 0) _selectModule(index, phoneRequested: phoneRequested);
  }

  @override
  void dispose() {
    _navigationEpoch++;
    unawaited(_projectionSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modules = widget.environment.moduleRegistry.modules;

    return ProjectionPresentationScope(
      waiting: _waitingSession != null,
      error: _activationError,
      child: Scaffold(
        body: ArgoBackground(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final geometry = DashboardGeometry(constraints.biggest);
                final scale = _settings.get(
                  AppSettingKeys.appearanceControlSize,
                );
                final services = widget.environment.services;
                final sheetHeight = (geometry.dockTop * .65).clamp(0.0, 420.0);
                return Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: geometry.primaryHeight,
                      child: _buildContent(modules),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: geometry.dockHeight,
                      height: geometry.mediaHeight,
                      child: Visibility(
                        visible: _mediaVisible,
                        maintainState: true,
                        child: DashboardMediaStrip(
                          scale: scale,
                          media: services.contains<MediaSessionService>()
                              ? services.get<MediaSessionService>()
                              : null,
                        ),
                      ),
                    ),
                    if (_modal)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        bottom: geometry.dockHeight,
                        child: ModalBarrier(
                          color: Colors.black45,
                          dismissible: true,
                          onDismiss: () => setState(() {
                            _climate = 0;
                            _apps = false;
                          }),
                        ),
                      ),
                    if (_apps)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: geometry.dockHeight,
                        height: sheetHeight,
                        child: Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (var i = 0; i < modules.length; i++)
                                    SizedBox(
                                      width: 140 * scale,
                                      child: ListTile(
                                        leading: Icon(modules[i].icon),
                                        title: Text(modules[i].label),
                                        onTap: () {
                                          setState(() => _apps = false);
                                          _selectModule(i);
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_climate > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: geometry.dockHeight,
                        height: sheetHeight * _climate,
                        child: DashboardClimate(
                          demo:
                              services.contains<ArgoRuntimeMode>() &&
                              services.get<ArgoRuntimeMode>() ==
                                  ArgoRuntimeMode.simulation,
                          onDismiss: () => setState(() => _climate = 0),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: geometry.dockHeight,
                      child: DashboardDock(
                        key: const ValueKey('dashboard-dock'),
                        scale: scale,
                        home: _home,
                        mediaVisible: _mediaVisible,
                        onHome: () {
                          setState(() {
                            _climate = 0;
                            _apps = false;
                          });
                          _selectId('home');
                        },
                        onMedia: () =>
                            setState(() => _mediaVisible = !_mediaVisible),
                        onApps: () => setState(() {
                          _apps = !_apps;
                          _climate = 0;
                        }),
                        onSettings: () {
                          setState(() {
                            _apps = false;
                            _climate = 0;
                          });
                          _selectId('settings');
                        },
                        onClimate: () => setState(() {
                          _apps = false;
                          _climate = _climate > 0 ? 0 : 1;
                        }),
                        onClimateDrag: (delta) => setState(() {
                          _apps = false;
                          _climate = (_climate - delta / sheetHeight).clamp(
                            0.0,
                            1.0,
                          );
                        }),
                        onClimateEnd: () =>
                            setState(() => _climate = _climate >= .2 ? 1 : 0),
                        audio: services.contains<AudioService>()
                            ? services.get<AudioService>()
                            : null,
                        onVolume: (v) => setState(() => _volume = v),
                      ),
                    ),
                    if (_volume != null)
                      Positioned(
                        right: 16,
                        bottom: geometry.dockHeight + 12,
                        child: IgnorePointer(
                          child: Material(
                            elevation: 8,
                            borderRadius: BorderRadius.circular(24),
                            child: SizedBox(
                              width: 64,
                              height: 160,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('${(_volume! * 100).round()}%'),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: 8,
                                    height: 90,
                                    child: RotatedBox(
                                      quarterTurns: 3,
                                      child: LinearProgressIndicator(
                                        value: _volume,
                                        minHeight: 8,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(List<AppModule> modules) {
    return IndexedStack(
      key: _contentKey,
      index: _selectedIndex,
      children: [
        for (final module in modules)
          ProjectionInputScope(
            key: ValueKey(module.id),
            active: module == modules[_selectedIndex],
            blocked: _modal,
            child: Builder(
              builder: (context) =>
                  module.builder(context, widget.environment.services),
            ),
          ),
      ],
    );
  }

  void _selectId(String id) {
    final index = widget.environment.moduleRegistry.modules.indexWhere(
      (m) => m.id == id,
    );
    if (index >= 0) _selectModule(index);
  }

  void _selectModule(int index, {bool phoneRequested = false}) {
    if (index == _selectedIndex) {
      if (_home && _projection != null) _resumeHome();
      return;
    }
    final oldStream = _home && _projection != null
        ? mainProjectionStream(selectedProjectionSession(_projection!.current))
        : null;
    final epoch = ++_navigationEpoch;

    setState(() {
      _selectedIndex = index;
      _waitingSession = null;
      _queuedHomeSession = null;
      _activationError = null;
    });
    if (oldStream != null && !phoneRequested) {
      // Allow the ownership scope to cancel gestures first. A later Home action
      // invalidates this hide, so an old surface can never hide a resumed one.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _navigationEpoch || _home) return;
        if (selectedProjectionSession(_projection!.current)?.id !=
            oldStream.sessionId) {
          return;
        }
        unawaited(
          _projection!.setVideoVisibility(oldStream.id, false).catchError((
            Object error,
          ) {
            debugPrint(
              'Argo projection: could not relinquish video focus: $error',
            );
          }),
        );
      });
    }
    if (_home && _projection != null) _resumeHome();
    final moduleId = widget.environment.moduleRegistry.modules[index].id;
    unawaited(
      _settings.set(AppSettingKeys.lastModule, moduleId).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Project Argo navigation',
            context: ErrorDescription('while saving the selected module'),
          ),
        );
      }),
    );
  }
}

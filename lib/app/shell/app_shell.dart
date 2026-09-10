import 'dashboard_geometry.dart';
import 'dashboard_dock.dart';
import 'dashboard_floating_media.dart';
import 'dashboard_climate.dart';
import '../../core/audio/audio_service.dart';
import '../../core/media/media_session_service.dart';
import 'dashboard_panel.dart';
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
  bool _mediaVisible = true;
  String? _panel, _climateSide;
  double _left = 22, _right = 22;
  double? _volume;
  bool get _modal => _panel != null;
  void _togglePanel(String panel) =>
      setState(() => _panel = _panel == panel ? null : panel);
  void _dismissPanel() => setState(() {
    _panel = null;
    _climateSide = null;
  });
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
                final panel = _panel;
                final sheetHeight = geometry.dockTop * .82;
                return Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: geometry.primaryHeight,
                      child: _buildContent(modules),
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
                          onDismiss: _dismissPanel,
                        ),
                      ),
                    if (_panel != null && _panel != 'media')
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: geometry.dockHeight,
                        height: sheetHeight,
                        child: DashboardPanel(
                          key: ValueKey(_panel),
                          height: sheetHeight,
                          label: _panel!,
                          onDismiss: () {
                            if (_panel == panel) _dismissPanel();
                          },
                          child: switch (_panel) {
                            'climate' => DashboardClimate(
                              onDismiss: _dismissPanel,
                              left: _left,
                              right: _right,
                              onLeft: (v) => setState(() => _left = v),
                              onRight: (v) => setState(() => _right = v),
                            ),
                            _ => _appsPanel(modules, scale),
                          },
                        ),
                      ),
                    Positioned(
                      key: const ValueKey('floating-media-slot'),
                      left: constraints.maxWidth * .025,
                      right: constraints.maxWidth * .025,
                      bottom: geometry.dockHeight + 4,
                      child: Visibility(
                        visible:
                            _mediaVisible &&
                            (_panel == null || _panel == 'media'),
                        maintainState: true,
                        child: DashboardFloatingMedia(
                          collapsedHeight:
                              (geometry.dockTop - geometry.primaryHeight - 8)
                                  .clamp(1, double.infinity),
                          expandedHeight: sheetHeight,
                          open: _panel == 'media',
                          onOpen: () => setState(() => _panel = 'media'),
                          onClose: () {
                            if (_panel == 'media') {
                              _dismissPanel();
                            }
                          },
                          media: services.contains<MediaSessionService>()
                              ? services.get<MediaSessionService>()
                              : null,
                          scale: scale,
                        ),
                      ),
                    ),
                    Positioned(
                      key: const ValueKey('fixed-dashboard-dock'),
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
                          _dismissPanel();
                          _selectId('home');
                        },
                        onMedia: () => setState(() {
                          _mediaVisible = !_mediaVisible;
                          if (!_mediaVisible && _panel == 'media') {
                            _panel = null;
                          }
                        }),
                        onApps: () => _togglePanel('apps'),
                        onSettings: () {
                          _dismissPanel();
                          _selectId('settings');
                        },
                        left: _left,
                        right: _right,
                        onLeft: (v) => setState(() => _left = v),
                        onRight: (v) => setState(() => _right = v),
                        onClimate: (side) => setState(() {
                          _panel = _panel == 'climate' && _climateSide == side
                              ? null
                              : 'climate';
                          _climateSide = side;
                        }),
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

  Widget _appsPanel(List<AppModule> modules, double scale) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Apps',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Close apps',
              onPressed: _dismissPanel,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, c) {
            final columns = (c.maxWidth / (180 * scale)).floor().clamp(2, 5);
            final extent = c.maxWidth / columns;
            return Wrap(
              alignment: WrapAlignment.center,
              runSpacing: 20,
              children: [
                for (var i = 0; i < modules.length; i++)
                  SizedBox(
                    width: extent,
                    height: 140 * scale,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        _dismissPanel();
                        _selectModule(i);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(modules[i].icon, size: 54 * scale),
                          const SizedBox(height: 16),
                          Text(
                            modules[i].label,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );

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

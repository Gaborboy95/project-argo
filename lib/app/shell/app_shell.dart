import 'argo_background.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/settings/app_setting_keys.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_types.dart';
import '../../core/projection/projection_render_test.dart';
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
  bool get _fullscreen =>
      _home &&
      _projection != null &&
      ((widget.environment.services.contains<ProjectionRenderTest>() &&
              widget.environment.services
                  .get<ProjectionRenderTest>()
                  .enabled) ||
          (_waitingSession == null &&
              projectionVideoUsable(
                selectedProjectionSession(_projection!.current),
              )));
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
        body: _fullscreen
            ? _buildContent(modules)
            : ArgoBackground(
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final useSideNavigation = constraints.maxWidth >= 1000;

                      return Column(
                        children: [
                          const _StatusBar(),
                          Expanded(
                            child: useSideNavigation
                                ? Row(
                                    children: [
                                      _SideNavigation(
                                        modules: modules,
                                        selectedIndex: _selectedIndex,
                                        onSelected: _selectModule,
                                      ),
                                      const VerticalDivider(width: 1),
                                      Expanded(child: _buildContent(modules)),
                                    ],
                                  )
                                : _buildContent(modules),
                          ),
                          if (!useSideNavigation)
                            _BottomNavigation(
                              modules: modules,
                              selectedIndex: _selectedIndex,
                              onSelected: _selectModule,
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
            child: Builder(
              builder: (context) =>
                  module.builder(context, widget.environment.services),
            ),
          ),
      ],
    );
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

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text('ARGO', style: Theme.of(context).textTheme.labelLarge),
            const Spacer(),
            const Icon(Icons.wifi, size: 17),
            const SizedBox(width: 12),
            const Icon(Icons.bluetooth, size: 17),
          ],
        ),
      ),
    );
  }
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    required this.modules,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<AppModule> modules;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          for (var index = 0; index < modules.length; index++)
            Expanded(
              child: _NavigationButton(
                label: modules[index].label,
                icon: modules[index].icon,
                selected: index == selectedIndex,
                onTap: () => onSelected(index),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 22,
            color: selected ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({
    required this.modules,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<AppModule> modules;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      labelType: NavigationRailLabelType.all,
      destinations: [
        for (final module in modules)
          NavigationRailDestination(
            icon: Icon(module.icon),
            label: Text(module.label),
          ),
      ],
    );
  }
}

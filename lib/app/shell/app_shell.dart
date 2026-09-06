import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/settings/app_setting_keys.dart';
import '../../core/settings/settings_service.dart';
import '../argo_environment.dart';
import '../../features/projection/projection_input_scope.dart';
import '../navigation/app_module.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.environment});

  final ArgoEnvironment environment;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _selectedIndex;

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
  }

  @override
  Widget build(BuildContext context) {
    final modules = widget.environment.moduleRegistry.modules;

    return Scaffold(
      body: SafeArea(
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
    );
  }

  Widget _buildContent(List<AppModule> modules) {
    return IndexedStack(
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

  void _selectModule(int index) {
    if (index == _selectedIndex) {
      return;
    }

    setState(() {
      _selectedIndex = index;
    });
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

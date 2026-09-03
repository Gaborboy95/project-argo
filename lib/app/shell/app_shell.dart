import 'package:flutter/material.dart';

import '../navigation/app_modules.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
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
                              selectedIndex: _selectedIndex,
                              onSelected: _selectModule,
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(child: _buildContent()),
                          ],
                        )
                      : _buildContent(),
                ),
                if (!useSideNavigation)
                  _BottomNavigation(
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

  Widget _buildContent() {
    return IndexedStack(
      index: _selectedIndex,
      children: [
        for (final module in appModules) Builder(builder: module.builder),
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
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          for (var index = 0; index < appModules.length; index++)
            Expanded(
              child: _NavigationButton(
                label: appModules[index].label,
                icon: appModules[index].icon,
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
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      labelType: NavigationRailLabelType.all,
      destinations: [
        for (final module in appModules)
          NavigationRailDestination(
            icon: Icon(module.icon),
            label: Text(module.label),
          ),
      ],
    );
  }
}

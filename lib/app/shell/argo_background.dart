import 'package:flutter/material.dart';

/// Shared native-page background. Projection paints its own opaque black.
class ArgoBackground extends StatelessWidget {
  const ArgoBackground({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface, child: child);
}

import 'package:flutter/material.dart';

/// Small product vocabulary layered on the user's Material color/scale choices.
abstract final class ArgoSpacing {
  static const page = 24.0, section = 24.0, gap = 12.0, radius = 16.0;
  static const touch = 48.0, icon = 24.0;
  static const transition = Duration(milliseconds: 180);
}

class ArgoPage extends StatelessWidget {
  const ArgoPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final List<Widget> children, actions;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(ArgoSpacing.page),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineMedium),
            if (subtitle != null) Text(subtitle!),
            if (actions.isNotEmpty)
              Wrap(spacing: ArgoSpacing.gap, children: actions),
            const SizedBox(height: ArgoSpacing.section),
            ...children,
          ],
        ),
      ),
    ),
  );
}

class ArgoSection extends StatelessWidget {
  const ArgoSection({
    super.key,
    required this.title,
    this.explanation,
    required this.children,
  });
  final String title;
  final String? explanation;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: ArgoSpacing.section),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (explanation != null) Text(explanation!),
        const SizedBox(height: ArgoSpacing.gap),
        ...children,
      ],
    ),
  );
}

class ArgoDeviceChoice extends StatelessWidget {
  const ArgoDeviceChoice({
    super.key,
    required this.name,
    required this.identifier,
    this.selected = false,
    this.available = true,
    this.onSelect,
    this.onPreview,
    this.actions,
    this.status,
  });
  final String name, identifier;
  final String? status;
  final Widget? actions;
  final bool selected, available;
  final VoidCallback? onSelect, onPreview;
  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        ListTile(
          leading: Icon(selected ? Icons.check_circle : Icons.devices),
          title: Text(name),
          subtitle: Text(
            status ??
                (!available
                    ? 'Unavailable'
                    : selected
                    ? 'Selected'
                    : 'Available'),
          ),
          onTap: available ? onSelect : null,
          trailing: onPreview == null
              ? null
              : TextButton(
                  onPressed: available ? onPreview : null,
                  child: const Text('Preview'),
                ),
        ),
        ?actions,
        ExpansionTile(
          title: const Text('Details'),
          children: [SelectableText(identifier)],
        ),
      ],
    ),
  );
}

Future<bool> confirmArgoAction(
  BuildContext context, {
  required String title,
  required String explanation,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(explanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class ArgoSetupStep extends StatelessWidget {
  const ArgoSetupStep({
    super.key,
    required this.index,
    required this.count,
    required this.title,
    required this.child,
    this.onBack,
    this.onNext,
    this.onSkip,
    this.pending = false,
  });
  final int index, count;
  final String title;
  final Widget child;
  final VoidCallback? onBack, onNext, onSkip;
  final bool pending;
  @override
  Widget build(BuildContext context) => ArgoPage(
    title: title,
    subtitle: 'Step ${index + 1} of $count',
    children: [
      LinearProgressIndicator(value: pending ? null : index / count),
      const SizedBox(height: ArgoSpacing.section),
      child,
      const SizedBox(height: ArgoSpacing.section),
      Wrap(
        spacing: ArgoSpacing.gap,
        children: [
          TextButton(
            onPressed: pending ? null : onBack,
            child: const Text('Back'),
          ),
          if (onSkip != null)
            TextButton(
              onPressed: pending ? null : onSkip,
              child: const Text('Set up later'),
            ),
          FilledButton(
            onPressed: pending ? null : onNext,
            child: Text(index == count - 1 ? 'Finish' : 'Next'),
          ),
        ],
      ),
    ],
  );
}

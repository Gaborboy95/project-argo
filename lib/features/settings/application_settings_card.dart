import 'package:flutter/material.dart';

import '../../core/lifecycle/application_exit_service.dart';

class ApplicationSettingsCard extends StatefulWidget {
  const ApplicationSettingsCard({required this.exit, super.key});
  final ApplicationExitService exit;
  @override
  State<ApplicationSettingsCard> createState() =>
      _ApplicationSettingsCardState();
}

class _ApplicationSettingsCardState extends State<ApplicationSettingsCard> {
  bool busy = false;
  String? error;
  Future<void> quit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.exit.quit();
    } on Object catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Application', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      const Text(
        'Quit stops projection, Bluetooth calls and music, releases owned audio and network resources, and saves settings before closing Argo.',
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: busy ? null : quit,
        icon: const Icon(Icons.power_settings_new),
        label: Text(busy ? 'Stopping connections…' : 'Quit Argo'),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'Argo is still open: $error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}

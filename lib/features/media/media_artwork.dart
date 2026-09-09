import 'dart:io';

import 'package:flutter/material.dart';

/// Only daemon-owned cache references are readable; no phone URLs or arbitrary paths.
class MediaArtwork extends StatelessWidget {
  const MediaArtwork({super.key, this.path});
  final String? path;
  static bool allowed(String path) {
    final root = Platform.environment['XDG_RUNTIME_DIR'];
    if (root == null) return false;
    return RegExp(
      '^${RegExp.escape(root)}/argo-artwork-[0-9]+-[a-f0-9]{32}/[a-f0-9]{32}\\.img\$',
    ).hasMatch(path);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return Semantics(
      label: path == null ? 'Music artwork unavailable' : 'Album artwork',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 192,
          height: 192,
          child: path != null && allowed(path!)
              ? Image.file(
                  File(path!),
                  fit: BoxFit.cover,
                  cacheWidth: 512,
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

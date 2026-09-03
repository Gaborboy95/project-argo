import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

class MediaPage extends StatelessWidget {
  const MediaPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: 'Media',
      icon: Icons.music_note_outlined,
      description: 'Media and audio',
    );
  }
}

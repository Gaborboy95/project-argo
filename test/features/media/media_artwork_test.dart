import 'dart:io';

import 'package:argo/features/media/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'only private artwork references are offered to the image decoder',
    (tester) async {
      final runtime = Platform.environment['XDG_RUNTIME_DIR'];
      final owned = '$runtime/argo-artwork-123-${'a' * 32}/${'b' * 32}.img';
      if (runtime != null) expect(MediaArtwork.allowed(owned), isTrue);
      for (final invalid in [
        'https://phone/art.jpg',
        '/etc/passwd',
        '$owned/../../secret',
        '$owned.extra',
      ]) {
        expect(MediaArtwork.allowed(invalid), isFalse);
        await tester.pumpWidget(MaterialApp(home: MediaArtwork(path: invalid)));
        expect(find.byType(Image), findsNothing);
        expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
      }
    },
  );
}

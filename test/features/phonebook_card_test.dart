import 'package:argo/features/calls/phonebook_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'imports are explicit and choosing a contact only fills a number',
    (tester) async {
      final requests = <String>[];
      final choices = <String>[];
      Future<void> show({Map<String, dynamic>? book, bool enabled = true}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: PhonebookCard(
                    book: book,
                    enabled: enabled,
                    request: (action, {target = ''}) async {
                      requests.add('$action/$target');
                    },
                    choose: choices.add,
                  ),
                ),
              ),
            ),
          );
      await show();
      expect(requests, isEmpty);
      await tester.tap(find.text('Import contacts'));
      expect(requests, ['callsPhonebook/contacts:0']);
      await show(
        book: {
          'kind': 'contacts',
          'entries': [
            {
              'name': 'Fixture',
              'numbers': ['123'],
            },
          ],
        },
      );
      await tester.tap(find.text('Fixture'));
      expect(choices, ['123']);
      expect(requests, ['callsPhonebook/contacts:0']);
      await tester.tap(find.text('Clear'));
      expect(requests.last, 'callsPhonebookClear/');
      await show(enabled: false);
      expect(find.text('Fixture'), findsNothing);
      await tester.tap(find.text('Import contacts'));
      expect(requests.length, 2);
      await show(book: {'busy': true});
      await tester.tap(find.text('Cancel import'));
      expect(requests.last, 'callsPhonebookClear/');
    },
  );
}

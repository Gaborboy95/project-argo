import 'dart:io';

import 'package:argo/integrations/projection/android_auto_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing identity paths fail clearly', () async {
    final identity = AndroidAutoIdentity(
      certificateFile: File('missing-cert.pem'),
      privateKeyFile: File('missing-key.pem'),
    );
    await expectLater(identity.validate(), throwsA(isA<StateError>()));
  });

  test(
    'malformed certificate and key fail without exposing key material',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'argo-aa-identity-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final certificate = File('${directory.path}/cert.pem');
      final key = File('${directory.path}/key.pem');
      await certificate.writeAsString('not a certificate');
      await key.writeAsString('private-but-invalid');
      final identity = AndroidAutoIdentity(
        certificateFile: certificate,
        privateKeyFile: key,
      );

      await expectLater(
        identity.validate(enforcePrivatePermissions: false),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('could not be parsed'),
              isNot(contains('private-but-invalid')),
            ),
          ),
        ),
      );
    },
  );
}

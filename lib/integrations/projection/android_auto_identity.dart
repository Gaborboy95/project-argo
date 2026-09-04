import 'dart:io';

final class AndroidAutoIdentity {
  const AndroidAutoIdentity({
    required this.certificateFile,
    required this.privateKeyFile,
  });

  final File certificateFile;
  final File privateKeyFile;

  static AndroidAutoIdentity fromEnvironment(Map<String, String> environment) {
    final certificate = environment['ARGO_ANDROID_AUTO_CERT_FILE']?.trim();
    final key = environment['ARGO_ANDROID_AUTO_KEY_FILE']?.trim();
    if (certificate == null ||
        certificate.isEmpty ||
        key == null ||
        key.isEmpty) {
      throw StateError(
        'Android Auto requires ARGO_ANDROID_AUTO_CERT_FILE and '
        'ARGO_ANDROID_AUTO_KEY_FILE. No development credential is embedded.',
      );
    }
    return AndroidAutoIdentity(
      certificateFile: File(certificate).absolute,
      privateKeyFile: File(key).absolute,
    );
  }

  Future<void> validate({bool enforcePrivatePermissions = true}) async {
    if (!await certificateFile.exists()) {
      throw StateError(
        'Android Auto certificate does not exist: ${certificateFile.path}',
      );
    }
    if (!await privateKeyFile.exists()) {
      throw StateError(
        'Android Auto private key does not exist: ${privateKeyFile.path}',
      );
    }
    if (enforcePrivatePermissions && Platform.isLinux) {
      final stat = await privateKeyFile.stat();
      if (stat.mode & 0x3f != 0) {
        throw StateError(
          'Android Auto private key must not be accessible by group or others.',
        );
      }
    }
    final context = SecurityContext(withTrustedRoots: false);
    try {
      context.useCertificateChain(certificateFile.path);
      context.usePrivateKey(privateKeyFile.path);
    } on Object catch (error) {
      throw FormatException(
        'Android Auto certificate/private key could not be parsed: $error',
      );
    }
  }
}

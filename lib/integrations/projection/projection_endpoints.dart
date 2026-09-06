import 'dart:convert';

String projectionEndpoint(
  Map<String, String> environment,
  String name,
  String filename,
) {
  final path =
      environment[name] ??
      '${environment['XDG_RUNTIME_DIR'] ?? '/run'}/argo/$filename';
  if (!path.startsWith('/') ||
      path.trim() != path ||
      path.contains('\u0000') ||
      utf8.encode(path).length >= 108 ||
      path.endsWith('/')) {
    throw ArgumentError(
      '$name must be an absolute nonempty Unix path under 108 bytes, without surrounding whitespace.',
    );
  }
  return path;
}

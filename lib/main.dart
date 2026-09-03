import 'dart:io';

import 'app/argo_application_runner.dart';

void main() {
  runArgoApplication(processEnvironment: Platform.environment);
}

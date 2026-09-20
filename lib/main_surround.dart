import 'dart:io';

import 'app/argo_application_runner.dart';
import 'app/editions/surround.dart';

void main() => runArgoApplication(
  processEnvironment: Platform.environment,
  cameraIntegration: const SurroundIntegration(),
);

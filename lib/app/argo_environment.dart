import '../core/services/service_registry.dart';
import 'navigation/app_module_registry.dart';

/// The explicitly composed application dependencies passed into the UI tree.
final class ArgoEnvironment {
  const ArgoEnvironment({required this.services, required this.moduleRegistry});

  final ServiceRegistry services;
  final AppModuleRegistry moduleRegistry;
}

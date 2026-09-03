/// A lightweight typed registry populated explicitly during application
/// bootstrap.
///
/// The registry provides references only. It does not own or dispose the
/// registered services.
final class ServiceRegistry {
  final Map<Type, Object> _services = {};

  void register<T extends Object>(T service) {
    if (_services.containsKey(T)) {
      throw StateError('Service $T is already registered.');
    }
    _services[T] = service;
  }

  T get<T extends Object>() {
    final service = _services[T];
    if (service == null) {
      throw StateError('Required service $T is not registered.');
    }
    return service as T;
  }

  bool contains<T extends Object>() => _services.containsKey(T);
}

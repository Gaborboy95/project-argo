/// A value observed from the normalized application-facing vehicle data API.
final class VehicleDataPoint<T> {
  const VehicleDataPoint({
    required this.key,
    required this.value,
    required this.timestamp,
    required this.sequence,
    this.sourceId,
  });

  final String key;
  final T value;
  final DateTime timestamp;
  final int sequence;
  final String? sourceId;
}

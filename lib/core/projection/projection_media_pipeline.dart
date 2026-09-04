import 'projection_models.dart';

/// Describes the native media boundary. Implementations move encoded video,
/// PCM, and microphone data entirely outside Dart.
abstract interface class ProjectionMediaPipeline {
  Future<void> attachVideo(ProjectionVideoStream stream);
  Future<void> detachVideo(String streamId);
  Future<void> attachAudio(ProjectionAudioStream stream);
  Future<void> detachAudio(String streamId);
  Future<void> setMicrophoneRequested(String sessionId, bool requested);
  Future<void> close();
}

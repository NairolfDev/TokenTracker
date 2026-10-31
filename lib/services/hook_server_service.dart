import 'hook_event.dart';
import 'hook_server_stub.dart' if (dart.library.io) 'hook_server_io.dart';

export 'hook_event.dart';

class HookServerService {
  late final HookServerPlatform _platform;

  HookServerService({
    required void Function(HookEventPayload event) onHookEvent,
    required Map<String, dynamic> Function() getStatusSnapshot,
    void Function(Map<String, dynamic> remoteStatus)? onRemoteStatus,
  }) {
    _platform = HookServerPlatform(
      onHookEvent: onHookEvent,
      getStatusSnapshot: getStatusSnapshot,
      onRemoteStatus: onRemoteStatus,
    );
  }

  bool get isRunning => _platform.isRunning;
  int get port => _platform.port;

  Future<bool> start({bool bindLan = false}) =>
      _platform.startServer(bindLan: bindLan);

  Future<void> stop() => _platform.stopServer();

  void broadcast(Map<String, dynamic> statusSnapshot) =>
      _platform.broadcastStatus(statusSnapshot);

  Future<void> connectToRemoteHost(String host) =>
      _platform.connectRemoteClient(host);

  Future<void> disconnectRemoteHost() => _platform.disconnectRemoteClient();
}

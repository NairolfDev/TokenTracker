import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_constants.dart';
import 'hook_event.dart';

class HookServerPlatform {
  final void Function(HookEventPayload event) onHookEvent;
  final Map<String, dynamic> Function() getStatusSnapshot;
  final void Function(Map<String, dynamic> remoteStatus)? onRemoteStatus;

  Timer? _remotePollTimer;
  String? _remoteHost;
  bool _isRunning = false;

  HookServerPlatform({
    required this.onHookEvent,
    required this.getStatusSnapshot,
    this.onRemoteStatus,
  });

  bool get isRunning => _isRunning;
  int get port => AppConstants.hookServerPort;

  Future<bool> startServer({bool bindLan = false}) async {
    // Web cannot bind a raw TCP server; acts as a remote sync client or interactive demo host.
    _isRunning = false;
    return false;
  }

  Future<void> stopServer() async {
    _isRunning = false;
  }

  void broadcastStatus(Map<String, dynamic> statusPayload) {
    // No-op on Web server stub
  }

  Future<void> connectRemoteClient(String host) async {
    await disconnectRemoteClient();
    final cleanHost = host.trim();
    if (cleanHost.isEmpty) return;
    _remoteHost = cleanHost;
    await _pollRemoteOnce();
    _remotePollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollRemoteOnce(),
    );
  }

  Future<void> _pollRemoteOnce() async {
    final host = _remoteHost;
    if (host == null || host.isEmpty) return;
    try {
      final uri = host.startsWith('http')
          ? Uri.parse('$host/api/status')
          : Uri.parse('http://$host:${AppConstants.hookServerPort}/api/status');
      final res =
          await http.get(uri).timeout(const Duration(milliseconds: 1800));
      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          onRemoteStatus?.call(decoded);
        }
      }
    } catch (_) {}
  }

  Future<void> disconnectRemoteClient() async {
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _remoteHost = null;
  }
}

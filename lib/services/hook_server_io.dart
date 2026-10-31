import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/app_constants.dart';
import 'hook_event.dart';

class HookServerPlatform {
  final void Function(HookEventPayload event) onHookEvent;
  final Map<String, dynamic> Function() getStatusSnapshot;
  final void Function(Map<String, dynamic> remoteStatus)? onRemoteStatus;

  HttpServer? _server;
  final Set<WebSocket> _wsClients = <WebSocket>{};
  WebSocket? _remoteWs;
  StreamSubscription<dynamic>? _remoteWsSub;
  Timer? _remotePollTimer;
  String? _remoteHost;
  int _boundPort = AppConstants.hookServerPort;

  HookServerPlatform({
    required this.onHookEvent,
    required this.getStatusSnapshot,
    this.onRemoteStatus,
  });

  bool get isRunning => _server != null;
  int get port => _boundPort;

  Future<bool> startServer({
    bool bindLan = false,
    int port = AppConstants.hookServerPort,
  }) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return false;
    }
    await stopServer();
    try {
      final address =
          bindLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      _server = await HttpServer.bind(address, port, shared: true);
      _boundPort = _server!.port;
      _server!.listen(
        _handleHttpRequest,
        onError: (_) {},
        cancelOnError: false,
      );
      return true;
    } catch (_) {
      _server = null;
      return false;
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    final path = request.uri.path;

    // WebSocket Upgrade on `/ws`
    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      try {
        final ws = await WebSocketTransformer.upgrade(request);
        _wsClients.add(ws);
        // Send initial state snapshot immediately upon connection
        ws.add(jsonEncode(getStatusSnapshot()));
        ws.listen(
          (dynamic msg) {
            if (msg is String) {
              try {
                final decoded = jsonDecode(msg);
                if (decoded is Map<String, dynamic>) {
                  final event = HookEventPayload.parse(decoded);
                  if (event != null) {
                    onHookEvent(event);
                  }
                }
              } catch (_) {}
            }
          },
          onDone: () => _wsClients.remove(ws),
          onError: (_) => _wsClients.remove(ws),
          cancelOnError: true,
        );
      } catch (_) {}
      return;
    }

    // Real-time Hook Ingestion on `POST /api/hook`
    if (request.method == 'POST' && path == '/api/hook') {
      try {
        final bodyStr = await utf8.decoder.bind(request).join();
        final decoded =
            bodyStr.isNotEmpty ? jsonDecode(bodyStr) : <String, dynamic>{};
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          final event = HookEventPayload.parse(map);
          if (event != null) {
            onHookEvent(event);
            response.statusCode = HttpStatus.ok;
            response.headers.contentType = ContentType.json;
            response.write(
              jsonEncode({
                'ok': true,
                'agent': event.agent.id,
                'state': event.targetState.name,
              }),
            );
            await response.close();
            return;
          }
        }
        response.statusCode = HttpStatus.badRequest;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'ok': false, 'error': 'Invalid hook payload'}));
        await response.close();
      } catch (_) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
      }
      return;
    }

    // Complete Status Snapshot on `GET /api/status`
    if (request.method == 'GET' && (path == '/api/status' || path == '/')) {
      try {
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(getStatusSnapshot()));
        await response.close();
      } catch (_) {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      }
      return;
    }

    response.statusCode = HttpStatus.notFound;
    await response.close();
  }

  void broadcastStatus(Map<String, dynamic> statusPayload) {
    if (_wsClients.isEmpty) return;
    final encoded = jsonEncode(statusPayload);
    final dead = <WebSocket>[];
    for (final client in _wsClients) {
      try {
        client.add(encoded);
      } catch (_) {
        dead.add(client);
      }
    }
    for (final d in dead) {
      _wsClients.remove(d);
    }
  }

  Future<void> stopServer() async {
    for (final client in _wsClients.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _wsClients.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  Future<void> connectRemoteClient(String host) async {
    await disconnectRemoteClient();
    final cleanHost = host.trim();
    if (cleanHost.isEmpty) return;
    _remoteHost = cleanHost;

    // 1. Try real-time WebSocket stream
    try {
      final wsUrl = cleanHost.startsWith('ws://') || cleanHost.startsWith('wss://')
          ? '$cleanHost/ws'
          : 'ws://$cleanHost:${AppConstants.hookServerPort}/ws';
      _remoteWs = await WebSocket.connect(wsUrl)
          .timeout(const Duration(milliseconds: 2000));
      _remoteWsSub = _remoteWs!.listen(
        (dynamic data) {
          if (data is String) {
            try {
              final decoded = jsonDecode(data);
              if (decoded is Map<String, dynamic>) {
                onRemoteStatus?.call(decoded);
              }
            } catch (_) {}
          }
        },
        onError: (_) {},
        onDone: () {},
      );
    } catch (_) {
      _remoteWs = null;
    }

    // 2. Also poll HTTP `/api/status` every 3 seconds as resilient fallback
    await _pollRemoteOnce();
    _remotePollTimer = Timer.periodic(
      const Duration(seconds: 3),
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
    await _remoteWsSub?.cancel();
    _remoteWsSub = null;
    try {
      await _remoteWs?.close();
    } catch (_) {}
    _remoteWs = null;
    _remoteHost = null;
  }
}

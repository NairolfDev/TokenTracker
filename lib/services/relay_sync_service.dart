import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

/// Carries the desktop's status snapshot to phones and the web app over the internet.
/// It uses a public ntfy topic whose name is a random secret that only the QR code reveals.
/// Works on every platform because it is plain HTTPS (no sockets, no CORS trouble: ntfy allows browsers).
class RelaySyncService {
  static const String defaultBase = 'https://ntfy.sh';

  /// ntfy turns bodies above 4096 bytes into attachments; stay below it.
  static const int maxBodyBytes = 3900;

  final http.Client _client;
  final String base;
  Timer? _poll;
  String _lastMessageId = '';

  RelaySyncService({http.Client? client, this.base = defaultBase})
      : _client = client ?? http.Client();

  /// 16 random bytes as 22 URL-safe characters.
  static String newSecret() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String topic(String secret) => 'agentlights-$secret';

  /// Accepts the scanned link (`...#pair=SECRET`), `pair=SECRET` or the bare secret.
  static String? parseSecret(String input) {
    final m = RegExp(r'(?:pair=)?([A-Za-z0-9_-]{22})\s*$').firstMatch(input.trim());
    return m?.group(1);
  }

  /// Publishes [snapshot] (already compacted below [maxBodyBytes]). Returns false when it could not be sent.
  Future<bool> publish(String secret, String body) async {
    if (utf8.encode(body).length > maxBodyBytes) return false;
    try {
      final res = await _client
          .post(
            Uri.parse('$base/${topic(secret)}'),
            headers: const {'Content-Type': 'text/plain; charset=utf-8'},
            body: body,
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Returns the newest snapshot of the last ten minutes, or null.
  Future<Map<String, dynamic>?> fetchLatest(String secret) async {
    try {
      final res = await _client
          .get(Uri.parse('$base/${topic(secret)}/json?poll=1&since=10m'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      Map<String, dynamic>? latest;
      var latestId = '';
      for (final line in const LineSplitter().convert(utf8.decode(res.bodyBytes))) {
        if (line.trim().isEmpty) continue;
        final m = jsonDecode(line);
        if (m is! Map || m['event'] != 'message') continue;
        final decoded = jsonDecode(m['message'].toString());
        if (decoded is Map<String, dynamic>) {
          latest = decoded;
          latestId = m['id']?.toString() ?? '';
        }
      }
      if (latest == null || latestId == _lastMessageId) return null;
      _lastMessageId = latestId;
      return latest;
    } catch (_) {
      return null;
    }
  }

  void startPolling(
    String secret,
    void Function(Map<String, dynamic> snapshot) onSnapshot, {
    Duration every = const Duration(seconds: 5),
  }) {
    stop();
    Future<void> tick() async {
      final s = await fetchLatest(secret);
      if (s != null) onSnapshot(s);
    }

    unawaited(tick());
    _poll = Timer.periodic(every, (_) => tick());
  }

  void stop() {
    _poll?.cancel();
    _poll = null;
    _lastMessageId = '';
  }
}

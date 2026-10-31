import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'platform_types.dart';

class PlatformBridge {
  static bool get isWeb => false;
  static bool get isWindows => Platform.isWindows;
  static bool get isLinux => Platform.isLinux;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isAndroid => Platform.isAndroid;
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Map<String, String> get environment => Platform.environment;

  static String get homeDirectory {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
    }
    return Platform.environment['HOME'] ?? '';
  }

  static String get resolvedExecutable => Platform.resolvedExecutable;

  static Future<bool> fileExists(String path) async {
    if (path.isEmpty) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> directoryExists(String path) async {
    if (path.isEmpty) return false;
    try {
      return await Directory(path).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<String?> readFileString(String path) async {
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString(encoding: utf8);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> writeFileString(String path, String content) async {
    if (path.isEmpty) return false;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final tmpFile = File('$path.tmp_${DateTime.now().microsecondsSinceEpoch}');
      await tmpFile.writeAsString(content, encoding: utf8, flush: true);
      try {
        await tmpFile.rename(path);
      } catch (_) {
        await file.writeAsString(content, encoding: utf8, flush: true);
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> copyFile(String source, String destination) async {
    try {
      final src = File(source);
      if (!await src.exists()) return false;
      await File(destination).parent.create(recursive: true);
      await src.copy(destination);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<FileStatEntry>> listFilesRecursive(
    String dirPath, {
    String? extensionFilter,
    int maxFiles = 300,
  }) async {
    final results = <FileStatEntry>[];
    if (dirPath.isEmpty) return results;
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return results;
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          if (extensionFilter != null &&
              !entity.path.toLowerCase().endsWith(extensionFilter.toLowerCase())) {
            continue;
          }
          try {
            final stat = await entity.stat();
            results.add(
              FileStatEntry(
                path: entity.path,
                modified: stat.modified,
                size: stat.size,
              ),
            );
          } catch (_) {
            continue;
          }
        }
      }
    } catch (_) {
      // Ignore permission or missing directory errors
    }
    // Sort before truncating: listing order is arbitrary, newest files must survive the cap.
    results.sort((a, b) => b.modified.compareTo(a.modified));
    return results.length > maxFiles ? results.sublist(0, maxFiles) : results;
  }

  static Future<String?> whichExecutable(List<String> names) async {
    final pathEnv = Platform.environment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final dirs = pathEnv.split(separator).where((s) => s.trim().isNotEmpty);

    for (final name in names) {
      for (final dir in dirs) {
        final candidate = p.join(dir.trim(), name);
        final ext = p.extension(candidate).toLowerCase();
        if (ext == '.cmd' || ext == '.bat' || ext == '.ps1') {
          continue;
        }
        try {
          if (await File(candidate).exists()) {
            return candidate;
          }
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  static Future<String?> findNewestCodexBinary(String rootDir) async {
    if (rootDir.isEmpty) return null;
    try {
      final dir = Directory(rootDir);
      if (!await dir.exists()) return null;
      File? newest;
      DateTime? newestTime;
      await for (final sub in dir.list(followLinks: false)) {
        if (sub is Directory) {
          final exeName = Platform.isWindows ? 'codex.exe' : 'codex';
          final candidate = File(p.join(sub.path, exeName));
          if (await candidate.exists()) {
            final stat = await candidate.stat();
            if (newestTime == null || stat.modified.isAfter(newestTime)) {
              newest = candidate;
              newestTime = stat.modified;
            }
          }
        }
      }
      return newest?.path;
    } catch (_) {
      return null;
    }
  }

  static Future<ProcessResultData?> runProcess(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      return ProcessResultData(
        exitCode: result.exitCode,
        stdout: result.stdout?.toString() ?? '',
        stderr: result.stderr?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> spawnDetached(
    String executable,
    List<String> arguments,
  ) async {
    try {
      await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends an HTTPS POST to `https://127.0.0.1:{port}{path}` with self-signed loopback certificate support
  /// and proxy bypass (`DIRECT`), matching `antigravity_usage.py`.
  static Future<LoopbackHttpResponse?> postLoopbackHttpsJson(
    int port,
    String path,
    Map<String, dynamic> payload,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (port < 1 || port > 65535) return null;
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 2);
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback =
        (X509Certificate cert, String host, int p) => host == '127.0.0.1';
    try {
      final uri = Uri.parse('https://127.0.0.1:$port$path');
      final request = await client.postUrl(uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      headers.forEach((key, value) {
        request.headers.set(key, value);
      });
      final bodyBytes = utf8.encode(jsonEncode(payload));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(timeout);
      final chunks = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        chunks.addAll(chunk);
        if (chunks.length > 1024 * 1024) {
          break;
        }
      }
      final bodyStr = utf8.decode(chunks, allowMalformed: true);
      return LoopbackHttpResponse(
        statusCode: response.statusCode,
        body: bodyStr,
        contentLength: chunks.length,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Runs the Codex `app-server --stdio` JSON-RPC flow ported 1:1 from `codex_usage.py`.
  static Future<CodexRpcResult> runCodexAppServerRpc({
    String? binaryPath,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    String? binary = binaryPath;
    if (binary == null || binary.isEmpty) {
      binary = await whichExecutable(['codex.exe', 'codex']);
      if (binary == null) {
        final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
        if (localAppData.isNotEmpty) {
          binary = await findNewestCodexBinary(
            p.join(localAppData, 'OpenAI', 'Codex', 'bin'),
          );
        }
      }
    }
    if (binary == null || binary.isEmpty) {
      return const CodexRpcResult(
        errorMessage:
            'Codex wurde nicht gefunden. Bitte die offizielle Codex-App installieren und dort mit deinem ChatGPT-Abo anmelden.',
      );
    }

    Process? process;
    StreamSubscription<String>? sub;
    try {
      process = await Process.start(
        binary,
        [
          'app-server',
          '--stdio',
          '-c',
          'mcp_servers={}',
          '-c',
          'analytics.enabled=false',
        ],
      );

      final incoming = StreamController<Map<String, dynamic>?>();
      sub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.length > 1000000) return;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map<String, dynamic>) {
              incoming.add(decoded);
            } else if (decoded is Map) {
              incoming.add(Map<String, dynamic>.from(decoded));
            }
          } catch (_) {}
        },
        onError: (_) {},
        onDone: () {
          if (!incoming.isClosed) {
            incoming.add(null);
            incoming.close();
          }
        },
      );

      // Drain stderr silently
      process.stderr.drain<void>().ignore();

      final queue = <Map<String, dynamic>?>[];
      Completer<void>? waiter;
      incoming.stream.listen((msg) {
        queue.add(msg);
        if (waiter != null && !waiter!.isCompleted) {
          waiter!.complete();
        }
      });

      final deadline = DateTime.now().add(timeout);

      void send(Map<String, dynamic> message) {
        process?.stdin.writeln(jsonEncode(message));
      }

      Future<Map<String, dynamic>?> request(
        int id,
        String method, [
        Map<String, dynamic>? params,
      ]) async {
        final msg = <String, dynamic>{'id': id, 'method': method};
        if (params != null) {
          msg['params'] = params;
        }
        send(msg);

        while (true) {
          final remaining = deadline.difference(DateTime.now());
          if (remaining.isNegative) {
            throw const FormatException(
              'Codex antwortet derzeit nicht. Bitte später erneut aktualisieren.',
            );
          }
          if (queue.isEmpty) {
            waiter = Completer<void>();
            await waiter!.future.timeout(
              remaining,
              onTimeout: () => throw const FormatException(
                'Codex antwortet derzeit nicht. Bitte später erneut aktualisieren.',
              ),
            );
          }
          if (queue.isEmpty) continue;
          final response = queue.removeAt(0);
          if (response == null) {
            throw const FormatException(
              'Die Codex-Verbindung wurde beendet. Bitte Codex öffnen und erneut prüfen.',
            );
          }
          if (response['id'] == id && !response.containsKey('method')) {
            if (response['error'] != null) {
              throw const FormatException(
                'Codex konnte die Abo-Limits nicht abrufen. Bitte die Anmeldung in Codex prüfen und erneut aktualisieren.',
              );
            }
            final res = response['result'];
            if (res is Map) {
              return Map<String, dynamic>.from(res);
            }
            return null;
          }
          if (response.containsKey('id') && response.containsKey('method')) {
            send({
              'id': response['id'],
              'error': {'code': -32601, 'message': 'Usage-only client'},
            });
          }
        }
      }

      await request(0, 'initialize', {
        'clientInfo': {
          'name': 'syp_tokentracker',
          'title': 'Agent Lights',
          'version': '2.3.0',
        },
      });
      send({'method': 'initialized', 'params': <String, dynamic>{}});
      final account = await request(1, 'account/read', {'refreshToken': false});
      final identity = account?['account'];
      if (identity is! Map ||
          !(identity['type'] == 'chatgpt' ||
              identity['type'] == 'chatgptAuthTokens')) {
        return CodexRpcResult(account: account);
      }
      final rateLimits = await request(2, 'account/rateLimits/read');
      return CodexRpcResult(account: account, rateLimits: rateLimits);
    } on FormatException catch (e) {
      return CodexRpcResult(errorMessage: e.message);
    } catch (_) {
      return const CodexRpcResult(
        errorMessage:
            'Die lokale Codex-Verbindung ist nicht bereit. Bitte Codex öffnen und erneut prüfen.',
      );
    } finally {
      await sub?.cancel();
      if (process != null) {
        try {
          await process.stdin.close();
        } catch (_) {}
        process.kill();
      }
    }
  }
}

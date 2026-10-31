import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

typedef ProgressCallback = void Function(double progress, String status);

class UpdaterInstaller {
  static String get currentPlatformAssetKeyword {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    return 'unknown';
  }

  static List<String> get preferredAssetNames {
    if (Platform.isWindows) {
      return const [
        'AgentAmpel-windows-x64.zip',
        'AgentAmpel-windows-x64.exe',
      ];
    }
    if (Platform.isLinux) {
      return const [
        'AgentAmpel-linux-x64.tar.gz',
      ];
    }
    if (Platform.isMacOS) {
      return const [
        'AgentAmpel-macos.zip',
      ];
    }
    if (Platform.isAndroid) {
      return const [
        'AgentAmpel-android.apk',
      ];
    }
    return const [];
  }

  static Future<bool> downloadAndApplyUpdate({
    required String downloadUrl,
    required String assetName,
    required String releasePageUrl,
    required ProgressCallback onProgress,
  }) async {
    if (Platform.isAndroid) {
      return _handleAndroidUpdate(
        downloadUrl: downloadUrl,
        assetName: assetName,
        releasePageUrl: releasePageUrl,
        onProgress: onProgress,
      );
    }

    if (downloadUrl.isEmpty) {
      return _openReleaseUrlFallback(releasePageUrl, onProgress);
    }

    Directory? stagingDir;
    try {
      stagingDir = await Directory.systemTemp.createTemp('agent_ampel_update_');
      final safeFileName =
          assetName.isNotEmpty ? assetName : p.basename(Uri.parse(downloadUrl).path);
      final downloadedFile = File(p.join(stagingDir.path, safeFileName));

      onProgress(0.02, 'Lade Update herunter ($safeFileName)...');
      await _downloadFileWithProgress(
        url: downloadUrl,
        destination: downloadedFile,
        onProgress: (fraction) {
          final pct = (fraction * 100).clamp(0, 100).toStringAsFixed(0);
          onProgress(
            0.05 + (fraction * 0.75),
            'Lade Update herunter ($pct%)...',
          );
        },
      );

      if (!await downloadedFile.exists() || await downloadedFile.length() == 0) {
        onProgress(0.0, 'Download fehlgeschlagen (leere Datei).');
        return false;
      }

      if (Platform.isWindows) {
        return await _applyWindowsUpdate(
          downloadedFile: downloadedFile,
          stagingDir: stagingDir,
          onProgress: onProgress,
        );
      } else if (Platform.isLinux || Platform.isMacOS) {
        return await _applyUnixUpdate(
          downloadedFile: downloadedFile,
          stagingDir: stagingDir,
          onProgress: onProgress,
        );
      }

      return await _openReleaseUrlFallback(releasePageUrl, onProgress);
    } catch (e) {
      onProgress(0.0, 'Update-Fehler: $e');
      return false;
    }
  }

  static Future<void> _downloadFileWithProgress({
    required String url,
    required File destination,
    required void Function(double fraction) onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'AgentAmpel-AutoUpdater/1.0';
      request.headers['Accept'] = 'application/octet-stream, */*';
      final response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} beim Herunterladen von $url',
        );
      }

      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;
      final sink = destination.openWrite();

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0) {
            onProgress((receivedBytes / totalBytes).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      onProgress(1.0);
    } finally {
      client.close();
    }
  }

  static Future<bool> _applyWindowsUpdate({
    required File downloadedFile,
    required Directory stagingDir,
    required ProgressCallback onProgress,
  }) async {
    final currentExe = Platform.resolvedExecutable;
    final installDir = File(currentExe).parent.path;
    final currentPid = pid;
    final extractDir = Directory(p.join(stagingDir.path, 'extracted'));
    await extractDir.create(recursive: true);

    final lowerName = downloadedFile.path.toLowerCase();
    if (lowerName.endsWith('.zip')) {
      onProgress(0.85, 'Entpacke Windows-Update...');
      // Try built-in tar.exe first (fast on Windows 10/11), fallback to PowerShell Expand-Archive
      var extracted = false;
      try {
        final tarRes = await Process.run('tar.exe', [
          '-xf',
          downloadedFile.path,
          '-C',
          extractDir.path,
        ]);
        extracted = tarRes.exitCode == 0;
      } catch (_) {}

      if (!extracted) {
        final psRes = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          'Expand-Archive -LiteralPath "${downloadedFile.path}" -DestinationPath "${extractDir.path}" -Force',
        ]);
        if (psRes.exitCode != 0) {
          onProgress(0.0, 'Entpacken fehlgeschlagen: ${psRes.stderr}');
          return false;
        }
      }
    } else if (lowerName.endsWith('.exe')) {
      final targetExeName = p.basename(currentExe);
      await downloadedFile.copy(p.join(extractDir.path, targetExeName));
    }

    onProgress(0.92, 'Starte Windows-Updater-Skript...');

    final ps1File = File(p.join(stagingDir.path, 'update_ampel.ps1'));
    final batFile = File(p.join(stagingDir.path, 'update_ampel.bat'));

    final escapedExtractDir = extractDir.path.replaceAll("'", "''");
    final escapedInstallDir = installDir.replaceAll("'", "''");
    final escapedCurrentExe = currentExe.replaceAll("'", "''");

    final psScript = '''
\$ErrorActionPreference = 'SilentlyContinue'
\$targetPid = $currentPid
\$sourceDir = '$escapedExtractDir'
\$destDir = '$escapedInstallDir'
\$exePath = '$escapedCurrentExe'

for (\$i = 0; \$i -lt 30; \$i++) {
  \$proc = Get-Process -Id \$targetPid -ErrorAction SilentlyContinue
  if (\$null -eq \$proc) { break }
  Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 400

Copy-Item -Path "\$sourceDir\\*" -Destination \$destDir -Recurse -Force
Start-Process -FilePath \$exePath -WorkingDirectory \$destDir
''';

    await ps1File.writeAsString(psScript, flush: true);

    final batScript = '''
@echo off
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "${ps1File.path}"
''';
    await batFile.writeAsString(batScript, flush: true);

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        ps1File.path,
      ],
      mode: ProcessStartMode.detached,
    );

    onProgress(1.0, 'Update bereit – App wird neu gestartet...');
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      exit(0);
    });
    return true;
  }

  static Future<bool> _applyUnixUpdate({
    required File downloadedFile,
    required Directory stagingDir,
    required ProgressCallback onProgress,
  }) async {
    final currentExe = Platform.resolvedExecutable;
    final installDir = File(currentExe).parent.path;
    final currentPid = pid;
    final extractDir = Directory(p.join(stagingDir.path, 'extracted'));
    await extractDir.create(recursive: true);

    onProgress(0.85, 'Entpacke Update-Archiv...');
    final lowerName = downloadedFile.path.toLowerCase();
    if (lowerName.endsWith('.tar.gz') || lowerName.endsWith('.tgz')) {
      final res = await Process.run('tar', [
        '-xzf',
        downloadedFile.path,
        '-C',
        extractDir.path,
      ]);
      if (res.exitCode != 0) {
        onProgress(0.0, 'Entpacken fehlgeschlagen: ${res.stderr}');
        return false;
      }
    } else if (lowerName.endsWith('.zip')) {
      final res = await Process.run('unzip', [
        '-q',
        '-o',
        downloadedFile.path,
        '-d',
        extractDir.path,
      ]);
      if (res.exitCode != 0) {
        onProgress(0.0, 'Entpacken fehlgeschlagen: ${res.stderr}');
        return false;
      }
    } else {
      final targetName = p.basename(currentExe);
      await downloadedFile.copy(p.join(extractDir.path, targetName));
    }

    await Process.run('chmod', ['-R', '+x', extractDir.path]);

    onProgress(0.92, 'Starte Updater-Skript...');
    final shFile = File(p.join(stagingDir.path, 'update_ampel.sh'));
    final shScript = '''#!/bin/sh
TARGET_PID=$currentPid
SOURCE_DIR="${extractDir.path}"
DEST_DIR="$installDir"
EXE_PATH="$currentExe"

i=0
while [ \$i -lt 30 ]; do
  if ! kill -0 "\$TARGET_PID" 2>/dev/null; then
    break
  fi
  sleep 0.3
  i=\$((i + 1))
done

cp -Rf "\$SOURCE_DIR"/* "\$DEST_DIR"/ 2>/dev/null || true
chmod +x "\$EXE_PATH" 2>/dev/null || true
nohup "\$EXE_PATH" >/dev/null 2>&1 &
''';

    await shFile.writeAsString(shScript, flush: true);
    await Process.run('chmod', ['+x', shFile.path]);

    await Process.start(
      '/bin/sh',
      [shFile.path],
      mode: ProcessStartMode.detached,
    );

    onProgress(1.0, 'Update bereit – App wird neu gestartet...');
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      exit(0);
    });
    return true;
  }

  static Future<bool> _handleAndroidUpdate({
    required String downloadUrl,
    required String assetName,
    required String releasePageUrl,
    required ProgressCallback onProgress,
  }) async {
    final targetUrl = downloadUrl.isNotEmpty ? downloadUrl : releasePageUrl;
    if (targetUrl.isEmpty) {
      onProgress(0.0, 'Keine gültige Update-URL für Android gefunden.');
      return false;
    }

    onProgress(0.3, 'Öffne Android-Update ($assetName)...');
    final uri = Uri.tryParse(targetUrl);
    if (uri != null) {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        onProgress(1.0, 'Android-Update im System-Installer/Browser geöffnet.');
        return true;
      }
    }
    return _openReleaseUrlFallback(releasePageUrl, onProgress);
  }

  static Future<bool> _openReleaseUrlFallback(
    String releasePageUrl,
    ProgressCallback onProgress,
  ) async {
    if (releasePageUrl.isEmpty) return false;
    final uri = Uri.tryParse(releasePageUrl);
    if (uri == null) return false;
    onProgress(0.5, 'Öffne GitHub Release-Seite...');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (ok) {
      onProgress(1.0, 'GitHub Release-Seite geöffnet.');
    }
    return ok;
  }
}

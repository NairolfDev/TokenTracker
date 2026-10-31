import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../models/app_constants.dart';
import 'updater/updater_installer.dart';

class AutoUpdaterService extends ChangeNotifier {
  static const String githubOwner = AppConstants.githubOwner;
  static const String githubRepo = AppConstants.githubRepo;
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';
  static const String releasesHtmlUrl =
      'https://github.com/$githubOwner/$githubRepo/releases/latest';
  static const Duration checkInterval = Duration(minutes: 30);

  final http.Client _httpClient;
  final bool _ownsHttpClient;

  Timer? _periodicTimer;
  bool _initialized = false;

  bool _isChecking = false;
  bool _isDownloading = false;
  bool _updateAvailable = false;
  String _currentVersion = '1.0.0';
  String _latestVersion = '1.0.0';
  String _releaseUrl = releasesHtmlUrl;
  String _releaseNotes = '';
  String? _assetDownloadUrl;
  String? _assetName;
  double _downloadProgress = 0.0;
  String _statusMessage = 'Bereit für Update-Prüfung';
  String? _errorMessage;

  AutoUpdaterService({
    http.Client? httpClient,
    bool autoStart = true,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null {
    if (autoStart) {
      Future.microtask(() => initialize());
    }
  }

  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  bool get updateAvailable => _updateAvailable;
  String get currentVersion => _currentVersion;
  String get latestVersion => _latestVersion;
  String get releaseUrl => _releaseUrl;
  String get releaseNotes => _releaseNotes;
  String? get assetDownloadUrl => _assetDownloadUrl;
  String? get assetName => _assetName;
  double get downloadProgress => _downloadProgress;
  String get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;

  /// Initializes the service, loads the current package version, checks GitHub Releases
  /// on startup, and schedules a periodic check every 30 minutes.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _loadCurrentPackageVersion();
    unawaited(checkForUpdates(silent: true));

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(
      checkInterval,
      (_) => checkForUpdates(silent: true),
    );
  }

  /// Alias for [initialize].
  Future<void> init() => initialize();

  Future<void> _loadCurrentPackageVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.trim().isNotEmpty) {
        _currentVersion = normalizeVersion(info.version);
        if (_latestVersion == '1.0.0') {
          _latestVersion = _currentVersion;
        }
        notifyListeners();
      }
    } catch (_) {
      // Fallback to default version if PackageInfo is unavailable in unit tests
    }
  }

  /// Queries `https://api.github.com/repos/NairolfDev/AgentLights/releases/latest`
  /// and compares `tag_name` with the running app version using Semantic Versioning.
  Future<bool> checkForUpdates({bool silent = false}) async {
    if (_isChecking || _isDownloading) return _updateAvailable;

    _isChecking = true;
    _errorMessage = null;
    if (!silent) {
      _statusMessage = 'Prüfe auf Updates via GitHub Releases...';
    }
    notifyListeners();

    try {
      await _loadCurrentPackageVersion();

      final response = await _httpClient
          .get(
            Uri.parse(latestReleaseApiUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'AgentLights-AutoUpdater/1.0',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 404) {
        _updateAvailable = false;
        _statusMessage = 'Aktuell (Noch kein GitHub Release veröffentlicht)';
        return false;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _errorMessage = 'GitHub API HTTP ${response.statusCode}';
        if (!silent) {
          _statusMessage =
              'Update-Prüfung fehlgeschlagen (HTTP ${response.statusCode})';
        }
        return _updateAvailable;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        _errorMessage = 'Ungültige GitHub API Antwort';
        return _updateAvailable;
      }

      final payload = Map<String, dynamic>.from(decoded);
      final rawTag = (payload['tag_name'] ?? payload['name'] ?? '').toString();
      if (rawTag.trim().isEmpty) {
        _statusMessage = 'Kein Release-Tag gefunden';
        return false;
      }

      final normalizedLatest = normalizeVersion(rawTag);
      _latestVersion = normalizedLatest;
      _releaseUrl = (payload['html_url'] ?? releasesHtmlUrl).toString();
      _releaseNotes = (payload['body'] ?? '').toString();

      final assets = payload['assets'];
      _selectPlatformAsset(assets is List ? assets : const []);

      final newer = isNewerVersion(normalizedLatest, _currentVersion);
      _updateAvailable = newer;

      if (newer) {
        _statusMessage =
            'Update verfügbar: v$_latestVersion (aktuell v$_currentVersion)';
      } else {
        _statusMessage = 'Version v$_currentVersion ist auf dem neuesten Stand';
      }

      return _updateAvailable;
    } catch (e) {
      _errorMessage = e.toString();
      if (!silent) {
        _statusMessage = 'Update-Prüfung nicht möglich (Offline/Timeout)';
      }
      return _updateAvailable;
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  void _selectPlatformAsset(List<dynamic> assets) {
    _assetDownloadUrl = null;
    _assetName = null;
    if (assets.isEmpty) return;

    final preferredNames = UpdaterInstaller.preferredAssetNames;
    final parsedAssets = <Map<String, String>>[];

    for (final item in assets) {
      if (item is Map) {
        final name = (item['name'] ?? '').toString();
        final url = (item['browser_download_url'] ?? '').toString();
        if (name.isNotEmpty && url.isNotEmpty) {
          parsedAssets.add({'name': name, 'url': url});
        }
      }
    }

    // 1. Exact match against preferred platform asset names
    for (final pref in preferredNames) {
      for (final asset in parsedAssets) {
        if (asset['name']!.toLowerCase() == pref.toLowerCase()) {
          _assetName = asset['name'];
          _assetDownloadUrl = asset['url'];
          return;
        }
      }
    }

    // 2. Fallback keyword match for current platform
    final keyword = UpdaterInstaller.currentPlatformAssetKeyword.toLowerCase();
    for (final asset in parsedAssets) {
      if (asset['name']!.toLowerCase().contains(keyword)) {
        _assetName = asset['name'];
        _assetDownloadUrl = asset['url'];
        return;
      }
    }
  }

  /// Downloads the platform release asset and applies the update automatically.
  Future<bool> downloadAndInstallUpdate() async {
    if (_isDownloading) return false;

    _isDownloading = true;
    _downloadProgress = 0.0;
    _errorMessage = null;
    _statusMessage = 'Starte Update auf v$_latestVersion...';
    notifyListeners();

    try {
      final success = await UpdaterInstaller.downloadAndApplyUpdate(
        downloadUrl: _assetDownloadUrl ?? '',
        assetName: _assetName ?? '',
        releasePageUrl: _releaseUrl,
        onProgress: (progress, status) {
          _downloadProgress = progress.clamp(0.0, 1.0);
          _statusMessage = status;
          notifyListeners();
        },
      );

      if (!success && _errorMessage == null) {
        _errorMessage = _statusMessage;
      }
      return success;
    } catch (e) {
      _errorMessage = e.toString();
      _statusMessage = 'Update fehlgeschlagen: $e';
      return false;
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  /// Normalizes a version string (e.g. `v1.0.4+2` -> `1.0.4`).
  static String normalizeVersion(String raw) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
      cleaned = cleaned.substring(1).trim();
    }
    final plusIndex = cleaned.indexOf('+');
    if (plusIndex != -1) {
      cleaned = cleaned.substring(0, plusIndex);
    }
    return cleaned.isEmpty ? '0.0.0' : cleaned;
  }

  /// Returns `true` if [latestVersion] is strictly newer than [currentVersion].
  static bool isNewerVersion(String latestVersion, String currentVersion) {
    return compareSemVer(latestVersion, currentVersion) > 0;
  }

  /// Compares two semantic version strings (`> 0` if [v1] > [v2], `< 0` if [v1] < [v2], `0` if equal).
  static int compareSemVer(String v1, String v2) {
    final norm1 = normalizeVersion(v1);
    final norm2 = normalizeVersion(v2);

    final mainAndPre1 = norm1.split('-');
    final mainAndPre2 = norm2.split('-');

    final parts1 = mainAndPre1[0]
        .split('.')
        .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final parts2 = mainAndPre2[0]
        .split('.')
        .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();

    final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;
    for (var i = 0; i < maxLen; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 != p2) {
        return p1.compareTo(p2);
      }
    }

    // Stable release (no pre-release suffix) is newer than pre-release of same version
    final hasPre1 = mainAndPre1.length > 1 && mainAndPre1[1].isNotEmpty;
    final hasPre2 = mainAndPre2.length > 1 && mainAndPre2[1].isNotEmpty;
    if (!hasPre1 && hasPre2) return 1;
    if (hasPre1 && !hasPre2) return -1;
    if (hasPre1 && hasPre2) {
      return mainAndPre1[1].compareTo(mainAndPre2[1]);
    }
    return 0;
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    super.dispose();
  }
}

import 'package:url_launcher/url_launcher.dart';

typedef ProgressCallback = void Function(double progress, String status);

class UpdaterInstaller {
  static String get currentPlatformAssetKeyword => 'web';

  static List<String> get preferredAssetNames => const [
        'AgentLights-web.zip',
      ];

  static Future<bool> downloadAndApplyUpdate({
    required String downloadUrl,
    required String assetName,
    required String releasePageUrl,
    required ProgressCallback onProgress,
  }) async {
    onProgress(0.5, 'Öffne Release-Seite im Browser...');
    final uri = Uri.tryParse(
      releasePageUrl.isNotEmpty ? releasePageUrl : downloadUrl,
    );
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      onProgress(1.0, 'Release-Seite im Browser geöffnet.');
      return true;
    }
    return false;
  }
}

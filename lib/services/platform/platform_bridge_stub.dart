import 'platform_types.dart';

class PlatformBridge {
  static bool get isWeb => true;
  static bool get isWindows => false;
  static bool get isLinux => false;
  static bool get isMacOS => false;
  static bool get isAndroid => false;
  static bool get isDesktop => false;

  static Map<String, String> get environment => const {};

  static String get homeDirectory => '';

  static String get resolvedExecutable => '';

  static Future<bool> fileExists(String path) async => false;

  static Future<bool> directoryExists(String path) async => false;

  static Future<String?> readFileString(String path) async => null;

  static Future<bool> writeFileString(String path, String content) async =>
      false;

  static Future<bool> copyFile(String source, String destination) async =>
      false;

  static Future<List<FileStatEntry>> listFilesRecursive(
    String dirPath, {
    String? extensionFilter,
    int maxFiles = 300,
  }) async =>
      const [];

  static Future<String?> whichExecutable(List<String> names) async => null;

  static Future<String?> findNewestCodexBinary(String rootDir) async => null;

  static Future<ProcessResultData?> runProcess(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 12),
  }) async =>
      null;

  static Future<bool> spawnDetached(
    String executable,
    List<String> arguments,
  ) async =>
      false;

  static Future<LoopbackHttpResponse?> postLoopbackHttpsJson(
    int port,
    String path,
    Map<String, dynamic> payload,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      null;

  static Future<CodexRpcResult> runCodexAppServerRpc({
    String? binaryPath,
    Duration timeout = const Duration(seconds: 25),
  }) async =>
      const CodexRpcResult(
        errorMessage: 'Codex lokaler App-Server ist im Web nicht verfügbar.',
      );
}

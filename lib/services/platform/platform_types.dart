class FileStatEntry {
  final String path;
  final DateTime modified;
  final int size;

  const FileStatEntry({
    required this.path,
    required this.modified,
    required this.size,
  });
}

class ProcessResultData {
  final int exitCode;
  final String stdout;
  final String stderr;

  const ProcessResultData({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

class LoopbackHttpResponse {
  final int statusCode;
  final String body;
  final int contentLength;

  const LoopbackHttpResponse({
    required this.statusCode,
    required this.body,
    required this.contentLength,
  });
}

class CodexRpcResult {
  final Map<String, dynamic>? account;
  final Map<String, dynamic>? rateLimits;
  final String? errorMessage;

  const CodexRpcResult({
    this.account,
    this.rateLimits,
    this.errorMessage,
  });
}

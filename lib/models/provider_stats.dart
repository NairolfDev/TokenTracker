import 'usage_window.dart';

class MetricEntry {
  final String label;
  final String value;

  const MetricEntry(this.label, this.value);

  Map<String, String> toJson() => {'label': label, 'value': value};
}

class ProviderStats {
  String status;
  String value;
  String label;
  String detail;
  double? progress;
  List<MetricEntry> metrics;
  String checkedAt;
  bool authenticated;
  List<UsageWindow> windows;
  List<UsageWindow> subLimits;
  bool stale;
  String source;

  ProviderStats({
    this.status = 'ok',
    this.value = 'Verbunden',
    this.label = 'Kontostatus',
    this.detail = '',
    this.progress,
    List<MetricEntry>? metrics,
    String? checkedAt,
    this.authenticated = false,
    List<UsageWindow>? windows,
    List<UsageWindow>? subLimits,
    this.stale = false,
    this.source = '',
  })  : metrics = metrics ?? [],
        checkedAt = checkedAt ?? DateTime.now().toUtc().toIso8601String(),
        windows = windows ?? [],
        subLimits = subLimits ?? [];

  Map<String, dynamic> toJson() => {
        'status': status,
        'value': value,
        'label': label,
        'detail': detail,
        'progress': progress,
        'metrics': metrics.map((m) => m.toJson()).toList(),
        'checked_at': checkedAt,
        'authenticated': authenticated,
        'windows': windows.map((w) => w.toJson()).toList(),
        'sub_limits': subLimits.map((w) => w.toJson()).toList(),
        'stale': stale,
        'source': source,
      };
}

String _formatPercentValue(double value) {
  final rounded = (value * 100).round() / 100.0;
  if (rounded == rounded.roundToDouble()) {
    return rounded.round().toString();
  }
  var text = rounded.toStringAsFixed(2);
  while (text.contains('.') && (text.endsWith('0') || text.endsWith('.'))) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// Ported 1:1 from `subscription_usage.py::quota_stats(windows, source, authenticated=True)`.
ProviderStats quotaStats(
  List<UsageWindow> windows,
  String source, {
  bool authenticated = true,
  List<UsageWindow>? subLimits,
}) {
  final measured = windows
      .where((w) => w.usedPercent != null && !w.disabled)
      .toList();
  UsageWindow? tightest;
  for (final w in measured) {
    if (tightest == null ||
        (w.remainingPercent ?? 100.0) < (tightest.remainingPercent ?? 100.0)) {
      tightest = w;
    }
  }
  final exhausted = measured.any((w) => (w.remainingPercent ?? 100.0) == 0.0);
  final warning = measured.any((w) => (w.remainingPercent ?? 100.0) <= 10.0);

  final status = warning
      ? 'warning'
      : measured.isNotEmpty
          ? 'ok'
          : 'unverified';
  final value = tightest != null
      ? '${_formatPercentValue(tightest.remainingPercent!)}%'
      : '—';
  final label = tightest != null
      ? '${tightest.group.isNotEmpty ? "${tightest.group} · " : ""}${tightest.title} übrig'
      : 'Abo-Limits noch nicht gelesen';
  final detail = exhausted
      ? 'Mindestens ein Abo-Zeitfenster ist ausgeschöpft.'
      : 'Verbleibende Abo-Kapazität aus der Nutzungsübersicht. Die Prozentwerte sind keine feste Tokenanzahl.';

  return ProviderStats(
    status: status,
    value: value,
    label: label,
    detail: detail,
    progress: tightest != null ? (tightest.remainingPercent! / 100.0) : null,
    metrics: windows
        .map(
          (w) => MetricEntry(
            '${w.group.isNotEmpty ? "${w.group} · " : ""}${w.title} übrig',
            remainingLabel(w),
          ),
        )
        .toList(),
    authenticated: authenticated,
    windows: windows,
    subLimits: subLimits ?? List<UsageWindow>.from(windows),
    source: source,
  );
}

/// Ported 1:1 from `subscription_usage.py::empty_quota`.
ProviderStats emptyQuota(
  String source, {
  String detail = '',
  String status = 'unverified',
  bool authenticated = false,
  String? providerId,
}) {
  final windows = windowSpecs(providerId)
      .map((s) => UsageWindow(key: s.key, title: s.title, group: s.group))
      .toList();
  final result = quotaStats(windows, source, authenticated: authenticated);
  if (detail.isNotEmpty) {
    result.detail = detail;
  }
  result.status = status;
  return result;
}

/// Ported 1:1 from `subscription_usage.py::codex_usage(payload)`.
ProviderStats? codexUsage(Map<String, dynamic>? payload) {
  if (payload == null) return null;
  Map<String, dynamic>? snapshot;
  final buckets = payload['rateLimitsByLimitId'];
  if (buckets is Map) {
    final codexBucket = buckets['codex'];
    if (codexBucket is Map) {
      snapshot = Map<String, dynamic>.from(codexBucket);
    }
  }
  if (snapshot == null) {
    final rateLimits = payload['rateLimits'];
    if (rateLimits is Map) {
      snapshot = Map<String, dynamic>.from(rateLimits);
    }
  }
  if (snapshot == null) return null;
  final limitId = snapshot['limitId'];
  if (limitId != null && limitId != 'codex') {
    return null;
  }
  final titles = {for (final s in kStandardWindows) s.key: s.title};
  final reported = <String, UsageWindow>{};
  for (final name in const ['primary', 'secondary']) {
    final row = snapshot[name];
    if (row is! Map) continue;
    final duration = row['windowDurationMins'];
    final key = duration == 300
        ? 'five_hour'
        : duration == 10080
            ? 'seven_day'
            : null;
    if (key != null) {
      final used = parsePercent(row['usedPercent']);
      if (used != null) {
        reported[key] = UsageWindow(
          key: key,
          title: titles[key]!,
          usedPercent: used,
          resetsAt: resetIso(row['resetsAt']),
        );
      }
    }
  }
  if (reported.isEmpty) return null;
  final windows = kStandardWindows
      .map((s) => reported[s.key] ?? UsageWindow(key: s.key, title: s.title))
      .toList();
  final result = quotaStats(windows, 'Codex · ChatGPT-Abo');
  if (!reported.containsKey('five_hour')) {
    result.detail =
        'Codex meldet für dieses Konto kein 5-Stunden-Fenster. Das Wochenlimit wird separat angezeigt.';
  }
  return result;
}

/// Ported 1:1 from `observed_usage.py::claude_usage(payload)`.
ProviderStats? claudeUsage(Map<String, dynamic>? payload) {
  if (payload == null) return null;
  final windows = <UsageWindow>[];
  for (final spec in kStandardWindows) {
    final data = payload[spec.key];
    double? used;
    String? resets;
    if (data is Map) {
      used = parsePercent(data['utilization']);
      resets = resetIso(data['resets_at']);
    }
    windows.add(
      UsageWindow(
        key: spec.key,
        title: spec.title,
        usedPercent: used,
        resetsAt: resets,
      ),
    );
  }
  if (!windows.any((w) => w.usedPercent != null)) {
    return null;
  }
  return quotaStats(windows, 'Claude-Abo');
}

const Map<String, int> _kGeminiMonths = {
  'jan': 1,
  'feb': 2,
  'mär': 3,
  'märz': 3,
  'mar': 3,
  'apr': 4,
  'mai': 5,
  'may': 5,
  'jun': 6,
  'juni': 6,
  'jul': 7,
  'juli': 7,
  'aug': 8,
  'sep': 9,
  'sept': 9,
  'okt': 10,
  'oct': 10,
  'nov': 11,
  'dez': 12,
  'dec': 12,
};

/// Ported 1:1 from `gemini_usage.py::reset_at(text, key, now=None)`.
String? geminiResetAt(String text, String key, [DateTime? now]) {
  final current = (now ?? DateTime.now()).toLocal();
  final horizon = key == 'five_hour'
      ? const Duration(hours: 5, minutes: 1)
      : const Duration(days: 8);
  final patterns = [
    RegExp(
      r'Wird\s+(?:am\s+(\d{1,2})\.\s*([A-Za-zÄÖÜäöüß]+)\.?\s+)?um\s+(\d{1,2})[:.](\d{2})\s+zurückgesetzt',
      caseSensitive: false,
    ),
    RegExp(
      r'Resets?\s+(?:on\s+([A-Za-z]+)\.?\s+(\d{1,2}),?\s+)?at\s+(\d{1,2}):(\d{2})\s*(AM|PM)?',
      caseSensitive: false,
    ),
  ];

  for (var index = 0; index < patterns.length; index++) {
    final match = patterns[index].firstMatch(text);
    if (match == null) continue;
    final dayStr = index == 0 ? match.group(1) : match.group(2);
    final monthStr = index == 0 ? match.group(2) : match.group(1);
    var hour = int.tryParse(match.group(3) ?? '') ?? -1;
    final minute = int.tryParse(match.group(4) ?? '') ?? -1;
    final ampm = index == 1 ? match.group(5) : null;
    if (ampm != null && ampm.isNotEmpty) {
      if (hour < 1 || hour > 12) return null;
      hour = (hour % 12) + (ampm.toLowerCase() == 'pm' ? 12 : 0);
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }
    final candidates = <DateTime>[];
    if (dayStr != null && monthStr != null) {
      final monthNum = _kGeminiMonths[monthStr.toLowerCase()];
      final dayNum = int.tryParse(dayStr);
      if (monthNum == null || dayNum == null) return null;
      for (final year in [current.year - 1, current.year, current.year + 1]) {
        final dt = DateTime(year, monthNum, dayNum, hour, minute);
        if (dt.month == monthNum && dt.day == dayNum) {
          candidates.add(dt);
        }
      }
    } else {
      for (final offset in const [0, 1]) {
        final d = current.add(Duration(days: offset));
        candidates.add(DateTime(d.year, d.month, d.day, hour, minute));
      }
    }
    final future = candidates.where((dt) {
      final diff = dt.difference(current);
      return !diff.isNegative && diff <= horizon;
    }).toList();
    if (future.isNotEmpty) {
      future.sort();
      return future.first.toUtc().toIso8601String();
    }
    final elapsed = candidates.where((dt) {
      final diff = current.difference(dt);
      return !diff.isNegative && diff <= horizon;
    }).toList();
    if (elapsed.isNotEmpty) {
      elapsed.sort();
      return elapsed.last.toUtc().toIso8601String();
    }
    return null;
  }
  return null;
}

/// Ported 1:1 from `subscription_usage.py::page_usage(text, provider_id)`.
ProviderStats? pageUsage(String text, String providerId, [DateTime? now]) {
  const headings = {
    'claude': [
      r'Current session|Aktuelle Sitzung|5[- ](?:hour|Stunden)',
      r'All models|Alle Modelle|Weekly (?:limit|usage)|Wochenlimit',
    ],
    'gemini_chat': [
      r'Current usage|Aktuelle Nutzung|5[-\s\u2011\u2013](?:hour|Stunden)|five[- ]hour|Fünf[- ]Stunden',
      r'Weekly (?:limit|usage)|Weekly|Wöchentlich(?:es Limit)?|Wochenlimit|Woche',
    ],
  };
  final patterns = headings[providerId];
  if (patterns == null) return null;

  final found = <String, UsageWindow>{};
  for (var i = 0; i < kStandardWindows.length; i++) {
    final spec = kStandardWindows[i];
    final headingMatch =
        RegExp('(?:${patterns[i]})', caseSensitive: false).firstMatch(text);
    if (headingMatch == null) continue;
    final start = headingMatch.end;
    final end = (start + 350) < text.length ? (start + 350) : text.length;
    var segment = text.substring(start, end);
    final otherMatch = RegExp(
      '(?:${patterns[1 - i]})',
      caseSensitive: false,
    ).firstMatch(segment);
    if (otherMatch != null) {
      segment = segment.substring(0, otherMatch.start);
    }

    String? raw;
    String? direction;
    final valueMatch = RegExp(
      r'(\d{1,3}(?:[.,]\d+)?)\s*%\s*(used|verbraucht|genutzt|verwendet|remaining|left|übrig|verbleibend)',
      caseSensitive: false,
    ).firstMatch(segment);
    if (valueMatch != null) {
      raw = valueMatch.group(1);
      direction = valueMatch.group(2);
    } else {
      final altMatch = RegExp(
        r'(used|verbraucht|genutzt|verwendet|remaining|left|übrig|verbleibend)\s*[:\s]*(\d{1,3}(?:[.,]\d+)?)\s*%',
        caseSensitive: false,
      ).firstMatch(segment);
      if (altMatch == null) continue;
      direction = altMatch.group(1);
      raw = altMatch.group(2);
    }

    if (raw == null || direction == null) continue;
    var used = parsePercent(raw.replaceAll(',', '.'));
    if (used == null) continue;
    final dirLower = direction.toLowerCase();
    if (const ['remaining', 'left', 'übrig', 'verbleibend'].contains(dirLower)) {
      used = 100.0 - used;
    }

    String? resetsAt;
    if (providerId == 'gemini_chat') {
      resetsAt = geminiResetAt(segment, spec.key, now);
    }
    final resetMatch = RegExp(
      r'(?:resets? in|reset in|zurückgesetzt in)\s*([^\n]{1,70})',
      caseSensitive: false,
    ).firstMatch(segment);
    if (resetMatch != null) {
      final unitMatches = RegExp(
        r'(\d+)\s*(days?|hours?|hrs?|minutes?|mins?|Tage?n?|Stunden?|Minuten?)\b',
        caseSensitive: false,
      ).allMatches(resetMatch.group(1) ?? '');
      var seconds = 0;
      var hasUnits = false;
      for (final m in unitMatches) {
        hasUnits = true;
        final count = int.tryParse(m.group(1) ?? '0') ?? 0;
        final unit = (m.group(2) ?? '').toLowerCase();
        final multiplier = (unit.startsWith('day') || unit.startsWith('tag'))
            ? 86400
            : (unit.startsWith('hour') ||
                    unit.startsWith('hr') ||
                    unit.startsWith('stund'))
                ? 3600
                : 60;
        seconds += count * multiplier;
      }
      if (hasUnits && seconds > 0 && seconds <= 7 * 86400) {
        resetsAt = (now ?? DateTime.now())
            .toUtc()
            .add(Duration(seconds: seconds))
            .toIso8601String();
      }
    }

    found[spec.key] = UsageWindow(
      key: spec.key,
      title: spec.title,
      usedPercent: used,
      resetsAt: resetsAt,
    );
  }

  if (found.isEmpty) return null;
  final windows = kStandardWindows
      .map((s) => found[s.key] ?? UsageWindow(key: s.key, title: s.title))
      .toList();
  return quotaStats(
    windows,
    providerId == 'claude' ? 'Claude-Abo' : 'Gemini-Abo',
  );
}

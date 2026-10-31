class WindowSpec {
  final String key;
  final String title;
  final String group;

  const WindowSpec(this.key, this.title, [this.group = '']);
}

const List<WindowSpec> kStandardWindows = [
  WindowSpec('five_hour', '5 Stunden'),
  WindowSpec('seven_day', 'Woche'),
];

const List<WindowSpec> kAntigravityWindows = [
  WindowSpec('gemini_five_hour', '5 Stunden', 'Gemini'),
  WindowSpec('gemini_seven_day', 'Woche', 'Gemini'),
  WindowSpec('claude_gpt_five_hour', '5 Stunden', 'Claude / GPT'),
  WindowSpec('claude_gpt_seven_day', 'Woche', 'Claude / GPT'),
];

List<WindowSpec> windowSpecs([String? providerId]) {
  if (providerId == 'antigravity') {
    return kAntigravityWindows;
  }
  return kStandardWindows;
}

/// Validates and parses a percentage in [0, 100], matching Python `percent(value)`.
double? parsePercent(Object? value) {
  if (value == null || value is bool) return null;
  double? parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    parsed = double.tryParse(value.trim());
  }
  if (parsed == null || !parsed.isFinite || parsed < 0.0 || parsed > 100.0) {
    return null;
  }
  return parsed;
}

/// Converts epoch seconds or ISO-8601 strings to UTC ISO-8601 strings, matching Python `reset_iso(value)`.
String? resetIso(Object? value) {
  if (value == null || value is bool) return null;
  try {
    if (value is num) {
      final d = value.toDouble();
      if (!d.isFinite) return null;
      final millis = (d * 1000.0).round();
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
          .toIso8601String();
    }
    if (value is String) {
      final raw = value.trim();
      if (raw.isEmpty) return null;
      // Require an explicit timezone indicator (`Z` or `+HH:MM` / `-HH:MM`), matching Python `parsed.tzinfo is not None`.
      final hasTz = raw.endsWith('Z') ||
          raw.endsWith('z') ||
          RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(raw);
      if (!hasTz) return null;
      final dt = DateTime.parse(raw).toUtc();
      return dt.toIso8601String();
    }
  } catch (_) {
    return null;
  }
  return null;
}

String _formatPercentNumber(double value) {
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

class UsageWindow {
  final String key;
  final String title;
  final double? usedPercent;
  final String? resetsAt;
  final String group;
  final bool disabled;
  final String? customQuotaLabel;

  const UsageWindow({
    required this.key,
    required this.title,
    this.usedPercent,
    this.resetsAt,
    this.group = '',
    this.disabled = false,
    this.customQuotaLabel,
  });

  /// Matches Python `remaining_percent`: `None if used_percent is None or disabled else max(0, 100 - used_percent)`
  double? get remainingPercent {
    if (usedPercent == null || disabled) return null;
    final rem = 100.0 - usedPercent!;
    return rem < 0.0 ? 0.0 : (rem > 100.0 ? 100.0 : rem);
  }

  double get usedFraction {
    if (usedPercent == null || disabled) return 0.0;
    return (usedPercent! / 100.0).clamp(0.0, 1.0);
  }

  double get remainingFraction {
    if (usedPercent == null || disabled) return 0.0;
    return (1.0 - usedFraction).clamp(0.0, 1.0);
  }

  bool get isCritical {
    if (disabled || usedPercent == null) return false;
    return remainingFraction <= 0.10;
  }

  bool get isExhausted {
    if (disabled || usedPercent == null) return false;
    return remainingFraction <= 0.0;
  }

  /// Short window badge for compact HUD rings (`5h`, `Week`, `Month`, etc.).
  String get shortLabel {
    if (key.contains('five_hour') || key.endsWith('5h') || title == '5 Stunden') {
      if (group.isNotEmpty) {
        final shortGroup = group.startsWith('Claude') ? '3P' : 'Gem';
        return '$shortGroup·5h';
      }
      return '5h';
    }
    if (key.contains('seven_day') || key.endsWith('weekly') || title == 'Woche') {
      if (group.isNotEmpty) {
        final shortGroup = group.startsWith('Claude') ? '3P' : 'Gem';
        return '$shortGroup·Wk';
      }
      return 'Week';
    }
    if (key.contains('month') || title.toLowerCase().contains('monat')) {
      return 'Month';
    }
    return title.length > 8 ? title.substring(0, 8) : title;
  }

  String get fullTitle {
    if (group.isEmpty) return title;
    return '$group · $title';
  }

  String get remainingPercentLabel {
    final rem = remainingPercent;
    if (disabled) return 'Deaktiviert';
    if (rem == null) return '—';
    return '${rem.round()}%';
  }

  String get quotaLabel {
    if (customQuotaLabel != null && customQuotaLabel!.isNotEmpty) {
      return customQuotaLabel!;
    }
    return remainingLabel(this);
  }

  String resetCountdownLabel([DateTime? now]) {
    if (resetsAt == null || resetsAt!.isEmpty) {
      return 'Reset —';
    }
    try {
      final reset = DateTime.parse(resetsAt!).toLocal();
      final current = (now ?? DateTime.now()).toLocal();
      final diff = reset.difference(current);
      if (diff.inSeconds <= 0) {
        return 'Reset fällig';
      }
      if (diff.inHours < 24) {
        final hours = diff.inHours;
        final mins = diff.inMinutes.remainder(60);
        if (hours > 0) {
          return '${hours}h ${mins}m';
        }
        return '${mins}m';
      }
      final days = diff.inDays;
      final hours = diff.inHours.remainder(24);
      return '${days}d ${hours}h';
    } catch (_) {
      return 'Reset —';
    }
  }

  UsageWindow copyWith({
    String? key,
    String? title,
    double? usedPercent,
    String? resetsAt,
    String? group,
    bool? disabled,
    String? customQuotaLabel,
  }) {
    return UsageWindow(
      key: key ?? this.key,
      title: title ?? this.title,
      usedPercent: usedPercent ?? this.usedPercent,
      resetsAt: resetsAt ?? this.resetsAt,
      group: group ?? this.group,
      disabled: disabled ?? this.disabled,
      customQuotaLabel: customQuotaLabel ?? this.customQuotaLabel,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'used_percent': usedPercent,
        'remaining_percent': remainingPercent,
        'resets_at': resetsAt,
        'group': group,
        'disabled': disabled,
        if (customQuotaLabel != null) 'custom_quota_label': customQuotaLabel,
      };

  factory UsageWindow.fromJson(Map<String, dynamic> json) {
    final disabled = json['disabled'] == true;
    return UsageWindow(
      key: json['key']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      usedPercent: disabled ? null : parsePercent(json['used_percent']),
      resetsAt: resetIso(json['resets_at']),
      group: json['group']?.toString() ?? '',
      disabled: disabled,
      customQuotaLabel: json['custom_quota_label']?.toString(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UsageWindow &&
        other.key == key &&
        other.title == title &&
        other.usedPercent == usedPercent &&
        other.resetsAt == resetsAt &&
        other.group == group &&
        other.disabled == disabled;
  }

  @override
  int get hashCode =>
      Object.hash(key, title, usedPercent, resetsAt, group, disabled);
}

/// Ported 1:1 from `subscription_usage.py::remaining_label(window)`.
String remainingLabel(UsageWindow window) {
  if (window.disabled) {
    return 'Nicht verfügbar';
  }
  final remaining = window.remainingPercent;
  if (remaining == null) {
    return 'Nicht gemeldet';
  }
  return '${_formatPercentNumber(remaining)}% übrig';
}

/// Ported 1:1 from `subscription_usage.py::reset_label(window, now=None)`.
String resetLabel(UsageWindow window, [DateTime? now]) {
  if (window.resetsAt == null || window.resetsAt!.isEmpty) {
    return 'Reset nicht gemeldet';
  }
  try {
    final reset = DateTime.parse(window.resetsAt!).toLocal();
    final current = (now ?? DateTime.now()).toLocal();
    if (!reset.isAfter(current)) {
      return 'Reset fällig · aktualisieren';
    }
    final hh = reset.hour.toString().padLeft(2, '0');
    final mm = reset.minute.toString().padLeft(2, '0');
    final sameDay = reset.year == current.year &&
        reset.month == current.month &&
        reset.day == current.day;
    if (sameDay) {
      return 'Reset $hh:$mm';
    }
    final dd = reset.day.toString().padLeft(2, '0');
    final mo = reset.month.toString().padLeft(2, '0');
    return 'Reset $dd.$mo. $hh:$mm';
  } catch (_) {
    return 'Reset nicht gemeldet';
  }
}

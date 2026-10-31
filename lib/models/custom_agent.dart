import 'dart:convert';
import 'package:flutter/material.dart';
import 'usage_window.dart';

/// User-defined agent (Kimi, Grok, ...). Status arrives via `POST /api/hook` with `"agent": "<id>"`.
class CustomAgent {
  final String id;
  final String name;
  final int colorValue;

  /// Manual limits as "5h=40, Woche=12" (label=used percent), editable in settings.
  final String limits;

  const CustomAgent({
    required this.id,
    required this.name,
    required this.colorValue,
    this.limits = '',
  });

  Color get color => Color(colorValue);

  static String slug(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  List<UsageWindow> get windows => parseLimits(limits);

  static List<UsageWindow> parseLimits(String raw) {
    final out = <UsageWindow>[];
    for (final part in raw.split(',')) {
      final kv = part.split('=');
      final label = kv.first.trim();
      if (label.isEmpty) continue;
      out.add(UsageWindow(
        key: slug(label),
        title: label,
        usedPercent: kv.length > 1 ? parsePercent(kv[1].trim()) : null,
      ));
    }
    return out;
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'color': colorValue, 'limits': limits};

  factory CustomAgent.fromJson(Map<String, dynamic> j) => CustomAgent(
        id: j['id'].toString(),
        name: j['name'].toString(),
        colorValue: (j['color'] as num?)?.toInt() ?? 0xFF94A3B8,
        limits: j['limits']?.toString() ?? '',
      );

  static String encodeList(List<CustomAgent> l) =>
      jsonEncode(l.map((a) => a.toJson()).toList());

  static List<CustomAgent> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => CustomAgent.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

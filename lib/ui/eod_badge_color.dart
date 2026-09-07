import 'package:flutter/material.dart';

/// EOD badge color: red &lt;1h, orange &lt;3h, else blue (gray if passed/unknown).
Color eodBadgeColor(Duration? remaining) {
  if (remaining == null || remaining.isNegative) {
    return const Color(0xFF64748B);
  }
  if (remaining.inMinutes < 60) return const Color(0xFFDC2626);
  if (remaining.inMinutes < 3 * 60) return const Color(0xFFB45309);
  return const Color(0xFF2563EB);
}

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/services/station_temperature_api.dart';
import 'package:timezone/timezone.dart' as tz;

/// How a Polymarket temperature outcome label maps to settlement degrees.
enum TempBucketKind { exact, orBelow, orAbove, range }

class TempOutcomeBucket {
  const TempOutcomeBucket({
    required this.kind,
    required this.label,
    required this.unit,
    this.exact,
    this.lo,
    this.hi,
  });

  final TempBucketKind kind;
  final String label;
  final String unit; // `C` or `F`
  final double? exact;
  final double? lo;
  final double? hi;

  bool contains(double temp) {
    switch (kind) {
      case TempBucketKind.exact:
        return exact != null && (temp - exact!).abs() < 1e-9;
      case TempBucketKind.orBelow:
        return exact != null && temp <= exact! + 1e-9;
      case TempBucketKind.orAbove:
        return exact != null && temp >= exact! - 1e-9;
      case TempBucketKind.range:
        if (lo == null || hi == null) return false;
        return temp >= lo! - 1e-9 && temp <= hi! + 1e-9;
    }
  }
}

final _exactRe = RegExp(
  r'^\s*(-?\d+(?:\.\d+)?)\s*°?\s*([CF])\s*$',
  caseSensitive: false,
);
final _orBelowRe = RegExp(
  r'^\s*(-?\d+(?:\.\d+)?)\s*°?\s*([CF])\s+or\s+below\s*$',
  caseSensitive: false,
);
final _orAboveRe = RegExp(
  r'^\s*(-?\d+(?:\.\d+)?)\s*°?\s*([CF])\s+or\s+above\s*$',
  caseSensitive: false,
);
final _rangeRe = RegExp(
  r'^\s*(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)\s*°?\s*([CF])\s*$',
  caseSensitive: false,
);

/// Parse labels like `26°C`, `20°C or below`, `30°C or above`, `50-51°F`.
TempOutcomeBucket? parseTempOutcomeBucket(String label) {
  final raw = label.trim();
  if (raw.isEmpty) return null;

  final orBelow = _orBelowRe.firstMatch(raw);
  if (orBelow != null) {
    final v = double.tryParse(orBelow.group(1)!);
    if (v == null) return null;
    return TempOutcomeBucket(
      kind: TempBucketKind.orBelow,
      label: raw,
      unit: orBelow.group(2)!.toUpperCase(),
      exact: v,
    );
  }

  final orAbove = _orAboveRe.firstMatch(raw);
  if (orAbove != null) {
    final v = double.tryParse(orAbove.group(1)!);
    if (v == null) return null;
    return TempOutcomeBucket(
      kind: TempBucketKind.orAbove,
      label: raw,
      unit: orAbove.group(2)!.toUpperCase(),
      exact: v,
    );
  }

  final range = _rangeRe.firstMatch(raw);
  if (range != null) {
    final a = double.tryParse(range.group(1)!);
    final b = double.tryParse(range.group(2)!);
    if (a == null || b == null) return null;
    final lo = a <= b ? a : b;
    final hi = a <= b ? b : a;
    return TempOutcomeBucket(
      kind: TempBucketKind.range,
      label: raw,
      unit: range.group(3)!.toUpperCase(),
      lo: lo,
      hi: hi,
    );
  }

  final exact = _exactRe.firstMatch(raw);
  if (exact != null) {
    final v = double.tryParse(exact.group(1)!);
    if (v == null) return null;
    return TempOutcomeBucket(
      kind: TempBucketKind.exact,
      label: raw,
      unit: exact.group(2)!.toUpperCase(),
      exact: v,
    );
  }

  return null;
}

/// Min among observed points before dayEnd. No forecast fallback.
double? seriesObservedMin(DailyTemperatureSeries series) {
  double? minTemp;
  for (final p in series.points) {
    if (p.kind != TempPointKind.observed) continue;
    if (p.localHourStart.isAfter(series.dayEnd)) continue;
    if (minTemp == null || p.temperature < minTemp) {
      minTemp = p.temperature;
    }
  }
  return minTemp;
}

/// Max among observed points. No forecast fallback.
double? seriesObservedMax(DailyTemperatureSeries series) {
  double? maxTemp;
  for (final p in series.points) {
    if (p.kind != TempPointKind.observed) continue;
    if (p.localHourStart.isAfter(series.dayEnd)) continue;
    if (maxTemp == null || p.temperature > maxTemp) {
      maxTemp = p.temperature;
    }
  }
  return maxTemp;
}

double? seriesObservedExtremum(
  DailyTemperatureSeries series,
  TempMarketKind kind,
) =>
    kind == TempMarketKind.high
        ? seriesObservedMax(series)
        : seriesObservedMin(series);

/// Min among forecast points at/after [nowLocal].
double? seriesForecastRemainingMin(
  DailyTemperatureSeries series, {
  tz.TZDateTime? nowLocal,
}) {
  final now = nowLocal ?? series.nowLocal;
  double? minTemp;
  for (final p in series.points) {
    if (p.kind != TempPointKind.forecast) continue;
    if (p.localHourStart.isBefore(now)) continue;
    if (p.localHourStart.isAfter(series.dayEnd)) continue;
    if (minTemp == null || p.temperature < minTemp) {
      minTemp = p.temperature;
    }
  }
  return minTemp;
}

/// Max among forecast points at/after [nowLocal].
double? seriesForecastRemainingMax(
  DailyTemperatureSeries series, {
  tz.TZDateTime? nowLocal,
}) {
  final now = nowLocal ?? series.nowLocal;
  double? maxTemp;
  for (final p in series.points) {
    if (p.kind != TempPointKind.forecast) continue;
    if (p.localHourStart.isBefore(now)) continue;
    if (p.localHourStart.isAfter(series.dayEnd)) continue;
    if (maxTemp == null || p.temperature > maxTemp) {
      maxTemp = p.temperature;
    }
  }
  return maxTemp;
}

double? seriesForecastRemainingExtremum(
  DailyTemperatureSeries series,
  TempMarketKind kind, {
  tz.TZDateTime? nowLocal,
}) =>
    kind == TempMarketKind.high
        ? seriesForecastRemainingMax(series, nowLocal: nowLocal)
        : seriesForecastRemainingMin(series, nowLocal: nowLocal);

/// Physics-dead from current observed extremum (min for low, max for high).
bool isPhysicsDeadOutcome(
  TempOutcomeBucket bucket,
  double observedExtremum, {
  required TempMarketKind kind,
}) {
  if (kind == TempMarketKind.high) {
    switch (bucket.kind) {
      case TempBucketKind.exact:
        return bucket.exact != null && observedExtremum > bucket.exact!;
      case TempBucketKind.range:
        return bucket.hi != null && observedExtremum > bucket.hi!;
      case TempBucketKind.orBelow:
        return bucket.exact != null && observedExtremum > bucket.exact!;
      case TempBucketKind.orAbove:
        return false;
    }
  }

  switch (bucket.kind) {
    case TempBucketKind.exact:
      return bucket.exact != null && observedExtremum < bucket.exact!;
    case TempBucketKind.range:
      return bucket.lo != null && observedExtremum < bucket.lo!;
    case TempBucketKind.orBelow:
      return false;
    case TempBucketKind.orAbove:
      return bucket.exact != null && observedExtremum < bucket.exact!;
  }
}

bool outcomeMarketIsPhysicsDead(
  OutcomeMarket market,
  double observedExtremum, {
  required TempMarketKind kind,
}) {
  final bucket = parseTempOutcomeBucket(market.displayLabel);
  if (bucket == null) return false;
  return isPhysicsDeadOutcome(bucket, observedExtremum, kind: kind);
}

/// Alive bucket that contains [observedExtremum], else floor/ceiling bucket.
TempOutcomeBucket? leadingSettlementBucket(
  Iterable<OutcomeMarket> markets,
  double observedExtremum, {
  required TempMarketKind kind,
}) {
  final buckets = <TempOutcomeBucket>[];
  for (final m in markets) {
    final b = parseTempOutcomeBucket(m.displayLabel);
    if (b != null) buckets.add(b);
  }
  if (buckets.isEmpty) return null;

  for (final b in buckets) {
    if (isPhysicsDeadOutcome(b, observedExtremum, kind: kind)) continue;
    if (b.kind == TempBucketKind.exact && b.contains(observedExtremum)) {
      return b;
    }
    if (b.kind == TempBucketKind.range && b.contains(observedExtremum)) {
      return b;
    }
  }

  for (final b in buckets) {
    if (b.kind != TempBucketKind.exact || b.exact == null) continue;
    if (isPhysicsDeadOutcome(b, observedExtremum, kind: kind)) continue;
    if (observedExtremum >= b.exact! && observedExtremum < b.exact! + 1) {
      return b;
    }
  }

  if (kind == TempMarketKind.high) {
    TempOutcomeBucket? bestOrAbove;
    for (final b in buckets) {
      if (b.kind != TempBucketKind.orAbove || b.exact == null) continue;
      if (isPhysicsDeadOutcome(b, observedExtremum, kind: kind)) continue;
      if (!b.contains(observedExtremum) && observedExtremum < b.exact!) {
        continue;
      }
      if (bestOrAbove == null ||
          (b.exact != null &&
              bestOrAbove.exact != null &&
              b.exact! < bestOrAbove.exact!)) {
        bestOrAbove = b;
      }
    }
    if (bestOrAbove != null) return bestOrAbove;

    // High markets often use "D or below" as the cold floor of the ladder.
    TempOutcomeBucket? bestOrBelow;
    for (final b in buckets) {
      if (b.kind != TempBucketKind.orBelow || b.exact == null) continue;
      if (isPhysicsDeadOutcome(b, observedExtremum, kind: kind)) continue;
      if (bestOrBelow == null ||
          (b.exact != null &&
              bestOrBelow.exact != null &&
              b.exact! > bestOrBelow.exact!)) {
        bestOrBelow = b;
      }
    }
    return bestOrBelow;
  }

  TempOutcomeBucket? bestOrBelow;
  for (final b in buckets) {
    if (b.kind != TempBucketKind.orBelow || b.exact == null) continue;
    if (!b.contains(observedExtremum) && observedExtremum > b.exact!) {
      continue;
    }
    if (bestOrBelow == null ||
        (b.exact != null &&
            bestOrBelow.exact != null &&
            b.exact! > bestOrBelow.exact!)) {
      bestOrBelow = b;
    }
  }
  return bestOrBelow;
}

String formatTempOneDecimal(double temp) {
  final rounded = (temp * 10).roundToDouble() / 10;
  if ((rounded - rounded.roundToDouble()).abs() < 1e-9) {
    return rounded.round().toString();
  }
  return rounded.toStringAsFixed(1);
}

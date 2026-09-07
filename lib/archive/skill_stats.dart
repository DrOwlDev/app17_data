import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:timezone/timezone.dart' as tz;

/// Pair forecast rows to nearest observations and aggregate Polymarket-oriented
/// skill metrics (hourly + daily extremes + extrema timing).
class SkillStatsBuilder {
  SkillStatsBuilder({
    StationArchiveStore? store,
    this.matchWindow = const Duration(minutes: 30),
    this.toleranceC = 0.4,
    this.hitRateThreshold = 0.80,
    this.timingLookbackDays = 14,
  }) : store = store ?? StationArchiveStore();

  final StationArchiveStore store;
  final Duration matchWindow;
  final double toleranceC;
  final double hitRateThreshold;
  final int timingLookbackDays;

  Future<Map<String, dynamic>> buildAll() async {
    final stations = await store.readIndex();
    final summaries = <Map<String, dynamic>>[];
    final byStation = <String, dynamic>{};

    for (final station in stations) {
      final result = await buildForStation(station);
      if (result == null) continue;
      summaries.add(result['summary'] as Map<String, dynamic>);
      byStation[station.stationId] = result['skill'];
    }

    summaries.sort(
      (a, b) => (a['stationId'] as String).compareTo(b['stationId'] as String),
    );

    return {
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'toleranceC': toleranceC,
      'matchWindowMinutes': matchWindow.inMinutes,
      'hitRateThreshold': hitRateThreshold,
      'timingLookbackDays': timingLookbackDays,
      'stationCount': summaries.length,
      'stations': summaries,
      'byStation': byStation,
    };
  }

  Future<Map<String, dynamic>?> buildForStation(ArchiveStation station) async {
    final obs = await _loadObservations(station.stationId);
    if (obs.isEmpty) return null;

    final obsByMs = [
      for (final o in obs) (ms: o.ms, tempC: o.tempC),
    ];

    final pairs = <_Pair>[];
    final sources = <String, int>{};
    final forecastFiles = <SkillForecastSnapshot>[];

    final fcDir = store.forecastsDir(station.stationId);
    if (await fcDir.exists()) {
      for (final entity in fcDir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.csv')) continue;
        final rows = parseForecastCsv(await entity.readAsString());
        if (rows.isEmpty) continue;
        final issuedAtUtc = rows.first.issuedAtUtc;
        forecastFiles.add(
          SkillForecastSnapshot(issuedAtUtc: issuedAtUtc, rows: rows),
        );
        for (final row in rows) {
          final match = nearestObs(obsByMs, row.validMs, matchWindow);
          if (match == null) continue;
          final err = row.tempC - match.tempC;
          pairs.add(
            _Pair(
              leadHours: row.leadHours,
              errorC: err,
              forecastSource: row.source,
              validLocal: row.validLocal,
              issuedAtUtc: row.issuedAtUtc,
              forecastC: row.tempC,
              obsC: match.tempC,
            ),
          );
          sources[row.source] = (sources[row.source] ?? 0) + 1;
        }
      }
    }

    final dayStats = computeObservedDayStats(obs);
    final timing = computeExtremaTiming(
      dayStats,
      lookbackDays: timingLookbackDays,
    );
    final extremeSkill = computeDailyExtremeSkill(
      dayStats: dayStats,
      forecastFiles: forecastFiles,
      timeZone: station.timeZone,
      toleranceC: toleranceC,
      hitRateThreshold: hitRateThreshold,
    );

    if (pairs.isEmpty &&
        extremeSkill.minSkillByLead.isEmpty &&
        (timing['daysAnalyzed'] as int? ?? 0) == 0) {
      return null;
    }

    final skillByLead = <Map<String, dynamic>>[];
    if (pairs.isNotEmpty) {
      final bins = <int, _BinAcc>{};
      for (final p in pairs) {
        final leadBin = p.leadHours.floor().clamp(0, 72);
        bins.putIfAbsent(leadBin, _BinAcc.new).add(p.errorC);
      }
      final leadKeys = bins.keys.toList()..sort();
      for (final lead in leadKeys) {
        final b = bins[lead]!;
        skillByLead.add({
          'leadHours': lead,
          'n': b.n,
          'mae': b.mae,
          'rmse': b.rmse,
          'bias': b.bias,
          'hitRate': b.hitRate(toleranceC),
        });
      }
    }

    final timeToSkill = timeToSkillHours(
      skillByLead,
      toleranceC: toleranceC,
      hitRateThreshold: hitRateThreshold,
    );

    String? dominantSource;
    var maxSrc = 0;
    sources.forEach((k, v) {
      if (v > maxSrc) {
        maxSrc = v;
        dominantSource = k;
      }
    });

    double? maeAt(int lead) => _metricNear(skillByLead, lead, 'mae');
    double? hitAt(int lead) => _metricNear(skillByLead, lead, 'hitRate');

    final summary = <String, dynamic>{
      'stationId': station.stationId,
      'cityName': station.cityName,
      'sourceKind': station.sourceKind,
      'pairCount': pairs.length,
      'dominantForecastSource': dominantSource,
      'maeAt6h': maeAt(6),
      'maeAt24h': maeAt(24),
      'maeAt48h': maeAt(48),
      'hitAt6h': hitAt(6),
      'hitAt24h': hitAt(24),
      'hitAt48h': hitAt(48),
      'timeToSkillHours': timeToSkill,
      if (pairs.isNotEmpty)
        'overallMae': pairs.map((p) => p.errorC.abs()).reduce((a, b) => a + b) /
            pairs.length,
      if (pairs.isNotEmpty)
        'overallHitRate':
            pairs.where((p) => p.errorC.abs() <= toleranceC).length /
                pairs.length,
      'timeToSkillMinHours': extremeSkill.timeToSkillMinHours,
      'timeToSkillMaxHours': extremeSkill.timeToSkillMaxHours,
      'minBucketHitRate': extremeSkill.minBucketHitRate,
      'maxBucketHitRate': extremeSkill.maxBucketHitRate,
      'minExtremeHitRate': extremeSkill.minExtremeHitRate,
      'maxExtremeHitRate': extremeSkill.maxExtremeHitRate,
      'minBefore6amDays': timing['minBefore6amDays'],
      'minAfter6pmDays': timing['minAfter6pmDays'],
      'minMidDayDays': timing['minMidDayDays'],
      'minMorningShare': timing['minMorningShare'],
      'maxAfternoonShare': timing['maxAfternoonShare'],
      'minModeHour': timing['minModeHour'],
      'maxModeHour': timing['maxModeHour'],
      'minLockModeHour': timing['minLockModeHour'],
      'maxLockModeHour': timing['maxLockModeHour'],
      'timingDaysAnalyzed': timing['daysAnalyzed'],
    };

    final byValid = <String, List<_Pair>>{};
    for (final p in pairs) {
      byValid.putIfAbsent(p.validLocal, () => []).add(p);
    }
    final evolutionTargets = <Map<String, dynamic>>[];
    final sortedValids = byValid.keys.toList()..sort();
    for (final valid in sortedValids.reversed.take(48)) {
      final list = byValid[valid]!;
      if (list.length < 2) continue;
      list.sort((a, b) => a.issuedAtUtc.compareTo(b.issuedAtUtc));
      evolutionTargets.add({
        'validLocal': valid,
        'obsC': list.last.obsC,
        'points': [
          for (final p in list)
            {
              'issuedAtUtc': p.issuedAtUtc,
              'forecastC': p.forecastC,
              'leadHours': p.leadHours,
              'errorC': p.errorC,
            },
        ],
      });
      if (evolutionTargets.length >= 12) break;
    }

    return {
      'summary': summary,
      'skill': {
        'stationId': station.stationId,
        'cityName': station.cityName,
        'skillByLead': skillByLead,
        'timeToSkillHours': timeToSkill,
        'evolutionTargets': evolutionTargets,
        'extremeSkillByLeadMin': extremeSkill.minSkillByLead,
        'extremeSkillByLeadMax': extremeSkill.maxSkillByLead,
        'timeToSkillMinHours': extremeSkill.timeToSkillMinHours,
        'timeToSkillMaxHours': extremeSkill.timeToSkillMaxHours,
        'timing': timing,
      },
    };
  }

  Future<List<ObsSample>> _loadObservations(String stationId) async {
    final dir = store.observedDir(stationId);
    if (!await dir.exists()) return const [];
    final out = <ObsSample>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.csv')) continue;
      out.addAll(parseObservedCsv(await entity.readAsString()));
    }
    out.sort((a, b) => a.ms.compareTo(b.ms));
    return out;
  }
}

/// Observed sample with wall-clock fields from archive CSV `local_time`.
class ObsSample {
  const ObsSample({
    required this.ms,
    required this.tempC,
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.dateKey,
  });

  final int ms;
  final double tempC;
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final String dateKey;
}

class ForecastSkillRow {
  const ForecastSkillRow({
    required this.validLocal,
    required this.validMs,
    required this.tempC,
    required this.source,
    required this.issuedAtUtc,
    required this.leadHours,
    required this.dateKey,
  });

  final String validLocal;
  final int validMs;
  final double tempC;
  final String source;
  final String issuedAtUtc;
  final double leadHours;
  final String dateKey;
}

/// One forecast CSV snapshot used for daily extreme skill.
class SkillForecastSnapshot {
  const SkillForecastSnapshot({required this.issuedAtUtc, required this.rows});

  factory SkillForecastSnapshot.fromCsv(String body) {
    final rows = parseForecastCsv(body);
    if (rows.isEmpty) {
      return const SkillForecastSnapshot(issuedAtUtc: '', rows: []);
    }
    return SkillForecastSnapshot(
      issuedAtUtc: rows.first.issuedAtUtc,
      rows: rows,
    );
  }

  final String issuedAtUtc;
  final List<ForecastSkillRow> rows;
}

class _Pair {
  const _Pair({
    required this.leadHours,
    required this.errorC,
    required this.forecastSource,
    required this.validLocal,
    required this.issuedAtUtc,
    required this.forecastC,
    required this.obsC,
  });

  final double leadHours;
  final double errorC;
  final String forecastSource;
  final String validLocal;
  final String issuedAtUtc;
  final double forecastC;
  final double obsC;
}

class _BinAcc {
  int n = 0;
  double sumAbs = 0;
  double sumSq = 0;
  double sum = 0;
  final List<double> _absErrors = [];

  void add(double errorC) {
    n++;
    sumAbs += errorC.abs();
    sumSq += errorC * errorC;
    sum += errorC;
    _absErrors.add(errorC.abs());
  }

  double get mae => n == 0 ? 0 : sumAbs / n;
  double get rmse => n == 0 ? 0 : math.sqrt(sumSq / n);
  double get bias => n == 0 ? 0 : sum / n;
  double hitRate(double tol) =>
      n == 0 ? 0 : _absErrors.where((e) => e <= tol).length / n;
}

class DayExtremeStats {
  DayExtremeStats({
    required this.dateKey,
    required this.minC,
    required this.maxC,
    required this.minFirstHour,
    required this.minLockHour,
    required this.maxFirstHour,
    required this.maxLockHour,
  });

  final String dateKey;
  final double minC;
  final double maxC;
  final int minFirstHour;
  final int minLockHour;
  final int maxFirstHour;
  final int maxLockHour;
}

class ExtremeSkillResult {
  ExtremeSkillResult({
    required this.minSkillByLead,
    required this.maxSkillByLead,
    required this.timeToSkillMinHours,
    required this.timeToSkillMaxHours,
    required this.minExtremeHitRate,
    required this.maxExtremeHitRate,
    required this.minBucketHitRate,
    required this.maxBucketHitRate,
  });

  final List<Map<String, dynamic>> minSkillByLead;
  final List<Map<String, dynamic>> maxSkillByLead;
  final int? timeToSkillMinHours;
  final int? timeToSkillMaxHours;
  final double? minExtremeHitRate;
  final double? maxExtremeHitRate;
  final double? minBucketHitRate;
  final double? maxBucketHitRate;
}

/// Whole-°C Polymarket-style bucket (floor toward colder integer for display).
int tempBucketC(double tempC) => tempC.floor();

/// Hours from forecast issue time until local midnight ending [dateKey].
double? leadHoursBeforeLocalEod({
  required DateTime issuedUtc,
  required String dateKey,
  required String timeZone,
}) {
  final parts = dateKey.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  CityTimezones.ensureInitialized();
  late final tz.Location loc;
  try {
    loc = tz.getLocation(timeZone);
  } catch (_) {
    loc = tz.UTC;
  }
  final eodLocal = tz.TZDateTime(loc, y, m, d + 1);
  return eodLocal.toUtc().difference(issuedUtc.toUtc()).inMinutes / 60.0;
}

List<ObsSample> parseObservedCsv(String body) {
  final out = <ObsSample>[];
  for (final line in body.split(RegExp(r'\r?\n')).skip(1)) {
    if (line.trim().isEmpty) continue;
    final parts = splitCsvLine(line);
    if (parts.length < 2) continue;
    final parsed = parseLocalWallTime(parts[0]);
    final temp = double.tryParse(parts[1]);
    if (parsed == null || temp == null) continue;
    out.add(
      ObsSample(
        ms: parsed.ms,
        tempC: temp,
        year: parsed.year,
        month: parsed.month,
        day: parsed.day,
        hour: parsed.hour,
        minute: parsed.minute,
        dateKey: parsed.dateKey,
      ),
    );
  }
  return out;
}

List<ForecastSkillRow> parseForecastCsv(String body) {
  final rows = <ForecastSkillRow>[];
  for (final line in body.split(RegExp(r'\r?\n')).skip(1)) {
    if (line.trim().isEmpty) continue;
    final parts = splitCsvLine(line);
    if (parts.length < 5) continue;
    final wall = parseLocalWallTime(parts[0]);
    final temp = double.tryParse(parts[1]);
    final issued = DateTime.tryParse(parts[3]);
    final lead = double.tryParse(parts[4]);
    if (wall == null || temp == null || issued == null || lead == null) {
      continue;
    }
    rows.add(
      ForecastSkillRow(
        validLocal: parts[0],
        validMs: wall.ms,
        tempC: temp,
        source: parts[2],
        issuedAtUtc: issued.toUtc().toIso8601String(),
        leadHours: lead,
        dateKey: wall.dateKey,
      ),
    );
  }
  return rows;
}

({
  int ms,
  int year,
  int month,
  int day,
  int hour,
  int minute,
  String dateKey,
})? parseLocalWallTime(String raw) {
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.parse(m.group(4)!);
  final minute = int.parse(m.group(5)!);
  final second = int.tryParse(m.group(6) ?? '0') ?? 0;
  // Treat wall clock as a sortable epoch-like key (not real UTC).
  final ms = DateTime.utc(year, month, day, hour, minute, second)
      .millisecondsSinceEpoch;
  final dateKey =
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
  return (
    ms: ms,
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    dateKey: dateKey,
  );
}

({int ms, double tempC})? nearestObs(
  List<({int ms, double tempC})> obs,
  int validMs,
  Duration matchWindow,
) {
  if (obs.isEmpty) return null;
  var lo = 0;
  var hi = obs.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (obs[mid].ms < validMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  ({int ms, double tempC})? best;
  var bestDist = matchWindow.inMilliseconds + 1;
  for (final i in [lo - 1, lo, lo + 1]) {
    if (i < 0 || i >= obs.length) continue;
    final d = (obs[i].ms - validMs).abs();
    if (d < bestDist) {
      bestDist = d;
      best = obs[i];
    }
  }
  return best;
}

List<DayExtremeStats> computeObservedDayStats(List<ObsSample> obs) {
  final byDay = <String, List<ObsSample>>{};
  for (final o in obs) {
    byDay.putIfAbsent(o.dateKey, () => []).add(o);
  }
  final out = <DayExtremeStats>[];
  final keys = byDay.keys.toList()..sort();
  for (final key in keys) {
    final samples = byDay[key]!;
    if (samples.length < 4) continue;
    samples.sort((a, b) => a.ms.compareTo(b.ms));
    var minC = samples.first.tempC;
    var maxC = samples.first.tempC;
    for (final s in samples) {
      if (s.tempC < minC) minC = s.tempC;
      if (s.tempC > maxC) maxC = s.tempC;
    }
    int? minFirst;
    int? minLock;
    int? maxFirst;
    int? maxLock;
    for (final s in samples) {
      if ((s.tempC - minC).abs() < 1e-9) {
        minFirst ??= s.hour;
        minLock = s.hour;
      }
      if ((s.tempC - maxC).abs() < 1e-9) {
        maxFirst ??= s.hour;
        maxLock = s.hour;
      }
    }
    out.add(
      DayExtremeStats(
        dateKey: key,
        minC: minC,
        maxC: maxC,
        minFirstHour: minFirst ?? 0,
        minLockHour: minLock ?? 0,
        maxFirstHour: maxFirst ?? 0,
        maxLockHour: maxLock ?? 0,
      ),
    );
  }
  return out;
}

Map<String, dynamic> computeExtremaTiming(
  List<DayExtremeStats> days, {
  int lookbackDays = 14,
}) {
  final sorted = [...days]..sort((a, b) => a.dateKey.compareTo(b.dateKey));
  final window = sorted.length <= lookbackDays
      ? sorted
      : sorted.sublist(sorted.length - lookbackDays);
  if (window.isEmpty) {
    return {
      'daysAnalyzed': 0,
      'minBefore6amDays': 0,
      'minAfter6pmDays': 0,
      'minMidDayDays': 0,
      'minMorningShare': null,
      'maxAfternoonShare': null,
      'minModeHour': null,
      'maxModeHour': null,
      'minLockModeHour': null,
      'maxLockModeHour': null,
      'minFirstHourHist': List<int>.filled(24, 0),
      'minLockHourHist': List<int>.filled(24, 0),
      'maxFirstHourHist': List<int>.filled(24, 0),
      'maxLockHourHist': List<int>.filled(24, 0),
    };
  }

  var before6 = 0;
  var after18 = 0;
  var mid = 0;
  final minFirstHist = List<int>.filled(24, 0);
  final minLockHist = List<int>.filled(24, 0);
  final maxFirstHist = List<int>.filled(24, 0);
  final maxLockHist = List<int>.filled(24, 0);
  var maxAfternoon = 0;

  for (final d in window) {
    if (d.minFirstHour < 6) {
      before6++;
    } else if (d.minFirstHour >= 18) {
      after18++;
    } else {
      mid++;
    }
    minFirstHist[d.minFirstHour.clamp(0, 23)]++;
    minLockHist[d.minLockHour.clamp(0, 23)]++;
    maxFirstHist[d.maxFirstHour.clamp(0, 23)]++;
    maxLockHist[d.maxLockHour.clamp(0, 23)]++;
    if (d.maxFirstHour >= 12 && d.maxFirstHour < 18) maxAfternoon++;
  }

  int modeHour(List<int> hist) {
    var bestH = 0;
    var bestN = -1;
    for (var h = 0; h < 24; h++) {
      if (hist[h] > bestN) {
        bestN = hist[h];
        bestH = h;
      }
    }
    return bestH;
  }

  final n = window.length;
  return {
    'daysAnalyzed': n,
    'minBefore6amDays': before6,
    'minAfter6pmDays': after18,
    'minMidDayDays': mid,
    'minMorningShare': before6 / n,
    'maxAfternoonShare': maxAfternoon / n,
    'minModeHour': modeHour(minFirstHist),
    'maxModeHour': modeHour(maxFirstHist),
    'minLockModeHour': modeHour(minLockHist),
    'maxLockModeHour': modeHour(maxLockHist),
    'minFirstHourHist': minFirstHist,
    'minLockHourHist': minLockHist,
    'maxFirstHourHist': maxFirstHist,
    'maxLockHourHist': maxLockHist,
  };
}

ExtremeSkillResult computeDailyExtremeSkill({
  required List<DayExtremeStats> dayStats,
  required List<SkillForecastSnapshot> forecastFiles,
  required String timeZone,
  required double toleranceC,
  required double hitRateThreshold,
}) {
  final byDate = {for (final d in dayStats) d.dateKey: d};
  final minBins = <int, _BinAcc>{};
  final maxBins = <int, _BinAcc>{};
  var minHits = 0;
  var minN = 0;
  var maxHits = 0;
  var maxN = 0;
  var minBucketHits = 0;
  var maxBucketHits = 0;

  for (final file in forecastFiles) {
    final issued = DateTime.tryParse(file.issuedAtUtc);
    if (issued == null) continue;
    final byDayTemps = <String, List<double>>{};
    for (final row in file.rows) {
      byDayTemps.putIfAbsent(row.dateKey, () => []).add(row.tempC);
    }
    for (final entry in byDayTemps.entries) {
      final day = byDate[entry.key];
      if (day == null) continue;
      final leadH = leadHoursBeforeLocalEod(
        issuedUtc: issued.toUtc(),
        dateKey: entry.key,
        timeZone: timeZone,
      );
      if (leadH == null || leadH < 0) continue; // issued after day ended
      final leadBin = leadH.floor().clamp(0, 72);
      final temps = entry.value;
      final fcMin = temps.reduce(math.min);
      final fcMax = temps.reduce(math.max);
      final errMin = fcMin - day.minC;
      final errMax = fcMax - day.maxC;
      minBins.putIfAbsent(leadBin, _BinAcc.new).add(errMin);
      maxBins.putIfAbsent(leadBin, _BinAcc.new).add(errMax);
      minN++;
      maxN++;
      if (errMin.abs() <= toleranceC) minHits++;
      if (errMax.abs() <= toleranceC) maxHits++;
      if (tempBucketC(fcMin) == tempBucketC(day.minC)) minBucketHits++;
      if (tempBucketC(fcMax) == tempBucketC(day.maxC)) maxBucketHits++;
    }
  }

  List<Map<String, dynamic>> toRows(Map<int, _BinAcc> bins) {
    final keys = bins.keys.toList()..sort();
    return [
      for (final lead in keys)
        {
          'leadHours': lead,
          'n': bins[lead]!.n,
          'mae': bins[lead]!.mae,
          'rmse': bins[lead]!.rmse,
          'bias': bins[lead]!.bias,
          'hitRate': bins[lead]!.hitRate(toleranceC),
        },
    ];
  }

  final minRows = toRows(minBins);
  final maxRows = toRows(maxBins);
  return ExtremeSkillResult(
    minSkillByLead: minRows,
    maxSkillByLead: maxRows,
    timeToSkillMinHours: timeToSkillHours(
      minRows,
      toleranceC: toleranceC,
      hitRateThreshold: hitRateThreshold,
    ),
    timeToSkillMaxHours: timeToSkillHours(
      maxRows,
      toleranceC: toleranceC,
      hitRateThreshold: hitRateThreshold,
    ),
    minExtremeHitRate: minN == 0 ? null : minHits / minN,
    maxExtremeHitRate: maxN == 0 ? null : maxHits / maxN,
    minBucketHitRate: minN == 0 ? null : minBucketHits / minN,
    maxBucketHitRate: maxN == 0 ? null : maxBucketHits / maxN,
  );
}

int? timeToSkillHours(
  List<Map<String, dynamic>> skillByLead, {
  required double toleranceC,
  required double hitRateThreshold,
  int minN = 5,
}) {
  if (skillByLead.isEmpty) return null;
  final byLead = {
    for (final row in skillByLead) row['leadHours'] as int: row,
  };
  final maxLead = byLead.keys.reduce(math.max);
  int? best;
  for (var l = 0; l <= maxLead; l++) {
    var ok = true;
    var any = false;
    for (var h = 0; h <= l; h++) {
      final row = byLead[h];
      if (row == null) continue;
      final n = row['n'] as int;
      if (n < minN) continue;
      any = true;
      final hit = row['hitRate'] as double;
      final mae = row['mae'] as double;
      if (hit < hitRateThreshold && mae > toleranceC) {
        ok = false;
        break;
      }
    }
    if (any && ok) best = l;
  }
  return best;
}

double? _metricNear(List<Map<String, dynamic>> rows, int lead, String key) {
  Map<String, dynamic>? best;
  var bestDist = 1 << 30;
  for (final row in rows) {
    final d = ((row['leadHours'] as int) - lead).abs();
    if (d < bestDist) {
      bestDist = d;
      best = row;
    }
  }
  if (best == null || bestDist > 2) return null;
  return (best[key] as num?)?.toDouble();
}

List<String> splitCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

/// Write skill JSON + file browse manifest under data/.
Future<void> writeAnalysisOutputs({
  required Map<String, dynamic> skill,
  StationArchiveStore? store,
  Directory? analysisDir,
  Directory? dataRoot,
}) async {
  final stationsStore = store ?? StationArchiveStore();
  final root = dataRoot ?? Directory('data');
  final analysis = analysisDir ??
      Directory('${root.path}${Platform.pathSeparator}analysis');
  await analysis.create(recursive: true);

  final skillFile =
      File('${analysis.path}${Platform.pathSeparator}skill.json');
  await skillFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(skill),
  );

  final manifest = await buildBrowseManifest(stationsStore);
  final manifestFile =
      File('${analysis.path}${Platform.pathSeparator}files_manifest.json');
  await manifestFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest),
  );
}

Future<Map<String, dynamic>> buildBrowseManifest(
  StationArchiveStore store,
) async {
  final stations = await store.readIndex();
  final outStations = <Map<String, dynamic>>[];
  var fileCount = 0;

  for (final station in stations) {
    final files = <Map<String, dynamic>>[];
    Future<void> addDir(Directory dir, String kind, String relPrefix) async {
      if (!await dir.exists()) return;
      final entities = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in entities) {
        final name = f.uri.pathSegments.last;
        if (name == '.gitkeep') continue;
        final rel = 'stations/${station.stationId}/$relPrefix$name';
        files.add({
          'path': rel.replaceAll('\\', '/'),
          'name': name,
          'kind': kind,
          'bytes': await f.length(),
        });
        fileCount++;
      }
    }

    await addDir(store.observedDir(station.stationId), 'observed', 'observed/');
    await addDir(
      store.forecastsDir(station.stationId),
      'forecast',
      'forecasts/',
    );
    final extremes = store.dailyExtremesFile(station.stationId);
    if (await extremes.exists()) {
      files.add({
        'path': 'stations/${station.stationId}/daily_extremes.csv',
        'name': 'daily_extremes.csv',
        'kind': 'daily_extremes',
        'bytes': await extremes.length(),
      });
      fileCount++;
    }
    final meta = store.metaFile(station.stationId);
    if (await meta.exists()) {
      files.add({
        'path': 'stations/${station.stationId}/meta.json',
        'name': 'meta.json',
        'kind': 'meta',
        'bytes': await meta.length(),
      });
      fileCount++;
    }

    files.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    outStations.add({
      'stationId': station.stationId,
      'cityName': station.cityName,
      'sourceKind': station.sourceKind,
      'timeZone': station.timeZone,
      'files': files,
    });
  }

  return {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'stationCount': outStations.length,
    'fileCount': fileCount,
    'stations': outStations,
  };
}

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:app17_data/archive/station_archive.dart';

/// Pair forecast rows to nearest observations and aggregate skill metrics.
class SkillStatsBuilder {
  SkillStatsBuilder({
    StationArchiveStore? store,
    this.matchWindow = const Duration(minutes: 30),
    this.toleranceC = 0.5,
    this.hitRateThreshold = 0.80,
  }) : store = store ?? StationArchiveStore();

  final StationArchiveStore store;
  final Duration matchWindow;
  final double toleranceC;
  final double hitRateThreshold;

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
      'stationCount': summaries.length,
      'stations': summaries,
      'byStation': byStation,
    };
  }

  Future<Map<String, dynamic>?> buildForStation(ArchiveStation station) async {
    final obs = await _loadObservations(station.stationId);
    if (obs.isEmpty) return null;

    final pairs = <_Pair>[];
    final fcDir = store.forecastsDir(station.stationId);
    if (!await fcDir.exists()) return null;

    final sources = <String, int>{};
    for (final entity in fcDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.csv')) continue;
      final rows = await _parseForecastCsv(await entity.readAsString());
      for (final row in rows) {
        final match = _nearestObs(obs, row.validMs);
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

    if (pairs.isEmpty) return null;

    final bins = <int, _BinAcc>{};
    for (final p in pairs) {
      final leadBin = p.leadHours.floor().clamp(0, 72);
      final bin = bins.putIfAbsent(leadBin, _BinAcc.new);
      bin.add(p.errorC);
    }

    final skillByLead = <Map<String, dynamic>>[];
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

    final timeToSkill = _timeToSkill(skillByLead);
    String? dominantSource;
    var maxSrc = 0;
    sources.forEach((k, v) {
      if (v > maxSrc) {
        maxSrc = v;
        dominantSource = k;
      }
    });

    double? maeAt(int lead) => _maeNear(skillByLead, lead);
    double? hitAt(int lead) => _hitNear(skillByLead, lead);

    final summary = {
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
      'overallMae': pairs.map((p) => p.errorC.abs()).reduce((a, b) => a + b) /
          pairs.length,
      'overallHitRate':
          pairs.where((p) => p.errorC.abs() <= toleranceC).length /
              pairs.length,
    };

    // Sample evolution targets: distinct valid hours that have obs + ≥2 issues.
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
      },
    };
  }

  int? _timeToSkill(List<Map<String, dynamic>> skillByLead) {
    if (skillByLead.isEmpty) return null;
    // Find smallest L such that for all bins with leadHours <= L that have
    // enough samples, hitRate >= threshold OR mae <= tolerance.
    const minN = 5;
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

  double? _maeNear(List<Map<String, dynamic>> rows, int lead) {
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
    return best['mae'] as double?;
  }

  double? _hitNear(List<Map<String, dynamic>> rows, int lead) {
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
    return best['hitRate'] as double?;
  }

  Future<List<({int ms, double tempC})>> _loadObservations(
    String stationId,
  ) async {
    final dir = store.observedDir(stationId);
    if (!await dir.exists()) return const [];
    final out = <({int ms, double tempC})>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.csv')) continue;
      final body = await entity.readAsString();
      for (final line in body.split(RegExp(r'\r?\n')).skip(1)) {
        if (line.trim().isEmpty) continue;
        final parts = _splitCsv(line);
        if (parts.length < 2) continue;
        final t = DateTime.tryParse(parts[0]);
        final temp = double.tryParse(parts[1]);
        if (t == null || temp == null) continue;
        out.add((ms: t.millisecondsSinceEpoch, tempC: temp));
      }
    }
    out.sort((a, b) => a.ms.compareTo(b.ms));
    return out;
  }

  ({int ms, double tempC})? _nearestObs(
    List<({int ms, double tempC})> obs,
    int validMs,
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

  Future<List<_FcRow>> _parseForecastCsv(String body) async {
    final rows = <_FcRow>[];
    for (final line in body.split(RegExp(r'\r?\n')).skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = _splitCsv(line);
      if (parts.length < 5) continue;
      final valid = DateTime.tryParse(parts[0]);
      final temp = double.tryParse(parts[1]);
      final issued = DateTime.tryParse(parts[3]);
      final lead = double.tryParse(parts[4]);
      if (valid == null || temp == null || issued == null || lead == null) {
        continue;
      }
      rows.add(
        _FcRow(
          validLocal: parts[0],
          validMs: valid.millisecondsSinceEpoch,
          tempC: temp,
          source: parts[2],
          issuedAtUtc: issued.toUtc().toIso8601String(),
          leadHours: lead,
        ),
      );
    }
    return rows;
  }
}

List<String> _splitCsv(String line) {
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

class _FcRow {
  const _FcRow({
    required this.validLocal,
    required this.validMs,
    required this.tempC,
    required this.source,
    required this.issuedAtUtc,
    required this.leadHours,
  });

  final String validLocal;
  final int validMs;
  final double tempC;
  final String source;
  final String issuedAtUtc;
  final double leadHours;
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
        final rel =
            'stations/${station.stationId}/$relPrefix$name';
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

import 'dart:io';

import 'package:app17_data/archive/station_archive.dart';

/// Delete observed day CSVs and forecast snapshots older than [retainDays].
/// Also drops stale rows from `daily_extremes.csv`.
class ArchivePruner {
  ArchivePruner({
    StationArchiveStore? store,
    this.retainDays = 90,
    DateTime? nowUtc,
  })  : store = store ?? StationArchiveStore(),
        nowUtc = nowUtc ?? DateTime.now().toUtc();

  final StationArchiveStore store;
  final int retainDays;
  final DateTime nowUtc;

  DateTime get cutoffDate {
    final c = nowUtc.subtract(Duration(days: retainDays));
    return DateTime.utc(c.year, c.month, c.day);
  }

  Future<({int deletedFiles, int prunedExtremeRows})> pruneAll() async {
    final stations = await store.readIndex();
    var deleted = 0;
    var extremeRows = 0;
    final ids = stations.map((s) => s.stationId).toList();
    if (ids.isEmpty) {
      // Still scan directories under root if index missing.
      if (await store.root.exists()) {
        for (final entity in store.root.listSync()) {
          if (entity is Directory) {
            final name = entity.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last;
            if (name == 'index.json') continue;
            ids.add(name);
          }
        }
      }
    }

    for (final id in ids.toSet()) {
      deleted += await _pruneObserved(id);
      deleted += await _pruneForecasts(id);
      extremeRows += await _pruneDailyExtremes(id);
    }
    return (deletedFiles: deleted, prunedExtremeRows: extremeRows);
  }

  Future<int> _pruneObserved(String stationId) async {
    final dir = store.observedDir(stationId);
    if (!await dir.exists()) return 0;
    var deleted = 0;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\.csv$').firstMatch(name);
      if (m == null) continue;
      final day = DateTime.utc(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
      if (day.isBefore(cutoffDate)) {
        await entity.delete();
        deleted++;
      }
    }
    return deleted;
  }

  Future<int> _pruneForecasts(String stationId) async {
    final dir = store.forecastsDir(stationId);
    if (!await dir.exists()) return 0;
    var deleted = 0;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final issued = parseForecastFilenameUtc(name);
      if (issued == null) continue;
      final issuedDay = DateTime.utc(issued.year, issued.month, issued.day);
      if (issuedDay.isBefore(cutoffDate)) {
        await entity.delete();
        deleted++;
      }
    }
    return deleted;
  }

  Future<int> _pruneDailyExtremes(String stationId) async {
    final file = store.dailyExtremesFile(stationId);
    if (!await file.exists()) return 0;
    final body = await file.readAsString();
    final lines = body.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return 0;
    final kept = <String>[];
    var removed = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (i == 0 || line.trim().isEmpty) {
        if (i == 0) kept.add(line);
        continue;
      }
      final dateStr = line.split(',').first.trim();
      final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateStr);
      if (m == null) {
        kept.add(line);
        continue;
      }
      final day = DateTime.utc(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
      if (day.isBefore(cutoffDate)) {
        removed++;
        continue;
      }
      kept.add(line);
    }
    if (removed > 0) {
      final out = StringBuffer();
      for (var i = 0; i < kept.length; i++) {
        out.writeln(kept[i]);
      }
      await file.writeAsString(out.toString());
    }
    return removed;
  }
}

/// Parse `YYYYMMDDTHHMMZ.csv` forecast snapshot filenames.
DateTime? parseForecastFilenameUtc(String name) {
  final m =
      RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})Z\.csv$').firstMatch(name);
  if (m == null) return null;
  return DateTime.utc(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
  );
}

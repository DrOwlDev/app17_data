import 'dart:convert';
import 'dart:io';

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/station_temperature_api.dart';
import 'package:timezone/timezone.dart' as tz;

/// One unique resolution station derived from Polymarket temperature markets.
class ArchiveStation {
  const ArchiveStation({
    required this.stationId,
    required this.cityName,
    required this.timeZone,
    required this.resolutionUrl,
    required this.sourceKind,
    this.countryCode,
  });

  /// ICAO (e.g. ZGGG) or `HKO`.
  final String stationId;
  final String cityName;
  final String timeZone;
  final String resolutionUrl;

  /// `hko` | `wrh` | `wu` | `icao`
  final String sourceKind;
  final String? countryCode;

  Map<String, dynamic> toJson() => {
        'stationId': stationId,
        'cityName': cityName,
        'timeZone': timeZone,
        'resolutionUrl': resolutionUrl,
        'sourceKind': sourceKind,
        if (countryCode != null) 'countryCode': countryCode,
      };

  factory ArchiveStation.fromJson(Map<String, dynamic> json) {
    return ArchiveStation(
      stationId: json['stationId']?.toString() ?? '',
      cityName: json['cityName']?.toString() ?? '',
      timeZone: json['timeZone']?.toString() ?? 'UTC',
      resolutionUrl: json['resolutionUrl']?.toString() ?? '',
      sourceKind: json['sourceKind']?.toString() ?? 'icao',
      countryCode: json['countryCode']?.toString(),
    );
  }

  tz.Location get location {
    try {
      return tz.getLocation(timeZone);
    } catch (_) {
      return CityTimezones.locationForCity(cityName) ?? tz.UTC;
    }
  }
}

/// Build unique chartable stations from Gamma temperature events.
List<ArchiveStation> stationsFromEvents(List<MarketEvent> events) {
  final byId = <String, ArchiveStation>{};
  for (final event in events) {
    if (!isChartableTemperatureSource(event)) continue;
    final hko = hongKongOcfStationId(event);
    final icao = metarStationIcaoForEvent(event);
    final stationId = hko ?? icao;
    if (stationId == null || stationId.isEmpty) continue;

    final url = event.resolutionSourceUrl ??
        event.resolutionSourceOpenUrl ??
        '';
    final location = CityTimezones.locationForCity(event.cityName) ?? tz.UTC;
    final String sourceKind;
    if (hko != null) {
      sourceKind = 'hko';
    } else if (weatherGovTimeseriesSiteId(event.resolutionSourceOpenUrl) !=
            null ||
        weatherGovTimeseriesSiteId(event.resolutionSourceUrl) != null) {
      sourceKind = 'wrh';
    } else if (weatherUndergroundHistoryIcao(event.resolutionSourceOpenUrl) !=
            null ||
        weatherUndergroundHistoryIcao(event.resolutionSourceUrl) != null) {
      sourceKind = 'wu';
    } else {
      sourceKind = 'icao';
    }

    final country = weatherUndergroundHistoryCountry(
          event.resolutionSourceOpenUrl,
        ) ??
        weatherUndergroundHistoryCountry(event.resolutionSourceUrl);

    // Prefer keeping the first city name we saw; refresh URL if empty.
    final existing = byId[stationId];
    if (existing == null) {
      byId[stationId] = ArchiveStation(
        stationId: stationId,
        cityName: event.cityName,
        timeZone: location.name,
        resolutionUrl: url,
        sourceKind: sourceKind,
        countryCode: country,
      );
    } else if (existing.resolutionUrl.isEmpty && url.isNotEmpty) {
      byId[stationId] = ArchiveStation(
        stationId: existing.stationId,
        cityName: existing.cityName,
        timeZone: existing.timeZone,
        resolutionUrl: url,
        sourceKind: existing.sourceKind,
        countryCode: existing.countryCode ?? country,
      );
    }
  }
  final list = byId.values.toList()
    ..sort((a, b) => a.stationId.compareTo(b.stationId));
  return list;
}

/// File-system layout under `data/stations/`.
class StationArchiveStore {
  StationArchiveStore({Directory? root})
      : root = root ?? Directory('data/stations');

  final Directory root;

  Directory stationDir(String stationId) =>
      Directory('${root.path}${Platform.pathSeparator}$stationId');

  File indexFile() => File('${root.path}${Platform.pathSeparator}index.json');

  File metaFile(String stationId) => File(
        '${stationDir(stationId).path}${Platform.pathSeparator}meta.json',
      );

  Directory observedDir(String stationId) => Directory(
        '${stationDir(stationId).path}${Platform.pathSeparator}observed',
      );

  Directory forecastsDir(String stationId) => Directory(
        '${stationDir(stationId).path}${Platform.pathSeparator}forecasts',
      );

  File dailyExtremesFile(String stationId) => File(
        '${stationDir(stationId).path}${Platform.pathSeparator}daily_extremes.csv',
      );

  File observedDayFile(String stationId, DateTime localDate) {
    final y = localDate.year.toString().padLeft(4, '0');
    final m = localDate.month.toString().padLeft(2, '0');
    final d = localDate.day.toString().padLeft(2, '0');
    return File(
      '${observedDir(stationId).path}${Platform.pathSeparator}$y-$m-$d.csv',
    );
  }

  File forecastSnapshotFile(String stationId, DateTime issuedAtUtc) {
    final stamp = _utcStamp(issuedAtUtc);
    return File(
      '${forecastsDir(stationId).path}${Platform.pathSeparator}$stamp.csv',
    );
  }

  Future<void> ensureStationDirs(String stationId) async {
    await observedDir(stationId).create(recursive: true);
    await forecastsDir(stationId).create(recursive: true);
  }

  Future<void> writeIndex(List<ArchiveStation> stations) async {
    await root.create(recursive: true);
    final payload = {
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'stationCount': stations.length,
      'stations': stations.map((s) => s.toJson()).toList(),
    };
    await indexFile().writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    for (final s in stations) {
      await ensureStationDirs(s.stationId);
      await metaFile(s.stationId).writeAsString(
        const JsonEncoder.withIndent('  ').convert(s.toJson()),
      );
    }
  }

  Future<List<ArchiveStation>> readIndex() async {
    final file = indexFile();
    if (!await file.exists()) return const [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return const [];
    final raw = decoded['stations'];
    if (raw is! List) return const [];
    final out = <ArchiveStation>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        out.add(ArchiveStation.fromJson(item));
      } else if (item is Map) {
        out.add(ArchiveStation.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    return out;
  }
}

const observedCsvHeader =
    'local_time,temp_c,data_source,collected_at_utc';
const dailyExtremesCsvHeader =
    'date,obs_min_c,obs_max_c,sample_count,updated_at_utc';
const forecastCsvHeader =
    'valid_local_time,temp_c,forecast_source,issued_at_utc,lead_hours';

/// Merge [incoming] into an existing observed day CSV (dedupe by local_time).
String mergeObservedCsv({
  required String? existingCsv,
  required List<TempObservationSample> incoming,
  required DateTime collectedAtUtc,
}) {
  final byTime = <String, _ObsRow>{};
  if (existingCsv != null && existingCsv.trim().isNotEmpty) {
    for (final row in _parseDataRows(existingCsv)) {
      if (row.length < 4) continue;
      byTime[row[0]] = _ObsRow(
        localTime: row[0],
        tempC: row[1],
        dataSource: row[2],
        collectedAtUtc: row[3],
      );
    }
  }
  final collected = collectedAtUtc.toIso8601String();
  for (final sample in incoming) {
    final key = _formatLocal(sample.localTime);
    byTime[key] = _ObsRow(
      localTime: key,
      tempC: _formatTemp(sample.tempC),
      dataSource: _escapeCsv(sample.dataSource),
      collectedAtUtc: collected,
    );
  }
  final keys = byTime.keys.toList()..sort();
  final buf = StringBuffer()..writeln(observedCsvHeader);
  for (final k in keys) {
    final r = byTime[k]!;
    buf.writeln(
      '${r.localTime},${r.tempC},${r.dataSource},${r.collectedAtUtc}',
    );
  }
  return buf.toString();
}

/// Recompute daily extremes for one local calendar date from observed CSV body.
({double? minC, double? maxC, int count}) extremesFromObservedCsv(
  String csvBody,
) {
  double? minC;
  double? maxC;
  var count = 0;
  for (final row in _parseDataRows(csvBody)) {
    if (row.length < 2) continue;
    final t = double.tryParse(row[1]);
    if (t == null) continue;
    count++;
    final curMin = minC;
    final curMax = maxC;
    minC = curMin == null ? t : (t < curMin ? t : curMin);
    maxC = curMax == null ? t : (t > curMax ? t : curMax);
  }
  return (minC: minC, maxC: maxC, count: count);
}

/// Upsert one date row in daily_extremes.csv.
String upsertDailyExtremesCsv({
  required String? existingCsv,
  required String dateYmd,
  required double? minC,
  required double? maxC,
  required int sampleCount,
  required DateTime updatedAtUtc,
}) {
  final byDate = <String, String>{};
  if (existingCsv != null && existingCsv.trim().isNotEmpty) {
    for (final row in _parseDataRows(existingCsv)) {
      if (row.isEmpty) continue;
      byDate[row[0]] = row.join(',');
    }
  }
  if (minC != null && maxC != null && sampleCount > 0) {
    byDate[dateYmd] = [
      dateYmd,
      _formatTemp(minC),
      _formatTemp(maxC),
      '$sampleCount',
      updatedAtUtc.toIso8601String(),
    ].join(',');
  }
  final keys = byDate.keys.toList()..sort();
  final buf = StringBuffer()..writeln(dailyExtremesCsvHeader);
  for (final k in keys) {
    buf.writeln(byDate[k]);
  }
  return buf.toString();
}

String buildForecastCsv({
  required ForecastHorizonSeries series,
}) {
  final issued = series.issuedAtUtc.toIso8601String();
  final source = _escapeCsv(series.forecastSource);
  final buf = StringBuffer()..writeln(forecastCsvHeader);
  for (final p in series.points) {
    buf.writeln(
      '${_formatLocal(p.validLocal)},'
      '${_formatTemp(p.tempC)},'
      '$source,'
      '$issued,'
      '${p.leadHours.toStringAsFixed(2)}',
    );
  }
  return buf.toString();
}

Future<void> writeRunSummary({
  required String job,
  required Map<String, dynamic> summary,
  Directory? runsDir,
}) async {
  final dir = runsDir ?? Directory('data/runs');
  await dir.create(recursive: true);
  final payload = {
    'job': job,
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    ...summary,
  };
  final file = File('${dir.path}${Platform.pathSeparator}latest.json');
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
}

String _utcStamp(DateTime utc) {
  final u = utc.toUtc();
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${p2(u.month)}${p2(u.day)}T${p2(u.hour)}${p2(u.minute)}Z';
}

String _formatLocal(tz.TZDateTime t) {
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${p2(t.month)}-${p2(t.day)}T${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}';
}

String _formatTemp(double t) {
  if (t == t.roundToDouble()) return t.toStringAsFixed(1);
  return t.toStringAsFixed(2);
}

String _escapeCsv(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

List<List<String>> _parseDataRows(String csvBody) {
  final lines = csvBody.split(RegExp(r'\r?\n'));
  final rows = <List<String>>[];
  for (final lineRaw in lines) {
    final line = lineRaw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('local_time') ||
        line.startsWith('date,') ||
        line.startsWith('valid_local_time')) {
      continue;
    }
    rows.add(_splitCsvLine(line));
  }
  return rows;
}

List<String> _splitCsvLine(String line) {
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

class _ObsRow {
  const _ObsRow({
    required this.localTime,
    required this.tempC,
    required this.dataSource,
    required this.collectedAtUtc,
  });

  final String localTime;
  final String tempC;
  final String dataSource;
  final String collectedAtUtc;
}

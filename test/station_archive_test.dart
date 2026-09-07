import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/station_temperature_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    CityTimezones.ensureInitialized();
  });

  group('mergeObservedCsv', () {
    test('dedupes by local_time and keeps latest incoming', () {
      const existing = '''
local_time,temp_c,data_source,collected_at_utc
2026-09-07T10:00:00,20.0,old,2026-09-07T01:00:00.000Z
2026-09-07T11:00:00,21.0,old,2026-09-07T01:00:00.000Z
''';
      final location = tz.getLocation('Asia/Hong_Kong');
      final incoming = [
        TempObservationSample(
          localTime: tz.TZDateTime(location, 2026, 9, 7, 11, 0),
          tempC: 22.5,
          dataSource: 'new',
        ),
        TempObservationSample(
          localTime: tz.TZDateTime(location, 2026, 9, 7, 12, 0),
          tempC: 23.0,
          dataSource: 'new',
        ),
      ];
      final merged = mergeObservedCsv(
        existingCsv: existing,
        incoming: incoming,
        collectedAtUtc: DateTime.utc(2026, 9, 7, 2),
      );
      expect(merged, contains('2026-09-07T10:00:00,20.0,old,'));
      expect(merged, contains('2026-09-07T11:00:00,22.50,new,'));
      expect(merged, contains('2026-09-07T12:00:00,23.0,new,'));
      expect(
        RegExp(r'2026-09-07T11:00:00').allMatches(merged).length,
        1,
      );
    });
  });

  group('extremesFromObservedCsv', () {
    test('computes obs min/max and count', () {
      const csv = '''
local_time,temp_c,data_source,collected_at_utc
2026-09-07T02:00:00,18.2,src,2026-09-07T01:00:00.000Z
2026-09-07T14:00:00,31.5,src,2026-09-07T01:00:00.000Z
2026-09-07T20:00:00,24.0,src,2026-09-07T01:00:00.000Z
''';
      final e = extremesFromObservedCsv(csv);
      expect(e.count, 3);
      expect(e.minC, closeTo(18.2, 1e-9));
      expect(e.maxC, closeTo(31.5, 1e-9));
    });
  });

  group('upsertDailyExtremesCsv', () {
    test('inserts and updates by date', () {
      final first = upsertDailyExtremesCsv(
        existingCsv: null,
        dateYmd: '2026-09-07',
        minC: 18.0,
        maxC: 30.0,
        sampleCount: 10,
        updatedAtUtc: DateTime.utc(2026, 9, 7, 3),
      );
      final second = upsertDailyExtremesCsv(
        existingCsv: first,
        dateYmd: '2026-09-07',
        minC: 17.5,
        maxC: 31.0,
        sampleCount: 12,
        updatedAtUtc: DateTime.utc(2026, 9, 7, 4),
      );
      expect(
        RegExp(r'^2026-09-07,', multiLine: true).allMatches(second).length,
        1,
      );
      expect(second, contains('17.50,31.0,12,'));
    });
  });

  group('buildForecastCsv', () {
    test('writes horizon rows with lead hours', () {
      final location = tz.getLocation('Asia/Tokyo');
      final now = tz.TZDateTime(location, 2026, 9, 7, 12);
      final series = ForecastHorizonSeries(
        siteId: 'RJTT',
        forecastSource: 'api.open-meteo.com',
        nowLocal: now,
        horizonEnd: now.add(const Duration(hours: 72)),
        issuedAtUtc: DateTime.utc(2026, 9, 7, 3),
        requestedHorizonHours: 72,
        points: [
          ForecastHorizonPoint(
            validLocal: now,
            tempC: 25.0,
            leadHours: 0,
          ),
          ForecastHorizonPoint(
            validLocal: now.add(const Duration(hours: 1)),
            tempC: 24.5,
            leadHours: 1,
          ),
        ],
      );
      final csv = buildForecastCsv(series: series);
      expect(csv, startsWith(forecastCsvHeader));
      expect(csv, contains('25.0,api.open-meteo.com,'));
      expect(csv, contains(',0.00'));
      expect(csv, contains(',1.00'));
      expect(series.horizonHoursAvailable, closeTo(1.0, 1e-9));
    });
  });
}

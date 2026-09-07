import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/services/station_temperature_api.dart';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  group('temperature conversion', () {
    test('celsius to fahrenheit', () {
      expect(celsiusToFahrenheit(0), 32);
      expect(celsiusToFahrenheit(10), 50);
      expect(convertTempC(0, 'C'), 0);
      expect(convertTempC(0, 'F'), 32);
    });

    test('fahrenheit to celsius', () {
      expect(fahrenheitToCelsius(32), 0);
      expect(fahrenheitToCelsius(50), closeTo(10, 1e-9));
    });
  });

  group('mergeHourlySeries now-split', () {
    late tz.Location seattle;
    late tz.TZDateTime dayStart;
    late tz.TZDateTime dayEnd;

    setUp(() {
      seattle = tz.getLocation('America/Los_Angeles');
      dayStart = tz.TZDateTime(seattle, 2026, 3, 20);
      dayEnd = dayStart.add(const Duration(days: 1));
    });

    Map<int, double> hourMap(Map<int, double> byHourOfDay) {
      return {
        for (final e in byHourOfDay.entries)
          tz.TZDateTime(seattle, 2026, 3, 20, e.key).millisecondsSinceEpoch:
              e.value,
      };
    }

    test('past hours use observed only; future use forecast only', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 14, 30);
      final observed = hourMap({10: 5, 11: 6, 14: 7});
      final forecast = hourMap({14: 99, 15: 8, 16: 9});

      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: observed,
        forecastC: forecast,
        unit: 'C',
      );

      final byHour = {
        for (final p in points) p.localHourStart.hour: p,
      };

      expect(byHour[10]?.temperature, 5);
      expect(byHour[10]?.kind, TempPointKind.observed);
      expect(byHour[11]?.kind, TempPointKind.observed);
      // Hour containing now prefers observed over forecast.
      expect(byHour[14]?.temperature, 7);
      expect(byHour[14]?.kind, TempPointKind.observed);
      expect(byHour[15]?.temperature, 8);
      expect(byHour[15]?.kind, TempPointKind.forecast);
      expect(byHour.containsKey(12), isFalse); // no obs in past → skip
    });

    test('current hour falls back to forecast when no observation', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 14, 10);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({10: 5}),
        forecastC: hourMap({14: 12}),
        unit: 'C',
      );
      final cur = points.singleWhere((p) => p.localHourStart.hour == 14);
      expect(cur.temperature, 12);
      expect(cur.kind, TempPointKind.forecast);
    });

    test('converts series to Fahrenheit when unit is F', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 18);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({10: 0}),
        forecastC: hourMap({20: 10}),
        unit: 'F',
      );
      expect(points.map((p) => p.temperature).toList(), [32.0, 50.0]);
    });

    test('fully past day uses only observations', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 21, 1);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({0: 1, 12: 2}),
        forecastC: hourMap({0: 99, 12: 99, 23: 99}),
        unit: 'C',
      );
      expect(points.length, 2);
      expect(points.every((p) => p.kind == TempPointKind.observed), isTrue);
      expect(points.map((p) => p.temperature).toList(), [1.0, 2.0]);
    });

    test('includes next-day local midnight forecast', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 22);
      final nextMidnight = dayEnd;
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({20: 5}),
        forecastC: {
          ...hourMap({23: 4}),
          nextMidnight.millisecondsSinceEpoch: 3,
        },
        unit: 'C',
      );
      final endpoint = points.singleWhere(
        (p) =>
            p.localHourStart.millisecondsSinceEpoch ==
            nextMidnight.millisecondsSinceEpoch,
      );
      expect(endpoint.temperature, 3);
      expect(endpoint.kind, TempPointKind.forecast);
      expect(endpoint.isDailyMinimum, isFalse);
    });

    test('marks all observation-day hours that tie the daily minimum', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 18);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({4: 10, 5: 10, 6: 12, 12: 15}),
        forecastC: {
          dayEnd.millisecondsSinceEpoch: 9, // colder but next day — not a day min
        },
        unit: 'C',
      );
      final mins = points.where((p) => p.isDailyMinimum).toList();
      expect(mins.length, 2);
      expect(mins.every((p) => p.temperature == 10), isTrue);
      expect(
        points
            .singleWhere((p) => p.localHourStart == dayEnd)
            .isDailyMinimum,
        isFalse,
      );
      final maxes = points.where((p) => p.isDailyMaximum).toList();
      expect(maxes.length, 1);
      expect(maxes.single.temperature, 15);
      expect(maxes.single.isDailyMinimum, isFalse);
    });

    test('assigns observed and forecast data sources', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 14);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({10: 5}),
        forecastC: hourMap({16: 8}),
        unit: 'C',
        observedDataSource: 'https://www.weather.gov/wrh/timeseries?site=ksea',
        forecastDataSource: StationTemperatureApi.nwsForecastDataSource,
      );
      final obs = points.singleWhere((p) => p.localHourStart.hour == 10);
      final fc = points.singleWhere((p) => p.localHourStart.hour == 16);
      expect(obs.kind, TempPointKind.observed);
      expect(obs.dataSource, contains('weather.gov/wrh/timeseries'));
      expect(fc.kind, TempPointKind.forecast);
      expect(fc.dataSource, 'api.weather.gov');
    });

    test('DailyTemperatureSeries JSON round-trips for Pages snapshot', () {
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 14, 30);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: hourMap({10: 5, 11: 6}),
        forecastC: hourMap({15: 8, 16: 9}),
        unit: 'C',
        observedDataSource: 'https://www.weather.gov/wrh/timeseries?site=ksea',
        forecastDataSource: StationTemperatureApi.openMeteoForecastDataSource,
      );
      final series = DailyTemperatureSeries(
        siteId: 'KSEA',
        unit: 'C',
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        points: points,
        latestObservation: LatestStationObservation(
          temperature: 7.2,
          observedAtLocal: tz.TZDateTime(seattle, 2026, 3, 20, 14, 20),
        ),
      );
      final restored = DailyTemperatureSeries.fromJson(series.toJson());
      expect(restored.siteId, 'KSEA');
      expect(restored.unit, 'C');
      expect(restored.dayStart.location.name, seattle.name);
      expect(restored.points.length, points.length);
      expect(restored.points.first.kind, TempPointKind.observed);
      expect(restored.points.last.kind, TempPointKind.forecast);
      expect(
        restored.points.first.dataSource,
        contains('timeseries?site=ksea'),
      );
      expect(
        restored.nowLocal.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
      expect(restored.latestObservation?.temperature, 7.2);
      expect(restored.latestObservation?.observedAtLocal.hour, 14);
      expect(restored.latestObservation?.observedAtLocal.minute, 20);
    });
  });

  group('forecast data source labels', () {
    test('NWS / NBM / Open-Meteo labels are distinct', () {
      expect(StationTemperatureApi.nwsForecastDataSource, 'api.weather.gov');
      expect(
        StationTemperatureApi.openMeteoNbmForecastDataSource,
        contains('NBM'),
      );
      expect(
        StationTemperatureApi.openMeteoNbmModel,
        'ncep_nbm_conus',
      );
      expect(
        StationTemperatureApi.openMeteoForecastDataSource,
        'api.open-meteo.com',
      );
    });
  });

  group('chart eligibility smoke', () {
    test('timeseries site id present for WRH URLs', () {
      expect(
        weatherGovTimeseriesSiteId(
          'https://www.weather.gov/wrh/timeseries?site=ksea',
        ),
        'ksea',
      );
    });

    test('unique resolution source has no timeseries site', () {
      expect(
        weatherGovTimeseriesSiteId('https://example.com/unique'),
        isNull,
      );
      expect(
        weatherGovTimeseriesSiteId(null),
        isNull,
      );
    });
  });

  group('METAR native resolution', () {
    test('keeps both :00 and :30 samples in the same local hour', () {
      final seattle = tz.getLocation('America/Los_Angeles');
      final dayStart = tz.TZDateTime(seattle, 2026, 3, 20);
      final dayEnd = dayStart.add(const Duration(days: 1));
      // 15:00 and 15:30 PDT = UTC 22:00 and 22:30 on Mar 20 (PDT = UTC-7).
      final indexed = indexMetarObservations(
        location: seattle,
        dayStart: dayStart,
        dayEnd: dayEnd,
        samples: [
          (utc: DateTime.utc(2026, 3, 20, 22, 0), tempC: 11),
          (utc: DateTime.utc(2026, 3, 20, 22, 30), tempC: 10),
        ],
      );
      final at00 =
          tz.TZDateTime(seattle, 2026, 3, 20, 15).millisecondsSinceEpoch;
      final at30 =
          tz.TZDateTime(seattle, 2026, 3, 20, 15, 30).millisecondsSinceEpoch;
      expect(indexed[at00], 11);
      expect(indexed[at30], 10);
    });

    test('merge plots sub-hourly observations before now', () {
      final seattle = tz.getLocation('America/Los_Angeles');
      final dayStart = tz.TZDateTime(seattle, 2026, 3, 20);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 15, 45);
      final at00 =
          tz.TZDateTime(seattle, 2026, 3, 20, 15).millisecondsSinceEpoch;
      final at30 =
          tz.TZDateTime(seattle, 2026, 3, 20, 15, 30).millisecondsSinceEpoch;
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: {at00: 11, at30: 10},
        forecastC: {
          tz.TZDateTime(seattle, 2026, 3, 20, 16).millisecondsSinceEpoch: 9,
        },
        unit: 'C',
      );
      final obs = points.where((p) => p.kind == TempPointKind.observed).toList();
      expect(obs, hasLength(2));
      expect(obs.map((p) => p.localHourStart.minute).toList(), [0, 30]);
      expect(
        points.where((p) => p.kind == TempPointKind.forecast).single.temperature,
        9,
      );
    });

    test('merge keeps single observation at its native minute', () {
      final seattle = tz.getLocation('America/Los_Angeles');
      final dayStart = tz.TZDateTime(seattle, 2026, 3, 20);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(seattle, 2026, 3, 20, 12);
      final key =
          tz.TZDateTime(seattle, 2026, 3, 20, 8, 30).millisecondsSinceEpoch;
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: {key: 4.5},
        forecastC: {},
        unit: 'C',
      );
      expect(points.single.temperature, 4.5);
      expect(points.single.localHourStart.hour, 8);
      expect(points.single.localHourStart.minute, 30);
    });
  });
}

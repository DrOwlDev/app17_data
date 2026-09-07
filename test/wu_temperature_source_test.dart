import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/station_temperature_api.dart';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    CityTimezones.ensureInitialized();
  });

  group('Weather Underground ICAO parse', () {
    test('extracts ZSJN from Jinan history URL', () {
      expect(
        weatherUndergroundHistoryIcao(
          'https://www.wunderground.com/history/daily/cn/jinan/ZSJN',
        ),
        'ZSJN',
      );
      expect(
        isWeatherUndergroundHistoryUrl(
          'https://www.wunderground.com/history/daily/cn/jinan/ZSJN',
        ),
        isTrue,
      );
    });

    test('extracts RCSS from Taipei history URL', () {
      expect(
        weatherUndergroundHistoryIcao(
          'https://www.wunderground.com/history/daily/tw/taipei/RCSS',
        ),
        'RCSS',
      );
    });

    test('rejects non-WU and non-history URLs', () {
      expect(
        weatherUndergroundHistoryIcao(
          'https://www.weather.gov/wrh/timeseries?site=kdal',
        ),
        isNull,
      );
      expect(
        weatherUndergroundHistoryIcao(
          'https://www.wunderground.com/weather/cn/jinan',
        ),
        isNull,
      );
      expect(weatherUndergroundHistoryIcao(null), isNull);
    });
  });

  group('Jinan / Taipei chart routing', () {
    MarketEvent jinan() => MarketEvent.fromJson({
          'id': 'jn-1',
          'title': 'Lowest temperature in Jinan on September 6?',
          'slug': 'jinan',
          'resolutionSource':
              'https://www.wunderground.com/history/daily/cn/jinan/ZSJN',
          'markets': [
            {
              'id': 'a',
              'question': '20°C?',
              'groupItemTitle': '20°C',
              'outcomes': '["Yes", "No"]',
              'outcomePrices': '["0.5", "0.5"]',
            },
          ],
        });

    MarketEvent taipei() => MarketEvent.fromJson({
          'id': 'tp-1',
          'title': 'Lowest temperature in Taipei on September 6?',
          'slug': 'taipei',
          'resolutionSource':
              'https://www.wunderground.com/history/daily/tw/taipei/RCSS',
          'markets': [
            {
              'id': 'a',
              'question': '26°C?',
              'groupItemTitle': '26°C',
              'outcomes': '["Yes", "No"]',
              'outcomePrices': '["0.5", "0.5"]',
            },
          ],
        });

    test('WU markets are chartable via METAR ICAO', () {
      final jn = jinan();
      expect(metarStationIcaoForEvent(jn), 'ZSJN');
      expect(isChartableTemperatureSource(jn), isTrue);
      expect(isHongKongTemperatureMarket(jn), isFalse);
      expect(hongKongOcfStationId(jn), isNull);
      expect(weatherGovTimeseriesSiteId(jn.resolutionSourceUrl), isNull);

      final tp = taipei();
      expect(metarStationIcaoForEvent(tp), 'RCSS');
      expect(isChartableTemperatureSource(tp), isTrue);
      expect(isHongKongTemperatureMarket(tp), isFalse);
    });

    test('does not steal WRH or HKO routing', () {
      final wrh = MarketEvent.fromJson({
        'id': 'dal-1',
        'title': 'Lowest temperature in Dallas on September 5?',
        'slug': 'dallas',
        'resolutionSource':
            'https://www.weather.gov/wrh/timeseries?site=kdal',
        'markets': [],
      });
      expect(metarStationIcaoForEvent(wrh), 'KDAL');
      expect(weatherGovTimeseriesSiteId(wrh.resolutionSourceUrl), 'kdal');
      expect(hongKongOcfStationId(wrh), isNull);

      final hk = MarketEvent.fromJson({
        'id': 'hk-1',
        'title': 'Lowest temperature in Hong Kong on September 5?',
        'slug': 'hk',
        'resolutionSource': '',
        'description':
            'available here: https://www.weather.gov.hk/en/cis/climat.htm',
        'markets': [],
      });
      expect(metarStationIcaoForEvent(hk), isNull);
      expect(hongKongOcfStationId(hk), 'HKO');
      expect(isChartableTemperatureSource(hk), isTrue);
    });
  });

  group('METAR + Open-Meteo merge at Asia airports', () {
    test('Taipei local day splits observed METAR and Open-Meteo forecast', () {
      final taipei = tz.getLocation('Asia/Taipei');
      final dayStart = tz.TZDateTime(taipei, 2026, 9, 6);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(taipei, 2026, 9, 6, 14, 30);

      final obsHour = tz.TZDateTime(taipei, 2026, 9, 6, 10).millisecondsSinceEpoch;
      final fcHour = tz.TZDateTime(taipei, 2026, 9, 6, 16).millisecondsSinceEpoch;
      const wuUrl =
          'https://www.wunderground.com/history/daily/tw/taipei/RCSS';

      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: {obsHour: 27.0},
        forecastC: {fcHour: 29.0},
        unit: 'C',
        observedDataSource: wuUrl,
        forecastDataSource:
            StationTemperatureApi.openMeteoForecastDataSource,
      );

      expect(points, hasLength(2));
      expect(points[0].kind, TempPointKind.observed);
      expect(points[0].temperature, 27.0);
      expect(points[0].dataSource, wuUrl);
      expect(points[1].kind, TempPointKind.forecast);
      expect(points[1].temperature, 29.0);
      expect(
        points[1].dataSource,
        StationTemperatureApi.openMeteoForecastDataSource,
      );
    });

    test('Jinan timezone uses Asia/Shanghai for day bounds', () {
      expect(CityTimezones.locationForCity('Jinan')?.name, 'Asia/Shanghai');
      expect(CityTimezones.locationForCity('Taipei')?.name, 'Asia/Taipei');
    });
  });

  group('Weather.com historical fallback (ZSJN)', () {
    test('country code from WU history URL', () {
      expect(
        countryCodeFromWuHistoryUrl(
          'https://www.wunderground.com/history/daily/cn/jinan/ZSJN',
        ),
        'CN',
      );
      expect(
        weatherUndergroundHistoryCountry(
          'https://www.wunderground.com/history/daily/tw/taipei/RCSS',
        ),
        'TW',
      );
    });

    test('parses historical JSON into Shanghai-local observed hours', () {
      final shanghai = tz.getLocation('Asia/Shanghai');
      final dayStart = tz.TZDateTime(shanghai, 2026, 9, 6);
      final dayEnd = dayStart.add(const Duration(days: 1));
      // 2026-09-05 16:00 UTC = Sep 6 00:00 CST; 21:00 UTC = Sep 6 05:00 CST
      final samples = parseWeatherComHistoricalObservationsC({
        'observations': [
          {'valid_time_gmt': 1788624000, 'temp': 19},
          {'valid_time_gmt': 1788642000, 'temp': 17},
          {'valid_time_gmt': 1788663600, 'temp': 29},
        ],
      });
      expect(samples, hasLength(3));
      expect(samples[1].tempC, 17);

      final indexed = indexMetarObservations(
        location: shanghai,
        dayStart: dayStart,
        dayEnd: dayEnd,
        samples: samples,
      );
      final at5 =
          tz.TZDateTime(shanghai, 2026, 9, 6, 5).millisecondsSinceEpoch;
      expect(indexed[at5], 17);

      final now = tz.TZDateTime(shanghai, 2026, 9, 6, 11, 30);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: indexed,
        forecastC: {
          tz.TZDateTime(shanghai, 2026, 9, 6, 12).millisecondsSinceEpoch: 30,
        },
        unit: 'C',
        observedDataSource:
            'https://www.wunderground.com/history/daily/cn/jinan/ZSJN',
        forecastDataSource:
            StationTemperatureApi.openMeteoForecastDataSource,
      );
      expect(points.any((p) => p.kind == TempPointKind.observed), isTrue);
      expect(
        points.where((p) => p.kind == TempPointKind.observed).map((p) => p.temperature),
        containsAll([19.0, 17.0, 29.0]),
      );
      expect(
        points.where((p) => p.isDailyMinimum).map((p) => p.temperature).toSet(),
        {17.0},
      );
    });
  });
}

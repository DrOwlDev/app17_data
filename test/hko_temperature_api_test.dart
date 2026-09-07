import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/hko_temperature_api.dart';
import 'package:app17_data/services/hko_weather_icons.dart';
import 'package:app17_data/services/station_temperature_api.dart';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    CityTimezones.ensureInitialized();
  });

  group('Hong Kong chart eligibility', () {
    test('weather.gov.hk resolution is chartable HKO', () {
      final event = MarketEvent.fromJson({
        'id': 'hk-1',
        'title': 'Lowest temperature in Hong Kong on September 5?',
        'slug': 'hk',
        'resolutionSource': '',
        'description':
            'available here: https://www.weather.gov.hk/en/cis/climat.htm',
        'markets': [],
      });
      expect(isHongKongObservatorySource(event.resolutionSourceUrl), isTrue);
      expect(isHongKongTemperatureMarket(event), isTrue);
      expect(isChartableTemperatureSource(event), isTrue);
      expect(hongKongOcfStationId(event), 'HKO');
      expect(weatherGovTimeseriesSiteId(event.resolutionSourceUrl), isNull);
    });

    test('city name Hong Kong is chartable without URL', () {
      final event = MarketEvent.fromJson({
        'id': 'hk-2',
        'title': 'Lowest temperature in Hong Kong on September 5?',
        'slug': 'hk',
        'markets': [],
      });
      expect(isHongKongTemperatureMarket(event), isTrue);
      expect(hongKongOcfStationId(event), 'HKO');
    });

    test('WRH timeseries markets are not routed to HKO', () {
      final event = MarketEvent.fromJson({
        'id': 'dal-1',
        'title': 'Lowest temperature in Dallas on September 5?',
        'slug': 'dallas',
        'resolutionSource':
            'https://www.weather.gov/wrh/timeseries?site=kdal',
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
      expect(weatherGovTimeseriesSiteId(event.resolutionSourceUrl), 'kdal');
      expect(isHongKongObservatorySource(event.resolutionSourceUrl), isFalse);
      expect(isHongKongTemperatureMarket(event), isFalse);
      expect(hongKongOcfStationId(event), isNull);
      expect(isChartableTemperatureSource(event), isTrue);
      expect(metarStationIcaoForEvent(event), 'KDAL');
    });
  });

  group('HKO parsers', () {
    test('parseHkocCsvSamples indexes HKT wall times', () {
      const csv = '''
Date/Time,Temperature,RH
202609051030,26.5,80
202609051100,27.0,78
''';
      final samples = parseHkocCsvSamples(csv);
      expect(samples, hasLength(2));
      final hk = tz.getLocation('Asia/Hong_Kong');
      final local0 = tz.TZDateTime.from(samples[0].utc, hk);
      expect(local0.hour, 10);
      expect(local0.minute, 30);
      expect(samples[0].tempC, 26.5);
    });

    test('indexOcfHourlyForecastC keeps day window hours', () {
      final hk = tz.getLocation('Asia/Hong_Kong');
      final dayStart = tz.TZDateTime(hk, 2026, 9, 5);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final indexed = indexOcfHourlyForecast(
        json: {
          'HourlyWeatherForecast': [
            {
              'ForecastHour': '2026090509',
              'ForecastTemperature': 28.4,
              'ForecastWeather': 50,
            },
            {
              'ForecastHour': '2026090510',
              'ForecastTemperature': 28.8,
            },
            {
              'ForecastHour': '2026090515',
              'ForecastTemperature': 31.0,
              'ForecastWeather': 62,
            },
            {
              'ForecastHour': '2026090516',
              'ForecastTemperature': 30.5,
            },
            {
              'ForecastHour': '2026090600',
              'ForecastTemperature': 27.0,
              'ForecastWeather': 751,
            },
            {
              'ForecastHour': '2026090700',
              'ForecastTemperature': 26.0,
              'ForecastWeather': 60,
            },
          ],
        },
        location: hk,
        dayStart: dayStart,
        dayEnd: dayEnd,
      );
      expect(indexed.tempsC.length, 5); // 09, 10, 15, 16, and next-day 00 (dayEnd)
      expect(
        indexed.tempsC[tz.TZDateTime(hk, 2026, 9, 5, 9).millisecondsSinceEpoch],
        28.4,
      );
      expect(
        indexed.tempsC[tz.TZDateTime(hk, 2026, 9, 6).millisecondsSinceEpoch],
        27.0,
      );
      expect(
        indexed.weatherIconCodes[
            tz.TZDateTime(hk, 2026, 9, 5, 9).millisecondsSinceEpoch],
        50,
      );
      expect(
        indexed.weatherIconCodes[
            tz.TZDateTime(hk, 2026, 9, 5, 15).millisecondsSinceEpoch],
        62,
      );
      // OCF composite 751 normalizes to official icon 75.
      expect(
        indexed.weatherIconCodes[
            tz.TZDateTime(hk, 2026, 9, 6).millisecondsSinceEpoch],
        75,
      );
      // Intermediate hours without explicit ForecastWeather inherit prior icon.
      expect(
        indexed.weatherIconCodes[
            tz.TZDateTime(hk, 2026, 9, 5, 10).millisecondsSinceEpoch],
        50,
      );
      expect(
        indexed.weatherIconCodes[
            tz.TZDateTime(hk, 2026, 9, 5, 16).millisecondsSinceEpoch],
        62,
      );
    });

    test('expandOcfWeatherIconCodes fills every hour', () {
      final filled = expandOcfWeatherIconCodes(
        hourKeys: [1, 2, 3, 4, 5, 6],
        sparseCodes: {1: 50, 4: 60},
      );
      expect(filled, {1: 50, 2: 50, 3: 50, 4: 60, 5: 60, 6: 60});
      expect(
        expandOcfWeatherIconCodes(
          hourKeys: [1, 2, 3],
          sparseCodes: {3: 62},
        ),
        {1: 62, 2: 62, 3: 62},
      );
    });

    test('normalizeHkoWeatherIconCode maps composites', () {
      expect(normalizeHkoWeatherIconCode(50), 50);
      expect(normalizeHkoWeatherIconCode(751), 75);
      expect(normalizeHkoWeatherIconCode(711), 71);
      expect(normalizeHkoWeatherIconCode(999), isNull);
    });

    test('merge attaches HKO weather icons only on forecast hours', () {
      final hk = tz.getLocation('Asia/Hong_Kong');
      final dayStart = tz.TZDateTime(hk, 2026, 9, 5);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(hk, 2026, 9, 5, 12);
      final hour15 = tz.TZDateTime(hk, 2026, 9, 5, 15);
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: {
          tz.TZDateTime(hk, 2026, 9, 5, 10).millisecondsSinceEpoch: 28,
        },
        forecastC: {
          hour15.millisecondsSinceEpoch: 30,
        },
        forecastWeatherCodes: {
          hour15.millisecondsSinceEpoch: 60,
        },
        unit: 'C',
      );
      final forecast = points.where((p) => p.kind == TempPointKind.forecast);
      expect(forecast, isNotEmpty);
      expect(forecast.first.weatherIconCode, 60);
      final observed = points.where((p) => p.kind == TempPointKind.observed);
      expect(observed.every((p) => p.weatherIconCode == null), isTrue);
    });

    test('parseHkoLatestTemperatureCsv finds HK Observatory', () {
      const csv = '''
Date time, Automatic Weather Station, Air Temperature(degree Celsius)
202609051420,Some Other,20.0
202609051425,HK Observatory,26.6
''';
      final parsed = parseHkoLatestTemperatureCsv(csv);
      expect(parsed, isNotNull);
      expect(parsed!.tempC, 26.6);
      expect(parsed.wall.hour, 14);
      expect(parsed.wall.minute, 25);
    });

    test('merge uses HKO obs before now and OCF forecast after', () {
      final hk = tz.getLocation('Asia/Hong_Kong');
      final dayStart = tz.TZDateTime(hk, 2026, 9, 5);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(hk, 2026, 9, 5, 14, 30);
      final at10 =
          tz.TZDateTime(hk, 2026, 9, 5, 10).millisecondsSinceEpoch;
      final at15 =
          tz.TZDateTime(hk, 2026, 9, 5, 15).millisecondsSinceEpoch;
      final points = mergeHourlySeries(
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        observedC: {at10: 26.0},
        forecastC: {at15: 29.0},
        unit: 'C',
        observedDataSource: HkoTemperatureApi.defaultObservedDataSource,
        forecastDataSource: HkoTemperatureApi.forecastDataSource,
      );
      expect(points, hasLength(2));
      expect(points.first.kind, TempPointKind.observed);
      expect(points.first.dataSource, contains('weather.gov.hk'));
      expect(points.last.kind, TempPointKind.forecast);
      expect(points.last.dataSource, contains('ocf'));
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/hko_temperature_api.dart';
import 'package:app17_data/services/polymarket_api.dart';
import 'package:app17_data/services/station_temperature_api.dart';

/// Fetches live Polymarket low-temp markets (+ CLOB asks) and writes
/// `web/data/markets.json` for GitHub Pages.
///
/// Also preloads WRH + WU-ICAO + HKO temperature series so the web app can
/// render charts without browser CORS to weather APIs.
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();

  final outPath = args.isNotEmpty ? args.first : 'web/data/markets.json';
  final api = PolymarketApi(preferStaticSnapshot: false);
  final tempApi = StationTemperatureApi();
  final hkoApi = HkoTemperatureApi();

  stdout.writeln('Fetching lowest + highest temperature events…');
  var events = await api.fetchTemperatureEvents();
  stdout.writeln('Enriching CLOB Buy Yes/No for ${events.length} events…');
  events = await api.enrichEventsBuyPrices(events);
  api.close();

  stdout.writeln('Preloading temperature series (WRH + WU + HKO)…');
  events = await _attachTemperatureSeries(events, tempApi, hkoApi);
  tempApi.close();
  hkoApi.close();

  final withSeries =
      events.where((e) => e.temperatureSeries != null).length;
  final payload = {
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'eventCount': events.length,
    'temperatureSeriesCount': withSeries,
    'events': events.map((e) => e.toSnapshotJson()).toList(),
  };

  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  stdout.writeln(
    'Wrote ${events.length} events ($withSeries with temp charts) to $outPath '
    '(${file.lengthSync()} bytes)',
  );
}

Future<List<MarketEvent>> _attachTemperatureSeries(
  List<MarketEvent> events,
  StationTemperatureApi tempApi,
  HkoTemperatureApi hkoApi,
) async {
  final cache = <String, Future<DailyTemperatureSeries?>>{};
  const concurrency = 6;
  var next = 0;
  final results = List<MarketEvent>.from(events);

  Future<DailyTemperatureSeries?> seriesFor(MarketEvent event) {
    final day = event.observationDayInCity;
    if (day == null || !isChartableTemperatureSource(event)) {
      return Future<DailyTemperatureSeries?>.value(null);
    }

    final unit = event.temperatureUnit ?? 'C';
    final observedSource =
        event.resolutionSourceUrl ?? event.resolutionSourceOpenUrl;
    final hkoStation = hongKongOcfStationId(event);
    final siteId = metarStationIcaoForEvent(event);

    final String key;
    if (hkoStation != null) {
      key = '$hkoStation|${day.year}-${day.month}-${day.day}|$unit';
    } else if (siteId != null) {
      key = '$siteId|${day.year}-${day.month}-${day.day}|$unit';
    } else {
      return Future<DailyTemperatureSeries?>.value(null);
    }

    return cache.putIfAbsent(key, () async {
      try {
        final DailyTemperatureSeries series;
        if (hkoStation != null) {
          series = await hkoApi.fetchDailySeries(
            year: day.year,
            month: day.month,
            day: day.day,
            unit: unit,
            observedDataSource: observedSource,
          );
        } else {
          series = await tempApi.fetchDailySeries(
            siteId: siteId!,
            cityName: event.cityName,
            year: day.year,
            month: day.month,
            day: day.day,
            unit: unit,
            observedDataSource: observedSource,
          );
        }
        stdout.writeln(
          '  ✓ $key (${series.points.length} points, ${event.cityName})',
        );
        return series;
      } catch (e) {
        stdout.writeln('  ✗ $key (${event.cityName}): $e');
        return null;
      }
    });
  }

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= events.length) return;
      final event = events[i];
      final series = await seriesFor(event);
      if (series != null) {
        results[i] = event.copyWith(temperatureSeries: series);
      }
    }
  }

  await Future.wait([
    for (var w = 0; w < concurrency; w++) worker(),
  ]);
  return results;
}

import 'dart:io';

import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/hko_temperature_api.dart';
import 'package:app17_data/services/station_temperature_api.dart';

/// Snapshot 72h hourly forecasts for each station into
/// `data/stations/{id}/forecasts/{issuedAt}.csv`.
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();

  final outRoot = args.isNotEmpty ? args.first : 'data/stations';
  final store = StationArchiveStore(root: Directory(outRoot));
  final stations = await store.readIndex();
  if (stations.isEmpty) {
    stderr.writeln(
      'No stations in ${store.indexFile().path}. '
      'Run tool/collect_stations.dart first.',
    );
    exitCode = 1;
    return;
  }

  final tempApi = StationTemperatureApi();
  final hkoApi = HkoTemperatureApi();
  final ok = <String>[];
  final failed = <String>[];
  final horizons = <String, double>{};

  const concurrency = 6;
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= stations.length) return;
      final station = stations[i];
      try {
        final series = station.sourceKind == 'hko'
            ? await hkoApi.fetchForecastHorizonC(horizonHours: 72)
            : await tempApi.fetchForecastHorizonC(
                siteId: station.stationId,
                cityName: station.cityName,
                horizonHours: 72,
              );

        await store.ensureStationDirs(station.stationId);
        final file = store.forecastSnapshotFile(
          station.stationId,
          series.issuedAtUtc,
        );
        await file.writeAsString(buildForecastCsv(series: series));

        ok.add(station.stationId);
        horizons[station.stationId] = series.horizonHoursAvailable;
        stdout.writeln(
          '  ✓ ${station.stationId} '
          '(${series.points.length} hours, '
          'available=${series.horizonHoursAvailable.toStringAsFixed(1)}h, '
          '${series.forecastSource})',
        );
      } catch (e) {
        failed.add(station.stationId);
        stderr.writeln('  ✗ ${station.stationId}: $e');
      }
    }
  }

  stdout.writeln('Collecting 72h forecasts for ${stations.length} stations…');
  await Future.wait(List.generate(concurrency, (_) => worker()));
  tempApi.close();
  hkoApi.close();

  await writeRunSummary(
    job: 'collect_forecasts',
    summary: {
      'stationCount': stations.length,
      'ok': ok.length,
      'failed': failed,
      'horizonHoursAvailable': horizons,
    },
  );

  stdout.writeln('Done. ok=${ok.length} failed=${failed.length}');
  if (failed.isNotEmpty) exitCode = 2;
}

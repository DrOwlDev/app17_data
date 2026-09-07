import 'dart:io';

import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/hko_temperature_api.dart';
import 'package:app17_data/services/station_temperature_api.dart';
import 'package:timezone/timezone.dart' as tz;

/// Append recent observed temperatures into per-day CSVs and refresh
/// `daily_extremes.csv` for each station in `data/stations/index.json`.
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();

  final outRoot = args.isNotEmpty ? args.first : 'data/stations';
  final store = StationArchiveStore(root: Directory(outRoot));
  var stations = await store.readIndex();
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
  final collectedAt = DateTime.now().toUtc();
  final ok = <String>[];
  final failed = <String>[];
  var sampleTotal = 0;

  const concurrency = 6;
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= stations.length) return;
      final station = stations[i];
      try {
        final samples = station.sourceKind == 'hko'
            ? await hkoApi.fetchRecentObservations(
                observedDataSource: station.resolutionUrl,
              )
            : await tempApi.fetchRecentObservations(
                siteId: station.stationId,
                cityName: station.cityName,
                observedDataSource: station.resolutionUrl.isEmpty
                    ? null
                    : station.resolutionUrl,
              );

        await store.ensureStationDirs(station.stationId);

        // Group samples by local calendar date.
        final byDate = <String, List<TempObservationSample>>{};
        for (final s in samples) {
          final y = s.localTime.year.toString().padLeft(4, '0');
          final m = s.localTime.month.toString().padLeft(2, '0');
          final d = s.localTime.day.toString().padLeft(2, '0');
          final key = '$y-$m-$d';
          byDate.putIfAbsent(key, () => []).add(s);
        }

        for (final entry in byDate.entries) {
          final parts = entry.key.split('-');
          final dayLocal = tz.TZDateTime(
            station.location,
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
          final dayFile = store.observedDayFile(station.stationId, dayLocal);
          final existing =
              await dayFile.exists() ? await dayFile.readAsString() : null;
          final merged = mergeObservedCsv(
            existingCsv: existing,
            incoming: entry.value,
            collectedAtUtc: collectedAt,
          );
          await dayFile.writeAsString(merged);

          final extremes = extremesFromObservedCsv(merged);
          final extremesFile = store.dailyExtremesFile(station.stationId);
          final extremesExisting = await extremesFile.exists()
              ? await extremesFile.readAsString()
              : null;
          final extremesCsv = upsertDailyExtremesCsv(
            existingCsv: extremesExisting,
            dateYmd: entry.key,
            minC: extremes.minC,
            maxC: extremes.maxC,
            sampleCount: extremes.count,
            updatedAtUtc: collectedAt,
          );
          await extremesFile.writeAsString(extremesCsv);
        }

        sampleTotal += samples.length;
        ok.add(station.stationId);
        stdout.writeln(
          '  ✓ ${station.stationId} (${samples.length} samples, '
          '${byDate.length} day file(s))',
        );
      } catch (e) {
        failed.add(station.stationId);
        stderr.writeln('  ✗ ${station.stationId}: $e');
      }
    }
  }

  stdout.writeln('Collecting observations for ${stations.length} stations…');
  await Future.wait(List.generate(concurrency, (_) => worker()));
  tempApi.close();
  hkoApi.close();

  await writeRunSummary(
    job: 'collect_observed',
    summary: {
      'stationCount': stations.length,
      'ok': ok.length,
      'failed': failed,
      'sampleTotal': sampleTotal,
    },
  );

  stdout.writeln(
    'Done. ok=${ok.length} failed=${failed.length} samples=$sampleTotal',
  );
  if (failed.isNotEmpty) exitCode = 2;
}

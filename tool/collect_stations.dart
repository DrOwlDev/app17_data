import 'dart:io';

import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:app17_data/services/polymarket_api.dart';

/// Discover chartable temperature-market stations and write
/// `data/stations/index.json` + per-station `meta.json`.
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();

  final outRoot = args.isNotEmpty ? args.first : 'data/stations';
  final store = StationArchiveStore(root: Directory(outRoot));
  final api = PolymarketApi(preferStaticSnapshot: false);

  stdout.writeln('Fetching lowest + highest temperature events…');
  final events = await api.fetchTemperatureEvents();
  api.close();

  final stations = stationsFromEvents(events);
  await store.writeIndex(stations);

  await writeRunSummary(
    job: 'collect_stations',
    summary: {
      'eventCount': events.length,
      'stationCount': stations.length,
      'stationIds': stations.map((s) => s.stationId).toList(),
    },
  );

  stdout.writeln(
    'Wrote ${stations.length} stations to ${store.indexFile().path}',
  );
  for (final s in stations) {
    stdout.writeln('  ${s.stationId}  ${s.cityName}  (${s.sourceKind})');
  }
}

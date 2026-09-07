import 'dart:io';

import 'package:app17_data/archive/prune_archive.dart';
import 'package:app17_data/archive/skill_stats.dart';
import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() => CityTimezones.ensureInitialized());

  test('parseForecastFilenameUtc', () {
    expect(
      parseForecastFilenameUtc('20260907T1618Z.csv'),
      DateTime.utc(2026, 9, 7, 16, 18),
    );
    expect(parseForecastFilenameUtc('nope.csv'), isNull);
  });

  test('ArchivePruner deletes old observed and forecast files', () async {
    final root = await Directory.systemTemp.createTemp('prune_test_');
    addTearDown(() => root.delete(recursive: true));
    final store = StationArchiveStore(root: root);
    await store.writeIndex([
      const ArchiveStation(
        stationId: 'TEST',
        cityName: 'Tokyo',
        timeZone: 'Asia/Tokyo',
        resolutionUrl: 'https://example.com',
        sourceKind: 'wrh',
      ),
    ]);

    final oldObs = store.observedDayFile('TEST', DateTime.utc(2025, 1, 1));
    await oldObs.writeAsString(
      '$observedCsvHeader\n2025-01-01T00:00:00,10.0,src,2025-01-01T00:00:00Z\n',
    );
    final newObs = store.observedDayFile('TEST', DateTime.utc(2026, 9, 1));
    await newObs.writeAsString(
      '$observedCsvHeader\n2026-09-01T00:00:00,20.0,src,2026-09-01T00:00:00Z\n',
    );
    final oldFc = store.forecastSnapshotFile(
      'TEST',
      DateTime.utc(2025, 1, 2, 12, 0),
    );
    await oldFc.writeAsString(forecastCsvHeader);
    final newFc = store.forecastSnapshotFile(
      'TEST',
      DateTime.utc(2026, 9, 7, 12, 0),
    );
    await newFc.writeAsString(forecastCsvHeader);

    final extremes = store.dailyExtremesFile('TEST');
    await extremes.writeAsString(
      '$dailyExtremesCsvHeader\n'
      '2025-01-01,10.0,12.0,2,2025-01-01T00:00:00Z\n'
      '2026-09-01,18.0,22.0,3,2026-09-01T00:00:00Z\n',
    );

    final pruner = ArchivePruner(
      store: store,
      retainDays: 90,
      nowUtc: DateTime.utc(2026, 9, 7),
    );
    final result = await pruner.pruneAll();
    expect(result.deletedFiles, 2);
    expect(await oldObs.exists(), isFalse);
    expect(await newObs.exists(), isTrue);
    expect(await oldFc.exists(), isFalse);
    expect(await newFc.exists(), isTrue);
    expect(result.prunedExtremeRows, 1);
    final exBody = await extremes.readAsString();
    expect(exBody.contains('2025-01-01'), isFalse);
    expect(exBody.contains('2026-09-01'), isTrue);
  });

  test('SkillStatsBuilder pairs forecast to nearest obs', () async {
    final root = await Directory.systemTemp.createTemp('skill_test_');
    addTearDown(() => root.delete(recursive: true));
    final store = StationArchiveStore(root: root);
    final station = const ArchiveStation(
      stationId: 'TEST',
      cityName: 'Tokyo',
      timeZone: 'Asia/Tokyo',
      resolutionUrl: 'https://example.com',
      sourceKind: 'wrh',
    );
    await store.writeIndex([station]);

    final loc = tz.getLocation('Asia/Tokyo');
    final day = tz.TZDateTime(loc, 2026, 9, 7);
    final obsFile = store.observedDayFile('TEST', day);
    await obsFile.writeAsString(
      '$observedCsvHeader\n'
      '2026-09-07T12:00:00,25.0,src,2026-09-07T01:00:00Z\n'
      '2026-09-07T13:00:00,26.0,src,2026-09-07T01:00:00Z\n',
    );

    final issued = DateTime.utc(2026, 9, 7, 1, 0);
    final fcFile = store.forecastSnapshotFile('TEST', issued);
    await fcFile.writeAsString(
      '$forecastCsvHeader\n'
      '2026-09-07T12:00:00,25.4,api.open-meteo.com,2026-09-07T01:00:00.000Z,11.0\n'
      '2026-09-07T13:00:00,27.5,api.open-meteo.com,2026-09-07T01:00:00.000Z,12.0\n',
    );

    final built = await SkillStatsBuilder(store: store).buildForStation(station);
    expect(built, isNotNull);
    final summary = built!['summary'] as Map<String, dynamic>;
    expect(summary['pairCount'], 2);
    // |25.4-25.0|=0.4 hit, |27.5-26.0|=1.5 miss → 50%
    expect(summary['overallHitRate'], closeTo(0.5, 1e-9));
  });
}

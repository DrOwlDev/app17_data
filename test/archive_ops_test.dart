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
    // |25.4-25.0|=0.4 hit @ 0.4°C, |27.5-26.0|=1.5 miss → 50%
    expect(summary['overallHitRate'], closeTo(0.5, 1e-9));
  });

  test('tempBucketC floors toward colder integer', () {
    expect(tempBucketC(25.0), 25);
    expect(tempBucketC(25.9), 25);
    expect(tempBucketC(-1.1), -2);
  });

  test('0.4°C boundary is a hit; 0.41 is a miss', () async {
    final root = await Directory.systemTemp.createTemp('skill_tol_');
    addTearDown(() => root.delete(recursive: true));
    final store = StationArchiveStore(root: root);
    final station = const ArchiveStation(
      stationId: 'TOL',
      cityName: 'Tokyo',
      timeZone: 'Asia/Tokyo',
      resolutionUrl: 'https://example.com',
      sourceKind: 'wrh',
    );
    await store.writeIndex([station]);
    final loc = tz.getLocation('Asia/Tokyo');
    final day = tz.TZDateTime(loc, 2026, 9, 7);
    await store.observedDayFile('TOL', day).writeAsString(
      '$observedCsvHeader\n'
      '2026-09-07T12:00:00,20.0,src,2026-09-07T01:00:00Z\n'
      '2026-09-07T13:00:00,20.0,src,2026-09-07T01:00:00Z\n',
    );
    final issued = DateTime.utc(2026, 9, 7, 1, 0);
    await store.forecastSnapshotFile('TOL', issued).writeAsString(
      '$forecastCsvHeader\n'
      '2026-09-07T12:00:00,20.4,api.open-meteo.com,2026-09-07T01:00:00.000Z,11.0\n'
      '2026-09-07T13:00:00,20.41,api.open-meteo.com,2026-09-07T01:00:00.000Z,12.0\n',
    );
    final built = await SkillStatsBuilder(store: store).buildForStation(station);
    final summary = built!['summary'] as Map<String, dynamic>;
    expect(summary['overallHitRate'], closeTo(0.5, 1e-9));
  });

  test('computeExtremaTiming counts before-6am and after-6pm mins', () {
    final days = [
      DayExtremeStats(
        dateKey: '2026-09-01',
        minC: 10,
        maxC: 20,
        minFirstHour: 4,
        minLockHour: 5,
        maxFirstHour: 14,
        maxLockHour: 15,
      ),
      DayExtremeStats(
        dateKey: '2026-09-02',
        minC: 11,
        maxC: 21,
        minFirstHour: 19,
        minLockHour: 20,
        maxFirstHour: 13,
        maxLockHour: 13,
      ),
      DayExtremeStats(
        dateKey: '2026-09-03',
        minC: 12,
        maxC: 22,
        minFirstHour: 10,
        minLockHour: 10,
        maxFirstHour: 16,
        maxLockHour: 17,
      ),
    ];
    final t = computeExtremaTiming(days, lookbackDays: 14);
    expect(t['daysAnalyzed'], 3);
    expect(t['minBefore6amDays'], 1);
    expect(t['minAfter6pmDays'], 1);
    expect(t['minMidDayDays'], 1);
    expect(t['minMorningShare'], closeTo(1 / 3, 1e-9));
    expect(t['maxAfternoonShare'], 1.0);
    expect((t['minFirstHourHist'] as List)[4], 1);
    expect((t['minLockHourHist'] as List)[20], 1);
    expect(t['minModeHour'], isIn([4, 19, 10]));
  });

  test('computeDailyExtremeSkill hits min/max within 0.4°C and buckets', () {
    final dayStats = [
      DayExtremeStats(
        dateKey: '2026-09-07',
        minC: 18.2,
        maxC: 27.6,
        minFirstHour: 5,
        minLockHour: 5,
        maxFirstHour: 14,
        maxLockHour: 15,
      ),
    ];
    // Issued 01:00 UTC = 10:00 JST; local EOD Sep 8 00:00 JST = Sep 7 15:00 UTC → lead ~14h
    final csv =
        '$forecastCsvHeader\n'
        '2026-09-07T05:00:00,18.0,api.open-meteo.com,2026-09-07T01:00:00.000Z,4.0\n'
        '2026-09-07T14:00:00,27.5,api.open-meteo.com,2026-09-07T01:00:00.000Z,13.0\n';
    final result = computeDailyExtremeSkill(
      dayStats: dayStats,
      forecastFiles: [SkillForecastSnapshot.fromCsv(csv)],
      timeZone: 'Asia/Tokyo',
      toleranceC: 0.4,
      hitRateThreshold: 0.8,
    );
    expect(result.minExtremeHitRate, 1.0); // |18.0-18.2|=0.2
    expect(result.maxExtremeHitRate, 1.0); // |27.5-27.6|=0.1
    expect(result.minBucketHitRate, 1.0); // floor 18 == 18
    expect(result.maxBucketHitRate, 1.0); // floor 27 == 27
    expect(result.minSkillByLead, isNotEmpty);
    expect(result.minSkillByLead.first['leadHours'], 14);
  });

  test('timeToSkillHours finds earliest good lead at 0.4°C', () {
    final rows = [
      for (var h = 0; h <= 6; h++)
        {
          'leadHours': h,
          'n': 10,
          'mae': h <= 3 ? 0.3 : 0.8,
          'hitRate': h <= 3 ? 0.9 : 0.5,
        },
    ];
    expect(
      timeToSkillHours(rows, toleranceC: 0.4, hitRateThreshold: 0.8),
      3,
    );
  });

  test('leadHoursBeforeLocalEod uses station timezone', () {
    final lead = leadHoursBeforeLocalEod(
      issuedUtc: DateTime.utc(2026, 9, 7, 1, 0),
      dateKey: '2026-09-07',
      timeZone: 'Asia/Tokyo',
    );
    // EOD = 2026-09-08 00:00 JST = 2026-09-07 15:00 UTC → 14h
    expect(lead, closeTo(14.0, 1e-9));
  });

  test('SkillStatsBuilder emits extreme and timing fields', () async {
    final root = await Directory.systemTemp.createTemp('skill_ext_');
    addTearDown(() => root.delete(recursive: true));
    final store = StationArchiveStore(root: root);
    final station = const ArchiveStation(
      stationId: 'EXT',
      cityName: 'Tokyo',
      timeZone: 'Asia/Tokyo',
      resolutionUrl: 'https://example.com',
      sourceKind: 'wrh',
    );
    await store.writeIndex([station]);
    final loc = tz.getLocation('Asia/Tokyo');
    final day = tz.TZDateTime(loc, 2026, 9, 7);
    await store.observedDayFile('EXT', day).writeAsString(
      '$observedCsvHeader\n'
      '2026-09-07T05:00:00,18.0,src,2026-09-07T01:00:00Z\n'
      '2026-09-07T08:00:00,19.0,src,2026-09-07T01:00:00Z\n'
      '2026-09-07T12:00:00,22.0,src,2026-09-07T01:00:00Z\n'
      '2026-09-07T15:00:00,27.0,src,2026-09-07T01:00:00Z\n',
    );
    final issued = DateTime.utc(2026, 9, 7, 1, 0);
    await store.forecastSnapshotFile('EXT', issued).writeAsString(
      '$forecastCsvHeader\n'
      '2026-09-07T05:00:00,18.2,api.open-meteo.com,2026-09-07T01:00:00.000Z,4.0\n'
      '2026-09-07T15:00:00,27.1,api.open-meteo.com,2026-09-07T01:00:00.000Z,14.0\n',
    );
    final built = await SkillStatsBuilder(store: store).buildForStation(station);
    expect(built, isNotNull);
    final summary = built!['summary'] as Map<String, dynamic>;
    final skill = built['skill'] as Map<String, dynamic>;
    expect(summary['minBefore6amDays'], 1);
    expect(summary['minExtremeHitRate'], 1.0);
    expect(summary['maxExtremeHitRate'], 1.0);
    expect(skill['extremeSkillByLeadMin'], isNotEmpty);
    expect(skill['timing'], isA<Map>());
    expect((skill['timing'] as Map)['minModeHour'], 5);
  });
}

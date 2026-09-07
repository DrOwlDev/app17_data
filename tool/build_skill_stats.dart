import 'dart:io';

import 'package:app17_data/archive/skill_stats.dart';
import 'package:app17_data/archive/station_archive.dart';
import 'package:app17_data/services/city_timezones.dart';

/// Build forecast-vs-observed skill stats + browse file manifesto.
Future<void> main(List<String> args) async {
  CityTimezones.ensureInitialized();
  final store = StationArchiveStore(
    root: Directory(args.isNotEmpty ? args.first : 'data/stations'),
  );
  stdout.writeln('Building skill stats…');
  final builder = SkillStatsBuilder(store: store);
  final skill = await builder.buildAll();
  await writeAnalysisOutputs(skill: skill, store: store);
  stdout.writeln(
    'Wrote data/analysis/skill.json '
    '(${skill['stationCount']} stations with pairs) and files_manifest.json',
  );
}

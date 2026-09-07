import 'dart:io';

import 'package:app17_data/archive/prune_archive.dart';
import 'package:app17_data/archive/station_archive.dart';

/// Delete archive CSVs older than 90 days (3 months).
Future<void> main(List<String> args) async {
  final retainDays = args.isNotEmpty ? int.tryParse(args.first) ?? 90 : 90;
  final store = StationArchiveStore();
  final pruner = ArchivePruner(store: store, retainDays: retainDays);
  stdout.writeln(
    'Pruning archive older than $retainDays days '
    '(cutoff ${pruner.cutoffDate.toIso8601String().substring(0, 10)})…',
  );
  final result = await pruner.pruneAll();
  stdout.writeln(
    'Deleted ${result.deletedFiles} files; '
    'removed ${result.prunedExtremeRows} daily_extremes rows.',
  );
}

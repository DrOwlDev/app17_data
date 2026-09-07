import 'dart:io';

/// Assemble `build/pages` for GitHub Pages: static site + data/ copy.
Future<void> main(List<String> args) async {
  final out = Directory(args.isNotEmpty ? args.first : 'build/pages');
  if (await out.exists()) {
    await out.delete(recursive: true);
  }
  await out.create(recursive: true);

  await _copyDir(Directory('site'), out);
  final dataOut = Directory('${out.path}${Platform.pathSeparator}data');
  await dataOut.create(recursive: true);

  final stationsSrc = Directory('data/stations');
  if (await stationsSrc.exists()) {
    await _copyDir(
      stationsSrc,
      Directory('${dataOut.path}${Platform.pathSeparator}stations'),
    );
  }
  final analysisSrc = Directory('data/analysis');
  if (await analysisSrc.exists()) {
    await _copyDir(
      analysisSrc,
      Directory('${dataOut.path}${Platform.pathSeparator}analysis'),
    );
  }
  final runsSrc = Directory('data/runs');
  if (await runsSrc.exists()) {
    await _copyDir(
      runsSrc,
      Directory('${dataOut.path}${Platform.pathSeparator}runs'),
    );
  }

  stdout.writeln('Built Pages bundle at ${out.path}');
}

Future<void> _copyDir(Directory src, Directory dest) async {
  await dest.create(recursive: true);
  await for (final entity in src.list(recursive: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == '.gitkeep') continue;
    final targetPath = '${dest.path}${Platform.pathSeparator}$name';
    if (entity is Directory) {
      await _copyDir(entity, Directory(targetPath));
    } else if (entity is File) {
      await entity.copy(targetPath);
    }
  }
}

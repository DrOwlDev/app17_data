import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import 'city_timezones.dart';
import 'hko_weather_icons.dart';
import 'station_temperature_api.dart';

/// Fetches HKO observed (hkoc.csv) + OCF forecast for Hong Kong markets.
class HkoTemperatureApi {
  HkoTemperatureApi({http.Client? client})
      : _client = client ?? http.Client();

  static const stationId = 'HKO';
  static const observedStationName = 'HK Observatory';
  static const regionalPortalUrl =
      'https://www.hko.gov.hk/en/wxinfo/awsgis/regional_portal.html?loc=hko';
  static const hkocCsvUrl =
      'https://www.hko.gov.hk/wxinfo/awsgis/hkoc.csv';
  static const ocfForecastUrl =
      'https://maps.weather.gov.hk/ocf/dat/$stationId.xml';
  static const latestTempCsvUrl =
      'https://data.weather.gov.hk/weatherAPI/hko_data/'
      'regional-weather/latest_1min_temperature.csv';
  static const hkocCsvReferer =
      'https://www.hko.gov.hk/en/wxinfo/awsgis/regional_portal.html';
  static const defaultObservedDataSource = 'https://www.weather.gov.hk';
  static const forecastDataSource = 'maps.weather.gov.hk/ocf';
  static const _userAgent =
      'app17_data (https://github.com/DrOwlDev/app17_data)';

  final http.Client _client;

  Map<String, String> get _hkocHeaders => {
        'Referer': hkocCsvReferer,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      };

  Map<String, String> get _jsonHeaders => {
        'User-Agent': _userAgent,
        'Accept': 'application/json,text/plain,*/*',
      };

  Future<DailyTemperatureSeries> fetchDailySeries({
    required int year,
    required int month,
    required int day,
    required String unit,
    String? observedDataSource,
    DateTime? nowUtc,
  }) async {
    final location =
        CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final dayStart = tz.TZDateTime(location, year, month, day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final nowLocal = tz.TZDateTime.from(
      (nowUtc ?? DateTime.now()).toUtc(),
      location,
    );
    final unitNorm = unit == 'F' ? 'F' : 'C';

    final obsFuture = _fetchHkocObservationsC(
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    final forecastFuture = _fetchOcfForecastC(
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    final latestFuture = _fetchLatestObservation(
      location: location,
      unit: unitNorm,
    );

    final observedC = await obsFuture;
    final forecast = await forecastFuture;
    final latestObservation = await latestFuture;

    final obsSource =
        (observedDataSource != null && observedDataSource.trim().isNotEmpty)
            ? observedDataSource.trim()
            : defaultObservedDataSource;

    final points = mergeHourlySeries(
      dayStart: dayStart,
      dayEnd: dayEnd,
      nowLocal: nowLocal,
      observedC: observedC,
      forecastC: forecast.tempsC,
      forecastWeatherCodes: forecast.weatherIconCodes,
      unit: unitNorm,
      observedDataSource: obsSource,
      forecastDataSource: forecastDataSource,
    );

    return DailyTemperatureSeries(
      siteId: stationId,
      unit: unitNorm,
      dayStart: dayStart,
      dayEnd: dayEnd,
      nowLocal: nowLocal,
      points: points,
      latestObservation: latestObservation,
    );
  }

  /// Recent HKO Observatory observations (°C) for a rolling lookback window.
  Future<List<TempObservationSample>> fetchRecentObservations({
    String? observedDataSource,
    Duration lookback = const Duration(hours: 36),
    DateTime? nowUtc,
  }) async {
    final location =
        CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final nowLocal = tz.TZDateTime.from(
      (nowUtc ?? DateTime.now()).toUtc(),
      location,
    );
    final windowStart = nowLocal.subtract(lookback);
    final obsSource =
        (observedDataSource != null && observedDataSource.trim().isNotEmpty)
            ? observedDataSource.trim()
            : defaultObservedDataSource;

    final indexed = await _fetchHkocObservationsC(
      location: location,
      dayStart: windowStart,
      dayEnd: nowLocal,
    );
    final keys = indexed.keys.toList()..sort();
    return [
      for (final key in keys)
        TempObservationSample(
          localTime:
              tz.TZDateTime.fromMillisecondsSinceEpoch(location, key),
          tempC: indexed[key]!,
          dataSource: obsSource,
        ),
    ];
  }

  /// HKO OCF hourly forecast from city-local now through [horizonHours].
  ///
  /// OCF may cover less than 72h; [ForecastHorizonSeries.horizonHoursAvailable]
  /// reports what was actually returned.
  Future<ForecastHorizonSeries> fetchForecastHorizonC({
    int horizonHours = 72,
    DateTime? nowUtc,
  }) async {
    final location =
        CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
    final issuedAtUtc = (nowUtc ?? DateTime.now()).toUtc();
    final nowLocal = tz.TZDateTime.from(issuedAtUtc, location);
    final horizonEnd = nowLocal.add(Duration(hours: horizonHours));

    final forecast = await _fetchOcfForecastC(
      location: location,
      dayStart: nowLocal,
      dayEnd: horizonEnd,
    );

    final keys = forecast.tempsC.keys.toList()..sort();
    final points = <ForecastHorizonPoint>[];
    for (final key in keys) {
      final valid =
          tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
      if (valid.isBefore(nowLocal) || valid.isAfter(horizonEnd)) continue;
      points.add(
        ForecastHorizonPoint(
          validLocal: valid,
          tempC: forecast.tempsC[key]!,
          leadHours: valid.difference(nowLocal).inMinutes / 60.0,
        ),
      );
    }

    return ForecastHorizonSeries(
      siteId: stationId,
      forecastSource: forecastDataSource,
      nowLocal: nowLocal,
      horizonEnd: horizonEnd,
      issuedAtUtc: issuedAtUtc,
      requestedHorizonHours: horizonHours,
      points: points,
    );
  }

  Future<Map<int, double>> _fetchHkocObservationsC({
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(hkocCsvUrl),
        headers: _hkocHeaders,
      );
      if (response.statusCode != 200) return {};
      final samples = parseHkocCsvSamples(response.body);
      return indexMetarObservations(
        location: location,
        dayStart: dayStart,
        dayEnd: dayEnd,
        samples: samples,
      );
    } catch (_) {
      return {};
    }
  }

  Future<({Map<int, double> tempsC, Map<int, int> weatherIconCodes})>
      _fetchOcfForecastC({
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(ocfForecastUrl),
        headers: _jsonHeaders,
      );
      if (response.statusCode != 200) {
        return (tempsC: <int, double>{}, weatherIconCodes: <int, int>{});
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return (tempsC: <int, double>{}, weatherIconCodes: <int, int>{});
      }
      return indexOcfHourlyForecast(
        json: Map<String, dynamic>.from(decoded),
        location: location,
        dayStart: dayStart,
        dayEnd: dayEnd,
      );
    } catch (_) {
      return (tempsC: <int, double>{}, weatherIconCodes: <int, int>{});
    }
  }

  Future<LatestStationObservation?> _fetchLatestObservation({
    required tz.Location location,
    required String unit,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(latestTempCsvUrl),
        headers: _jsonHeaders,
      );
      if (response.statusCode != 200) return null;
      final parsed = parseHkoLatestTemperatureCsv(response.body);
      if (parsed == null) return null;
      final local = tz.TZDateTime(
        location,
        parsed.wall.year,
        parsed.wall.month,
        parsed.wall.day,
        parsed.wall.hour,
        parsed.wall.minute,
      );
      return LatestStationObservation(
        temperature: convertTempC(parsed.tempC, unit),
        observedAtLocal: local,
      );
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

/// Parse hkoc.csv into UTC samples (wall times interpreted as HKT).
List<({DateTime utc, double tempC})> parseHkocCsvSamples(String csvBody) {
  final location = CityTimezones.locationForCity('Hong Kong') ?? tz.UTC;
  final samples = <({DateTime utc, double tempC})>[];
  final lines = csvBody.split('\n');
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(',');
    if (parts.length < 2) continue;
    final wall = parseHkoCompactDateTime(parts[0].trim());
    final temp = _parseHkoNumber(parts[1].trim());
    if (wall == null || temp == null) continue;
    final local = tz.TZDateTime(
      location,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    samples.add((utc: local.toUtc(), tempC: temp));
  }
  return samples;
}

/// Index OCF hourly forecast temperatures (°C) and weather icon codes.
({Map<int, double> tempsC, Map<int, int> weatherIconCodes})
    indexOcfHourlyForecast({
  required Map<String, dynamic> json,
  required tz.Location location,
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
}) {
  final hourly = json['HourlyWeatherForecast'];
  if (hourly is! List) {
    return (tempsC: <int, double>{}, weatherIconCodes: <int, int>{});
  }
  final tempsC = <int, double>{};
  final weatherIconCodes = <int, int>{};
  for (final item in hourly) {
    if (item is! Map) continue;
    final hourRaw = item['ForecastHour']?.toString() ?? '';
    final temp = _toDouble(item['ForecastTemperature']);
    if (temp == null) continue;
    final wall = parseHkoCompactDateTime(hourRaw);
    if (wall == null) continue;
    final hourStart = tz.TZDateTime(
      location,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
    );
    if (hourStart.isBefore(dayStart) || hourStart.isAfter(dayEnd)) continue;
    final key = hourStart.millisecondsSinceEpoch;
    tempsC[key] = temp;
    final iconRaw = item['ForecastWeather'];
    int? rawCode;
    if (iconRaw is num) {
      rawCode = iconRaw.toInt();
    } else if (iconRaw != null) {
      rawCode = int.tryParse(iconRaw.toString());
    }
    final icon = normalizeHkoWeatherIconCode(rawCode);
    if (icon != null) weatherIconCodes[key] = icon;
  }
  return (
    tempsC: tempsC,
    weatherIconCodes: expandOcfWeatherIconCodes(
      hourKeys: tempsC.keys,
      sparseCodes: weatherIconCodes,
    ),
  );
}

/// OCF emits [ForecastWeather] about every 3 hours; expand so every forecast
/// hour gets an icon (forward-fill, then back-fill before the first code).
Map<int, int> expandOcfWeatherIconCodes({
  required Iterable<int> hourKeys,
  required Map<int, int> sparseCodes,
}) {
  if (sparseCodes.isEmpty) return {};
  final hours = hourKeys.toList()..sort();
  if (hours.isEmpty) return Map<int, int>.from(sparseCodes);

  final out = <int, int>{};
  int? last;
  for (final h in hours) {
    final explicit = sparseCodes[h];
    if (explicit != null) last = explicit;
    if (last != null) out[h] = last;
  }

  int? next;
  for (var i = hours.length - 1; i >= 0; i--) {
    final h = hours[i];
    final explicit = sparseCodes[h];
    if (explicit != null) next = explicit;
    if (!out.containsKey(h) && next != null) out[h] = next;
  }
  return out;
}

/// Index OCF hourly forecast temperatures (°C) for the local day window.
Map<int, double> indexOcfHourlyForecastC({
  required Map<String, dynamic> json,
  required tz.Location location,
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
}) {
  return indexOcfHourlyForecast(
    json: json,
    location: location,
    dayStart: dayStart,
    dayEnd: dayEnd,
  ).tempsC;
}

/// Parse `latest_1min_temperature.csv` row for HK Observatory.
({DateTime wall, double tempC})? parseHkoLatestTemperatureCsv(String csvBody) {
  final lines = csvBody.split('\n');
  for (final line in lines) {
    final parts = _splitCsvLine(line);
    if (parts.length < 3) continue;
    if (parts[1].trim() != HkoTemperatureApi.observedStationName) continue;
    final wall = parseHkoCompactDateTime(parts[0].trim());
    final temp = _parseHkoNumber(parts[2].trim());
    if (wall == null || temp == null) continue;
    return (wall: wall, tempC: temp);
  }
  return null;
}

/// Parse HKO compact timestamps: `YYYYMMDDHH`, `YYYYMMDDHHMM`, or `YYYY/MM/DD HH:MM`.
DateTime? parseHkoCompactDateTime(String raw) {
  if (RegExp(r'^\d+$').hasMatch(raw)) {
    if (raw.length == 10) {
      final year = int.tryParse(raw.substring(0, 4));
      final month = int.tryParse(raw.substring(4, 6));
      final day = int.tryParse(raw.substring(6, 8));
      final hour = int.tryParse(raw.substring(8, 10));
      if ([year, month, day, hour].contains(null)) return null;
      return DateTime(year!, month!, day!, hour!);
    }
    if (raw.length >= 12) {
      final year = int.tryParse(raw.substring(0, 4));
      final month = int.tryParse(raw.substring(4, 6));
      final day = int.tryParse(raw.substring(6, 8));
      final hour = int.tryParse(raw.substring(8, 10));
      final minute = int.tryParse(raw.substring(10, 12));
      if ([year, month, day, hour, minute].contains(null)) return null;
      return DateTime(year!, month!, day!, hour!, minute!);
    }
    return null;
  }

  final match =
      RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  );
}

double? _parseHkoNumber(String raw) {
  if (raw.isEmpty || raw == '----' || raw == '9999') return null;
  final cleaned = raw.endsWith('*') ? raw.substring(0, raw.length - 1) : raw;
  return double.tryParse(cleaned);
}

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

List<String> _splitCsvLine(String line) {
  // Simple split is enough for HKO regional CSVs (no embedded commas in fields).
  return line.split(',');
}

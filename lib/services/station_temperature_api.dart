import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import 'city_timezones.dart';

enum TempPointKind { observed, forecast }

class HourlyTempPoint {
  const HourlyTempPoint({
    required this.localHourStart,
    required this.temperature,
    required this.kind,
    this.dataSource = '',
    this.isDailyMinimum = false,
    this.isDailyMaximum = false,
    this.weatherIconCode,
  });

  /// City-local timestamp for this sample (may be sub-hourly for observations).
  final tz.TZDateTime localHourStart;
  final double temperature;
  final TempPointKind kind;

  /// Where the value came from (WRH URL, api.weather.gov, api.open-meteo.com, …).
  final String dataSource;

  /// True when this hour ties the observation-day minimum temperature.
  final bool isDailyMinimum;

  /// True when this hour ties the observation-day maximum temperature.
  final bool isDailyMaximum;

  /// HKO OCF [ForecastWeather] icon code when present (forecast hours only).
  final int? weatherIconCode;

  HourlyTempPoint copyWith({
    String? dataSource,
    bool? isDailyMinimum,
    bool? isDailyMaximum,
    int? weatherIconCode,
  }) {
    return HourlyTempPoint(
      localHourStart: localHourStart,
      temperature: temperature,
      kind: kind,
      dataSource: dataSource ?? this.dataSource,
      isDailyMinimum: isDailyMinimum ?? this.isDailyMinimum,
      isDailyMaximum: isDailyMaximum ?? this.isDailyMaximum,
      weatherIconCode: weatherIconCode ?? this.weatherIconCode,
    );
  }

  Map<String, dynamic> toJson() => {
        't': localHourStart.toUtc().toIso8601String(),
        'temp': temperature,
        'kind': kind == TempPointKind.observed ? 'observed' : 'forecast',
        if (dataSource.isNotEmpty) 'dataSource': dataSource,
        if (isDailyMinimum) 'isDailyMinimum': true,
        if (isDailyMaximum) 'isDailyMaximum': true,
        if (weatherIconCode != null) 'weatherIconCode': weatherIconCode,
      };

  factory HourlyTempPoint.fromJson(
    Map<String, dynamic> json, {
    required tz.Location location,
  }) {
    final kindRaw = json['kind']?.toString() ?? 'forecast';
    final iconRaw = json['weatherIconCode'];
    int? iconCode;
    if (iconRaw is num) {
      iconCode = iconRaw.toInt();
    } else if (iconRaw != null) {
      iconCode = int.tryParse(iconRaw.toString());
    }
    return HourlyTempPoint(
      localHourStart: _tzFromUtcIso(json['t']?.toString(), location),
      temperature: (json['temp'] as num?)?.toDouble() ?? 0,
      kind: kindRaw == 'observed'
          ? TempPointKind.observed
          : TempPointKind.forecast,
      dataSource: json['dataSource']?.toString() ?? '',
      isDailyMinimum: json['isDailyMinimum'] == true,
      isDailyMaximum: json['isDailyMaximum'] == true,
      weatherIconCode: iconCode,
    );
  }
}

class DailyTemperatureSeries {
  const DailyTemperatureSeries({
    required this.siteId,
    required this.unit,
    required this.dayStart,
    required this.dayEnd,
    required this.nowLocal,
    required this.points,
    this.latestObservation,
  });

  final String siteId;
  /// `C` or `F`.
  final String unit;
  final tz.TZDateTime dayStart;
  final tz.TZDateTime dayEnd;
  final tz.TZDateTime nowLocal;
  final List<HourlyTempPoint> points;

  /// Latest station observation from api.weather.gov (temp + observed time).
  final LatestStationObservation? latestObservation;

  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'unit': unit,
        'timeZone': dayStart.location.name,
        'dayStart': dayStart.toUtc().toIso8601String(),
        'dayEnd': dayEnd.toUtc().toIso8601String(),
        'nowLocal': nowLocal.toUtc().toIso8601String(),
        'points': points.map((p) => p.toJson()).toList(),
        if (latestObservation != null)
          'latestObservation': latestObservation!.toJson(),
      };

  factory DailyTemperatureSeries.fromJson(Map<String, dynamic> json) {
    final tzName = json['timeZone']?.toString() ?? 'UTC';
    late final tz.Location location;
    try {
      location = tz.getLocation(tzName);
    } catch (_) {
      location = tz.UTC;
    }
    final pointsRaw = json['points'];
    final points = <HourlyTempPoint>[];
    if (pointsRaw is List) {
      for (final item in pointsRaw) {
        if (item is Map<String, dynamic>) {
          points.add(HourlyTempPoint.fromJson(item, location: location));
        } else if (item is Map) {
          points.add(
            HourlyTempPoint.fromJson(
              Map<String, dynamic>.from(item),
              location: location,
            ),
          );
        }
      }
    }
    LatestStationObservation? latest;
    final latestRaw = json['latestObservation'];
    if (latestRaw is Map<String, dynamic>) {
      latest = LatestStationObservation.fromJson(latestRaw, location: location);
    } else if (latestRaw is Map) {
      latest = LatestStationObservation.fromJson(
        Map<String, dynamic>.from(latestRaw),
        location: location,
      );
    }
    return DailyTemperatureSeries(
      siteId: json['siteId']?.toString() ?? '',
      unit: json['unit']?.toString() == 'F' ? 'F' : 'C',
      dayStart: _tzFromUtcIso(json['dayStart']?.toString(), location),
      dayEnd: _tzFromUtcIso(json['dayEnd']?.toString(), location),
      nowLocal: _tzFromUtcIso(json['nowLocal']?.toString(), location),
      points: points,
      latestObservation: latest,
    );
  }
}

/// Latest observation from `api.weather.gov/stations/{id}/observations/latest`.
class LatestStationObservation {
  const LatestStationObservation({
    required this.temperature,
    required this.observedAtLocal,
  });

  /// Temperature in the series unit (`C` or `F`).
  final double temperature;
  final tz.TZDateTime observedAtLocal;

  Map<String, dynamic> toJson() => {
        'temp': temperature,
        't': observedAtLocal.toUtc().toIso8601String(),
      };

  factory LatestStationObservation.fromJson(
    Map<String, dynamic> json, {
    required tz.Location location,
  }) {
    return LatestStationObservation(
      temperature: (json['temp'] as num?)?.toDouble() ?? 0,
      observedAtLocal: _tzFromUtcIso(json['t']?.toString(), location),
    );
  }
}

tz.TZDateTime _tzFromUtcIso(String? iso, tz.Location location) {
  final parsed = DateTime.tryParse(iso ?? '');
  if (parsed == null) {
    return tz.TZDateTime.fromMillisecondsSinceEpoch(location, 0);
  }
  return tz.TZDateTime.from(parsed.toUtc(), location);
}

/// One observed temperature sample for the archive (°C).
class TempObservationSample {
  const TempObservationSample({
    required this.localTime,
    required this.tempC,
    required this.dataSource,
  });

  final tz.TZDateTime localTime;
  final double tempC;
  final String dataSource;
}

/// One hourly forecast valid time for a horizon snapshot (°C).
class ForecastHorizonPoint {
  const ForecastHorizonPoint({
    required this.validLocal,
    required this.tempC,
    required this.leadHours,
  });

  final tz.TZDateTime validLocal;
  final double tempC;
  final double leadHours;
}

/// Forecast from city-local now through a requested horizon.
class ForecastHorizonSeries {
  const ForecastHorizonSeries({
    required this.siteId,
    required this.forecastSource,
    required this.nowLocal,
    required this.horizonEnd,
    required this.issuedAtUtc,
    required this.requestedHorizonHours,
    required this.points,
  });

  final String siteId;
  final String forecastSource;
  final tz.TZDateTime nowLocal;
  final tz.TZDateTime horizonEnd;
  final DateTime issuedAtUtc;
  final int requestedHorizonHours;
  final List<ForecastHorizonPoint> points;

  /// Hours from now to the last available forecast point (0 if empty).
  double get horizonHoursAvailable {
    if (points.isEmpty) return 0;
    return points.last.validLocal.difference(nowLocal).inMinutes / 60.0;
  }
}

/// Fetches observed METARs + hourly forecast for a WRH timeseries site day.
///
/// Forecast preference: api.weather.gov hourly → Open-Meteo NBM (CONUS) →
/// default Open-Meteo (last resort / non-US).
class StationTemperatureApi {
  StationTemperatureApi({http.Client? client})
      : _client = client ?? http.Client();

  static const _aviationBase = 'https://aviationweather.gov/api/data';
  static const _nwsBase = 'https://api.weather.gov';
  static const _openMeteoBase = 'https://api.open-meteo.com/v1/forecast';
  static const _userAgent =
      'app17_data (https://github.com/DrOwlDev/app17_data)';

  /// Default observed label when the market resolution URL is unavailable.
  static const defaultObservedDataSource =
      'https://www.weather.gov/wrh/timeseries';
  static const nwsForecastDataSource = 'api.weather.gov';
  /// Open-Meteo National Blend of Models (CONUS) — preferred US fallback.
  static const openMeteoNbmForecastDataSource =
      'api.open-meteo.com (NBM)';
  static const openMeteoForecastDataSource = 'api.open-meteo.com';
  static const openMeteoNbmModel = 'ncep_nbm_conus';

  /// Weather.com historical observations (same feed WU Daily Observations uses).
  /// Used when aviationweather.gov METAR is empty (common for some CN ICAOs).
  static const weatherComHistoricalBase =
      'https://api.weather.com/v1/location';
  /// Public key embedded in Weather Underground / weather.com web clients.
  static const weatherComPublicApiKey = '6532d6454b8aa370768e63d6ba5a832e';

  final http.Client _client;

  /// Recent station observations (°C) for the rolling [lookback] window ending
  /// at [nowUtc] (default now). METAR first; Weather.com historical fallback.
  Future<List<TempObservationSample>> fetchRecentObservations({
    required String siteId,
    required String cityName,
    String? observedDataSource,
    Duration lookback = const Duration(hours: 36),
    DateTime? nowUtc,
  }) async {
    final location = CityTimezones.locationForCity(cityName) ?? tz.UTC;
    final nowLocal = tz.TZDateTime.from(
      (nowUtc ?? DateTime.now()).toUtc(),
      location,
    );
    final windowStart = nowLocal.subtract(lookback);
    final icao = siteId.toUpperCase();
    final hours = lookback.inHours.clamp(24, 96);
    final obsSource =
        (observedDataSource != null && observedDataSource.trim().isNotEmpty)
            ? observedDataSource.trim()
            : defaultObservedDataSource;

    final stationFuture = _fetchStation(icao);
    final samples = await _fetchMetarRawSamples(icao: icao, hours: hours);
    final station = await stationFuture;

    var indexed = indexMetarObservations(
      location: location,
      dayStart: windowStart,
      dayEnd: nowLocal,
      samples: samples,
    );

    if (indexed.isEmpty) {
      final country = station?.country ??
          countryCodeFromWuHistoryUrl(observedDataSource);
      if (country != null && country.isNotEmpty) {
        // Cover each local calendar day that intersects the lookback window.
        var day = tz.TZDateTime(
          location,
          windowStart.year,
          windowStart.month,
          windowStart.day,
        );
        final lastDay = tz.TZDateTime(
          location,
          nowLocal.year,
          nowLocal.month,
          nowLocal.day,
        );
        final merged = <int, double>{};
        while (!day.isAfter(lastDay)) {
          final dayEnd = day.add(const Duration(days: 1));
          final wu = await _fetchWuHistoricalObservationsC(
            icao: icao,
            country: country,
            location: location,
            dayStart: day,
            dayEnd: dayEnd,
          );
          for (final e in wu.temps.entries) {
            final t =
                tz.TZDateTime.fromMillisecondsSinceEpoch(location, e.key);
            if (t.isBefore(windowStart) || t.isAfter(nowLocal)) continue;
            merged[e.key] = e.value;
          }
          day = dayEnd;
        }
        indexed = merged;
      }
    }

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

  /// Hourly forecast from city-local now through [horizonHours] ahead (°C).
  Future<ForecastHorizonSeries> fetchForecastHorizonC({
    required String siteId,
    required String cityName,
    int horizonHours = 72,
    DateTime? nowUtc,
  }) async {
    final location = CityTimezones.locationForCity(cityName) ?? tz.UTC;
    final issuedAtUtc = (nowUtc ?? DateTime.now()).toUtc();
    final nowLocal = tz.TZDateTime.from(issuedAtUtc, location);
    final horizonEnd = nowLocal.add(Duration(hours: horizonHours));
    final icao = siteId.toUpperCase();

    final station = await _fetchStation(icao);
    var temps = <int, double>{};
    var source = openMeteoForecastDataSource;
    if (station != null) {
      final forecast = await _fetchForecastHourlyC(
        lat: station.lat,
        lon: station.lon,
        location: location,
        dayStart: nowLocal,
        dayEnd: horizonEnd,
        openMeteoForecastDays: 4,
        openMeteoPastDays: 0,
      );
      temps = forecast.temps;
      source = forecast.source;
    }

    final keys = temps.keys.toList()..sort();
    final points = <ForecastHorizonPoint>[];
    for (final key in keys) {
      final valid =
          tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
      if (valid.isBefore(nowLocal) || valid.isAfter(horizonEnd)) continue;
      final lead =
          valid.difference(nowLocal).inMinutes / 60.0;
      points.add(
        ForecastHorizonPoint(
          validLocal: valid,
          tempC: temps[key]!,
          leadHours: lead,
        ),
      );
    }

    return ForecastHorizonSeries(
      siteId: icao,
      forecastSource: source,
      nowLocal: nowLocal,
      horizonEnd: horizonEnd,
      issuedAtUtc: issuedAtUtc,
      requestedHorizonHours: horizonHours,
      points: points,
    );
  }

  Future<DailyTemperatureSeries> fetchDailySeries({
    required String siteId,
    required String cityName,
    required int year,
    required int month,
    required int day,
    required String unit,
    String? observedDataSource,
    DateTime? nowUtc,
  }) async {
    final location = CityTimezones.locationForCity(cityName) ?? tz.UTC;
    final dayStart = tz.TZDateTime(location, year, month, day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final nowLocal = tz.TZDateTime.from(
      (nowUtc ?? DateTime.now()).toUtc(),
      location,
    );

    final icao = siteId.toUpperCase();
    final unitNorm = unit == 'F' ? 'F' : 'C';
    final hoursNeeded = math.max(
      24,
      dayEnd.toUtc().difference(DateTime.now().toUtc()).inHours.abs() + 36,
    );
    final stationFuture = _fetchStation(icao);
    final obsFuture = _fetchMetarObservationsC(
      icao: icao,
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
      hours: hoursNeeded.clamp(24, 96),
    );
    final latestFuture = _fetchNwsLatestObservation(
      icao: icao,
      location: location,
      unit: unitNorm,
    );

    final station = await stationFuture;
    var obsC = await obsFuture;
    var latestObservation = await latestFuture;

    // Some ICAOs (e.g. ZSJN) are listed in stationinfo but return no METARs
    // from AWC; fall back to Weather.com historical (WU Daily Observations).
    if (obsC.isEmpty) {
      final country = station?.country ??
          countryCodeFromWuHistoryUrl(observedDataSource);
      if (country != null && country.isNotEmpty) {
        final wu = await _fetchWuHistoricalObservationsC(
          icao: icao,
          country: country,
          location: location,
          dayStart: dayStart,
          dayEnd: dayEnd,
        );
        obsC = wu.temps;
        latestObservation ??= wu.latest == null
            ? null
            : LatestStationObservation(
                temperature: convertTempC(wu.latest!.tempC, unitNorm),
                observedAtLocal: wu.latest!.local,
              );
      }
    }

    var forecastC = <int, double>{};
    var forecastSource = openMeteoForecastDataSource;
    if (station != null) {
      final forecast = await _fetchForecastHourlyC(
        lat: station.lat,
        lon: station.lon,
        location: location,
        dayStart: dayStart,
        dayEnd: dayEnd,
      );
      forecastC = forecast.temps;
      forecastSource = forecast.source;
    }

    final obsSource = (observedDataSource != null &&
            observedDataSource.trim().isNotEmpty)
        ? observedDataSource.trim()
        : defaultObservedDataSource;

    final points = mergeHourlySeries(
      dayStart: dayStart,
      dayEnd: dayEnd,
      nowLocal: nowLocal,
      observedC: obsC,
      forecastC: forecastC,
      unit: unitNorm,
      observedDataSource: obsSource,
      forecastDataSource: forecastSource,
    );

    return DailyTemperatureSeries(
      siteId: icao,
      unit: unitNorm,
      dayStart: dayStart,
      dayEnd: dayEnd,
      nowLocal: nowLocal,
      points: points,
      latestObservation: latestObservation,
    );
  }

  Future<LatestStationObservation?> _fetchNwsLatestObservation({
    required String icao,
    required tz.Location location,
    required String unit,
  }) async {
    try {
      final uri = Uri.parse('$_nwsBase/stations/$icao/observations/latest');
      final response = await _client.get(
        uri,
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final props = decoded['properties'];
      if (props is! Map) return null;
      final tempObj = props['temperature'];
      final tempC = tempObj is Map ? (tempObj['value'] as num?)?.toDouble() : null;
      final ts = DateTime.tryParse(props['timestamp']?.toString() ?? '');
      if (tempC == null || ts == null) return null;
      return LatestStationObservation(
        temperature: convertTempC(tempC, unit),
        observedAtLocal: tz.TZDateTime.from(ts.toUtc(), location),
      );
    } catch (_) {
      return null;
    }
  }

  Future<({double lat, double lon, String? country})?> _fetchStation(
    String icao,
  ) async {
    final uri = Uri.parse(
      '$_aviationBase/stationinfo?ids=$icao&format=json',
    );
    final response = await _client.get(uri);
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty) return null;
    final first = decoded.first;
    if (first is! Map) return null;
    final lat = (first['lat'] as num?)?.toDouble();
    final lon = (first['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    final country = first['country']?.toString().trim().toUpperCase();
    return (
      lat: lat,
      lon: lon,
      country: (country == null || country.isEmpty) ? null : country,
    );
  }

  /// Weather.com / WU historical observations when AWC METAR is unavailable.
  Future<
      ({
        Map<int, double> temps,
        ({tz.TZDateTime local, double tempC})? latest,
      })> _fetchWuHistoricalObservationsC({
    required String icao,
    required String country,
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
  }) async {
    final ymd =
        '${dayStart.year.toString().padLeft(4, '0')}'
        '${dayStart.month.toString().padLeft(2, '0')}'
        '${dayStart.day.toString().padLeft(2, '0')}';
    final locId = '$icao:9:${country.toUpperCase()}';
    final uri = Uri.parse(
      '$weatherComHistoricalBase/$locId/observations/historical.json'
      '?apiKey=$weatherComPublicApiKey&units=m&startDate=$ymd&endDate=$ymd',
    );
    try {
      final response = await _client.get(
        uri,
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
      );
      if (response.statusCode != 200) {
        return (temps: <int, double>{}, latest: null);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return (temps: <int, double>{}, latest: null);
      }
      final samples = parseWeatherComHistoricalObservationsC(decoded);
      final temps = indexMetarObservations(
        location: location,
        dayStart: dayStart,
        dayEnd: dayEnd,
        samples: samples,
      );
      ({tz.TZDateTime local, double tempC})? latest;
      if (samples.isNotEmpty) {
        final last = samples.last;
        latest = (
          local: tz.TZDateTime.from(last.utc.toUtc(), location),
          tempC: last.tempC,
        );
      }
      return (temps: temps, latest: latest);
    } catch (_) {
      return (temps: <int, double>{}, latest: null);
    }
  }

  Future<List<({DateTime utc, double tempC})>> _fetchMetarRawSamples({
    required String icao,
    required int hours,
  }) async {
    final uri = Uri.parse(
      '$_aviationBase/metar?ids=$icao&format=json&hours=$hours',
    );
    final response = await _client.get(uri);
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];

    final samples = <({DateTime utc, double tempC})>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final temp = (item['temp'] as num?)?.toDouble();
      if (temp == null) continue;
      final reportTime = DateTime.tryParse(item['reportTime']?.toString() ?? '');
      DateTime? obsUtc;
      if (reportTime != null) {
        obsUtc = reportTime.toUtc();
      } else {
        final obsSec = item['obsTime'];
        if (obsSec is num) {
          obsUtc = DateTime.fromMillisecondsSinceEpoch(
            (obsSec * 1000).round(),
            isUtc: true,
          );
        }
      }
      if (obsUtc == null) continue;
      samples.add((utc: obsUtc, tempC: temp));
    }
    return samples;
  }

  Future<Map<int, double>> _fetchMetarObservationsC({
    required String icao,
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
    required int hours,
  }) async {
    final samples = await _fetchMetarRawSamples(icao: icao, hours: hours);
    return indexMetarObservations(
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
      samples: samples,
    );
  }

  Future<({Map<int, double> temps, String source})> _fetchForecastHourlyC({
    required double lat,
    required double lon,
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
    int openMeteoForecastDays = 2,
    int openMeteoPastDays = 1,
  }) async {
    // 1) Official NWS WFO hourly (best match for weather.gov US sites).
    final nws = await _fetchNwsHourlyC(
      lat: lat,
      lon: lon,
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    if (nws.isNotEmpty) {
      return (temps: nws, source: nwsForecastDataSource);
    }

    // 2) NOAA NBM via Open-Meteo (better US fallback than default blend).
    final nbm = await _fetchOpenMeteoHourlyC(
      lat: lat,
      lon: lon,
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
      models: openMeteoNbmModel,
      forecastDays: openMeteoForecastDays,
      pastDays: openMeteoPastDays,
    );
    if (nbm.isNotEmpty) {
      return (temps: nbm, source: openMeteoNbmForecastDataSource);
    }

    // 3) Default Open-Meteo (last resort / non-US coverage).
    final om = await _fetchOpenMeteoHourlyC(
      lat: lat,
      lon: lon,
      location: location,
      dayStart: dayStart,
      dayEnd: dayEnd,
      forecastDays: openMeteoForecastDays,
      pastDays: openMeteoPastDays,
    );
    return (temps: om, source: openMeteoForecastDataSource);
  }

  Future<Map<int, double>> _fetchNwsHourlyC({
    required double lat,
    required double lon,
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
  }) async {
    try {
      final pointsUri = Uri.parse(
        '$_nwsBase/points/${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}',
      );
      final pointsRes = await _client.get(
        pointsUri,
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );
      if (pointsRes.statusCode != 200) return {};
      final pointsJson = jsonDecode(pointsRes.body);
      final pointsProps =
          pointsJson is Map ? pointsJson['properties'] : null;
      final hourlyUrl =
          pointsProps is Map ? pointsProps['forecastHourly'] : null;
      if (hourlyUrl is! String || hourlyUrl.isEmpty) return {};

      final hourlyRes = await _client.get(
        Uri.parse(hourlyUrl),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );
      if (hourlyRes.statusCode != 200) return {};
      final hourlyJson = jsonDecode(hourlyRes.body);
      final hourlyProps =
          hourlyJson is Map ? hourlyJson['properties'] : null;
      final periods = hourlyProps is Map ? hourlyProps['periods'] : null;
      if (periods is! List) return {};

      final out = <int, double>{};
      for (final p in periods) {
        if (p is! Map) continue;
        final start = DateTime.tryParse(p['startTime']?.toString() ?? '');
        final temp = (p['temperature'] as num?)?.toDouble();
        final unit = p['temperatureUnit']?.toString().toUpperCase();
        if (start == null || temp == null) continue;
        final local = tz.TZDateTime.from(start.toUtc(), location);
        final hourStart = tz.TZDateTime(
          location,
          local.year,
          local.month,
          local.day,
          local.hour,
        );
        // Include next-day local 00:00 (dayEnd) as the series endpoint.
        if (hourStart.isBefore(dayStart) || hourStart.isAfter(dayEnd)) continue;
        final tempC = unit == 'F' ? fahrenheitToCelsius(temp) : temp;
        out[hourStart.millisecondsSinceEpoch] = tempC;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<Map<int, double>> _fetchOpenMeteoHourlyC({
    required double lat,
    required double lon,
    required tz.Location location,
    required tz.TZDateTime dayStart,
    required tz.TZDateTime dayEnd,
    String? models,
    int forecastDays = 2,
    int pastDays = 1,
  }) async {
    final query = <String, String>{
      'latitude': lat.toString(),
      'longitude': lon.toString(),
      'hourly': 'temperature_2m',
      'forecast_days': '$forecastDays',
      'past_days': '$pastDays',
      'timezone': 'auto',
    };
    if (models != null && models.isNotEmpty) {
      query['models'] = models;
    }
    final uri = Uri.parse(_openMeteoBase).replace(queryParameters: query);
    final response = await _client.get(uri);
    if (response.statusCode != 200) return {};
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return {};
    final hourly = decoded['hourly'];
    if (hourly is! Map) return {};
    final times = hourly['time'];
    final temps = hourly['temperature_2m'];
    if (times is! List || temps is! List) return {};

    final out = <int, double>{};
    for (var i = 0; i < times.length && i < temps.length; i++) {
      final t = DateTime.tryParse(times[i].toString());
      final temp = (temps[i] as num?)?.toDouble();
      if (t == null || temp == null) continue;
      // Open-Meteo returns local wall times when timezone=auto (no Z).
      final local = t.isUtc
          ? tz.TZDateTime.from(t, location)
          : tz.TZDateTime(
              location,
              t.year,
              t.month,
              t.day,
              t.hour,
              t.minute,
            );
      final hourStart = tz.TZDateTime(
        location,
        local.year,
        local.month,
        local.day,
        local.hour,
      );
      // Include next-day local 00:00 (dayEnd) as the series endpoint.
      if (hourStart.isBefore(dayStart) || hourStart.isAfter(dayEnd)) continue;
      out[hourStart.millisecondsSinceEpoch] = temp;
    }
    return out;
  }

  void close() => _client.close();
}

/// Parse Weather.com historical JSON (`units=m`) into UTC samples (°C).
List<({DateTime utc, double tempC})> parseWeatherComHistoricalObservationsC(
  Map decoded,
) {
  final raw = decoded['observations'];
  if (raw is! List) return const [];
  final samples = <({DateTime utc, double tempC})>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final temp = (item['temp'] as num?)?.toDouble();
    if (temp == null) continue;
    final validGmt = item['valid_time_gmt'];
    if (validGmt is! num) continue;
    final utc = DateTime.fromMillisecondsSinceEpoch(
      (validGmt * 1000).round(),
      isUtc: true,
    );
    samples.add((utc: utc, tempC: temp));
  }
  samples.sort((a, b) => a.utc.compareTo(b.utc));
  return samples;
}

/// ISO country from WU path `/history/daily/{cc}/city/{ICAO}` (e.g. `CN`).
String? countryCodeFromWuHistoryUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (!host.contains('wunderground.com')) return null;
  if (!uri.path.toLowerCase().contains('/history/daily/')) return null;
  final segments = uri.pathSegments;
  if (segments.length < 3) return null;
  final lower = segments.map((s) => s.toLowerCase()).toList();
  final dailyIdx = lower.indexOf('daily');
  if (dailyIdx < 0 || dailyIdx + 1 >= segments.length) return null;
  final cc = segments[dailyIdx + 1].trim();
  if (!RegExp(r'^[A-Za-z]{2}$').hasMatch(cc)) return null;
  return cc.toUpperCase();
}

/// Index METAR samples at native local resolution (minute precision).
///
/// Stations that report every 30 minutes (e.g. VILK) keep both :00 and :30
/// points instead of collapsing to one value per hour. Later samples win on
/// the same local minute.
Map<int, double> indexMetarObservations({
  required tz.Location location,
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
  required List<({DateTime utc, double tempC})> samples,
}) {
  final sorted = [...samples]
    ..sort((a, b) => a.utc.toUtc().compareTo(b.utc.toUtc()));
  final out = <int, double>{};
  for (final sample in sorted) {
    final local = tz.TZDateTime.from(sample.utc.toUtc(), location);
    final atMinute = tz.TZDateTime(
      location,
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
    if (atMinute.isBefore(dayStart) || atMinute.isAfter(dayEnd)) continue;
    out[atMinute.millisecondsSinceEpoch] = sample.tempC;
  }
  return out;
}

double celsiusToFahrenheit(double c) => c * 9 / 5 + 32;

double fahrenheitToCelsius(double f) => (f - 32) * 5 / 9;

double convertTempC(double tempC, String unit) =>
    unit == 'F' ? celsiusToFahrenheit(tempC) : tempC;

/// Merge native-resolution observations with hourly forecasts.
///
/// Observed points keep their native timestamps (e.g. every 30 min). Forecast
/// points stay on the hour for times after [nowLocal] (and the current hour
/// when no observation exists in that hour). Includes next-day local 00:00.
List<HourlyTempPoint> mergeHourlySeries({
  required tz.TZDateTime dayStart,
  required tz.TZDateTime dayEnd,
  required tz.TZDateTime nowLocal,
  required Map<int, double> observedC,
  required Map<int, double> forecastC,
  required String unit,
  String observedDataSource =
      StationTemperatureApi.defaultObservedDataSource,
  String forecastDataSource =
      StationTemperatureApi.openMeteoForecastDataSource,
  Map<int, int>? forecastWeatherCodes,
}) {
  final location = dayStart.location;
  final points = <HourlyTempPoint>[];

  bool hasObsInHour(tz.TZDateTime hourStart) {
    final hourEnd = hourStart.add(const Duration(hours: 1));
    for (final key in observedC.keys) {
      final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
      if (!t.isBefore(hourStart) && t.isBefore(hourEnd)) return true;
    }
    return false;
  }

  final obsKeys = observedC.keys.toList()..sort();
  for (final key in obsKeys) {
    final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, key);
    if (t.isBefore(dayStart) || t.isAfter(dayEnd)) continue;
    if (t.isAfter(nowLocal)) continue;
    points.add(
      HourlyTempPoint(
        localHourStart: t,
        temperature: convertTempC(observedC[key]!, unit),
        kind: TempPointKind.observed,
        dataSource: observedDataSource,
      ),
    );
  }

  var hour = dayStart;
  while (!hour.isAfter(dayEnd)) {
    final key = hour.millisecondsSinceEpoch;
    final fc = forecastC[key];
    final hourEnd = hour.add(const Duration(hours: 1));
    if (fc != null) {
      final containsNow =
          !nowLocal.isBefore(hour) && nowLocal.isBefore(hourEnd);
      final fullyFuture = !hour.isBefore(nowLocal);
      if (fullyFuture || (containsNow && !hasObsInHour(hour))) {
        // Avoid duplicating a forecast at the same instant as an observation.
        final alreadyObs = observedC.containsKey(key) &&
            !tz.TZDateTime.fromMillisecondsSinceEpoch(location, key)
                .isAfter(nowLocal);
        if (!alreadyObs) {
          points.add(
            HourlyTempPoint(
              localHourStart: hour,
              temperature: convertTempC(fc, unit),
              kind: TempPointKind.forecast,
              dataSource: forecastDataSource,
              weatherIconCode: forecastWeatherCodes?[key],
            ),
          );
        }
      }
    }
    hour = hourEnd;
  }

  points.sort(
    (a, b) => a.localHourStart.millisecondsSinceEpoch
        .compareTo(b.localHourStart.millisecondsSinceEpoch),
  );
  return markDailyExtremes(points, dayEnd);
}

/// Marks observation-day samples that tie the day's min/max temperature.
///
/// Next-day local midnight ([dayEnd]) is excluded from the extreme set.
List<HourlyTempPoint> markDailyExtremes(
  List<HourlyTempPoint> points,
  tz.TZDateTime dayEnd,
) {
  final dayPoints =
      points.where((p) => p.localHourStart.isBefore(dayEnd)).toList();
  if (dayPoints.isEmpty) return points;
  final minTemp =
      dayPoints.map((p) => p.temperature).reduce((a, b) => a < b ? a : b);
  final maxTemp =
      dayPoints.map((p) => p.temperature).reduce((a, b) => a > b ? a : b);
  return [
    for (final p in points)
      p.copyWith(
        isDailyMinimum: p.localHourStart.isBefore(dayEnd) &&
            (p.temperature - minTemp).abs() < 1e-9,
        isDailyMaximum: p.localHourStart.isBefore(dayEnd) &&
            (p.temperature - maxTemp).abs() < 1e-9,
      ),
  ];
}

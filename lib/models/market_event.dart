import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import '../services/city_timezones.dart';
import '../services/station_temperature_api.dart';

/// Daily low vs daily high temperature Polymarket event.
enum TempMarketKind { low, high }

class OutcomeMarket {
  const OutcomeMarket({
    required this.id,
    required this.question,
    required this.groupItemTitle,
    required this.outcomes,
    required this.outcomePrices,
    required this.volume,
    this.bestBid,
    this.bestAsk,
    this.lastTradePrice,
    this.yesTokenId,
    this.noTokenId,
    this.clobBuyYes,
    this.clobBuyNo,
  });

  final String id;
  final String question;
  final String groupItemTitle;
  final List<String> outcomes;
  final List<double> outcomePrices;
  final double volume;
  final double? bestBid;
  final double? bestAsk;
  final double? lastTradePrice;
  final String? yesTokenId;
  final String? noTokenId;

  /// Live CLOB best-ask for Yes (price to buy Yes), if loaded.
  final double? clobBuyYes;

  /// Live CLOB best-ask for No (price to buy No), if loaded.
  final double? clobBuyNo;

  /// Mid/last Yes from Gamma `outcomePrices` (can lag the live book).
  double? get yesPrice {
    if (outcomePrices.isEmpty) return null;
    final yesIndex = outcomes.indexWhere((o) => o.toLowerCase() == 'yes');
    if (yesIndex >= 0 && yesIndex < outcomePrices.length) {
      return outcomePrices[yesIndex];
    }
    return outcomePrices.first;
  }

  double? get noPrice {
    if (outcomePrices.length < 2) return null;
    final noIndex = outcomes.indexWhere((o) => o.toLowerCase() == 'no');
    if (noIndex >= 0 && noIndex < outcomePrices.length) {
      return outcomePrices[noIndex];
    }
    return outcomePrices[1];
  }

  /// Price to buy Yes (0–1). Only a real ask — matches Polymarket "Buy Yes".
  double? get buyYesPrice =>
      _usableBuyPrice(clobBuyYes) ?? _usableBuyPrice(bestAsk);

  /// Price to buy No (0–1), or null when shown as "--".
  double? get buyNoPrice {
    final fromClob = _usableBuyPrice(clobBuyNo);
    if (fromClob != null) return fromClob;
    if (bestBid != null) {
      return _usableBuyPrice(1 - bestBid!);
    }
    return null;
  }

  /// Chance % for the event row, matching Polymarket's large percentage.
  ///
  /// Polymarket does **not** always show Buy Yes here. With a wide bid/ask
  /// (illiquid book — e.g. Yes bid 8¢ / ask 93¢), the UI shows mid
  /// `outcomePrices` (or last trade), while Buy Yes/No stay as the asks.
  /// With a tight book, the displayed % tracks the Yes ask.
  double? get displayChance {
    final ask = buyYesPrice;
    final bid = _usableBuyPrice(bestBid);
    final last = _usableBuyPrice(lastTradePrice);
    final mid = _usableBuyPrice(yesPrice);

    // One-sided book with a stale/conflicting last trade → "-"
    if (ask != null && bid == null && last != null) {
      if ((ask - last).abs() >= 0.15) return null;
    }

    // Wide spread: Polymarket shows last/mid, not the ask (Ankara 13°C:
    // ask 93¢ / bid 8¢ → "51%", not "93%").
    if (ask != null && bid != null && (ask - bid) >= 0.15) {
      if (last != null) return last;
      if (mid != null) return mid;
    }

    if (ask != null) return ask;
    if (last != null) return last;
    return mid;
  }

  /// True when both buy sides are missing or effectively 0¢.
  bool get bothBuysInactive =>
      _isZeroOrMissing(buyYesPrice) && _isZeroOrMissing(buyNoPrice);

  /// Thin row: Buy Yes &lt;1¢ with Buy No unavailable ("--").
  bool get isThinOutcomeRow {
    final yes = buyYesPrice;
    return yes != null && yes < 0.01 && _isZeroOrMissing(buyNoPrice);
  }

  String get displayLabel {
    if (groupItemTitle.isNotEmpty) return groupItemTitle;
    return question;
  }

  OutcomeMarket copyWithClobPrices({double? buyYes, double? buyNo}) {
    return OutcomeMarket(
      id: id,
      question: question,
      groupItemTitle: groupItemTitle,
      outcomes: outcomes,
      outcomePrices: outcomePrices,
      volume: volume,
      bestBid: bestBid,
      bestAsk: bestAsk,
      lastTradePrice: lastTradePrice,
      yesTokenId: yesTokenId,
      noTokenId: noTokenId,
      clobBuyYes: buyYes ?? clobBuyYes,
      clobBuyNo: buyNo ?? clobBuyNo,
    );
  }

  factory OutcomeMarket.fromJson(Map<String, dynamic> json) {
    final tokenIds = _decodeStringList(json['clobTokenIds']);
    return OutcomeMarket(
      id: json['id']?.toString() ?? '',
      question: json['question'] as String? ?? '',
      groupItemTitle: json['groupItemTitle'] as String? ?? '',
      outcomes: _decodeStringList(json['outcomes']),
      outcomePrices: _decodeDoubleList(json['outcomePrices']),
      volume: _asDouble(json['volumeNum'] ?? json['volume']),
      bestBid: _asNullableDouble(json['bestBid']),
      bestAsk: _asNullableDouble(json['bestAsk']),
      lastTradePrice: _asNullableDouble(json['lastTradePrice']),
      yesTokenId: json['yesTokenId']?.toString() ??
          (tokenIds.isNotEmpty ? tokenIds[0] : null),
      noTokenId: json['noTokenId']?.toString() ??
          (tokenIds.length > 1 ? tokenIds[1] : null),
      clobBuyYes: _asNullableDouble(json['clobBuyYes']),
      clobBuyNo: _asNullableDouble(json['clobBuyNo']),
    );
  }

  Map<String, dynamic> toSnapshotJson() {
    return {
      'id': id,
      'question': question,
      'groupItemTitle': groupItemTitle,
      'outcomes': outcomes,
      'outcomePrices': outcomePrices.map((e) => e.toString()).toList(),
      'volume': volume,
      if (bestBid != null) 'bestBid': bestBid,
      if (bestAsk != null) 'bestAsk': bestAsk,
      if (lastTradePrice != null) 'lastTradePrice': lastTradePrice,
      'clobTokenIds': [
        if (yesTokenId != null) yesTokenId,
        if (noTokenId != null) noTokenId,
      ],
      if (clobBuyYes != null) 'clobBuyYes': clobBuyYes,
      if (clobBuyNo != null) 'clobBuyNo': clobBuyNo,
    };
  }
}

class MarketEvent {
  const MarketEvent({
    required this.id,
    required this.title,
    required this.slug,
    required this.volume,
    required this.volume24hr,
    required this.endDate,
    required this.markets,
    this.description = '',
    this.resolutionSource = '',
    this.temperatureSeries,
  });

  final String id;
  final String title;
  final String slug;
  final double volume;
  final double volume24hr;
  final DateTime? endDate;
  final List<OutcomeMarket> markets;
  final String description;
  final String resolutionSource;

  /// Preloaded hourly chart series (GitHub Pages snapshot). Null on live Gamma.
  final DailyTemperatureSeries? temperatureSeries;

  String get polymarketUrl => 'https://polymarket.com/event/$slug';

  /// Low vs high daily-temperature market (from title).
  TempMarketKind get tempKind {
    if (RegExp(r'Highest temperature', caseSensitive: false).hasMatch(title)) {
      return TempMarketKind.high;
    }
    return TempMarketKind.low;
  }

  /// City from titles like "Lowest/Highest temperature in Hong Kong on …".
  String get cityName {
    final match = RegExp(
      r'(?:Lowest|Highest) temperature in (.+?) on ',
      caseSensitive: false,
    ).firstMatch(title);
    if (match != null) return match.group(1)!.trim();
    return title;
  }

  /// Resolution source URL from Gamma `resolutionSource` or Rules/description text.
  String? get resolutionSourceUrl {
    final direct = resolutionSource.trim();
    if (direct.startsWith('http://') || direct.startsWith('https://')) {
      return direct;
    }
    final match = RegExp(
      r'https?://[^\s\)\"<>]+',
      caseSensitive: false,
    ).firstMatch(description);
    if (match == null) return null;
    return match.group(0)!.replaceAll(RegExp(r'[.,;:]+$'), '');
  }

  /// Temperature unit used by this market's outcomes: `C`, `F`, or null if unknown.
  String? get temperatureUnit {
    for (final market in markets) {
      final label = '${market.groupItemTitle} ${market.question}';
      if (label.contains('°F')) return 'F';
      if (label.contains('°C')) return 'C';
    }
    final blob = '$title $description';
    if (RegExp(r'degrees?\s+Fahrenheit|°F', caseSensitive: false)
        .hasMatch(blob)) {
      return 'F';
    }
    if (RegExp(r'degrees?\s+Celsius|°C', caseSensitive: false).hasMatch(blob)) {
      return 'C';
    }
    return null;
  }

  /// Resolution URL adjusted for NOAA timeseries metric units when market is °C.
  String? get resolutionSourceOpenUrl {
    final url = resolutionSourceUrl;
    if (url == null) return null;
    return adjustWeatherGovTimeseriesUrl(url, temperatureUnit);
  }

  /// Highest displayed chance among outcomes (Buy Yes / last / mid).
  double? get leadingYesPrice {
    double? best;
    for (final market in markets) {
      final yes = market.displayChance;
      if (yes == null) continue;
      if (best == null || yes > best) best = yes;
    }
    return best;
  }

  /// ≥90% on one outcome, and Buy No > 1¢ on a different outcome with chance < 90%.
  bool get matchesLockedMarketWithNos {
    for (var i = 0; i < markets.length; i++) {
      final highChance = markets[i].displayChance;
      if (highChance == null || highChance < 0.90) continue;
      for (var j = 0; j < markets.length; j++) {
        if (i == j) continue;
        final otherChance = markets[j].displayChance;
        if (otherChance != null && otherChance >= 0.90) continue;
        final no = markets[j].buyNoPrice;
        if (no != null && no > 0.01) return true;
      }
    }
    return false;
  }

  /// Exactly one temperature outcome with Buy Yes ≥ 95¢.
  bool get matchesBuyYesAtLeast95 {
    var count = 0;
    for (final market in markets) {
      final yes = market.buyYesPrice;
      if (yes != null && yes >= 0.95) {
        count++;
        if (count > 1) return false;
      }
    }
    return count == 1;
  }

  MarketEvent copyWith({
    List<OutcomeMarket>? markets,
    DailyTemperatureSeries? temperatureSeries,
  }) {
    return MarketEvent(
      id: id,
      title: title,
      slug: slug,
      volume: volume,
      volume24hr: volume24hr,
      endDate: endDate,
      markets: markets ?? this.markets,
      description: description,
      resolutionSource: resolutionSource,
      temperatureSeries: temperatureSeries ?? this.temperatureSeries,
    );
  }

  /// Top markets by displayed chance, for summary chips on the list row.
  List<OutcomeMarket> topMarkets({int count = 2}) {
    final withPrice = markets.where((m) => m.displayChance != null).toList()
      ..sort(
        (a, b) => (b.displayChance ?? 0).compareTo(a.displayChance ?? 0),
      );
    return withPrice.take(count).toList();
  }

  /// Calendar day of the observation (date in the city's timezone when possible).
  DateTime? get observationDay {
    final cityDay = observationDayInCity;
    if (cityDay != null) {
      return DateTime.utc(cityDay.year, cityDay.month, cityDay.day);
    }
    final d = endDate;
    if (d == null) return null;
    return DateTime.utc(d.year, d.month, d.day);
  }

  /// Observation Y/M/D in the market city's timezone.
  ({int year, int month, int day})? get observationDayInCity {
    final fromTitle = _observationDateFromTitle();
    if (fromTitle != null) return fromTitle;

    final d = endDate;
    if (d == null) return null;
    final location = CityTimezones.locationForCity(cityName);
    if (location != null) {
      final cityTime = tz.TZDateTime.from(d.toUtc(), location);
      return (year: cityTime.year, month: cityTime.month, day: cityTime.day);
    }
    final utc = d.toUtc();
    return (year: utc.year, month: utc.month, day: utc.day);
  }

  /// 23:59:59 on the observation day in the **city's** local timezone (UTC instant).
  DateTime? get localEndOfDay {
    final day = observationDayInCity;
    if (day == null) return null;
    final eod = CityTimezones.endOfDayUtc(
      cityName: cityName,
      year: day.year,
      month: day.month,
      day: day.day,
    );
    if (eod != null) return eod;

    // Fallback: device-local EOD if city timezone is unknown.
    final d = endDate;
    if (d == null) return null;
    final local = d.toLocal();
    return DateTime(local.year, local.month, local.day, 23, 59, 59);
  }

  /// Remaining time until city-local 23:59:59 on the observation day.
  Duration? get timeToLocalEndOfDay {
    final eod = localEndOfDay;
    if (eod == null) return null;
    return eod.toUtc().difference(DateTime.now().toUtc());
  }

  ({int year, int month, int day})? _observationDateFromTitle() {
    final match = RegExp(
      r'on\s+([A-Za-z]+)\s+(\d{1,2})\??\s*$',
      caseSensitive: false,
    ).firstMatch(title);
    if (match == null) return null;

    final monthName = match.group(1)!.toLowerCase();
    final day = int.tryParse(match.group(2)!);
    if (day == null) return null;

    const months = {
      'january': 1,
      'february': 2,
      'march': 3,
      'april': 4,
      'may': 5,
      'june': 6,
      'july': 7,
      'august': 8,
      'september': 9,
      'october': 10,
      'november': 11,
      'december': 12,
    };
    final month = months[monthName];
    if (month == null) return null;

    // Prefer year from endDate in the city zone; else UTC year.
    var year = endDate?.toUtc().year;
    final location = CityTimezones.locationForCity(cityName);
    if (endDate != null && location != null) {
      year = tz.TZDateTime.from(endDate!.toUtc(), location).year;
    }
    year ??= DateTime.now().year;

    return (year: year, month: month, day: day);
  }

  MarketEvent withMarkets(List<OutcomeMarket> markets) {
    return MarketEvent(
      id: id,
      title: title,
      slug: slug,
      volume: volume,
      volume24hr: volume24hr,
      endDate: endDate,
      markets: markets,
      description: description,
      resolutionSource: resolutionSource,
      temperatureSeries: temperatureSeries,
    );
  }

  factory MarketEvent.fromJson(Map<String, dynamic> json) {
    final marketsJson = json['markets'];
    final markets = <OutcomeMarket>[];
    if (marketsJson is List) {
      for (final item in marketsJson) {
        if (item is Map<String, dynamic>) {
          markets.add(OutcomeMarket.fromJson(item));
        } else if (item is Map) {
          markets.add(
            OutcomeMarket.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    DailyTemperatureSeries? temperatureSeries;
    final seriesRaw = json['temperatureSeries'];
    if (seriesRaw is Map<String, dynamic>) {
      temperatureSeries = DailyTemperatureSeries.fromJson(seriesRaw);
    } else if (seriesRaw is Map) {
      temperatureSeries = DailyTemperatureSeries.fromJson(
        Map<String, dynamic>.from(seriesRaw),
      );
    }

    return MarketEvent(
      id: json['id']?.toString() ?? '',
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      volume: _asDouble(json['volume']),
      volume24hr: _asDouble(json['volume24hr']),
      endDate: _parseDate(json['endDate']),
      markets: markets,
      description: json['description']?.toString() ?? '',
      resolutionSource: json['resolutionSource']?.toString() ?? '',
      temperatureSeries: temperatureSeries,
    );
  }

  Map<String, dynamic> toSnapshotJson() {
    return {
      'id': id,
      'title': title,
      'slug': slug,
      'volume': volume,
      'volume24hr': volume24hr,
      if (endDate != null) 'endDate': endDate!.toUtc().toIso8601String(),
      'description': description,
      'resolutionSource': resolutionSource,
      'markets': markets.map((m) => m.toSnapshotJson()).toList(),
      if (temperatureSeries != null)
        'temperatureSeries': temperatureSeries!.toJson(),
    };
  }
}

/// For NOAA WRH timeseries links: append `units=metric` when the market is °C.
String adjustWeatherGovTimeseriesUrl(String url, String? temperatureUnit) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (!isWeatherGovTimeseriesUrl(url)) return url;

  final params = Map<String, String>.from(uri.queryParameters);
  if (temperatureUnit == 'C') {
    params['units'] = 'metric';
  } else {
    params.remove('units');
  }
  return uri.replace(queryParameters: params).toString();
}

/// True when [url] is a NOAA WRH timeseries station link.
bool isWeatherGovTimeseriesUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.host.contains('weather.gov') &&
      uri.path.contains('/wrh/timeseries');
}

/// Station code from `?site=` on a NOAA WRH timeseries URL, or null.
String? weatherGovTimeseriesSiteId(String? url) {
  if (url == null || url.isEmpty) return null;
  if (!isWeatherGovTimeseriesUrl(url)) return null;
  final site = Uri.tryParse(url)?.queryParameters['site']?.trim();
  if (site == null || site.isEmpty) return null;
  return site.toLowerCase();
}

/// True when [url] points at Hong Kong Observatory / weather.gov.hk.
bool isHongKongObservatorySource(String? url) {
  if (url == null || url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host.contains('weather.gov.hk') || host.contains('hko.gov.hk');
}

/// True when [event] is the Hong Kong HKO temperature market.
bool isHongKongTemperatureMarket(MarketEvent event) {
  if (isHongKongObservatorySource(event.resolutionSourceOpenUrl) ||
      isHongKongObservatorySource(event.resolutionSourceUrl)) {
    return true;
  }
  return event.cityName.toLowerCase() == 'hong kong';
}

/// True when this market can show an expand temperature chart.
bool isChartableTemperatureSource(MarketEvent event) {
  if (isHongKongTemperatureMarket(event)) return true;
  return metarStationIcaoForEvent(event) != null;
}

/// HKO OCF station id when [event] is a Hong Kong chartable market.
String? hongKongOcfStationId(MarketEvent event) {
  if (!isHongKongTemperatureMarket(event)) return null;
  return 'HKO';
}

/// True when [url] is a Weather Underground daily airport history page.
bool isWeatherUndergroundHistoryUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (!host.contains('wunderground.com')) return false;
  return uri.path.toLowerCase().contains('/history/daily/');
}

/// ICAO from WU path like `/history/daily/cn/jinan/ZSJN`, or null.
String? weatherUndergroundHistoryIcao(String? url) {
  if (url == null || url.isEmpty) return null;
  if (!isWeatherUndergroundHistoryUrl(url)) return null;
  final segments = Uri.tryParse(url)?.pathSegments;
  if (segments == null || segments.isEmpty) return null;
  final icao = segments.last.trim();
  if (!RegExp(r'^[A-Za-z]{4}$').hasMatch(icao)) return null;
  return icao.toUpperCase();
}

/// ISO country from WU path — see [countryCodeFromWuHistoryUrl].
String? weatherUndergroundHistoryCountry(String? url) =>
    countryCodeFromWuHistoryUrl(url);

/// ICAO for METAR/Open-Meteo charts (WRH site or WU history ICAO).
///
/// Returns null for Hong Kong HKO markets (use [hongKongOcfStationId] instead).
String? metarStationIcaoForEvent(MarketEvent event) {
  if (isHongKongTemperatureMarket(event)) return null;
  final wrh = weatherGovTimeseriesSiteId(event.resolutionSourceOpenUrl) ??
      weatherGovTimeseriesSiteId(event.resolutionSourceUrl);
  if (wrh != null && wrh.isNotEmpty) return wrh.toUpperCase();
  return weatherUndergroundHistoryIcao(event.resolutionSourceOpenUrl) ??
      weatherUndergroundHistoryIcao(event.resolutionSourceUrl);
}

/// Formats a displayed chance as Polymarket-style percent, or "—".
String formatChancePercent(double? chance) {
  if (chance == null) return '—';
  if (chance < 0.01) return '<1%';
  final pct = (chance * 100).round();
  return '$pct%';
}

/// Formats a 0–1 price as Polymarket-style cents, or "--".
String formatBuyCents(double? price) {
  if (_isZeroOrMissing(price)) return '--';
  final cents = price! * 100;
  if (cents < 1) {
    final text = cents.toStringAsFixed(1);
    if (text == '0.0') return '0¢';
    return '$text¢';
  }
  if ((cents - cents.roundToDouble()).abs() < 0.05) {
    return '${cents.round()}¢';
  }
  return '${cents.toStringAsFixed(1)}¢';
}

/// Formats remaining time until local end-of-day for a market.
String formatTimeToEndOfDay(Duration? remaining) {
  if (remaining == null) return '—';
  if (remaining.isNegative) return 'EOD passed';
  final days = remaining.inDays;
  final hours = remaining.inHours.remainder(24);
  final minutes = remaining.inMinutes.remainder(60);
  if (days > 0) return '${days}d ${hours}h';
  if (remaining.inHours > 0) return '${remaining.inHours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '<1m';
}

bool _isZeroOrMissing(double? price) {
  if (price == null) return true;
  if (price <= 0) return true;
  if (price >= 1) return true;
  // Treat sub-0.05¢ as 0¢ for filter purposes.
  if (price * 100 < 0.05) return true;
  return false;
}

double? _usableBuyPrice(double? price) {
  if (price == null) return null;
  if (price <= 0 || price >= 1) return null;
  return price;
}

List<String> _decodeStringList(dynamic value) {
  if (value == null) return const [];
  if (value is List) {
    return value.map((e) => e.toString()).toList();
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

List<double> _decodeDoubleList(dynamic value) {
  if (value == null) return const [];
  if (value is List) {
    return value.map(_asDouble).toList();
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map(_asDouble).toList();
      }
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

double _asDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

double? _asNullableDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

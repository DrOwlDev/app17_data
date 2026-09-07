import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/market_event.dart';

/// Fetches Lowest + Highest Temperature events from Polymarket Gamma API.
///
/// When [preferStaticSnapshot] is true (GitHub Pages web build), loads a
/// same-origin snapshot at `data/markets.json` so browser CORS to Polymarket
/// is not required. Windows/Android keep live Gamma + CLOB calls.
class PolymarketApi {
  PolymarketApi({
    http.Client? client,
    this.preferStaticSnapshot = false,
  }) : _client = client ?? http.Client();

  static const int lowestTemperatureTagId = 104597;
  static const int highestTemperatureTagId = 104596;
  static const String _baseUrl = 'https://gamma-api.polymarket.com';
  static const String _clobUrl = 'https://clob.polymarket.com';
  static const int _pageSize = 100;
  static const String staticSnapshotPath = 'data/markets.json';

  final http.Client _client;
  final bool preferStaticSnapshot;

  bool get _useStaticSnapshot => preferStaticSnapshot;

  /// Active open Lowest + Highest temperature events (deduped by id).
  Future<List<MarketEvent>> fetchTemperatureEvents() async {
    if (_useStaticSnapshot) {
      return _fetchFromStaticSnapshot();
    }
    final low = await _fetchFromGamma(lowestTemperatureTagId);
    final high = await _fetchFromGamma(highestTemperatureTagId);
    return _dedupeById([...low, ...high]);
  }

  /// Alias for [fetchTemperatureEvents] (legacy name).
  Future<List<MarketEvent>> fetchLowestTemperatureEvents() =>
      fetchTemperatureEvents();

  static List<MarketEvent> _dedupeById(List<MarketEvent> events) {
    final seen = <String>{};
    final out = <MarketEvent>[];
    for (final e in events) {
      if (seen.add(e.id)) out.add(e);
    }
    return out;
  }

  Future<List<MarketEvent>> _fetchFromStaticSnapshot() async {
    final uri = Uri.parse(
      '$staticSnapshotPath?t=${DateTime.now().millisecondsSinceEpoch}',
    );
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw PolymarketApiException(
        'Static snapshot returned ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body);
    final List<dynamic> rawEvents;
    if (decoded is Map && decoded['events'] is List) {
      rawEvents = decoded['events'] as List<dynamic>;
    } else if (decoded is List) {
      rawEvents = decoded;
    } else {
      throw const PolymarketApiException(
        'Unexpected static snapshot shape',
      );
    }

    return rawEvents.map((item) {
      if (item is Map<String, dynamic>) {
        return MarketEvent.fromJson(item);
      }
      if (item is Map) {
        return MarketEvent.fromJson(Map<String, dynamic>.from(item));
      }
      throw const PolymarketApiException('Invalid event in snapshot');
    }).toList();
  }

  Future<List<MarketEvent>> _fetchFromGamma(int tagId) async {
    final events = <MarketEvent>[];
    var offset = 0;

    while (true) {
      final uri = Uri.parse('$_baseUrl/events').replace(
        queryParameters: {
          'tag_id': '$tagId',
          'active': 'true',
          'closed': 'false',
          'limit': '$_pageSize',
          'offset': '$offset',
          'order': 'volume24hr',
          'ascending': 'false',
        },
      );

      final response = await _client.get(uri);
      if (response.statusCode != 200) {
        throw PolymarketApiException(
          'Gamma API returned ${response.statusCode}: ${response.body}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const PolymarketApiException(
          'Unexpected Gamma API response shape',
        );
      }

      if (decoded.isEmpty) break;

      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          events.add(MarketEvent.fromJson(item));
        } else if (item is Map) {
          events.add(MarketEvent.fromJson(Map<String, dynamic>.from(item)));
        }
      }

      if (decoded.length < _pageSize) break;
      offset += _pageSize;
    }

    return events;
  }

  /// Fetches CLOB best-ask (SELL) prices for Yes/No tokens of [markets].
  ///
  /// On web, skips the live CLOB call (snapshot already includes asks).
  Future<List<OutcomeMarket>> enrichBuyPrices(
    List<OutcomeMarket> markets,
  ) async {
    if (markets.isEmpty) return markets;
    if (_useStaticSnapshot) return markets;

    const chunkSize = 80;
    var result = List<OutcomeMarket>.from(markets);
    for (var start = 0; start < markets.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, markets.length);
      final chunk = markets.sublist(start, end);
      final enrichedChunk = await _enrichBuyPricesChunk(chunk);
      for (var i = 0; i < enrichedChunk.length; i++) {
        result[start + i] = enrichedChunk[i];
      }
    }
    return result;
  }

  /// Enriches Buy Yes/No for every outcome across [events] (chunked CLOB calls).
  Future<List<MarketEvent>> enrichEventsBuyPrices(
    List<MarketEvent> events,
  ) async {
    if (_useStaticSnapshot) return events;
    final flat = events.expand((e) => e.markets).toList();
    if (flat.isEmpty) return events;
    final enriched = await enrichBuyPrices(flat);
    final byId = {for (final m in enriched) m.id: m};
    return events
        .map(
          (e) => e.copyWith(
            markets: e.markets.map((m) => byId[m.id] ?? m).toList(),
          ),
        )
        .toList();
  }

  Future<List<OutcomeMarket>> _enrichBuyPricesChunk(
    List<OutcomeMarket> markets,
  ) async {
    final requests = <Map<String, String>>[];
    for (final market in markets) {
      if (market.yesTokenId != null) {
        requests.add({'token_id': market.yesTokenId!, 'side': 'SELL'});
      }
      if (market.noTokenId != null) {
        requests.add({'token_id': market.noTokenId!, 'side': 'SELL'});
      }
    }
    if (requests.isEmpty) return markets;

    final response = await _client.post(
      Uri.parse('$_clobUrl/prices'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requests),
    );
    if (response.statusCode != 200) {
      throw PolymarketApiException(
        'CLOB prices returned ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return markets;

    return markets.map((market) {
      final yesRaw = market.yesTokenId == null
          ? null
          : decoded[market.yesTokenId];
      final noRaw =
          market.noTokenId == null ? null : decoded[market.noTokenId];
      return market.copyWithClobPrices(
        buyYes: _priceFromClobEntry(yesRaw, 'SELL'),
        buyNo: _priceFromClobEntry(noRaw, 'SELL'),
      );
    }).toList();
  }

  double? _priceFromClobEntry(dynamic entry, String side) {
    if (entry is! Map) return null;
    final raw = entry[side] ?? entry[side.toLowerCase()];
    if (raw == null) return null;
    final value = double.tryParse(raw.toString());
    if (value == null || value <= 0 || value >= 1) return null;
    return value;
  }

  void close() => _client.close();
}

class PolymarketApiException implements Exception {
  const PolymarketApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

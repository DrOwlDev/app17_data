import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/user_position.dart';
import 'polymarket_api.dart';

/// Public Data API for wallet positions (no auth).
class PolymarketPositionsApi {
  PolymarketPositionsApi({http.Client? client})
      : _client = client ?? http.Client();

  static const String _baseUrl = 'https://data-api.polymarket.com';
  static const String defaultUserId =
      '0x8cEF3c1B592953D61EEE2bC9375C5944A8926B6d';

  final http.Client _client;

  /// Fetches open positions for [userId] (proxy wallet), sorted by value.
  Future<List<UserPosition>> fetchPositions({
    String userId = defaultUserId,
    int limit = 100,
  }) async {
    final positions = <UserPosition>[];
    var offset = 0;

    while (true) {
      final uri = Uri.parse('$_baseUrl/positions').replace(
        queryParameters: {
          'user': userId,
          'sizeThreshold': '0',
          'limit': '$limit',
          'offset': '$offset',
          'sortBy': 'CURRENT',
          'sortDirection': 'DESC',
        },
      );

      final response = await _client.get(uri);
      if (response.statusCode != 200) {
        throw PolymarketApiException(
          'Positions API returned ${response.statusCode}: ${response.body}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const PolymarketApiException(
          'Unexpected positions response shape',
        );
      }
      if (decoded.isEmpty) break;

      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          positions.add(UserPosition.fromJson(item));
        } else if (item is Map) {
          positions.add(
            UserPosition.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }

      if (decoded.length < limit) break;
      offset += limit;
      if (offset > 2000) break;
    }

    return positions;
  }

  void close() => _client.close();
}

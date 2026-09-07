import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/market_event.dart';
import '../services/polymarket_api.dart';

/// Unique cities with resolution-source URLs from Polymarket Rules.
class MarketsPage extends StatefulWidget {
  const MarketsPage({super.key});

  @override
  State<MarketsPage> createState() => _MarketsPageState();
}

class _CityResolution {
  const _CityResolution({
    required this.cityName,
    required this.resolutionUrl,
    required this.openUrl,
    required this.temperatureUnit,
    required this.eventCount,
    required this.sampleEventUrl,
  });

  final String cityName;
  final String? resolutionUrl;
  final String? openUrl;
  /// `C`, `F`, or null.
  final String? temperatureUnit;
  final int eventCount;
  final String sampleEventUrl;
}

class _MarketsPageState extends State<MarketsPage>
    with AutomaticKeepAliveClientMixin {
  final PolymarketApi _api = PolymarketApi(preferStaticSnapshot: kIsWeb);
  final TextEditingController _searchController = TextEditingController();

  List<_CityResolution> _cities = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  DateTime? _lastRefreshedAt;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _api.close();
    super.dispose();
  }

  List<_CityResolution> get _filteredCities {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _cities;
    return _cities.where((c) {
      if (c.cityName.toLowerCase().contains(query)) return true;
      final siteId = weatherGovTimeseriesSiteId(c.resolutionUrl);
      if (siteId != null && siteId.toLowerCase().contains(query)) return true;
      final wuIcao = weatherUndergroundHistoryIcao(c.resolutionUrl) ??
          weatherUndergroundHistoryIcao(c.openUrl);
      if (wuIcao != null && wuIcao.toLowerCase().contains(query)) return true;
      return false;
    }).toList();
  }

  Future<void> _load({bool silent = false}) async {
    setState(() {
      if (!silent || _cities.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });

    try {
      final events = await _api.fetchTemperatureEvents();
      if (!mounted) return;
      setState(() {
        _cities = _uniqueCities(events);
        _loading = false;
        _refreshing = false;
        _lastRefreshedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _refreshing = false;
      });
    }
  }

  List<_CityResolution> _uniqueCities(List<MarketEvent> events) {
    final byCity = <String, _CityResolution>{};
    for (final event in events) {
      final city = event.cityName;
      final key = city.toLowerCase();
      final existing = byCity[key];
      final unit = event.temperatureUnit;
      final rawUrl = event.resolutionSourceUrl;
      final openUrl = event.resolutionSourceOpenUrl;
      if (existing == null) {
        byCity[key] = _CityResolution(
          cityName: city,
          resolutionUrl: rawUrl,
          openUrl: openUrl,
          temperatureUnit: unit,
          eventCount: 1,
          sampleEventUrl: event.polymarketUrl,
        );
      } else {
        final mergedUnit = existing.temperatureUnit ?? unit;
        final mergedRaw = existing.resolutionUrl ?? rawUrl;
        byCity[key] = _CityResolution(
          cityName: existing.cityName,
          resolutionUrl: mergedRaw,
          openUrl: mergedRaw == null
              ? null
              : adjustWeatherGovTimeseriesUrl(mergedRaw, mergedUnit),
          temperatureUnit: mergedUnit,
          eventCount: existing.eventCount + 1,
          sampleEventUrl: existing.sampleEventUrl,
        );
      }
    }
    final list = byCity.values.toList()
      ..sort(
        (a, b) => a.cityName.toLowerCase().compareTo(b.cityName.toLowerCase()),
      );
    return list;
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final filtered = _filteredCities;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        hintText: 'Search city…',
                        hintStyle: const TextStyle(fontSize: 13),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          size: 18,
                          color: scheme.primary,
                        ),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _searchController.clear(),
                                icon: const Icon(Icons.clear, size: 16),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  if (_refreshing || (_loading && _cities.isNotEmpty))
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_lastRefreshedAt != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        DateFormat.Hm().format(_lastRefreshedAt!),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Refresh cities',
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        (_loading || _refreshing) ? null : () => _load(),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _loading && _cities.isEmpty
                      ? 'Cities…'
                      : filtered.length == _cities.length
                          ? '${_cities.length} cities (A–Z)'
                          : '${filtered.length} of ${_cities.length} cities',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody(scheme, filtered)),
      ],
    );
  }

  Widget _buildBody(ColorScheme scheme, List<_CityResolution> cities) {
    if (_loading && _cities.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _cities.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_cities.isEmpty) {
      return const Center(child: Text('No cities found'));
    }
    if (cities.isEmpty) {
      return const Center(child: Text('No cities match search'));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: cities.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final row = cities[index];
        final displayUrl = row.openUrl ?? row.resolutionUrl;
        final siteId = weatherGovTimeseriesSiteId(row.resolutionUrl);
        final wuIcao = weatherUndergroundHistoryIcao(row.resolutionUrl) ??
            weatherUndergroundHistoryIcao(row.openUrl);
        final isStandardTimeseries = siteId != null;
        final String titleText;
        if (isStandardTimeseries) {
          titleText = '${row.cityName} - $siteId';
        } else if (wuIcao != null) {
          titleText = '${row.cityName} - $wuIcao';
        } else {
          titleText = row.cityName;
        }
        return Card(
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 2,
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    titleText,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (row.temperatureUnit != null) ...[
                  const SizedBox(width: 6),
                  _UnitBadge(unit: row.temperatureUnit!),
                ],
                if (!isStandardTimeseries) ...[
                  const SizedBox(width: 6),
                  const UniqueSourceBadge(),
                ],
              ],
            ),
            subtitle: displayUrl == null
                ? Text(
                    'No resolution source URL · ${row.eventCount} market(s)',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : Text(
                    displayUrl,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (displayUrl != null)
                  IconButton(
                    tooltip: 'Open resolution source',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openUrl(displayUrl),
                    icon: Icon(
                      Icons.cloud_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ),
                IconButton(
                  tooltip: 'Open on Polymarket',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openUrl(row.sampleEventUrl),
                  icon: Icon(
                    Icons.open_in_new,
                    size: 16,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            onTap: displayUrl != null
                ? () => _openUrl(displayUrl)
                : () => _openUrl(row.sampleEventUrl),
          ),
        );
      },
    );
  }
}

class _UnitBadge extends StatelessWidget {
  const _UnitBadge({required this.unit});

  final String unit;

  @override
  Widget build(BuildContext context) {
    final isC = unit == 'C';
    final color = isC ? const Color(0xFF0D9488) : const Color(0xFFEA580C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        isC ? '°C' : '°F',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class UniqueSourceBadge extends StatelessWidget {
  const UniqueSourceBadge({super.key});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFDC2626);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: const Text(
        'Unique Resolution Source',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

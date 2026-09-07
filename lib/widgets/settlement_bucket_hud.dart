import 'package:flutter/material.dart';

import '../models/market_event.dart';
import '../models/temp_outcome_bucket.dart';
import '../services/station_temperature_api.dart';

/// Compact settlement strip: obs extremum, forecast remaining, leading bucket.
class SettlementBucketHud extends StatelessWidget {
  const SettlementBucketHud({
    super.key,
    required this.series,
    required this.markets,
    required this.tempKind,
  });

  final DailyTemperatureSeries series;
  final List<OutcomeMarket> markets;
  final TempMarketKind tempKind;

  @override
  Widget build(BuildContext context) {
    final high = tempKind == TempMarketKind.high;
    final obs = seriesObservedExtremum(series, tempKind);
    final fcst = seriesForecastRemainingExtremum(series, tempKind);
    final unit = series.unit == 'F' ? 'F' : 'C';
    final leading = obs == null
        ? null
        : leadingSettlementBucket(markets, obs, kind: tempKind);

    String fmt(double? t) =>
        t == null ? '—' : '${formatTempOneDecimal(t)}°$unit';

    final obsLabel = high ? 'Observed maximum' : 'Observed minimum';
    final obsTooltip = high
        ? 'Highest temperature observed so far today at the resolution '
            'station. Only real observations count — forecast points are ignored.'
        : 'Lowest temperature observed so far today at the resolution '
            'station. Only real observations count — forecast points are ignored.';
    final fcstLabel =
        high ? 'Forecast remaining maximum' : 'Forecast remaining minimum';
    final fcstTooltip = high
        ? 'Highest temperature still forecast for the rest of the local day '
            '(after the current time).'
        : 'Lowest temperature still forecast for the rest of the local day '
            '(after the current time).';
    final leadingTooltip = high
        ? 'Outcome bucket that currently contains the observed maximum. '
            'If the daily high does not move further, this is the leading '
            'settlement candidate.'
        : 'Outcome bucket that currently contains the observed minimum. '
            'If the daily low does not move further, this is the leading '
            'settlement candidate.';
    final deadHint = high ? 'Colder outcomes eliminated' : 'Warmer outcomes eliminated';
    final deadTooltip = high
        ? 'Outcomes that can no longer win: the observed maximum already '
            'exceeds these colder buckets, so the daily high can only stay '
            'the same or rise further.'
        : 'Outcomes that can no longer win: the observed minimum is already '
            'colder than these warmer buckets, so the daily low can only stay '
            'the same or fall further.';

    return Container(
      width: double.infinity,
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Tooltip(
            message:
                'Settlement physics from the station temperature series for '
                'this market day.',
            waitDuration: Duration(milliseconds: 400),
            child: Text(
              'Settlement',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Color(0xFF334155),
              ),
            ),
          ),
          _kv(obsLabel, fmt(obs), obsTooltip),
          _kv(fcstLabel, fmt(fcst), fcstTooltip),
          _kv('Leading outcome', leading?.label ?? '—', leadingTooltip),
          if (obs != null)
            Tooltip(
              message: deadTooltip,
              waitDuration: const Duration(milliseconds: 400),
              child: Text(
                deadHint,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF64748B),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v, String tooltip) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$k ',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w500,
              ),
            ),
            TextSpan(
              text: v,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

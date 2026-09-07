import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:app17_data/models/market_event.dart';
import 'package:app17_data/models/temp_outcome_bucket.dart';
import 'package:app17_data/services/station_temperature_api.dart';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  group('parseTempOutcomeBucket', () {
    test('exact C and F', () {
      final c = parseTempOutcomeBucket('26°C');
      expect(c?.kind, TempBucketKind.exact);
      expect(c?.exact, 26);
      expect(c?.unit, 'C');

      final f = parseTempOutcomeBucket('50F');
      expect(f?.kind, TempBucketKind.exact);
      expect(f?.exact, 50);
      expect(f?.unit, 'F');
    });

    test('or below and or above', () {
      final below = parseTempOutcomeBucket('20°C or below');
      expect(below?.kind, TempBucketKind.orBelow);
      expect(below?.exact, 20);

      final above = parseTempOutcomeBucket('30°C or above');
      expect(above?.kind, TempBucketKind.orAbove);
      expect(above?.exact, 30);
    });

    test('range', () {
      final b = parseTempOutcomeBucket('50-51°F');
      expect(b?.kind, TempBucketKind.range);
      expect(b?.lo, 50);
      expect(b?.hi, 51);
      expect(b?.unit, 'F');
    });
  });

  group('isPhysicsDeadOutcome low', () {
    test('exact warmer than obs min is dead', () {
      final exact18 = parseTempOutcomeBucket('18°C')!;
      expect(
        isPhysicsDeadOutcome(exact18, 17, kind: TempMarketKind.low),
        isTrue,
      );
      expect(
        isPhysicsDeadOutcome(exact18, 18, kind: TempMarketKind.low),
        isFalse,
      );
    });

    test('or below never dead from observed alone', () {
      final floor = parseTempOutcomeBucket('16°C or below')!;
      expect(
        isPhysicsDeadOutcome(floor, 20, kind: TempMarketKind.low),
        isFalse,
      );
    });

    test('range dead when obs already below lo', () {
      final range = parseTempOutcomeBucket('50-51°F')!;
      expect(
        isPhysicsDeadOutcome(range, 49, kind: TempMarketKind.low),
        isTrue,
      );
      expect(
        isPhysicsDeadOutcome(range, 50, kind: TempMarketKind.low),
        isFalse,
      );
    });
  });

  group('isPhysicsDeadOutcome high', () {
    test('exact colder than obs max is dead', () {
      final exact28 = parseTempOutcomeBucket('28°C')!;
      expect(
        isPhysicsDeadOutcome(exact28, 29, kind: TempMarketKind.high),
        isTrue,
      );
      expect(
        isPhysicsDeadOutcome(exact28, 28, kind: TempMarketKind.high),
        isFalse,
      );
    });

    test('or below dies when max exceeds floor', () {
      final floor = parseTempOutcomeBucket('25°C or below')!;
      expect(
        isPhysicsDeadOutcome(floor, 26, kind: TempMarketKind.high),
        isTrue,
      );
      expect(
        isPhysicsDeadOutcome(floor, 25, kind: TempMarketKind.high),
        isFalse,
      );
    });

    test('or above never dead from observed alone', () {
      final ceiling = parseTempOutcomeBucket('35°C or above')!;
      expect(
        isPhysicsDeadOutcome(ceiling, 40, kind: TempMarketKind.high),
        isFalse,
      );
    });
  });

  group('leadingSettlementBucket', () {
    OutcomeMarket m(String label) => OutcomeMarket(
          id: label,
          question: label,
          groupItemTitle: label,
          outcomes: const ['Yes', 'No'],
          outcomePrices: const [0.5, 0.5],
          volume: 0,
        );

    test('low picks exact degree containing obs min', () {
      final leading = leadingSettlementBucket(
        [m('17°C'), m('18°C'), m('16°C or below')],
        17,
        kind: TempMarketKind.low,
      );
      expect(leading?.label, '17°C');
    });

    test('high picks exact degree containing obs max', () {
      final leading = leadingSettlementBucket(
        [m('25°C or below'), m('28°C'), m('29°C')],
        28,
        kind: TempMarketKind.high,
      );
      expect(leading?.label, '28°C');
    });
  });

  group('series mins and maxes', () {
    test('observed and forecast remaining extrema', () {
      final loc = tz.getLocation('Asia/Shanghai');
      final dayStart = tz.TZDateTime(loc, 2026, 9, 6);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(loc, 2026, 9, 6, 12);
      final series = DailyTemperatureSeries(
        siteId: 'ZSJN',
        unit: 'C',
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        points: [
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 6, 5),
            temperature: 17,
            kind: TempPointKind.observed,
            isDailyMinimum: true,
          ),
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 6, 10),
            temperature: 22,
            kind: TempPointKind.observed,
            isDailyMaximum: true,
          ),
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 6, 14),
            temperature: 19,
            kind: TempPointKind.forecast,
          ),
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 6, 18),
            temperature: 24,
            kind: TempPointKind.forecast,
          ),
        ],
      );
      expect(seriesObservedMin(series), 17);
      expect(seriesObservedMax(series), 22);
      expect(seriesForecastRemainingMin(series), 19);
      expect(seriesForecastRemainingMax(series), 24);
      expect(
        seriesObservedExtremum(series, TempMarketKind.high),
        22,
      );
      expect(
        seriesForecastRemainingExtremum(series, TempMarketKind.high),
        24,
      );
    });

    test('forecast-only series has no Obs min/max even if daily-min flagged', () {
      final loc = tz.getLocation('Asia/Seoul');
      final dayStart = tz.TZDateTime(loc, 2026, 9, 7);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final now = tz.TZDateTime(loc, 2026, 9, 7, 0, 30);
      final series = DailyTemperatureSeries(
        siteId: 'RKPK',
        unit: 'C',
        dayStart: dayStart,
        dayEnd: dayEnd,
        nowLocal: now,
        points: [
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 7, 0),
            temperature: 24,
            kind: TempPointKind.forecast,
          ),
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 7, 23),
            temperature: 22.1,
            kind: TempPointKind.forecast,
            isDailyMinimum: true,
          ),
          HourlyTempPoint(
            localHourStart: tz.TZDateTime(loc, 2026, 9, 7, 13),
            temperature: 27.5,
            kind: TempPointKind.forecast,
            isDailyMaximum: true,
          ),
        ],
      );
      expect(seriesObservedMin(series), isNull);
      expect(seriesObservedMax(series), isNull);
      expect(seriesObservedExtremum(series, TempMarketKind.low), isNull);
      expect(seriesForecastRemainingMin(series), 22.1);
    });
  });

  group('MarketEvent tempKind and cityName', () {
    test('Highest title parses city and high kind', () {
      final event = MarketEvent.fromJson({
        'id': 'h1',
        'title': 'Highest temperature in Hong Kong on September 6?',
        'slug': 'hk-high',
        'markets': [],
      });
      expect(event.tempKind, TempMarketKind.high);
      expect(event.cityName, 'Hong Kong');
    });

    test('Lowest title remains low kind', () {
      final event = MarketEvent.fromJson({
        'id': 'l1',
        'title': 'Lowest temperature in Jinan on September 6?',
        'slug': 'jn-low',
        'markets': [],
      });
      expect(event.tempKind, TempMarketKind.low);
      expect(event.cityName, 'Jinan');
    });
  });
}

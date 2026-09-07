enum MarketAlertKind { obsMinDrop, lockWithNos }

class MarketAlert {
  const MarketAlert({
    required this.at,
    required this.kind,
    required this.eventId,
    required this.title,
    required this.message,
  });

  final DateTime at;
  final MarketAlertKind kind;
  final String eventId;
  final String title;
  final String message;
}

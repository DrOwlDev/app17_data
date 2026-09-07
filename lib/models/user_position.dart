class UserPosition {
  const UserPosition({
    required this.proxyWallet,
    required this.asset,
    required this.conditionId,
    required this.size,
    required this.avgPrice,
    required this.initialValue,
    required this.currentValue,
    required this.cashPnl,
    required this.percentPnl,
    required this.curPrice,
    required this.redeemable,
    required this.title,
    required this.slug,
    required this.eventSlug,
    required this.outcome,
    this.endDate,
    this.icon,
  });

  final String proxyWallet;
  final String asset;
  final String conditionId;
  final double size;
  final double avgPrice;
  final double initialValue;
  final double currentValue;
  final double cashPnl;
  final double percentPnl;
  final double curPrice;
  final bool redeemable;
  final String title;
  final String slug;
  final String eventSlug;
  final String outcome;
  final String? endDate;
  final String? icon;

  String get polymarketEventUrl {
    final slug = eventSlug.isNotEmpty ? eventSlug : this.slug;
    return 'https://polymarket.com/event/$slug';
  }

  factory UserPosition.fromJson(Map<String, dynamic> json) {
    return UserPosition(
      proxyWallet: json['proxyWallet']?.toString() ?? '',
      asset: json['asset']?.toString() ?? '',
      conditionId: json['conditionId']?.toString() ?? '',
      size: _asDouble(json['size']),
      avgPrice: _asDouble(json['avgPrice']),
      initialValue: _asDouble(json['initialValue']),
      currentValue: _asDouble(json['currentValue']),
      cashPnl: _asDouble(json['cashPnl']),
      percentPnl: _asDouble(json['percentPnl']),
      curPrice: _asDouble(json['curPrice']),
      redeemable: json['redeemable'] == true,
      title: json['title']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      eventSlug: json['eventSlug']?.toString() ?? '',
      outcome: json['outcome']?.toString() ?? '',
      endDate: json['endDate']?.toString(),
      icon: json['icon']?.toString(),
    );
  }
}

double _asDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

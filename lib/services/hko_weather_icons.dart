// HKO OCF / official weather icon helpers (ForecastWeather codes).
// Icon list: https://www.hko.gov.hk/textonly/v2/explain/wxicon_e.htm
// Images: https://www.hko.gov.hk/images/HKOWxIconOutline/picNN.png

const Set<int> kHkoWeatherIconCodes = {
  50, 51, 52, 53, 54,
  60, 61, 62, 63, 64, 65,
  70, 71, 72, 73, 74, 75, 76, 77,
  80, 81, 82, 83, 84, 85,
  90, 91, 92, 93,
};

/// OCF sometimes emits 3-digit composites (e.g. 751 → 75, 711 → 71).
int? normalizeHkoWeatherIconCode(int? raw) {
  if (raw == null) return null;
  if (kHkoWeatherIconCodes.contains(raw)) return raw;
  if (raw >= 100) {
    final prefix = int.tryParse(raw.toString().substring(0, 2));
    if (prefix != null && kHkoWeatherIconCodes.contains(prefix)) {
      return prefix;
    }
  }
  return null;
}

String hkoWeatherIconImageUrl(int code) =>
    'https://www.hko.gov.hk/images/HKOWxIconOutline/pic$code.png';

String hkoWeatherIconCaption(int code) {
  switch (code) {
    case 50:
      return 'Sunny';
    case 51:
      return 'Sunny Periods';
    case 52:
      return 'Sunny Intervals';
    case 53:
      return 'Sunny Periods with A Few Showers';
    case 54:
      return 'Sunny Intervals with Showers';
    case 60:
      return 'Cloudy';
    case 61:
      return 'Overcast';
    case 62:
      return 'Light Rain';
    case 63:
      return 'Rain';
    case 64:
      return 'Heavy Rain';
    case 65:
      return 'Thunderstorms';
    case 70:
    case 71:
    case 72:
    case 73:
    case 74:
    case 75:
      return 'Fine';
    case 76:
      return 'Mainly Cloudy';
    case 77:
      return 'Mainly Fine';
    case 80:
      return 'Windy';
    case 81:
      return 'Dry';
    case 82:
      return 'Humid';
    case 83:
      return 'Fog';
    case 84:
      return 'Mist';
    case 85:
      return 'Haze';
    case 90:
      return 'Hot';
    case 91:
      return 'Warm';
    case 92:
      return 'Cool';
    case 93:
      return 'Cold';
    default:
      return 'Weather';
  }
}

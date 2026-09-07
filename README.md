# app17_data

GitHub Actions–driven **temperature archive** for Polymarket daily
[lowest](https://polymarket.com/weather/low-temperature) and
[highest](https://polymarket.com/weather/high-temperature) market cities.

For each chartable resolution station (WRH ICAO, Weather Underground ICAO, HKO):

1. **Observed** — append actual temperatures over time into per-day CSVs, plus **observed daily min/max**.
2. **Forecast snapshots** — every ~30 minutes, save hourly forecast from **city-local now → +72h**.
3. **Retention** — delete observed/forecast files (and daily_extremes rows) older than **3 months**.
4. **Pages** — browse/download archive files and view **forecast skill** analysis.

| Runtime | Role |
|---|---|
| **GitHub Actions** | Collect + prune + skill stats + deploy Pages |
| **Local CLI** | Same Dart tools for dry-runs |
| **GitHub Pages** | https://drowldev.github.io/app17_data/ |

Gamma tags: Lowest `104597` + Highest `104596`.

---

## GitHub Pages

After deploy:

- **[Files](https://drowldev.github.io/app17_data/)** — station file browser with download links
- **[Forecast skill](https://drowldev.github.io/app17_data/skill.html)** — Polymarket-oriented skill: hit @ 0.4°C, \(L\) / \(L_{min}\) / \(L_{max}\), daily extreme skill vs lead, 14-day min/max timing histograms

Static UI lives in [`site/`](site/). Data is published from `data/stations` + `data/analysis`.

---

## Archive layout

```
data/
  stations/
    index.json
    {stationId}/
      meta.json
      observed/YYYY-MM-DD.csv
      daily_extremes.csv
      forecasts/YYYYMMDDTHHMMZ.csv
  analysis/
    skill.json              # forecast vs observed skill
    files_manifest.json     # browse UI catalog
  runs/
    latest.json
```

Temperatures are stored in **°C**. Files older than **90 days** are pruned on each collect run.

---

## Collectors

```bash
flutter pub get
dart run tool/collect_stations.dart
dart run tool/collect_observed.dart
dart run tool/collect_forecasts.dart
dart run tool/prune_archive.dart 90
dart run tool/build_skill_stats.dart
dart run tool/build_pages.dart          # → build/pages
```

### Actions schedule

Every **~30 minutes** ([collect-archive.yml](.github/workflows/collect-archive.yml)):

`collect_stations` → observed → forecasts → **prune 90d** → **skill stats** → commit `data/` → **deploy Pages**

Manual: [Deploy Archive Pages](.github/workflows/deploy-pages.yml) also on `main` pushes that touch `site/` or `data/`.

---

## Forecast skill (Polymarket edge @ 0.4°C)

Markets settle on resolution-source **daily min (Low)** or **daily max (High)**. Earlier accurate extreme forecasts usually mean better entry prices.

**Pairing:** nearest observation within **±30 minutes** of each forecast `valid_local_time`.

**Hit:** \|forecast − observed\| ≤ **0.4°C** (hourly and daily extremes).

**Time-to-skill \(L\):** smallest lead hour such that forecasts with lead ≤ \(L\) meet hit rate ≥ 80% **or** MAE ≤ 0.4°C (bins with enough samples). \(L_{min}\) / \(L_{max}\) use the same rule on forecast day min/max vs observed extremes (lead = hours before local EOD).

**Bucket hit:** integer °C of forecast extreme equals integer °C of observed extreme (closer to Polymarket outcomes).

**14-day timing:** from observed only — share of days with min before 6am vs after 6pm, plus occurrence / lock-hour histograms for min and max.

UI: hourly skill + evolution (±0.4°C), extreme hit/MAE vs lead, timing histograms, summary with \(L_{min}\)/\(L_{max}\) and morning/afternoon shares. Tip: HKO Absolute Daily Extract can differ from the live hkoc chart curve.

---

## Legacy Flutter UI

`lib/main.dart` still has the old market browser; not required for archive collection.

---

## Google Drive (later)

CSV tree under `data/stations/` can be mirrored to Drive without schema changes.

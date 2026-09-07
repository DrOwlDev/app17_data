(function () {
  const DATA_BASE = 'data';
  const TOL = 0.4;
  const stationEl = document.getElementById('station');
  const targetEl = document.getElementById('target');
  const statusEl = document.getElementById('status');
  const statsEl = document.getElementById('stats');
  const summaryBody = document.getElementById('summaryBody');
  const evoCaption = document.getElementById('evoCaption');
  const timingCaption = document.getElementById('timingCaption');

  let skillDoc = null;
  let skillChart = null;
  let evoChart = null;
  let extremeChart = null;
  let timingChart = null;

  function pct(x) {
    if (x == null || Number.isNaN(x)) return '—';
    return (x * 100).toFixed(0) + '%';
  }
  function num(x, d) {
    if (x == null || Number.isNaN(x)) return '—';
    return Number(x).toFixed(d);
  }
  function skillPill(l) {
    if (l == null) return '<span class="pill warn">n/a</span>';
    const cls = l <= 12 ? 'good' : l <= 24 ? 'warn' : 'bad';
    return '<span class="pill ' + cls + '">' + l + 'h</span>';
  }
  function tol() {
    return skillDoc && skillDoc.toleranceC != null ? skillDoc.toleranceC : TOL;
  }

  function renderSummary() {
    summaryBody.innerHTML = '';
    for (const s of skillDoc.stations || []) {
      const tr = document.createElement('tr');
      tr.innerHTML =
        '<td class="mono"><a href="#" data-id="' +
        s.stationId +
        '">' +
        s.stationId +
        '</a></td>' +
        '<td>' +
        (s.cityName || '') +
        '</td>' +
        '<td class="mono">' +
        (s.pairCount || 0) +
        '</td>' +
        '<td class="mono">' +
        pct(s.hitAt6h) +
        '</td>' +
        '<td>' +
        skillPill(s.timeToSkillHours) +
        '</td>' +
        '<td>' +
        skillPill(s.timeToSkillMinHours) +
        '</td>' +
        '<td>' +
        skillPill(s.timeToSkillMaxHours) +
        '</td>' +
        '<td class="mono">' +
        pct(s.minExtremeHitRate) +
        '</td>' +
        '<td class="mono">' +
        pct(s.maxExtremeHitRate) +
        '</td>' +
        '<td class="mono">' +
        (s.minBefore6amDays != null ? s.minBefore6amDays : '—') +
        '</td>' +
        '<td class="mono">' +
        (s.minAfter6pmDays != null ? s.minAfter6pmDays : '—') +
        '</td>' +
        '<td class="mono">' +
        pct(s.maxAfternoonShare) +
        '</td>' +
        '<td class="mono">' +
        (s.dominantForecastSource || '—') +
        '</td>';
      summaryBody.appendChild(tr);
    }
    summaryBody.querySelectorAll('a[data-id]').forEach((a) => {
      a.addEventListener('click', (ev) => {
        ev.preventDefault();
        stationEl.value = a.getAttribute('data-id');
        onStationChange();
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    });
  }

  function fillStations() {
    stationEl.innerHTML = '';
    for (const s of skillDoc.stations || []) {
      const opt = document.createElement('option');
      opt.value = s.stationId;
      opt.textContent = s.stationId + ' — ' + (s.cityName || '');
      stationEl.appendChild(opt);
    }
  }

  function currentSkill() {
    const id = stationEl.value;
    return (skillDoc.byStation || {})[id] || null;
  }

  function currentSummary() {
    const id = stationEl.value;
    return (skillDoc.stations || []).find((s) => s.stationId === id);
  }

  function renderStats() {
    const s = currentSummary();
    if (!s) {
      statsEl.innerHTML = '';
      return;
    }
    statsEl.innerHTML =
      '<div class="stat"><div class="k">Pairs</div><div class="v">' +
      (s.pairCount || 0) +
      '</div></div>' +
      '<div class="stat"><div class="k">Hit @' +
      tol() +
      '°C</div><div class="v">' +
      pct(s.overallHitRate) +
      '</div></div>' +
      '<div class="stat"><div class="k">L hourly</div><div class="v">' +
      (s.timeToSkillHours == null ? '—' : s.timeToSkillHours + 'h') +
      '</div></div>' +
      '<div class="stat"><div class="k">L<sub>min</sub></div><div class="v">' +
      (s.timeToSkillMinHours == null ? '—' : s.timeToSkillMinHours + 'h') +
      '</div></div>' +
      '<div class="stat"><div class="k">L<sub>max</sub></div><div class="v">' +
      (s.timeToSkillMaxHours == null ? '—' : s.timeToSkillMaxHours + 'h') +
      '</div></div>' +
      '<div class="stat"><div class="k">Min &lt;6am / &gt;6pm</div><div class="v" style="font-size:1rem">' +
      (s.minBefore6amDays != null ? s.minBefore6amDays : '—') +
      ' / ' +
      (s.minAfter6pmDays != null ? s.minAfter6pmDays : '—') +
      '</div></div>' +
      '<div class="stat"><div class="k">Bucket hit min/max</div><div class="v" style="font-size:1rem">' +
      pct(s.minBucketHitRate) +
      ' / ' +
      pct(s.maxBucketHitRate) +
      '</div></div>';
  }

  function renderSkillChart() {
    const sk = currentSkill();
    const rows = (sk && sk.skillByLead) || [];
    const labels = rows.map((r) => r.leadHours);
    const mae = rows.map((r) => r.mae);
    const hit = rows.map((r) => (r.hitRate || 0) * 100);
    const L = sk && sk.timeToSkillHours;

    if (skillChart) skillChart.destroy();
    skillChart = new Chart(document.getElementById('skillChart'), {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'MAE (°C)',
            data: mae,
            borderColor: '#0b6bcb',
            yAxisID: 'y',
            tension: 0.2,
          },
          {
            label: 'Hit @' + tol() + '°C (%)',
            data: hit,
            borderColor: '#1b7f4e',
            yAxisID: 'y1',
            tension: 0.2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: { legend: { position: 'bottom' } },
        scales: {
          x: { title: { display: true, text: 'Lead hours before valid time' } },
          y: { title: { display: true, text: 'MAE °C' }, suggestedMin: 0 },
          y1: {
            position: 'right',
            min: 0,
            max: 100,
            grid: { drawOnChartArea: false },
            title: { display: true, text: 'Hit %' },
          },
        },
      },
      plugins: [
        {
          id: 'skillMarker',
          afterDraw(chart) {
            if (L == null) return;
            const meta = chart.getDatasetMeta(0);
            if (!meta || !meta.data.length) return;
            const idx = labels.indexOf(L);
            if (idx < 0) return;
            const x = meta.data[idx].x;
            const { top, bottom } = chart.chartArea;
            const c = chart.ctx;
            c.save();
            c.strokeStyle = '#b86e00';
            c.setLineDash([4, 4]);
            c.beginPath();
            c.moveTo(x, top);
            c.lineTo(x, bottom);
            c.stroke();
            c.fillStyle = '#b86e00';
            c.font = '12px sans-serif';
            c.fillText('L=' + L + 'h', x + 4, top + 14);
            c.restore();
          },
        },
      ],
    });
  }

  function renderExtremeChart() {
    const sk = currentSkill();
    const minRows = (sk && sk.extremeSkillByLeadMin) || [];
    const maxRows = (sk && sk.extremeSkillByLeadMax) || [];
    const leadSet = new Set([
      ...minRows.map((r) => r.leadHours),
      ...maxRows.map((r) => r.leadHours),
    ]);
    const labels = [...leadSet].sort((a, b) => a - b);
    const minMap = Object.fromEntries(minRows.map((r) => [r.leadHours, r]));
    const maxMap = Object.fromEntries(maxRows.map((r) => [r.leadHours, r]));

    if (extremeChart) extremeChart.destroy();
    extremeChart = new Chart(document.getElementById('extremeChart'), {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'Min hit %',
            data: labels.map((h) =>
              minMap[h] ? (minMap[h].hitRate || 0) * 100 : null
            ),
            borderColor: '#0b6bcb',
            tension: 0.2,
            yAxisID: 'y',
          },
          {
            label: 'Max hit %',
            data: labels.map((h) =>
              maxMap[h] ? (maxMap[h].hitRate || 0) * 100 : null
            ),
            borderColor: '#b42318',
            tension: 0.2,
            yAxisID: 'y',
          },
          {
            label: 'Min MAE',
            data: labels.map((h) => (minMap[h] ? minMap[h].mae : null)),
            borderColor: '#5b6570',
            borderDash: [4, 4],
            tension: 0.2,
            yAxisID: 'y1',
          },
          {
            label: 'Max MAE',
            data: labels.map((h) => (maxMap[h] ? maxMap[h].mae : null)),
            borderColor: '#b86e00',
            borderDash: [4, 4],
            tension: 0.2,
            yAxisID: 'y1',
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: { legend: { position: 'bottom' } },
        scales: {
          x: { title: { display: true, text: 'Lead hours before local EOD' } },
          y: { min: 0, max: 100, title: { display: true, text: 'Hit %' } },
          y1: {
            position: 'right',
            suggestedMin: 0,
            grid: { drawOnChartArea: false },
            title: { display: true, text: 'MAE °C' },
          },
        },
      },
    });
  }

  function renderTimingChart() {
    const sk = currentSkill();
    const t = (sk && sk.timing) || {};
    const minFirst = t.minFirstHourHist || Array(24).fill(0);
    const minLock = t.minLockHourHist || Array(24).fill(0);
    const maxFirst = t.maxFirstHourHist || Array(24).fill(0);
    const maxLock = t.maxLockHourHist || Array(24).fill(0);
    const labels = Array.from({ length: 24 }, (_, i) => i + 'h');

    timingCaption.textContent =
      (t.daysAnalyzed || 0) +
      ' days · min before 6am: ' +
      (t.minBefore6amDays ?? '—') +
      ', after 6pm: ' +
      (t.minAfter6pmDays ?? '—') +
      ', mid: ' +
      (t.minMidDayDays ?? '—') +
      ' · mode min ' +
      (t.minModeHour != null ? t.minModeHour + 'h' : '—') +
      ' lock ' +
      (t.minLockModeHour != null ? t.minLockModeHour + 'h' : '—') +
      ' · mode max ' +
      (t.maxModeHour != null ? t.maxModeHour + 'h' : '—') +
      ' lock ' +
      (t.maxLockModeHour != null ? t.maxLockModeHour + 'h' : '—');

    if (timingChart) timingChart.destroy();
    timingChart = new Chart(document.getElementById('timingChart'), {
      type: 'bar',
      data: {
        labels,
        datasets: [
          {
            label: 'Min first hour',
            data: minFirst,
            backgroundColor: 'rgba(11,107,203,0.55)',
          },
          {
            label: 'Min lock hour',
            data: minLock,
            backgroundColor: 'rgba(11,107,203,0.25)',
          },
          {
            label: 'Max first hour',
            data: maxFirst,
            backgroundColor: 'rgba(180,35,24,0.55)',
          },
          {
            label: 'Max lock hour',
            data: maxLock,
            backgroundColor: 'rgba(180,35,24,0.25)',
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { position: 'bottom' } },
        scales: {
          x: { title: { display: true, text: 'Local hour' } },
          y: {
            beginAtZero: true,
            ticks: { stepSize: 1 },
            title: { display: true, text: 'Days' },
          },
        },
      },
    });
  }

  function fillTargets() {
    const sk = currentSkill();
    targetEl.innerHTML = '';
    const targets = (sk && sk.evolutionTargets) || [];
    if (!targets.length) {
      const opt = document.createElement('option');
      opt.textContent = 'No paired evolution targets yet';
      targetEl.appendChild(opt);
      return;
    }
    for (const t of targets) {
      const opt = document.createElement('option');
      opt.value = t.validLocal;
      opt.textContent = t.validLocal + ' (obs ' + num(t.obsC, 1) + '°C)';
      targetEl.appendChild(opt);
    }
  }

  function renderEvolution() {
    const sk = currentSkill();
    const targets = (sk && sk.evolutionTargets) || [];
    const t = targets.find((x) => x.validLocal === targetEl.value) || targets[0];
    if (evoChart) evoChart.destroy();
    if (!t) {
      evoCaption.textContent = 'Need more forecast+observed overlap.';
      return;
    }
    const band = tol();
    evoCaption.textContent =
      'Valid ' +
      t.validLocal +
      ' · observed ' +
      num(t.obsC, 2) +
      '°C · ±' +
      band +
      '°C band shaded';
    const labels = t.points.map((p) =>
      p.issuedAtUtc.replace('T', ' ').slice(0, 16)
    );
    const fc = t.points.map((p) => p.forecastC);
    const obs = t.points.map(() => t.obsC);
    const hi = t.points.map(() => t.obsC + band);
    const lo = t.points.map(() => t.obsC - band);

    evoChart = new Chart(document.getElementById('evoChart'), {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'Forecast',
            data: fc,
            borderColor: '#0b6bcb',
            tension: 0.15,
          },
          {
            label: 'Observed',
            data: obs,
            borderColor: '#1a1f26',
            borderDash: [6, 4],
            pointRadius: 0,
          },
          {
            label: '+' + band + '°C',
            data: hi,
            borderColor: 'rgba(27,127,78,0.35)',
            pointRadius: 0,
            borderDash: [2, 2],
          },
          {
            label: '−' + band + '°C',
            data: lo,
            borderColor: 'rgba(27,127,78,0.35)',
            pointRadius: 0,
            borderDash: [2, 2],
            fill: '-1',
            backgroundColor: 'rgba(27,127,78,0.08)',
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { position: 'bottom' } },
        scales: {
          x: { title: { display: true, text: 'Forecast issued (UTC)' } },
          y: { title: { display: true, text: '°C' } },
        },
      },
    });
  }

  function onStationChange() {
    renderStats();
    renderSkillChart();
    renderExtremeChart();
    renderTimingChart();
    fillTargets();
    renderEvolution();
  }

  async function load() {
    statusEl.innerHTML = '<p class="muted">Loading skill stats…</p>';
    try {
      const res = await fetch(DATA_BASE + '/analysis/skill.json', {
        cache: 'no-store',
      });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      skillDoc = await res.json();
      statusEl.innerHTML =
        '<p class="muted">Generated ' +
        (skillDoc.generatedAt || '') +
        ' · tolerance ' +
        tol() +
        '°C · match ±' +
        (skillDoc.matchWindowMinutes || 30) +
        'm · timing lookback ' +
        (skillDoc.timingLookbackDays || 14) +
        'd</p>';
      fillStations();
      renderSummary();
      onStationChange();
    } catch (e) {
      statusEl.innerHTML =
        '<div class="error">Could not load skill.json. Collect data, then run <code>dart run tool/build_skill_stats.dart</code> and deploy Pages. (' +
        e.message +
        ')</div>';
    }
  }

  stationEl.addEventListener('change', onStationChange);
  targetEl.addEventListener('change', renderEvolution);
  load();
})();

(function () {
  const DATA_BASE = 'data';
  const stationEl = document.getElementById('station');
  const targetEl = document.getElementById('target');
  const statusEl = document.getElementById('status');
  const statsEl = document.getElementById('stats');
  const summaryBody = document.getElementById('summaryBody');
  const evoCaption = document.getElementById('evoCaption');

  let skillDoc = null;
  let skillChart = null;
  let evoChart = null;

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
        num(s.maeAt6h, 2) +
        '</td>' +
        '<td class="mono">' +
        num(s.maeAt24h, 2) +
        '</td>' +
        '<td class="mono">' +
        num(s.maeAt48h, 2) +
        '</td>' +
        '<td class="mono">' +
        pct(s.hitAt6h) +
        '</td>' +
        '<td class="mono">' +
        pct(s.hitAt24h) +
        '</td>' +
        '<td class="mono">' +
        pct(s.hitAt48h) +
        '</td>' +
        '<td>' +
        skillPill(s.timeToSkillHours) +
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
      '<div class="stat"><div class="k">Overall MAE</div><div class="v">' +
      num(s.overallMae, 2) +
      '°</div></div>' +
      '<div class="stat"><div class="k">Hit @0.5°C</div><div class="v">' +
      pct(s.overallHitRate) +
      '</div></div>' +
      '<div class="stat"><div class="k">Time-to-skill L</div><div class="v">' +
      (s.timeToSkillHours == null ? '—' : s.timeToSkillHours + 'h') +
      '</div></div>' +
      '<div class="stat"><div class="k">Source</div><div class="v" style="font-size:0.85rem">' +
      (s.dominantForecastSource || '—') +
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
    const ctx = document.getElementById('skillChart');
    skillChart = new Chart(ctx, {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'MAE (°C)',
            data: mae,
            borderColor: '#0b6bcb',
            backgroundColor: 'rgba(11,107,203,0.12)',
            yAxisID: 'y',
            tension: 0.2,
          },
          {
            label: 'Hit rate @0.5°C (%)',
            data: hit,
            borderColor: '#1b7f4e',
            backgroundColor: 'rgba(27,127,78,0.08)',
            yAxisID: 'y1',
            tension: 0.2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { position: 'bottom' },
          annotation: undefined,
        },
        scales: {
          x: { title: { display: true, text: 'Lead hours before valid time' } },
          y: {
            title: { display: true, text: 'MAE °C' },
            suggestedMin: 0,
          },
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
    evoCaption.textContent =
      'Valid ' +
      t.validLocal +
      ' · observed ' +
      num(t.obsC, 2) +
      '°C · ±0.5°C band shaded';
    const labels = t.points.map((p) => p.issuedAtUtc.replace('T', ' ').slice(0, 16));
    const fc = t.points.map((p) => p.forecastC);
    const obs = t.points.map(() => t.obsC);
    const hi = t.points.map(() => t.obsC + 0.5);
    const lo = t.points.map(() => t.obsC - 0.5);

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
            label: '+0.5°C',
            data: hi,
            borderColor: 'rgba(27,127,78,0.35)',
            pointRadius: 0,
            borderDash: [2, 2],
          },
          {
            label: '−0.5°C',
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
        (skillDoc.toleranceC || 0.5) +
        '°C · match ±' +
        (skillDoc.matchWindowMinutes || 30) +
        'm</p>';
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

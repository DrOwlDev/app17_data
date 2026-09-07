(function () {
  const DATA_BASE = 'data';
  const listEl = document.getElementById('list');
  const metaEl = document.getElementById('meta');
  const statusEl = document.getElementById('status');
  const qEl = document.getElementById('q');
  const kindEl = document.getElementById('kind');

  let manifest = null;

  function fmtBytes(n) {
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(2) + ' MB';
  }

  function render() {
    if (!manifest) return;
    const q = (qEl.value || '').trim().toLowerCase();
    const kind = kindEl.value;
    const stations = manifest.stations.filter((s) => {
      if (!q) return true;
      return (
        s.stationId.toLowerCase().includes(q) ||
        (s.cityName || '').toLowerCase().includes(q)
      );
    });

    listEl.innerHTML = '';
    for (const s of stations) {
      const files = (s.files || []).filter((f) =>
        kind === 'all' ? true : f.kind === kind
      );
      if (!files.length) continue;
      const block = document.createElement('section');
      block.className = 'station-block card';
      block.innerHTML =
        '<h3>' +
        s.stationId +
        ' <span class="muted">· ' +
        (s.cityName || '') +
        '</span> <span class="pill">' +
        (s.sourceKind || '') +
        '</span></h3>';
      const ul = document.createElement('ul');
      ul.className = 'file-list';
      for (const f of files) {
        const li = document.createElement('li');
        const href = DATA_BASE + '/' + f.path;
        li.innerHTML =
          '<div><a href="' +
          href +
          '" download="' +
          f.name +
          '">' +
          f.name +
          '</a> <span class="pill">' +
          f.kind +
          '</span></div>' +
          '<div class="bytes mono">' +
          fmtBytes(f.bytes || 0) +
          '</div>';
        ul.appendChild(li);
      }
      block.appendChild(ul);
      listEl.appendChild(block);
    }
    if (!listEl.children.length) {
      listEl.innerHTML = '<p class="muted">No files match.</p>';
    }
  }

  async function load() {
    statusEl.innerHTML = '<p class="muted">Loading manifest…</p>';
    try {
      const res = await fetch(DATA_BASE + '/analysis/files_manifest.json', {
        cache: 'no-store',
      });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      manifest = await res.json();
      metaEl.textContent =
        (manifest.stationCount || 0) +
        ' stations · ' +
        (manifest.fileCount || 0) +
        ' files · generated ' +
        (manifest.generatedAt || '');
      statusEl.innerHTML = '';
      render();
    } catch (e) {
      statusEl.innerHTML =
        '<div class="error">Could not load file manifest. Run collectors + <code>dart run tool/build_skill_stats.dart</code>, then deploy Pages. (' +
        e.message +
        ')</div>';
    }
  }

  qEl.addEventListener('input', render);
  kindEl.addEventListener('change', render);
  load();
})();

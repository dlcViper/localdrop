import 'dart:html';
import 'dart:convert';
import 'dart:typed_data';

void main() {
  window.console.time('[init]');
  log('[init]', 'client starting');

  const api = '/api';
  let token = null;
  let currentPath = '';
  let transfersMap = {};
  let pollingTimer = null;

  // ── Auth ────────────────────────────────────────
  const loginForm = document.getElementById('login-form');
  const pinInput = document.getElementById('pin-input');
  const loginError = document.getElementById('login-error');
  const appEl = document.getElementById('app');
  const loginEl = document.getElementById('login');

  loginForm.addEventListener('submit', (e) {
    e.preventDefault();
    const pin = pinInput.value.trim();
    if (pin.length !== 6) {
      loginError.textContent = 'PIN must be 6 digits';
      return;
    }
    loginError.textContent = '';
    fetch('$api/auth', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({pin}),
    })
      .then((r) => {
        if (!r.ok) throw new Error('auth failed');
        return r.json();
      })
      .then((data) => {
        token = data.token;
        _showApp();
        _loadFiles();
      })
      .catch((err) => {
        loginError.textContent = 'Invalid PIN';
        log('[auth]', 'login failed');
      });
  });

  function _showApp() {
    loginEl.style.display = 'none';
    appEl.style.display = 'block';
    _startPolling();
  }

  // ── Polling ──────────────────────────────────────
  function _startPolling() {
    if (pollingTimer) clearInterval(pollingTimer);
    pollingTimer = setInterval(_pollTransfers, 1500);
    _pollTransfers();
  }

  function _pollTransfers() {
    fetch('$api/progress')
      .then((r) => r.json())
      .then((data) => {
        transfersMap = {};
        for (const t of data.transfers) {
          transfersMap[t.id] = t;
        }
        _updateTransferRows();
      })
      .catch(() => {});
  }

  function _updateTransferRows() {
    const tbody = document.getElementById('transfers-tbody');
    if (!tbody) return;
    const all = Object.values(transfersMap);
    tbody.innerHTML = all
      .map((t) => {
        const pct =
          t.bytes_total > 0 ? ((t.bytes_done / t.bytes_total) * 100).toFixed(1) : '—';
        const statusLabel =
          t.status === 'failed'
            ? `FAIL: ${t.error || t.reason || 'unknown'}`
            : t.status;
        return `<tr>
          <td>${t.direction}</td>
          <td title="${t.name}">${_esc(t.name)}</td>
          <td>${pct}%</td>
          <td>${t.bytes_done}/${t.bytes_total}</td>
          <td>${statusLabel}</td>
        </tr>`;
      })
      .join('');
  }

  function _esc(s) {
    const d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  // ── Files ────────────────────────────────────────
  function _loadFiles() {
    const qs = currentPath ? '?path=' + encodeURIComponent(currentPath) : '?path=';
    fetch(`${api}/files${qs}`)
      .then((r) => {
        if (r.status === 401) _handleUnauth();
        return r.json();
      })
      .then((data) => {
        _renderFileList(data);
        _updateBreadcrumb(data.path || currentPath);
      })
      .catch((err) => {
        log('[files]', 'load failed path=' + currentPath, err);
      });
  }

  function _renderFileList(data) {
    const tbody = document.getElementById('files-tbody');
    const root = document.getElementById('files-root');
    if (!tbody) return;
    const entries = data.entries || [];
    root.textContent = data.path || '/';
    tbody.innerHTML = entries
      .map((e) => {
        const isDir = e.is_directory;
        const icon = isDir ? '📁' : '📄';
        const size = isDir ? '—' : _fmtSize(e.size);
        const mod = new Date(e.modified).toLocaleString();
        return `<tr class="${isDir ? 'dir-row' : 'file-row'}" data-path="${_esc(e.path)}">
          <td>${icon}</td>
          <td>${_esc(e.name)}</td>
          <td>${e.type || (isDir ? 'directory' : 'unknown')}</td>
          <td>${size}</td>
          <td>${mod}</td>
          <td>${isDir ? '' : '<button class="btn-dl" onclick="_downloadFile(\'' + _esc(e.path).replace(/'/g, "\\'") + '\')">Download</button>'}</td>
        </tr>`;
      })
      .join('');

    // Click row → navigate into folder or trigger download
    tbody.querySelectorAll('tr.dir-row').forEach((row) => {
      row.style.cursor = 'pointer';
      row.addEventListener('click', () => {
        const p = row.getAttribute('data-path');
        if (p) {
          currentPath = p;
          _loadFiles();
        }
      });
    });
  }

  function _downloadFile(relPath) {
    const transferId = 'web-' + Date.now();
    const a = document.createElement('a');
    a.href = `${api}/download/${encodeURIComponent(relPath)}?t=${Date.now()}`;
    a.headers = {'X-Session-Token': token, 'X-Transfer-Id': transferId};
    a.style.display = 'none';
    document.body.appendChild(a);
    // Use fetch for progress tracking + blob download
    fetch(a.href, {
      headers: {
        'X-Session-Token': token,
        'X-Transfer-Id': transferId,
      },
    })
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const reader = r.body.getReader();
        const contentLength = r.headers.get('content-length');
        const total = contentLength ? parseInt(contentLength, 10) : 0;
        let received = 0;
        const chunks = [];

        function read() {
          return reader.read().then(({done, value}) => {
            if (done) {
              const blob = new Blob(chunks);
              const url = URL.createObjectURL(blob);
              const da = document.createElement('a');
              da.href = url;
              da.download = relPath.split('/').pop() || 'file';
              da.click();
              URL.revokeObjectURL(url);
              log('[download]', `file=${relPath.split('/').pop()} bytes=${received} status=completed`);
              return;
            }
            chunks.push(value);
            received += value.length;
            if (total > 0) {
              const pct = ((received / total) * 100).toFixed(1);
              log('[download]', `file=${relPath.split('/').pop()} bytes=${received}/${total} progress=${pct}% status=active`);
            }
            return read();
          });
        }
        return read();
      })
      .catch((err) => {
        log('[download]', `file=${relPath.split('/').pop()} status=failed reason=${err.message}`);
      });
  }

  function _updateBreadcrumb(path) {
    const bc = document.getElementById('breadcrumb');
    if (!bc) return;
    const parts = path.split('/').filter(Boolean);
    let acc = '';
    bc.innerHTML = parts
      .map((p, i) => {
        acc += '/' + p;
        const isLast = i === parts.length - 1;
        return isLast
          ? `<span class="bc-current">${_esc(p)}</span>`
          : `<a href="#" onclick="_navigateTo('${acc}');return false;">${_esc(p)}</a>`;
      })
      .join(' / ');
  }

  window._navigateTo = function(p) {
    currentPath = p;
    _loadFiles();
  };
  window._downloadFile = _downloadFile;

  // ── Search / Filter / Sort ───────────────────────
  const searchInput = document.getElementById('search-input');
  const sortSelect = document.getElementById('sort-select');
  const filterSelect = document.getElementById('filter-select');

  function _applyFiltersAndSort(entries) {
    const q = (searchInput?.value || '').toLowerCase();
    let list = [...entries];
    if (q) {
      list = list.filter((e) => e.name.toLowerCase().includes(q));
    }
    const filter = filterSelect?.value || 'all';
    if (filter !== 'all') {
      list = list.filter((e) => e.is_directory === (filter === 'dirs'));
    }
    const sort = sortSelect?.value || 'name-asc';
    list.sort((a, b) => {
      switch (sort) {
        case 'name-asc': return a.name.localeCompare(b.name);
        case 'name-desc': return b.name.localeCompare(a.name);
        case 'size-asc': return (a.size||0) - (b.size||0);
        case 'size-desc': return (b.size||0) - (a.size||0);
        case 'date-asc': return new Date(a.modified) - new Date(b.modified);
        case 'date-desc': return new Date(b.modified) - new Date(a.modified);
        case 'type-asc': return (a.type||'').localeCompare(b.type||'');
        case 'type-desc': return (b.type||'').localeCompare(a.type||'');
        default: return 0;
      }
    });
    return list;
  }

  searchInput?.addEventListener('input', _refreshList);
  sortSelect?.addEventListener('change', _refreshList);
  filterSelect?.addEventListener('change', _refreshList);

  function _refreshList() {
    fetch(`${api}/files?path=${encodeURIComponent(currentPath)}`)
      .then((r) => r.json())
      .then((data) => {
        data.entries = _applyFiltersAndSort(data.entries || []);
        _renderFileList(data);
      });
  }

  // ── Upload ───────────────────────────────────────
  const dropZone = document.getElementById('drop-zone');
  const fileInput = document.getElementById('file-input');

  dropZone?.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropZone.classList.add('drag-over');
  });
  dropZone?.addEventListener('dragleave', () => {
    dropZone.classList.remove('drag-over');
  });
  dropZone?.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('drag-over');
    _handleFiles(e.dataTransfer.files);
  });
  fileInput?.addEventListener('change', () => {
    _handleFiles(fileInput.files);
    fileInput.value = '';
  });

  function _handleFiles(fileList) {
    if (!fileList || fileList.length === 0) return;
    const formData = new FormData();
    for (const f of fileList) {
      formData.append('file', f, f.name);
    }
    const transferId = 'web-' + Date.now();
    const xhr = new XMLHttpRequest();
    xhr.upload.addEventListener('progress', (ev) => {
      if (ev.lengthComputable) {
        const pct = ((ev.loaded / ev.total) * 100).toFixed(1);
        log('[upload]', `file=${(ev.target as any)._fileName || '?'} bytes=${ev.loaded}/${ev.total} progress=${pct}% status=active`);
      }
    });
    xhr.addEventListener('load', () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        log('[upload]', 'batch completed status=completed');
        _loadFiles();
      } else {
        log('[upload]', `batch failed status=${xhr.status} response=${xhr.responseText}`);
      }
    });
    xhr.addEventListener('error', () => {
      log('[upload]', 'batch failed reason=connection_lost');
    });
    xhr.open('POST', `${api}/upload?path=${encodeURIComponent(currentPath)}`);
    xhr.setRequestHeader('X-Session-Token', token);
    xhr.setRequestHeader('X-Transfer-Id', transferId);
    xhr._fileName = fileList[0]?.name ?? '';
    xhr.send(formData);
  }

  // ── Unauth ───────────────────────────────────────
  function _handleUnauth() {
    log('[auth]', 'session expired');
    token = null;
    loginEl.style.display = 'block';
    appEl.style.display = 'none';
    if (pollingTimer) clearInterval(pollingTimer);
  }

  // ── Helpers ──────────────────────────────────────
  function _fmtSize(bytes) {
    if (bytes === 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    return (bytes / Math.pow(1024, i)).toFixed(i > 0 ? 1 : 0) + ' ' + units[i];
  }

  // Expose for onclick handler in rows
  window._downloadFile = _downloadFile;
  window._navigateTo = function(p) {
    currentPath = p;
    _loadFiles();
  };

  function log(tag, message) {
    window.console.log(`[${tag}] ${message}`);
  }

  window._log = log;
  window.console.timeEnd('[init]');
  log('[init]', 'client loaded');
}

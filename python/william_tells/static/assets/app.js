// William Tells UI on the shared blastbox ingress. One blastbox job per image:
//   POST /v1/jobs (file, engine, params) -> poll GET /v1/jobs/{id} -> GET /v1/jobs/{id}/metadata
// Decoded payloads came out of a hostile image: they are rendered as TEXT only (textContent),
// never as HTML and never as live links.
'use strict';

const ENGINE = 'williamtells';
const TERMINAL = new Set(['done', 'failed', 'expired', 'cancelled']);
const $ = (id) => document.getElementById(id);
const dropZone = $('dropZone'), fileInput = $('fileInput'), fileList = $('fileList');
const scanBtn = $('scanBtn'), spinner = $('spinner'), statusEl = $('status'), resultsDiv = $('results');
let files = [];

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = String(text);
  return e;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

dropZone.addEventListener('click', () => fileInput.click());
dropZone.addEventListener('dragover', (e) => { e.preventDefault(); dropZone.classList.add('dragover'); });
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', (e) => {
  e.preventDefault(); dropZone.classList.remove('dragover'); addFiles(e.dataTransfer.files);
});
fileInput.addEventListener('change', () => { addFiles(fileInput.files); fileInput.value = ''; });

function addFiles(list) { for (const f of list) files.push(f); renderFileList(); }

function renderFileList() {
  fileList.replaceChildren(...files.map((f, i) => {
    const tag = el('div', 'file-tag', f.name);
    const x = el('span', 'remove', '×');
    x.addEventListener('click', () => { files.splice(i, 1); renderFileList(); });
    tag.append(' ', x);
    return tag;
  }));
  scanBtn.disabled = files.length === 0;
}

async function api(path, opts) {
  const r = await fetch(path, opts);
  if (!r.ok) {
    let detail = r.statusText;
    try { detail = (await r.json()).detail || detail; } catch (_) { /* not JSON */ }
    throw new Error(`${r.status} ${typeof detail === 'string' ? detail : JSON.stringify(detail)}`);
  }
  return r.json();
}

async function submit(file, mode) {
  const fd = new FormData();
  fd.append('file', file, file.name);
  fd.append('engine', ENGINE);
  fd.append('params', `WTQRK_MODE=${mode}`);   // the ingress takes repeated KEY=VALUE fields
  return (await api('/v1/jobs', { method: 'POST', body: fd })).job_id;
}

async function waitFor(jobId) {
  for (let delay = 250; ; delay = Math.min(delay * 1.5, 2000)) {
    const st = await api(`/v1/jobs/${encodeURIComponent(jobId)}`);
    if (TERMINAL.has(st.status)) return st;
    await sleep(delay);
  }
}

// Pull the scan record out of the dispatcher-validated metadata.json.
async function scanRecord(jobId) {
  const meta = await api(`/v1/jobs/${encodeURIComponent(jobId)}/metadata`);
  const fields = (meta.payload && meta.payload.fields) || {};
  const dets = Object.values((fields.detections && fields.detections.fields) || {})
    .map((d) => (d && d.fields) || {});
  return { meta, fields, dets };
}

function card(name, jobId) {
  const c = el('div', 'result-card');
  const h = el('div', 'result-header');
  h.append(el('span', 'result-filename', name), el('span', 'result-timing', 'queued'));
  c.append(h);
  if (jobId) {
    const link = el('div', 'result-link');
    const a = el('a', '', `job ${jobId}`);
    a.href = `/jobs/${encodeURIComponent(jobId)}`;
    link.append(a);
    c.append(link);
  }
  resultsDiv.append(c);
  return { c, timing: h.lastChild };
}

function fillCard(ui, st, rec) {
  const ms = st.finished_at && st.started_at ? Math.round((st.finished_at - st.started_at) * 1000) : null;
  const f = rec ? rec.fields : {};
  const muts = f.mutations_tried || 0;
  ui.timing.textContent = (ms !== null ? `${ms}ms` : st.status)
    + (rec ? (muts > 0 ? ` · ${muts} mutations` : ' · raw') : '');
  if (st.status !== 'done' || !rec || rec.meta.status !== 'ok') {
    const why = st.error || (rec && rec.meta.warnings && rec.meta.warnings.map((w) => w.message).join('; '))
      || (rec && rec.meta.status) || st.status;
    ui.c.append(el('div', 'result-error', `Not scanned: ${why}`));
    return false;
  }
  if (rec.dets.length === 0) {
    ui.c.append(el('div', 'result-payload none', 'No QR code detected'));
    return false;
  }
  for (const d of rec.dets) {
    ui.c.append(el('div', 'result-payload', d.payload));
    const sym = String(d.symbology || '').replace('VNBarcodeSymbology', '');
    const bb = [d.bbox_x, d.bbox_y, d.bbox_w, d.bbox_h].map((v) => Number(v).toFixed(3)).join(', ');
    ui.c.append(el('div', 'result-meta', `${sym} · bbox: [${bb}]`));
  }
  return true;
}

async function runOne(file, mode, counts) {
  let ui;
  try {
    const jobId = await submit(file, mode);
    ui = card(file.name, jobId);
    return await show(jobId, ui, counts);
  } catch (e) {
    ui = ui || card(file.name, null);
    ui.c.append(el('div', 'result-error', e.message));
  }
}

async function show(jobId, ui, counts) {
  const st = await waitFor(jobId);
  let rec = null;
  if (st.status === 'done') rec = await scanRecord(jobId);
  if (fillCard(ui, st, rec)) counts.hit++;
  counts.done++;
}

function summary(counts, elapsed) {
  const bar = el('div', 'summary-bar');
  for (const [k, v] of [['Scanned', counts.done], ['Detected', counts.hit], ['Total', `${elapsed}ms`]]) {
    const d = el('div', '', `${k}: `);
    d.append(el('span', 'val', v));
    bar.append(d);
  }
  resultsDiv.prepend(bar);
}

function busy(on, text) {
  spinner.classList.toggle('active', on);
  scanBtn.disabled = on || files.length === 0;
  statusEl.textContent = text || '';
}

scanBtn.addEventListener('click', async () => {
  if (files.length === 0) return;
  const mode = document.querySelector('input[name="mode"]:checked').value;
  resultsDiv.replaceChildren();
  busy(true, `Scanning ${files.length} image(s)...`);
  const t0 = performance.now(), counts = { done: 0, hit: 0 };
  await Promise.all(files.map((f) => runOne(f, mode, counts)));
  const elapsed = Math.round(performance.now() - t0);
  summary(counts, elapsed);
  busy(false, `Done in ${elapsed}ms`);
});

// Deep link: /jobs/<id> shows that job's result.
const deep = location.pathname.match(/^\/jobs\/([A-Za-z0-9-]{1,64})$/);
if (deep) {
  const ui = card('job', deep[1]);
  api(`/v1/jobs/${deep[1]}`).then((st) => {
    ui.c.querySelector('.result-filename').textContent = st.filename || 'job';
    return show(deep[1], ui, { done: 0, hit: 0 });
  }).catch((e) => ui.c.append(el('div', 'result-error', e.message)));
}

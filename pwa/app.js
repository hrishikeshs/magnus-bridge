/* Magnus Bridge — phone client.
   Talks to the elisp server over REST + Server-Sent Events. */

'use strict';

const $ = (id) => document.getElementById(id);

const HEALTH_GLYPHS = { ok: '●', stale: '◐', stuck: '·', dead: '✕' };
const HEALTH_LABELS = { stuck: 'idle', stale: 'quiet' };

const state = {
  agents: [],            // roster from /api/status
  events: [],            // chronological event list
  attentions: new Map(), // agent id -> latest unresolved attention event
  selected: 'all',
  lastEventId: 0,
  lastSeen: JSON.parse(localStorage.getItem('lastSeen') || '{}'),
  source: null,          // EventSource
  typing: new Map(),     // agent id -> expiry ms; fed by transient events
};

setInterval(() => {                 // expire stale typing bubbles
  const now = Date.now();
  let changed = false;
  for (const [id, until] of state.typing) {
    if (until < now) { state.typing.delete(id); changed = true; }
  }
  if (changed) renderFeed();
}, 2000);

/* ---------- bootstrap ---------- */

async function init() {
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }
  const res = await fetch('/api/status').catch(() => null);
  if (!res) return showOffline();          // unreachable: show cached feed
  if (res.status === 401) return showPairing();
  const data = await res.json();
  state.agents = data.agents || [];
  showApp();
  await loadHistory();
  connectEvents();
  setInterval(refreshStatus, 30000);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) { refreshStatus(); connectEvents(); }
  });
}

/* Server unreachable (laptop asleep, Emacs restarting): show the last
   cached conversation read-only, and retry until the bridge is back. */
function showOffline() {
  const cached = JSON.parse(localStorage.getItem('eventCache') || 'null');
  if (cached) {
    state.agents = cached.agents || [];
    cached.events.forEach(ingest);
  }
  showApp();
  setConnected(false);
  setTimeout(init, 5000);
}

function cacheEvents() {
  try {
    localStorage.setItem('eventCache', JSON.stringify({
      agents: state.agents,
      events: state.events.slice(-100),
    }));
  } catch (e) { /* storage full — cache is best-effort */ }
}

function showPairing() {
  $('pair-screen').classList.remove('hidden');
  $('app').classList.add('hidden');
}

function showApp() {
  $('pair-screen').classList.add('hidden');
  $('app').classList.remove('hidden');
  renderTabs();
  renderFeed();
}

/* ---------- pairing ---------- */

$('pair-btn').addEventListener('click', async () => {
  const code = $('pair-code').value.trim();
  const res = await fetch('/api/pair', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code, device: navigator.userAgent.slice(0, 120) }),
  }).catch(() => null);
  if (res && res.ok) {
    $('pair-error').classList.add('hidden');
    init();
  } else {
    $('pair-error').classList.remove('hidden');
  }
});

/* ---------- data ---------- */

async function refreshStatus() {
  const res = await fetch('/api/status').catch(() => null);
  if (!res || !res.ok) return setConnected(false);
  const data = await res.json();
  state.agents = data.agents || [];
  renderTabs();
}

async function loadHistory() {
  const res = await fetch('/api/history?since=0').catch(() => null);
  if (!res || !res.ok) return;
  const data = await res.json();
  (data.events || []).forEach(ingest);
  cacheEvents();
  renderFeed();
}

function connectEvents() {
  if (state.source && state.source.readyState !== EventSource.CLOSED) return;
  const source = new EventSource('/api/events?since=' + state.lastEventId);
  state.source = source;
  source.onopen = () => setConnected(true);
  source.onerror = () => setConnected(false); // EventSource auto-reconnects
  source.onmessage = (msg) => {
    const event = JSON.parse(msg.data);
    if (event.type === 'typing') {          // transient: never stored
      state.typing.set(event.agent, Date.now() + 6000);
      renderFeed();
      return;
    }
    ingest(event);
    cacheEvents();
    renderFeed();
    renderTabs();
    maybeNotify(event);
  };
}

function ingest(event) {
  if (event.id <= state.lastEventId) return;
  state.lastEventId = event.id;
  state.events.push(event);
  if (event.type === 'attention') {
    state.attentions.set(event.agent, event);
  } else if (event.type === 'attention-clear' || event.type === 'approved') {
    state.attentions.delete(event.agent);
  }
  if (event.type === 'reply' || event.type === 'mention') {
    state.typing.delete(event.agent);   // the reply arrived; stop the dots
  }
}

function setConnected(on) {
  $('conn-dot').classList.toggle('on', !!on);
}

function markSeen(agentId) {
  state.lastSeen[agentId] = state.lastEventId;
  localStorage.setItem('lastSeen', JSON.stringify(state.lastSeen));
}

function hasUnread(agentId) {
  const seen = state.lastSeen[agentId] || 0;
  return state.events.some((e) =>
    e.agent === agentId && e.id > seen && e.type !== 'sent');
}

/* ---------- tabs ---------- */

function renderTabs() {
  const tabs = $('agent-tabs');
  tabs.innerHTML = '';
  tabs.appendChild(makeTab('all', 'All', null));
  for (const agent of state.agents) {
    tabs.appendChild(makeTab(agent.id, agent.name, agent.health));
  }
}

function makeTab(id, label, health) {
  const el = document.createElement('button');
  el.className = 'tab' + (state.selected === id ? ' active' : '');
  el.textContent = label;
  if (health) {
    const dot = document.createElement('span');
    dot.className = 'h ' + health;
    dot.textContent = HEALTH_GLYPHS[health] || '·';
    dot.title = HEALTH_LABELS[health] || health;
    el.prepend(dot);
  }
  if (state.attentions.has(id)) {
    el.appendChild(chip('bang', '!'));
  } else if (id !== 'all' && hasUnread(id)) {
    el.appendChild(chip('unread', ''));
  }
  el.onclick = () => {
    state.selected = id;
    if (id !== 'all') markSeen(id);
    renderTabs();
    renderFeed();
    restoreDraft();
  };
  return el;
}

function chip(cls, text) {
  const el = document.createElement('span');
  el.className = cls;
  el.textContent = text;
  return el;
}

/* ---------- feed ---------- */

function visibleEvents() {
  if (state.selected === 'all') return state.events;
  return state.events.filter((e) => e.agent === state.selected);
}

function renderFeed() {
  const feed = $('feed');
  const stick = feed.scrollHeight - feed.scrollTop - feed.clientHeight < 60;
  feed.innerHTML = '';
  let lastDay = '';
  for (const event of visibleEvents()) {
    const day = (event.ts || '').slice(0, 10);
    if (day && day !== lastDay) {
      lastDay = day;
      const sep = document.createElement('div');
      sep.className = 'day-sep';
      sep.textContent = day;
      feed.appendChild(sep);
    }
    feed.appendChild(renderEvent(event));
  }
  const now = Date.now();
  for (const [id, until] of state.typing) {
    if (until < now) continue;
    if (state.selected !== 'all' && state.selected !== id) continue;
    feed.appendChild(typingBubble(agentName(id) || 'agent'));
  }
  if (stick) feed.scrollTop = feed.scrollHeight;
  if (state.selected !== 'all') markSeen(state.selected);
  $('msg-input').placeholder = state.selected === 'all'
    ? 'Pick an agent to message…'
    : 'Message ' + (agentName(state.selected) || 'agent') + '…';
  const noAgent = state.selected === 'all';
  $('send-btn').disabled = noAgent;
  $('attach-btn').disabled = noAgent;
}

function agentName(id) {
  const agent = state.agents.find((a) => a.id === id);
  return agent && agent.name;
}

function renderEvent(event) {
  const el = document.createElement('div');
  if (event.type === 'sent') {
    el.className = 'msg sent';
    el.appendChild(who('you → ' + (event.name || '?'), event.ts));
    el.appendChild(richText(event.text));
  } else if (event.type === 'reply') {
    el.className = 'msg reply';
    el.appendChild(who(event.name || '?', event.ts));
    el.appendChild(richText(event.text));
  } else if (event.type === 'mention') {
    el.className = 'msg mention';
    el.appendChild(who((event.name || 'crew') + ' · @mention', event.ts));
    el.appendChild(richText(event.text));
  } else if (event.type === 'attention') {
    el.className = 'attention' +
      (state.attentions.get(event.agent) === event ? '' : ' resolved');
    el.appendChild(who((event.name || '?') + ' needs your attention', event.ts));
    el.appendChild(promptExcerpt(event.text));
    el.appendChild(approveKeys(event));
  } else if (event.type === 'auto-approved') {
    el.className = 'msg system';
    el.textContent = '⚡ auto-approved for ' + (event.name || '?');
  } else if (event.type === 'pattern-learned') {
    el.className = 'msg system';
    el.textContent = '✓ always allow: ' + event.text;
  } else if (event.type === 'pattern-removed') {
    el.className = 'msg system';
    el.textContent = '✕ revoked: ' + event.text;
  } else {
    el.className = 'msg system';
    el.textContent = (event.name || '') + ' · ' + event.type +
      (event.text ? ' · ' + event.text : '');
  }
  return el;
}

function typingBubble(name) {
  const el = document.createElement('div');
  el.className = 'msg typing';
  const label = document.createElement('span');
  label.className = 'who';
  label.textContent = name + ' is working';
  el.appendChild(label);
  const dots = document.createElement('span');
  dots.className = 'dots';
  for (let i = 0; i < 3; i++) dots.appendChild(document.createElement('i'));
  el.appendChild(dots);
  return el;
}

function who(label, ts) {
  const el = document.createElement('span');
  el.className = 'who';
  el.textContent = label + (ts ? '  ' + localTime(ts) : '');
  return el;
}

function localTime(ts) {
  const d = new Date(ts);
  return isNaN(d) ? '' :
    d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

/* Render text with [thinking] blocks collapsed into tappable pills and
   very long remainders clamped behind "show more". */
function richText(text) {
  const container = document.createElement('div');
  container.className = 'rich';
  const re = /\[thinking\]([\s\S]*?)(?:\[end-thinking\]|\[\/thinking\]|(?=\[response\])|$)/g;
  let cursor = 0;
  let match;
  while ((match = re.exec(text)) !== null) {
    appendPlain(container, text.slice(cursor, match.index));
    appendThinking(container, match[1].trim());
    cursor = re.lastIndex;
  }
  appendPlain(container, text.slice(cursor).replace(/\[response\]/g, '').trim());
  return container;
}

function appendPlain(container, chunk) {
  chunk = chunk.trim();
  if (!chunk) return;
  const el = document.createElement('span');
  el.className = 'plain';
  if (chunk.length > 1200) {
    el.textContent = chunk.slice(0, 1000) + '…';
    const more = document.createElement('button');
    more.className = 'show-more';
    more.textContent = 'show more';
    more.onclick = () => { el.textContent = chunk; more.remove(); };
    container.appendChild(el);
    container.appendChild(more);
  } else {
    el.textContent = chunk;
    container.appendChild(el);
  }
}

function appendThinking(container, thought) {
  if (!thought) return;
  const words = thought.split(/\s+/).length;
  const pill = document.createElement('button');
  pill.className = 'think-pill';
  pill.textContent = '💭 thinking · ' + words + ' words';
  const body = document.createElement('div');
  body.className = 'think-body hidden';
  body.textContent = thought;
  pill.onclick = () => {
    const open = body.classList.toggle('hidden');
    pill.textContent = open ? '💭 thinking · ' + words + ' words' : '💭 hide thinking';
  };
  container.appendChild(pill);
  container.appendChild(body);
}

/* ---------- attention cards ---------- */

function promptExcerpt(text) {
  const pre = document.createElement('pre');
  const lines = (text || '').split('\n');
  if (lines.length > 4) {
    pre.textContent = lines.slice(-4).join('\n');
    const more = document.createElement('button');
    more.className = 'show-more';
    more.textContent = 'show full prompt';
    more.onclick = () => { pre.textContent = text; more.remove(); };
    const wrap = document.createElement('div');
    wrap.appendChild(more);
    wrap.appendChild(pre);
    return wrap;
  }
  pre.textContent = text || '(no prompt text captured)';
  return pre;
}

/* Parse numbered options like "❯ 1. Yes" out of the prompt so buttons
   carry labels instead of bare digits. */
function promptOptions(text) {
  const options = [];
  for (const line of (text || '').split('\n')) {
    const m = line.match(/^\s*(?:❯\s*)?([123])\.\s*(.+?)\s*$/);
    if (m) options.push({ key: m[1], label: m[2].slice(0, 28) });
  }
  return options.length ? options : [
    { key: '1', label: 'Yes' }, { key: '3', label: 'No' }];
}

function approveKeys(event) {
  const keys = document.createElement('div');
  keys.className = 'keys';
  for (const opt of promptOptions(event.text)) {
    const btn = document.createElement('button');
    btn.textContent = opt.label;
    btn.onclick = () => approve(event.agent, opt.key);
    keys.appendChild(btn);
  }
  const esc = document.createElement('button');
  esc.textContent = '⎋';
  esc.className = 'esc';
  esc.onclick = () => approve(event.agent, 'esc');
  keys.appendChild(esc);

  const always = document.createElement('button');
  always.textContent = '✓ Always allow this';
  always.className = 'always';
  always.onclick = () => openAlwaysAllow(event);
  const wrap = document.createElement('div');
  wrap.appendChild(keys);
  wrap.appendChild(always);
  return wrap;
}

/* "Always allow" — taught at the moment of decision. The extracted
   pattern is shown editable before anything is learned. */
function extractPattern(text) {
  for (const line of (text || '').split('\n')) {
    const m = line.trim().match(/^[A-Z][A-Za-z]*\(.+\)$/);
    if (m) return m[0];
  }
  const first = (text || '').split('\n').map((l) => l.trim()).find(Boolean);
  return first || '';
}

function openAlwaysAllow(event) {
  const guess = extractPattern(event.text);
  $('allow-pattern').value = guess;
  $('allow-pattern').placeholder = guess
    ? '' : 'type the prompt text to match (min 6 chars)';
  $('allow-modal').classList.remove('hidden');
  $('allow-confirm').onclick = async () => {
    const pattern = $('allow-pattern').value.trim();
    if (!pattern) return;
    const res = await api('/api/patterns', { action: 'add', pattern });
    if (res && res.ok) {
      $('allow-modal').classList.add('hidden');
      approve(event.agent, '1');
    } else {
      $('allow-hint').textContent =
        'Rejected — patterns need at least 6 characters.';
    }
  };
}

$('allow-cancel').addEventListener('click',
  () => $('allow-modal').classList.add('hidden'));

/* ---------- patterns sheet ---------- */

$('settings-btn').addEventListener('click', async () => {
  const res = await fetch('/api/patterns').catch(() => null);
  if (!res || !res.ok) return;
  const data = await res.json();
  const list = $('patterns-list');
  list.innerHTML = '';
  for (const pattern of data.learned || []) {
    const row = document.createElement('div');
    row.className = 'pattern-row';
    const label = document.createElement('code');
    label.textContent = pattern;
    const del = document.createElement('button');
    del.textContent = 'revoke';
    del.onclick = async () => {
      await api('/api/patterns', { action: 'remove', pattern });
      row.remove();
    };
    row.appendChild(label);
    row.appendChild(del);
    list.appendChild(row);
  }
  if (!(data.learned || []).length) {
    list.textContent = 'No patterns taught from the phone yet. ' +
      'Use “Always allow this” on an attention card.';
  }
  $('patterns-note').textContent = (data.builtin || []).length +
    ' more configured in Emacs (managed there).';
  $('patterns-modal').classList.remove('hidden');
});

$('patterns-close').addEventListener('click',
  () => $('patterns-modal').classList.add('hidden'));

/* ---------- composer ---------- */

const input = $('msg-input');

function autogrow() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 120) + 'px';
}

function draftKey() { return 'draft-' + state.selected; }

function restoreDraft() {
  input.value = localStorage.getItem(draftKey()) || '';
  autogrow();
}

input.addEventListener('input', () => {
  localStorage.setItem(draftKey(), input.value);
  autogrow();
});

/* iOS shows a Prev/Next/Done accessory bar above the keyboard whenever
   the page has more than one focusable element. While the composer is
   focused, take every other control out of the tab order (taps still
   work) so Safari sees a single input and drops the bar — the
   iMessage-clean keyboard. Restored on blur for desktop keyboard users. */
function setComposerFocusMode(on) {
  document.querySelectorAll('button, [href], input, [tabindex]').forEach((el) => {
    if (el === input) return;
    if (on) {
      if (!el.dataset.tabSaved) el.dataset.tabSaved = el.tabIndex;
      el.tabIndex = -1;
    } else if (el.dataset.tabSaved !== undefined) {
      el.tabIndex = Number(el.dataset.tabSaved);
      delete el.dataset.tabSaved;
    }
  });
}
input.addEventListener('focus', () => setComposerFocusMode(true));
input.addEventListener('blur', () => setComposerFocusMode(false));

const coarsePointer = matchMedia('(pointer: coarse)').matches;
input.addEventListener('keydown', (e) => {
  // Desktop: Enter sends, Shift+Enter breaks. Touch: Enter always breaks
  // (fat-thumb protection) — the send button is the only trigger.
  if (e.key === 'Enter' && !e.shiftKey && !coarsePointer) {
    e.preventDefault();
    sendMessage();
  }
});

/* ---------- attachments ---------- */

let pendingImage = null; // base64 payload (no data: prefix)

$('attach-btn').addEventListener('click', () => $('attach-input').click());

$('attach-input').addEventListener('change', async (e) => {
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!file) return;
  const dataUrl = await downscale(file).catch(() => null);
  if (!dataUrl) return;
  pendingImage = dataUrl.split(',')[1];
  $('attach-thumb').src = dataUrl;
  $('attach-preview').classList.remove('hidden');
});

$('attach-remove').addEventListener('click', clearAttachment);

function clearAttachment() {
  pendingImage = null;
  $('attach-thumb').src = '';
  $('attach-preview').classList.add('hidden');
}

/* Re-encode client-side: caps dimensions at 2048px and always produces
   JPEG — smaller uploads and HEIC handled for free by the canvas. */
function downscale(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      const scale = Math.min(1, 2048 / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      resolve(canvas.toDataURL('image/jpeg', 0.85));
    };
    img.onerror = reject;
    img.src = url;
  });
}

async function sendMessage() {
  const body = input.value.trim();
  const image = pendingImage;
  if ((!body && !image) || state.selected === 'all') return;
  input.value = '';
  localStorage.removeItem(draftKey());
  clearAttachment();
  autogrow();
  requestNotifyPermission();
  const res = image
    ? await api('/api/upload', { agent: state.selected, text: body, image })
    : await api('/api/send', { agent: state.selected, text: body });
  if (!res || !res.ok) {
    input.value = body;   // give the message back rather than losing it
    localStorage.setItem(draftKey(), body);
    autogrow();
    setConnected(false);
  }
}

$('send-btn').addEventListener('click', sendMessage);

/* ---------- actions ---------- */

async function api(path, payload) {
  return fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).catch(() => null);
}

async function approve(agent, key) {
  await api('/api/approve', { agent, key });
}

/* ---------- notifications (best-effort; no-op where unsupported) ---------- */

function requestNotifyPermission() {
  if ('Notification' in window && Notification.permission === 'default') {
    Notification.requestPermission().catch(() => {});
  }
}

function maybeNotify(event) {
  if (!('Notification' in window)) return;
  if (Notification.permission !== 'granted' || !document.hidden) return;
  if (event.type === 'attention') {
    new Notification(event.name + ' needs your attention', {
      body: (event.text || '').slice(-120),
    });
  } else if (event.type === 'mention' || event.type === 'reply') {
    new Notification(event.name || 'crew', {
      body: (event.text || '').slice(0, 160),
    });
  }
}

init();

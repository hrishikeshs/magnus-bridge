/* Magnus Bridge — phone client.
   Talks to the elisp server over REST + Server-Sent Events. */

'use strict';

const $ = (id) => document.getElementById(id);

const state = {
  agents: [],          // roster from /api/status
  events: [],          // chronological event list
  attentions: new Map(), // agent id -> latest unresolved attention event
  selected: 'all',
  lastEventId: 0,
  source: null,        // EventSource
};

/* ---------- bootstrap ---------- */

async function init() {
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }
  const res = await fetch('/api/status').catch(() => null);
  if (!res) return showPairing();          // offline or unreachable
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
    ingest(event);
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
}

function setConnected(on) {
  $('conn-dot').classList.toggle('on', !!on);
}

/* ---------- rendering ---------- */

function renderTabs() {
  const tabs = $('agent-tabs');
  tabs.innerHTML = '';
  tabs.appendChild(makeTab('all', 'All', null, null));
  for (const agent of state.agents) {
    tabs.appendChild(makeTab(agent.id, agent.name, agent.health,
                             state.attentions.has(agent.id)));
  }
}

function makeTab(id, label, health, needsAttention) {
  const el = document.createElement('button');
  el.className = 'tab' + (state.selected === id ? ' active' : '');
  el.textContent = label;
  if (health) {
    const dot = document.createElement('span');
    dot.className = 'h ' + health;
    dot.textContent = { ok: '●', stale: '◐', stuck: '○', dead: '✕' }[health] || '·';
    el.prepend(dot);
  }
  if (needsAttention) {
    const bang = document.createElement('span');
    bang.className = 'bang';
    bang.textContent = '!';
    el.appendChild(bang);
  }
  el.onclick = () => { state.selected = id; renderTabs(); renderFeed(); };
  return el;
}

function visibleEvents() {
  if (state.selected === 'all') return state.events;
  return state.events.filter((e) => e.agent === state.selected);
}

function renderFeed() {
  const feed = $('feed');
  const stick = feed.scrollHeight - feed.scrollTop - feed.clientHeight < 60;
  feed.innerHTML = '';
  for (const event of visibleEvents()) {
    feed.appendChild(renderEvent(event));
  }
  if (stick) feed.scrollTop = feed.scrollHeight;
  $('msg-input').placeholder = state.selected === 'all'
    ? 'Pick an agent to message…'
    : 'Message ' + (agentName(state.selected) || 'agent') + '…';
  $('send-btn').disabled = state.selected === 'all';
}

function agentName(id) {
  const agent = state.agents.find((a) => a.id === id);
  return agent && agent.name;
}

function renderEvent(event) {
  const el = document.createElement('div');
  if (event.type === 'sent') {
    el.className = 'msg sent';
    el.appendChild(who('you → ' + (event.name || '?')));
    el.appendChild(text(event.text));
  } else if (event.type === 'mention') {
    el.className = 'msg mention';
    el.appendChild(who(event.name || 'crew'));
    el.appendChild(text(event.text));
  } else if (event.type === 'attention') {
    const active = state.attentions.get(event.agent) === event;
    el.className = 'attention' + (active ? '' : ' resolved');
    el.appendChild(who((event.name || '?') + ' needs your attention'));
    const pre = document.createElement('pre');
    pre.textContent = event.text || '(no prompt text captured)';
    el.appendChild(pre);
    const keys = document.createElement('div');
    keys.className = 'keys';
    for (const key of ['1', '2', '3', 'esc']) {
      const btn = document.createElement('button');
      btn.textContent = key === 'esc' ? '⎋' : key;
      btn.onclick = () => approve(event.agent, key);
      keys.appendChild(btn);
    }
    el.appendChild(keys);
  } else {
    el.className = 'msg system';
    el.textContent = (event.name || '') + ' · ' + event.type +
      (event.text ? ' · ' + event.text : '');
  }
  return el;
}

function who(label) {
  const el = document.createElement('span');
  el.className = 'who';
  el.textContent = label;
  return el;
}

function text(content) {
  const el = document.createElement('span');
  el.textContent = content;
  return el;
}

/* ---------- actions ---------- */

async function sendMessage() {
  const input = $('msg-input');
  const body = input.value.trim();
  if (!body || state.selected === 'all') return;
  input.value = '';
  requestNotifyPermission();
  const res = await fetch('/api/send', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ agent: state.selected, text: body }),
  }).catch(() => null);
  if (!res || !res.ok) {
    input.value = body;   // give the message back rather than losing it
    setConnected(false);
  }
}

async function approve(agent, key) {
  await fetch('/api/approve', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ agent, key }),
  }).catch(() => null);
}

$('send-btn').addEventListener('click', sendMessage);
$('msg-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') sendMessage();
});

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
  } else if (event.type === 'mention') {
    new Notification(event.name || 'crew', { body: event.text });
  }
}

init();

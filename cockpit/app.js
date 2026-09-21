/* ============================================================
   SecondBrain Cockpit — app.js (vanilla, sem framework)
   Consome /api/tasks e /api/task/{sbid}. Render por categoria.
   ============================================================ */

const CATEGORIES = [
  { key: "fazer",             label: "Fazer hoje",        cls: "cat-fazer" },
  { key: "responder",         label: "Responder",         cls: "cat-responder" },
  { key: "cobrar",            label: "Cobrar",            cls: "cat-cobrar" },
  { key: "aguardando",        label: "Aguardando",        cls: "cat-aguardando" },
  { key: "preparar",          label: "Preparar reunião",  cls: "cat-preparar" },
  { key: "risco",             label: "Riscos",            cls: "cat-risco" },
  { key: "whatsapp-pessoal",  label: "WhatsApp pessoal",  cls: "cat-responder" },
  { key: "whatsapp-trabalho", label: "WhatsApp trabalho", cls: "cat-fazer" },
  { key: "referencia",        label: "Referência",        cls: "cat-referencia" },
];

const PREFIX = {
  fazer: "Fazer", responder: "Responder", cobrar: "Cobrar",
  aguardando: "Aguardando", preparar: "Preparar", risco: "Risco", referencia: "Ref",
};

let STATE = { tasks: [], search: "", showRef: false, showDone: false };

// ---------- helpers ----------
const $ = (s, r = document) => r.querySelector(s);
const el = (tag, cls, txt) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (txt != null) n.textContent = txt;
  return n;
};
const todayStr = () => new Date().toISOString().slice(0, 10);

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), 2200);
}

function dueInfo(task) {
  const d = task.dueDate;
  if (!d) return { label: "", cls: "" };
  const today = todayStr();
  let cls = "", label = d;
  if (d < today) { cls = "late"; label = "atrasado · " + d; }
  else if (d === today) { cls = "today"; label = "hoje"; }
  else {
    const diff = Math.round((new Date(d) - new Date(today)) / 86400000);
    label = diff === 1 ? "amanhã" : d;
  }
  return { label, cls };
}

// ---------- clock ----------
function tickClock() {
  const now = new Date();
  $("#clock-time").textContent = now.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
  $("#clock-date").textContent = now.toLocaleDateString("pt-BR", { weekday: "short", day: "2-digit", month: "short" });
}

// ---------- data ----------
async function load() {
  const btn = $("#refresh");
  btn.classList.add("spin");
  try {
    const res = await fetch("/api/tasks", { cache: "no-store" });
    const data = await res.json();
    STATE.tasks = Array.isArray(data) ? data : (data.tasks || []);
    render();
  } catch (e) {
    toast("Falha ao carregar tarefas");
    console.error(e);
  } finally {
    setTimeout(() => btn.classList.remove("spin"), 400);
  }
}

async function patch(sbid, body) {
  try {
    const res = await fetch("/api/task/" + encodeURIComponent(sbid), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const updated = await res.json();
    const i = STATE.tasks.findIndex(t => t.sbid === sbid);
    if (i >= 0 && updated && updated.sbid) STATE.tasks[i] = updated;
    render();
  } catch (e) {
    toast("Não consegui salvar");
    console.error(e);
  }
}

// ---------- filtering ----------
function visible(task) {
  if (task.done && !STATE.showDone) return false;
  if (!STATE.showDone && task.snoozedUntil && task.snoozedUntil > todayStr()) return false;
  const offBoard = task.board && task.board !== "active";
  const isLow = offBoard || task.categoria === "referencia" || task.prioridade === "baixa";
  if (isLow && !STATE.showRef) return false;
  if (STATE.search) {
    const q = STATE.search.toLowerCase();
    const hay = [task.pessoa, task.assunto, task.resumo, task.proxima_acao]
      .filter(Boolean).join(" ").toLowerCase();
    if (!hay.includes(q)) return false;
  }
  return true;
}

// ---------- stats ----------
function updateStats() {
  const t = todayStr();
  const open = STATE.tasks.filter(x => !x.done);
  $("#stat-hoje").textContent = open.filter(x => x.dueDate === t).length;
  $("#stat-atrasadas").textContent = open.filter(x => x.dueDate && x.dueDate < t).length;
  $("#stat-aguardando").textContent = open.filter(x => x.categoria === "aguardando").length;
  $("#stat-total").textContent = open.length;
}

// ---------- render ----------
// Buckets: o status vira ETIQUETA, nao filtro. Nada seu e aberto fica escondido.
//  - "agora"       = tudo que pede acao (nao aguardando, nao referencia/baixa)
//  - "aguardando"  = bola com os outros (visivel, mas abaixo)
//  - "referencia"  = sem acao / baixa (so aparece com o filtro "mostrar referencia")
const byPrio = (a, b) => {
  const pr = { alta: 0, media: 1, baixa: 2 };
  const dp = (pr[a.prioridade] ?? 1) - (pr[b.prioridade] ?? 1);
  if (dp) return dp;
  return (a.dueDate || "9999").localeCompare(b.dueDate || "9999");
};
const isRef = t => (t.categoria === "referencia") || (t.board && t.board !== "active");
const isWaiting = t => (t.status === "aguardando") || (t.categoria === "aguardando");

function feedSection(title, list, cls, feed) {
  const col = el("section", "column " + cls + (feed ? " feed" : " section-collapsible"));
  const head = el("div", "col-head");
  head.appendChild(el("span", "dot"));
  head.appendChild(el("span", null, title));
  head.appendChild(el("span", "count", String(list.length)));
  if (!feed) {
    head.classList.add("clickable");
    head.addEventListener("click", () => col.classList.toggle("collapsed"));
  }
  col.appendChild(head);
  const bodyEl = el("div", "col-body");
  for (const t of list) bodyEl.appendChild(renderCard(t));
  col.appendChild(bodyEl);
  return col;
}

function render() {
  updateStats();
  const board = $("#board");
  board.innerHTML = "";

  const shown = STATE.tasks.filter(visible);
  if (shown.length === 0) {
    const empty = el("div", "empty");
    empty.innerHTML = '<div class="empty-glyph">◇</div><p>Nada aqui com os filtros atuais.</p>' +
      '<small>Rode <code>secondbrain-run.ps1 -OpenCockpit</code> ou ajuste os filtros.</small>';
    board.appendChild(empty);
    return;
  }

  const agora = shown.filter(t => !isRef(t) && !isWaiting(t)).sort(byPrio);
  const aguardando = shown.filter(t => !isRef(t) && isWaiting(t)).sort(byPrio);
  const referencia = shown.filter(isRef).sort(byPrio);

  if (agora.length)      board.appendChild(feedSection("O que importa agora", agora, "feed", true));
  if (aguardando.length) board.appendChild(feedSection("Aguardando os outros", aguardando, "cat-aguardando", false));
  if (referencia.length) board.appendChild(feedSection("Referência / baixa", referencia, "cat-referencia", false));
}

function renderCard(task) {
  const card = el("div", "card prio-" + (task.prioridade || "media"));
  if (task.done) card.classList.add("done");

  const top = el("div", "card-top");
  top.appendChild(el("span", "badge st-" + (task.status || "x"), PREFIX[task.status] || task.status || "•"));
  if (task.prioridade) top.appendChild(el("span", "badge " + task.prioridade, task.prioridade));
  if (task.pessoa) top.appendChild(el("span", "card-person", task.pessoa));
  card.appendChild(top);

  card.appendChild(el("div", "card-title", task.assunto || task.titulo || "(sem assunto)"));
  if (task.proxima_acao) card.appendChild(el("div", "card-action", "→ " + task.proxima_acao));

  const meta = el("div", "card-meta");
  const di = dueInfo(task);
  if (di.label) meta.appendChild(el("span", "due " + di.cls, di.label));
  const srcs = el("div", "sources");
  for (const s of (task.fontes || [])) srcs.appendChild(el("span", "src", s));
  meta.appendChild(srcs);
  card.appendChild(meta);

  // expandable detail
  const detail = el("div", "card-detail");
  if (task.resumo) detail.appendChild(el("div", null, task.resumo));
  if (task.risco) { const r = el("div", "risk", "⚠ " + task.risco); detail.appendChild(r); }
  if (task.reuniao_em) detail.appendChild(el("div", null, "📅 " + task.reuniao_em));

  const notes = el("textarea");
  notes.placeholder = "notas…";
  notes.value = task.notas || "";
  notes.addEventListener("click", e => e.stopPropagation());
  notes.addEventListener("change", () => patch(task.sbid, { notas: notes.value }));
  detail.appendChild(notes);

  const actions = el("div", "card-actions");
  const bDone = el("button", "btn-done", task.done ? "↺ Reabrir" : "✓ Feito");
  bDone.addEventListener("click", e => { e.stopPropagation(); patch(task.sbid, { done: !task.done }); });
  const bSnooze = el("button", "btn-snooze", "⏱ Adiar");
  bSnooze.addEventListener("click", e => {
    e.stopPropagation();
    const d = new Date(); d.setDate(d.getDate() + 1);
    patch(task.sbid, { snoozedUntil: d.toISOString().slice(0, 10) });
  });
  const bPrio = el("button", "btn-prio", "↑↓ Prio");
  bPrio.addEventListener("click", e => {
    e.stopPropagation();
    const order = ["baixa", "media", "alta"];
    const next = order[(order.indexOf(task.prioridade) + 1) % 3];
    patch(task.sbid, { prioridade: next });
  });
  actions.appendChild(bDone); actions.appendChild(bSnooze); actions.appendChild(bPrio);
  detail.appendChild(actions);
  card.appendChild(detail);

  card.addEventListener("click", () => card.classList.toggle("open"));
  return card;
}

// ---------- wire up ----------
$("#search").addEventListener("input", e => { STATE.search = e.target.value.trim(); render(); });
$("#show-ref").addEventListener("change", e => { STATE.showRef = e.target.checked; render(); });
$("#show-done").addEventListener("change", e => { STATE.showDone = e.target.checked; render(); });
$("#refresh").addEventListener("click", load);

tickClock();
setInterval(tickClock, 10000);
load();
setInterval(load, 60000); // auto-refresh 1 min

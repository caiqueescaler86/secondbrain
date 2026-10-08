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

let STATE = { tasks: [], search: "", showDone: false, open: new Set(), seen: new Set(), filter: null, sig: "", sort: (localStorage.getItem("sb-sort") === "data" ? "data" : "prio") };

const STATUS_KEYS = ["fazer", "responder", "cobrar", "aguardando", "preparar", "risco", "referencia"];
const PRIO_KEYS = ["alta", "media", "baixa"];

// ---------- helpers ----------
const $ = (s, r = document) => r.querySelector(s);
const el = (tag, cls, txt) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (txt != null) n.textContent = txt;
  return n;
};
// Data de HOJE no fuso LOCAL (mesma base do backend, que grava createdAt/dueDate
// com hora local). NAO usar toISOString(): ele converte pra UTC e, no Brasil
// (UTC-3), "vira" o dia seguinte a partir das 21h -> "hoje" ficaria errado.
const todayStr = () => {
  const d = new Date(), p = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
};

// Card criado HOJE (base local). Estavel: nao depende de "ja visto".
const isCreatedToday = t => (t.createdAt || "").slice(0, 10) === todayStr();

// "Novo pendente" = criado hoje, ainda aberto E que voce ainda NAO mexeu.
// (userTouched vem do backend quando voce edita/anota/conclui/adia -> ja foi tratado.)
const isNovoPendente = t => isCreatedToday(t) && !t.done && !t.userTouched;

// Card criado HOJE e ainda nao reconhecido pelo usuario (abrir o card "quita" o aviso).
const isNew = t => !t.done && isCreatedToday(t) && !t.userTouched && !STATE.seen.has(t.sbid);

// normaliza texto p/ comparacao: minusculo, sem acento, espacos colapsados
const normalize = s => (s || "").toString().toLowerCase()
  .normalize("NFD").replace(/\p{Diacritic}/gu, "").replace(/\s+/g, " ").trim();

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), 2200);
}

// Micro-reward ao concluir (dopamina/TDAH): burst de confete no ponto do clique +
// elogio curto. Visual apenas, sem som. Respeita prefers-reduced-motion.
const CHEERS = ["✓ feito!", "boa!", "mandou bem 💪", "menos um!", "🔥 foco!", "isso aí!"];
function celebrate(x, y) {
  toast(CHEERS[Math.floor(Math.random() * CHEERS.length)]);
  if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const n = 16;
  for (let i = 0; i < n; i++) {
    const p = el("div", "confetti");
    p.style.left = x + "px";
    p.style.top = y + "px";
    p.style.background = "hsl(" + Math.floor(Math.random() * 360) + " 90% 62%)";
    const ang = (Math.PI * 2 * i) / n + Math.random();
    const dist = 45 + Math.random() * 65;
    p.style.setProperty("--dx", (Math.cos(ang) * dist).toFixed(1) + "px");
    p.style.setProperty("--dy", (Math.sin(ang) * dist - 30).toFixed(1) + "px");
    document.body.appendChild(p);
    setTimeout(() => p.remove(), 780);
  }
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
    const arr = Array.isArray(data) ? data : (data.tasks || []);
    // Evita o "blink": so re-renderiza se os dados mudaram de fato. A maioria
    // dos ticks de auto-refresh traz payload identico -> nada muda na tela.
    const sig = JSON.stringify(arr);
    STATE.tasks = arr;
    if (sig === STATE.sig) return;
    STATE.sig = sig;
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
    // Sem "blink": atualiza SO o card afetado, sem recriar o board inteiro.
    // Render completo so quando o card pode sumir/trocar de secao (concluir/adiar).
    const structural = ("done" in body) || ("snoozedUntil" in body);
    if (structural || !replaceCardInPlace(sbid)) render();
    else { updateStats(); renderFilterBar(); }
    STATE.sig = JSON.stringify(STATE.tasks);
  } catch (e) {
    toast("Não consegui salvar");
    console.error(e);
  }
}

// ---------- create (tarefa manual) ----------
async function createTask(payload) {
  try {
    const res = await fetch("/api/task", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (res.status === 409) { toast("Já existe uma tarefa com essa pessoa + assunto"); return false; }
    if (!res.ok) throw new Error("HTTP " + res.status);
    const created = await res.json();
    if (created && created.sbid) STATE.tasks.push(created);
    render();
    toast("Tarefa criada");
    return true;
  } catch (e) {
    toast("Não consegui criar a tarefa");
    console.error(e);
    return false;
  }
}

// ---------- modal ----------
function openModal() {
  $("#task-form").reset();
  $("#f-prioridade").value = "media";
  $("#modal-backdrop").hidden = false;
  setTimeout(() => $("#f-assunto").focus(), 30);
}
function closeModal() { $("#modal-backdrop").hidden = true; }

// ---------- filtering ----------
function visible(task) {
  const f = STATE.filter;
  const showDone = STATE.showDone || (f && f.incluirConcluidas);
  if (task.done && !showDone) return false;
  if (!showDone && task.snoozedUntil && task.snoozedUntil > todayStr()) return false;

  if (f) {
    if (!matchFilter(task, f)) return false;
  }

  if (STATE.search) {
    const q = STATE.search.toLowerCase();
    const hay = [task.pessoa, task.assunto, task.resumo, task.proxima_acao]
      .filter(Boolean).join(" ").toLowerCase();
    if (!hay.includes(q)) return false;
  }
  return true;
}

// Casa uma tarefa contra o filtro estruturado montado pelo agente (ou o filtro
// especial de duplicados).
function matchFilter(task, f) {
  if (f.dupes) return f.ids && f.ids.has(task.sbid);
  if (f.novo && !isCreatedToday(task)) return false;   // filtro rapido "novos de hoje"
  if (f.pessoa && !normalize(task.pessoa).includes(normalize(f.pessoa))) return false;
  if (f.texto) {
    const hay = normalize([task.pessoa, task.assunto, task.resumo, task.proxima_acao].filter(Boolean).join(" "));
    if (!hay.includes(normalize(f.texto))) return false;
  }
  if (f.status && f.status.length) {
    if (!f.status.some(s => s === task.status || s === task.categoria)) return false;
  }
  if (f.prioridade && f.prioridade.length) {
    if (!f.prioridade.includes(task.prioridade || "media")) return false;
  }
  if (f.prazo) {
    const d = task.dueDate;
    if (!d) return false;
    const today = todayStr();
    if (f.prazo === "atrasado" && !(d < today)) return false;
    if (f.prazo === "hoje" && d !== today) return false;
    if (f.prazo === "semana") {
      const lim = new Date(); lim.setDate(lim.getDate() + 7);
      if (d > lim.toISOString().slice(0, 10)) return false;
    }
  }
  return true;
}

// ---------- stats ----------
function updateStats() {
  const t = todayStr();
  const open = STATE.tasks.filter(x => !x.done);
  const hoje = open.filter(x => x.dueDate === t).length;
  $("#stat-hoje").textContent = hoje;
  const hojeWrap = $("#stat-hoje-wrap");
  if (hojeWrap) {
    hojeWrap.classList.toggle("empty", hoje === 0);
    hojeWrap.classList.toggle("active", !!(STATE.filter && STATE.filter.prazo === "hoje"));
  }
  $("#stat-atrasadas").textContent = open.filter(x => x.dueDate && x.dueDate < t).length;
  $("#stat-aguardando").textContent = open.filter(x => x.categoria === "aguardando").length;
  $("#stat-total").textContent = open.length;

  // "novos": criados hoje e ainda abertos. Clicavel -> filtra a tela.
  const novos = open.filter(isCreatedToday).length;
  const wrap = $("#stat-novos-wrap");
  if (wrap) {
    $("#stat-novos").textContent = novos;
    wrap.classList.toggle("empty", novos === 0);
    wrap.classList.toggle("active", !!(STATE.filter && STATE.filter.novo));
  }
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
// Ordena por data (prazo) crescente: mais atrasado/proximo primeiro; sem prazo por
// ultimo. Empate cai no criterio de prioridade.
const byDate = (a, b) => {
  const da = a.dueDate, db = b.dueDate;
  if (!da && !db) return byPrio(a, b);
  if (!da) return 1;
  if (!db) return -1;
  return da.localeCompare(db) || byPrio(a, b);
};
// Comparador ativo conforme o modo escolhido (persistido em localStorage).
const sortCmp = () => (STATE.sort === "data" ? byDate : byPrio);
const isRef = t => t.categoria === "referencia";
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
  renderFilterBar();
  updateExpandBtn();
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

  // Modo duplicados: um feed unico, cards do mesmo grupo adjacentes.
  if (STATE.filter && STATE.filter.dupes) {
    const go = STATE.filter.groupOf || {};
    const sorted = shown.slice().sort((a, b) => ((go[a.sbid] ?? 0) - (go[b.sbid] ?? 0)) || byPrio(a, b));
    board.appendChild(feedSection("Possíveis duplicados", sorted, "feed", true));
    return;
  }

  const cmp = sortCmp();
  const agora = shown.filter(t => !isRef(t) && !isWaiting(t)).sort(cmp);
  const aguardando = shown.filter(t => !isRef(t) && isWaiting(t)).sort(cmp);
  const referencia = shown.filter(isRef).sort(cmp);

  if (agora.length)      board.appendChild(feedSection("O que importa agora", agora, "feed", true));
  if (aguardando.length) board.appendChild(feedSection("Aguardando os outros", aguardando, "cat-aguardando", false));
  if (referencia.length) board.appendChild(feedSection("Referência / baixa", referencia, "cat-referencia", false));
}

function renderCard(task) {
  const card = el("div", "card prio-" + (task.prioridade || "media"));
  card.dataset.sbid = task.sbid;
  if (task.done) card.classList.add("done");
  if (STATE.open.has(task.sbid)) card.classList.add("open");
  if (isNew(task)) card.classList.add("is-new");

  const top = el("div", "card-top");
  // Concluir em 1 clique, sem precisar expandir o card (parte externa).
  const quick = el("button", "card-check" + (task.done ? " on" : ""), "✓");
  quick.title = task.done ? "Reabrir (1 clique)" : "Concluir (1 clique)";
  quick.setAttribute("aria-label", quick.title);
  quick.addEventListener("click", e => { e.stopPropagation(); if (!task.done) celebrate(e.clientX, e.clientY); patch(task.sbid, { done: !task.done }); });
  top.appendChild(quick);
  // Sanitiza status para display: pega só a 1ª palavra válida (LLM pode concatenar).
  const STATUS_VALID = new Set(STATUS_KEYS);
  const statusDisplay = (task.status || "").split(/\s+/).find(w => STATUS_VALID.has(w)) || task.status || "fazer";
  top.appendChild(el("span", "badge st-" + statusDisplay, PREFIX[statusDisplay] || statusDisplay || "•"));
  if (task.prioridade) top.appendChild(el("span", "badge " + task.prioridade, task.prioridade));
  // Badge "novo": card criado hoje e ainda nao aberto pelo usuario.
  // "hoje": criado hoje mas ja reconhecido/mexido -> marcador persistente do dia.
  if (isNew(task)) top.appendChild(el("span", "badge novo", "novo"));
  else if (isCreatedToday(task)) top.appendChild(el("span", "badge hoje", "hoje"));
  // Em modo duplicados, marca a qual grupo o card pertence.
  if (STATE.filter && STATE.filter.dupes && STATE.filter.groupOf) {
    const gi = STATE.filter.groupOf[task.sbid];
    if (gi != null) top.appendChild(el("span", "badge dup", "≈ grupo " + (gi + 1)));
  }

  // Cluster direito: pessoa + edicao rapida de prazo (card fechado, canto sup. dir.)
  const topRight = el("div", "card-top-right");
  if (task.pessoa) topRight.appendChild(el("span", "card-person", task.pessoa));
  const dueQuick = el("input", "card-due-quick");
  dueQuick.type = "date";
  dueQuick.value = task.dueDate || "";
  dueQuick.title = "Alterar prazo";
  dueQuick.setAttribute("aria-label", "Alterar prazo");
  dueQuick.addEventListener("click", e => e.stopPropagation());
  dueQuick.addEventListener("change", () => patch(task.sbid, { dueDate: dueQuick.value }));
  topRight.appendChild(dueQuick);
  top.appendChild(topRight);
  card.appendChild(top);

  card.appendChild(el("div", "card-title", task.assunto || task.titulo || "(sem assunto)"));
  if (task.proxima_acao) card.appendChild(el("div", "card-action", "→ " + task.proxima_acao));

  const meta = el("div", "card-meta");
  const di = dueInfo(task);
  if (di.label) meta.appendChild(el("span", "due " + di.cls, di.label));
  const srcs = el("div", "sources");
  // dedup defensivo: LLM ocasionalmente concatena fontes ("whatsapp whatsapp")
  const fontesRaw = (task.fontes || []).map(s => String(s).split(/\s+/)).flat().filter(Boolean);
  const fontes = [...new Set(fontesRaw)];
  for (const s of fontes) srcs.appendChild(el("span", "src", s));
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
  bDone.addEventListener("click", e => { e.stopPropagation(); if (!task.done) celebrate(e.clientX, e.clientY); patch(task.sbid, { done: !task.done }); });
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

  card.addEventListener("click", () => {
    const isOpen = card.classList.toggle("open");
    if (isOpen) {
      STATE.open.add(task.sbid);
      // "Reconhece" o card novo: remove o realce verde e troca o badge "novo"
      // pelo "hoje" (marcador do dia persiste), sem recriar o board.
      if (card.classList.contains("is-new")) {
        STATE.seen.add(task.sbid);
        card.classList.remove("is-new");
        const badgeNovo = card.querySelector(".badge.novo");
        if (badgeNovo) { badgeNovo.className = "badge hoje"; badgeNovo.textContent = "hoje"; }
      }
    } else {
      STATE.open.delete(task.sbid);
    }
  });
  return card;
}

// Troca SO o card afetado no DOM (sem recriar o board) -> mata o "blink" ao salvar
// notas/prazo/prioridade. Retorna false se o card nao esta na tela (ai o chamador
// faz render() completo).
function replaceCardInPlace(sbid) {
  const updated = STATE.tasks.find(t => t.sbid === sbid);
  if (!updated) return false;
  const sel = (window.CSS && CSS.escape) ? CSS.escape(sbid) : sbid;
  const old = $("#board").querySelector('.card[data-sbid="' + sel + '"]');
  if (!old) return false;
  old.replaceWith(renderCard(updated));
  return true;
}

// ---------- agente (IA local streaming | Joule assincrono) ----------
const LLAMA = "http://127.0.0.1:19001";
let AGENT = { open: false, busy: false, target: "joule", history: [], ctrl: null, poll: null };

// Resumo compacto dos cards pro contexto da IA local (cabe folgado nos 32k).
function buildAgentContext() {
  const open = STATE.tasks.filter(t => !t.done).sort(byPrio).slice(0, 120);
  if (!open.length) return "(nenhuma tarefa aberta no momento)";
  const lines = open.map(t => {
    const p = [];
    p.push("[" + (t.status || "?") + "/" + (t.prioridade || "media") + "]");
    p.push(t.assunto || t.titulo || "(sem assunto)");
    if (t.pessoa) p.push("— " + t.pessoa);
    if (t.dueDate) p.push("— prazo " + t.dueDate);
    if (t.proxima_acao) p.push("— → " + t.proxima_acao);
    if (t.risco) p.push("— ⚠ " + t.risco);
    return "- " + p.join(" ");
  });
  return lines.join("\n");
}

function localSystemPrompt() {
  const hoje = todayStr();
  return [
    "Voce e o assistente do SecondBrain de um CSM da SAP. Hoje e " + hoje + ".",
    "Responda em portugues do Brasil, direto e conciso.",
    "Baseie-se SOMENTE nas tarefas/cards abaixo quando a pergunta for sobre o trabalho dele.",
    "Cite pessoas, prazos e proximos passos reais dos cards. Se algo nao estiver nos cards, diga que nao sabe — nao invente.",
    "Para perguntas gerais (fora dos cards), pode responder normalmente.",
    "",
    "=== CARDS ABERTOS (mais prioritarios primeiro) ===",
    buildAgentContext(),
  ].join("\n");
}

function scrollAgentLog() {
  const log = $("#agent-log");
  log.scrollTop = log.scrollHeight;
}

function addAgentBubble(role) {
  const wrap = el("div", "agent-msg " + role);
  const bubble = el("div", "agent-bubble");
  wrap.appendChild(bubble);
  $("#agent-log").appendChild(wrap);
  scrollAgentLog();
  return bubble;
}

function setAgentBusy(b) {
  AGENT.busy = b;
  $("#agent-input").disabled = b;
  $("#agent-send").disabled = b;
  $("#tgt-local").disabled = b;
  $("#tgt-joule").disabled = b;
}

function autosizeAgent() {
  const t = $("#agent-input");
  t.style.height = "auto";
  t.style.height = Math.min(t.scrollHeight, 140) + "px";
}

function setAgentTarget(t) {
  if (AGENT.busy) return;
  AGENT.target = t;
  $("#tgt-local").classList.toggle("active", t === "local");
  $("#tgt-joule").classList.toggle("active", t === "joule");
  $("#agent-input").placeholder = (t === "joule")
    ? "Perguntar ao Joule…  (ele lê seu tasks.json)"
    : "Pergunte ao agente…  (Enter envia · Shift+Enter quebra linha)";
}

function openAgent() {
  AGENT.open = true;
  $("#agent-panel").hidden = false;
  setTimeout(() => $("#agent-input").focus(), 30);
}
function closeAgent() {
  AGENT.open = false;
  $("#agent-panel").hidden = true;
  if (AGENT.ctrl) { try { AGENT.ctrl.abort(); } catch (e) {} }
  if (AGENT.poll) { clearInterval(AGENT.poll); AGENT.poll = null; }
  setAgentBusy(false);
}
function clearAgent() {
  if (AGENT.busy) return;
  AGENT.history = [];
  $("#agent-log").innerHTML = "";
}

async function askLocal(question, bubble) {
  const ctrl = new AbortController();
  AGENT.ctrl = ctrl;
  const messages = [{ role: "system", content: localSystemPrompt() }, ...AGENT.history, { role: "user", content: question }];
  let answer = "";
  try {
    const res = await fetch(LLAMA + "/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: "qwen-coder-local", stream: true, temperature: 0.3, max_tokens: 1024, messages }),
      signal: ctrl.signal,
    });
    if (!res.ok || !res.body) throw new Error("HTTP " + res.status);
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const line of lines) {
        const s = line.trim();
        if (!s.startsWith("data:")) continue;
        const payload = s.slice(5).trim();
        if (payload === "[DONE]") continue;
        try {
          const j = JSON.parse(payload);
          const tok = (j.choices && j.choices[0] && j.choices[0].delta && j.choices[0].delta.content) || "";
          if (tok) {
            bubble.classList.remove("typing");
            answer += tok;
            bubble.textContent = answer;
            scrollAgentLog();
          }
        } catch (e) {}
      }
    }
    if (!answer) { bubble.classList.remove("typing"); bubble.textContent = "(sem resposta)"; }
    else {
      AGENT.history.push({ role: "user", content: question }, { role: "assistant", content: answer });
      if (AGENT.history.length > 12) AGENT.history = AGENT.history.slice(-12);
    }
  } catch (e) {
    if (e.name === "AbortError") { const w = bubble.parentElement; if (w) w.remove(); }
    else {
      bubble.classList.remove("typing");
      bubble.classList.add("err");
      bubble.textContent = "IA local fora do ar. Rode start-llama e tente de novo.";
      toast("llama local não respondeu");
    }
  } finally {
    AGENT.ctrl = null;
    setAgentBusy(false);
  }
}

async function askJoule(question, bubble) {
  let id = null;
  try {
    const res = await fetch("/api/joule", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: question }),
    });
    const j = await res.json();
    if (!res.ok || !j.id) throw new Error(j.error || "falha ao iniciar");
    id = j.id;
  } catch (e) {
    bubble.classList.remove("typing");
    bubble.classList.add("err");
    bubble.textContent = "Não consegui falar com o Joule. Ele está aberto?";
    toast("Joule indisponível");
    setAgentBusy(false);
    return;
  }
  AGENT.poll = setInterval(async () => {
    try {
      const r = await fetch("/api/joule/" + encodeURIComponent(id), { cache: "no-store" });
      const st = await r.json();
      if (st.status === "pending") return;
      clearInterval(AGENT.poll); AGENT.poll = null;
      bubble.classList.remove("typing");
      if (st.status === "done") bubble.textContent = st.text || "(sem resposta)";
      else { bubble.classList.add("err"); bubble.textContent = st.error || "Erro no Joule."; }
      scrollAgentLog();
      setAgentBusy(false);
    } catch (e) {
      clearInterval(AGENT.poll); AGENT.poll = null;
      bubble.classList.remove("typing");
      bubble.classList.add("err");
      bubble.textContent = "Perdi contato com o cockpit.";
      setAgentBusy(false);
    }
  }, 1500);
}

// Roteamento: comandos de filtro/limpar/duplicados/criar vs pergunta normal.
const RE_CLEAR = /^\s*(limpa|limpar|tira\w*\s+o?\s*filtro|remove\w*\s+o?\s*filtro|mostrar?\s+tudo|tudo\s+de\s+novo|ver\s+tudo)/i;
const RE_DUPE  = /(duplicad|repetid|poss[íi]ve\w*\s+duplicad|tem\s+repetido|duplicat|iguais)/i;
const RE_CREATE = /^\s*(me\s+)?(cria\w*|crie|adiciona\w*|adicione|anota\w*|anote|apont\w+|registr\w+|nova\s+tarefa|novo\s+(card|lembrete)|lembr\w+\s+(de|que|-?me)|preciso\s+|tenho\s+que\s+|agenda\w*\s+)/i;
const RE_FILTER = /^\s*(me\s+)?(traga|traz|tras|mostra|mostre|mostrar|exib\w*|filtr\w*|deixa\s+s[óo]|deixe\s+s[óo]|s[óo]\s|somente|apenas|esconde|esconda|oculta\w*|lista\s|listar)/i;

function agentSend() {
  if (AGENT.busy) return;
  const inp = $("#agent-input");
  const q = inp.value.trim();
  if (!q) return;
  const hint = $("#agent-hint"); if (hint) hint.remove();
  addAgentBubble("user").textContent = q;
  inp.value = ""; autosizeAgent();

  // Comandos locais instantaneos (sem modelo).
  if (RE_CLEAR.test(q)) {
    clearFilter();
    addAgentBubble("assistant").textContent = "Limpei o filtro — mostrando tudo de novo.";
    scrollAgentLog();
    return;
  }
  if (RE_DUPE.test(q)) { applyDuplicatesFilter(); return; }

  const bubble = addAgentBubble("assistant");
  bubble.classList.add("typing");
  scrollAgentLog();
  setAgentBusy(true);

  if (RE_CREATE.test(q)) askCreate(q, bubble);
  else if (RE_FILTER.test(q)) askFilter(q, bubble);
  else if (AGENT.target === "joule") askJoule(q, bubble);
  else askLocal(q, bubble);
}

// ---------- criar tarefa pela conversa ----------
// O modelo do alvo atual extrai os campos (fora do servidor, p/ nao congelar o
// cockpit single-thread); grava via /api/task. Se o modelo falhar, cai no
// fallback: cria com a frase crua como assunto (nunca perde a captura).
function buildCreatePrompt(q) {
  return [
    "Voce converte uma frase em PT-BR numa UNICA tarefa. Hoje e " + todayStr() + ".",
    "Responda APENAS com um objeto JSON valido: sem texto fora dele, sem crases, sem markdown.",
    'Formato exato: {"assunto":string,"pessoa":string|null,"proxima_acao":string|null,"prazo":"YYYY-MM-DD"|null,"status":string,"prioridade":string,"notas":string|null}',
    "status valido: " + STATUS_KEYS.join(", ") + " (use 'fazer' na duvida). prioridade valida: " + PRIO_KEYS.join(", ") + " (use 'media' na duvida, 'alta' se cliente/prazo/risco).",
    "NAO invente: o que nao estiver claro vira null. Resolva datas relativas (amanha, sexta, semana que vem, dia 30) para ISO usando a data de hoje.",
    "assunto = nucleo curto da tarefa, SEM repetir o nome da pessoa (a pessoa vai no campo pessoa).",
    "",
    "Frase: " + q,
  ].join("\n");
}

function sanitizeCreate(j, fallbackText) {
  j = j || {};
  const clean = v => {
    const s = (v == null ? "" : String(v)).trim();
    return (s && s.toLowerCase() !== "null") ? s : "";
  };
  let due = clean(j.prazo);
  if (due && !/^\d{4}-\d{2}-\d{2}$/.test(due)) due = "";
  return {
    assunto: clean(j.assunto) || fallbackText,
    pessoa: clean(j.pessoa),
    proxima_acao: clean(j.proxima_acao),
    dueDate: due,
    status: STATUS_KEYS.includes(clean(j.status)) ? clean(j.status) : "fazer",
    prioridade: PRIO_KEYS.includes(clean(j.prioridade)) ? clean(j.prioridade) : "media",
    notas: clean(j.notas),
    origem: "agente",
  };
}

async function askCreate(q, bubble) {
  let raw = null;
  try {
    raw = await modelRaw(buildCreatePrompt(q));
  } catch (e) {
    if (e && e.name === "AbortError") { const w = bubble.parentElement; if (w) w.remove(); setAgentBusy(false); return; }
    raw = null; // modelo fora do ar -> fallback com texto cru
  }
  const payload = sanitizeCreate(raw ? parseFilterJson(raw) : null, q);
  bubble.classList.remove("typing");
  try {
    const res = await fetch("/api/task", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await res.json().catch(() => null);
    if (res.status === 409) {
      const t = data && data.task;
      bubble.textContent = "Já existe algo parecido: " + ((t && (t.titulo || t.assunto)) || "essa tarefa") + ".";
      scrollAgentLog(); setAgentBusy(false); return;
    }
    if (!res.ok || !data || !data.sbid) throw new Error("HTTP " + res.status);
    STATE.tasks.push(data);
    STATE.sig = JSON.stringify(STATE.tasks);
    // Se houver filtro ativo, limpa pra o card novo aparecer (senão pode ficar oculto).
    if (STATE.filter) clearFilter(); else render();
    const bits = [];
    if (data.pessoa) bits.push(data.pessoa);
    if (data.dueDate) bits.push("prazo " + data.dueDate);
    bubble.textContent = "✓ criei: " + (data.assunto || data.titulo || "(sem assunto)") +
      (bits.length ? " (" + bits.join(" · ") + ")" : "");
    toast("Tarefa criada 🎯");
  } catch (e) {
    bubble.classList.add("err");
    bubble.textContent = "Não consegui salvar a tarefa no cockpit.";
    toast("não criei a tarefa");
    console.error(e);
  } finally {
    setAgentBusy(false);
  }
}

// ---------- filtro pela conversa (modelo monta o filtro) ----------
function distinctPeople() {
  const set = new Set();
  for (const t of STATE.tasks) if (t.pessoa) set.add(t.pessoa);
  return [...set];
}

function buildFilterPrompt(q) {
  const pessoas = distinctPeople().slice(0, 200);
  return [
    "Voce converte um pedido em PT-BR num FILTRO de tarefas. Hoje e " + todayStr() + ".",
    "Responda APENAS com um objeto JSON valido: sem texto fora dele, sem crases, sem markdown.",
    "Formato exato:",
    '{"acao":"filtrar"|"limpar","filtro":{"pessoa":string|null,"texto":string|null,"status":string[]|null,"prioridade":string[]|null,"prazo":"atrasado"|"hoje"|"semana"|null,"incluirConcluidas":boolean},"resumo":string}',
    "status validos: " + STATUS_KEYS.join(", ") + ". prioridade valida: " + PRIO_KEYS.join(", ") + ".",
    "Se o pedido citar uma pessoa, use EXATAMENTE um nome desta lista (o mais provavel):",
    pessoas.join(" | "),
    'pendencias/abertas => incluirConcluidas=false. "resumo": frase curtissima (ex.: "Cantu · pendencias").',
    "Se pedir para limpar/ver tudo, use acao=limpar.",
    "",
    "Pedido: " + q,
  ].join("\n");
}

// Extrai o 1o objeto JSON balanceado de um texto (Joule pode embrulhar em prosa/crases).
function parseFilterJson(text) {
  if (!text) return null;
  let s = String(text).trim();
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) s = fence[1].trim();
  const start = s.indexOf("{");
  if (start < 0) return null;
  let depth = 0, end = -1;
  for (let i = start; i < s.length; i++) {
    if (s[i] === "{") depth++;
    else if (s[i] === "}") { depth--; if (depth === 0) { end = i; break; } }
  }
  if (end < 0) return null;
  try { return JSON.parse(s.slice(start, end + 1)); } catch (e) { return null; }
}

function sanitizeFilter(f) {
  f = f || {};
  const out = {
    pessoa: f.pessoa ? String(f.pessoa) : null,
    texto: f.texto ? String(f.texto) : null,
    status: Array.isArray(f.status) ? f.status.filter(s => STATUS_KEYS.includes(s)) : null,
    prioridade: Array.isArray(f.prioridade) ? f.prioridade.filter(p => PRIO_KEYS.includes(p)) : null,
    prazo: ["atrasado", "hoje", "semana"].includes(f.prazo) ? f.prazo : null,
    incluirConcluidas: !!f.incluirConcluidas,
  };
  if (out.status && !out.status.length) out.status = null;
  if (out.prioridade && !out.prioridade.length) out.prioridade = null;
  return out;
}

// Transportes genericos: mandam um prompt ao modelo do alvo atual e devolvem o
// texto cru. Usados pelo filtro (buildFilterPrompt) e pela criacao (buildCreatePrompt).
async function promptViaLocal(prompt) {
  const ctrl = new AbortController(); AGENT.ctrl = ctrl;
  try {
    const res = await fetch(LLAMA + "/v1/chat/completions", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "qwen-coder-local", stream: false, temperature: 0, max_tokens: 400,
        response_format: { type: "json_object" },
        messages: [{ role: "user", content: prompt }],
      }),
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const j = await res.json();
    return j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
  } finally { AGENT.ctrl = null; }
}

function promptViaJoule(prompt) {
  return new Promise((resolve, reject) => {
    fetch("/api/joule", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: prompt }),
    }).then(r => r.json()).then(j => {
      if (!j.id) { reject(new Error(j.error || "falha ao iniciar")); return; }
      AGENT.poll = setInterval(async () => {
        try {
          const r = await fetch("/api/joule/" + encodeURIComponent(j.id), { cache: "no-store" });
          const st = await r.json();
          if (st.status === "pending") return;
          clearInterval(AGENT.poll); AGENT.poll = null;
          if (st.status === "done") resolve(st.text || "");
          else reject(new Error(st.error || "erro"));
        } catch (e) { clearInterval(AGENT.poll); AGENT.poll = null; reject(e); }
      }, 1500);
    }).catch(reject);
  });
}

function modelRaw(prompt) {
  return (AGENT.target === "joule") ? promptViaJoule(prompt) : promptViaLocal(prompt);
}

function filterFail(bubble, e) {
  if (e && e.name === "AbortError") { const w = bubble.parentElement; if (w) w.remove(); setAgentBusy(false); return; }
  bubble.classList.remove("typing");
  bubble.classList.add("err");
  bubble.textContent = (AGENT.target === "joule")
    ? "Não consegui montar o filtro pelo Joule. Ele está aberto? Tenta de novo ou usa a IA local."
    : "Não entendi o filtro. Tenta algo como \"me mostra os cards da Cantu\" ou \"riscos atrasados\".";
  toast("filtro não aplicado");
  setAgentBusy(false);
}

async function askFilter(q, bubble) {
  let raw = null;
  try {
    raw = await modelRaw(buildFilterPrompt(q));
  } catch (e) { filterFail(bubble, e); return; }
  const parsed = parseFilterJson(raw);
  if (!parsed) { filterFail(bubble, new Error("json invalido")); return; }
  bubble.classList.remove("typing");
  if (parsed.acao === "limpar") {
    clearFilter();
    bubble.textContent = "Limpei o filtro — mostrando tudo de novo.";
    scrollAgentLog(); setAgentBusy(false); return;
  }
  const f = sanitizeFilter(parsed.filtro);
  f.resumo = (parsed.resumo || "filtro").toString().slice(0, 80);
  applyFilter(f);
  const n = STATE.tasks.filter(visible).length;
  bubble.textContent = "Filtrei: " + f.resumo + " · " + n + (n === 1 ? " card." : " cards.");
  scrollAgentLog(); setAgentBusy(false);
}

// ---------- aplicar / limpar filtro ----------
function applyFilter(f) { STATE.filter = f; render(); }
function clearFilter() { STATE.filter = null; render(); }

// ---------- expandir/recolher todos (respeita filtro/busca atuais) ----------
// Atua so nos cards VISIVEIS via o mesmo Set STATE.open que o render() reaplica.
function toggleExpandAll() {
  const vis = STATE.tasks.filter(visible);
  const allOpen = vis.length > 0 && vis.every(t => STATE.open.has(t.sbid));
  for (const t of vis) { if (allOpen) STATE.open.delete(t.sbid); else STATE.open.add(t.sbid); }
  render();
}
function updateExpandBtn() {
  const btn = $("#expand-all");
  if (!btn) return;
  const vis = STATE.tasks.filter(visible);
  const allOpen = vis.length > 0 && vis.every(t => STATE.open.has(t.sbid));
  btn.textContent = allOpen ? "⤡" : "⤢";
  btn.title = allOpen ? "Recolher todos os cards visíveis" : "Expandir todos os cards visíveis";
}

// ---------- ordenacao do board (prioridade | data), persistida ----------
function setSort(mode) {
  STATE.sort = (mode === "data") ? "data" : "prio";
  localStorage.setItem("sb-sort", STATE.sort);
  $("#sort-prio").classList.toggle("active", STATE.sort === "prio");
  $("#sort-date").classList.toggle("active", STATE.sort === "data");
  render();
}

function renderFilterBar() {
  const bar = $("#filter-bar");
  if (!bar) return;
  const f = STATE.filter;
  bar.innerHTML = "";
  if (!f) { bar.hidden = true; return; }
  const n = STATE.tasks.filter(visible).length;
  bar.hidden = false;
  const chip = el("div", "filter-chip");
  chip.appendChild(el("span", "filter-ic", "🔎"));
  chip.appendChild(el("span", "filter-lbl", (f.resumo || "filtro") + " · " + n + (n === 1 ? " card" : " cards")));
  const x = el("button", "filter-x", "✕ limpar");
  x.addEventListener("click", clearFilter);
  chip.appendChild(x);
  bar.appendChild(chip);
}

// ---------- possiveis duplicados (deteccao local deterministica) ----------
function tokenSet(s) { return new Set(normalize(s).split(" ").filter(w => w.length > 2)); }
function jaccard(a, b) {
  if (!a.size || !b.size) return 0;
  let inter = 0; for (const w of a) if (b.has(w)) inter++;
  return inter / (a.size + b.size - inter);
}
function findDuplicateGroups() {
  const open = STATE.tasks.filter(t => !t.done);
  const byPerson = new Map();
  for (const t of open) {
    const p = normalize(t.pessoa) || "(sem pessoa)";
    if (!byPerson.has(p)) byPerson.set(p, []);
    byPerson.get(p).push(t);
  }
  const groups = [];
  for (const list of byPerson.values()) {
    const toks = list.map(t => tokenSet(t.assunto));
    const used = new Array(list.length).fill(false);
    for (let i = 0; i < list.length; i++) {
      if (used[i]) continue;
      const cluster = [list[i]]; used[i] = true;
      for (let j = i + 1; j < list.length; j++) {
        if (used[j]) continue;
        const exact = normalize(list[i].assunto) === normalize(list[j].assunto);
        if (exact || jaccard(toks[i], toks[j]) >= 0.6) { cluster.push(list[j]); used[j] = true; }
      }
      if (cluster.length >= 2) groups.push(cluster);
    }
  }
  return groups;
}
function applyDuplicatesFilter() {
  const groups = findDuplicateGroups();
  if (!groups.length) {
    addAgentBubble("assistant").textContent = "Não achei possíveis duplicados entre as tarefas abertas. 👍";
    scrollAgentLog();
    return;
  }
  const ids = new Set(), groupOf = {};
  groups.forEach((g, gi) => g.forEach(t => { ids.add(t.sbid); groupOf[t.sbid] = gi; }));
  applyFilter({ dupes: true, ids, groupOf, resumo: "possíveis duplicados", incluirConcluidas: false });
  addAgentBubble("assistant").textContent =
    "Achei " + groups.length + (groups.length === 1 ? " grupo" : " grupos") +
    " de possíveis duplicados (" + ids.size + " cards). Deixei só eles na tela, agrupados. Confere e conclua/ajuste o que for repetido.";
  scrollAgentLog();
}

// ---------- painel de saude / rodada (ao vivo) ----------
// Somente leitura: consome /api/run-status, /api/run-history e /api/heavy-queue.
// Todos podem devolver vazio (arquivos ainda nao existem) -> nunca quebra.
let HEALTH = { open: false, poll: null };

const CH_ORDER = ["joule", "copilot", "whatsapp", "meetings"];
const CH_LABELS = { joule: "Joule", copilot: "Copilot", whatsapp: "WhatsApp", meetings: "Reuniões" };

function chStatusInfo(st) {
  switch ((st || "pending").toLowerCase()) {
    case "ok":      return { cls: "ok",      txt: "OK" };
    case "fail":    return { cls: "fail",    txt: "FALHOU" };
    case "running": return { cls: "running", txt: "rodando" };
    default:        return { cls: "pending", txt: "—" };
  }
}

function fmtClock(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
}
function fmtMs(ms) {
  if (typeof ms !== "number") return "";
  return ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : ms + "ms";
}
function fmtChars(n) {
  if (typeof n !== "number") return "";
  if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k car.";
  return n + " car.";
}

async function loadHealth() {
  const btn = $("#health-refresh");
  if (btn) btn.classList.add("spin");
  let status = {}, history = [], heavy = { items: [] }, watch = { running: false }, deps = { deps: [] };
  try {
    const [rs, rh, hq, mw, dp] = await Promise.all([
      fetch("/api/run-status",  { cache: "no-store" }).then(r => r.json()).catch(() => ({})),
      fetch("/api/run-history", { cache: "no-store" }).then(r => r.json()).catch(() => []),
      fetch("/api/heavy-queue", { cache: "no-store" }).then(r => r.json()).catch(() => ({ items: [] })),
      fetch("/api/meeting-watch", { cache: "no-store" }).then(r => r.json()).catch(() => ({ running: false })),
      fetch("/api/deps", { cache: "no-store" }).then(r => r.json()).catch(() => ({ deps: [] })),
    ]);
    status  = rs || {};
    history = Array.isArray(rh) ? rh : [];
    heavy   = hq || { items: [] };
    watch   = mw || { running: false };
    deps    = dp || { deps: [] };
  } catch (e) {
    console.error(e);
  } finally {
    if (btn) setTimeout(() => btn.classList.remove("spin"), 400);
  }
  renderHealth(status, history, heavy, watch, deps);
}

function renderChannelChip(key, c) {
  c = c || {};
  const info = chStatusInfo(c.status);
  const chip = el("div", "ch-chip ch-" + info.cls);
  const line = el("div", "ch-line");
  line.appendChild(el("span", "ch-name", CH_LABELS[key] || key));
  line.appendChild(el("span", "ch-state", info.txt));
  chip.appendChild(line);
  const bits = [];
  if (typeof c.items === "number") bits.push(c.items + (c.items === 1 ? " item" : " itens"));
  if (typeof c.ms === "number") bits.push(fmtMs(c.ms));
  if (bits.length) chip.appendChild(el("div", "ch-sub", bits.join(" · ")));
  if (c.error) chip.appendChild(el("div", "ch-err", "⚠ " + c.error));
  return chip;
}

function layaStat(val, label) {
  const s = el("div", "laya-stat");
  s.appendChild(el("span", "laya-val", (val == null ? "—" : String(val))));
  s.appendChild(el("span", "laya-lbl", label));
  return s;
}

function renderHistRow(run) {
  run = run || {};
  const row = el("div", "hist-row");
  const top = el("div", "hist-top");
  const st = (run.status || "").toLowerCase();
  top.appendChild(el("span", "hist-when", fmtClock(run.startedAt || run.updatedAt)));
  top.appendChild(el("span", "run-badge sm " + (st || "pending"), st || "—"));
  row.appendChild(top);
  const dots = el("div", "hist-dots");
  const channels = run.channels || {};
  for (const key of CH_ORDER) {
    const c = channels[key] || {};
    const info = chStatusInfo(c.status);
    const d = el("span", "hist-dot hd-" + info.cls, (CH_LABELS[key] || key).slice(0, 1));
    d.title = (CH_LABELS[key] || key) + ": " + info.txt +
      (typeof c.items === "number" ? " (" + c.items + ")" : "") +
      (c.error ? " — " + c.error : "");
    dots.appendChild(d);
  }
  row.appendChild(dots);
  return row;
}

function renderHeavyItem(it) {
  it = it || {};
  const row = el("div", "heavy-item");
  const top = el("div", "heavy-top");
  top.appendChild(el("span", "heavy-kind hk-" + (it.kind || ""), it.kind || "?"));
  top.appendChild(el("span", "heavy-label", it.label || it.id || "(sem rótulo)"));
  row.appendChild(top);
  const meta = el("div", "heavy-meta");
  if (typeof it.sizeChars === "number") meta.appendChild(el("span", "heavy-size", fmtChars(it.sizeChars)));
  if (it.reason) meta.appendChild(el("span", "heavy-reason", it.reason));
  if (it.addedAt) meta.appendChild(el("span", "heavy-when", fmtClock(it.addedAt)));
  row.appendChild(meta);
  const btn = el("button", "heavy-btn", "processar");
  btn.disabled = true;
  btn.title = "Em breve — o processamento manual ainda não está disponível";
  row.appendChild(btn);
  return row;
}

async function runNow() {
  try {
    const r = await fetch("/api/run-now", { method: "POST" });
    if (r.status === 409) { alert("Já há uma rodada em execução."); return; }
    if (!r.ok) {
      let detail = "";
      try { const d = await r.json(); detail = d.error || ""; } catch {}
      alert("Erro ao iniciar rodada." + (detail ? "\n\n" + detail : ""));
      return;
    }
    setTimeout(loadHealth, 1200);
  } catch { alert("Erro de rede."); }
}

async function toggleSkip() {
  try {
    const r = await fetch("/api/skip-next-run", { method: "POST" });
    if (!r.ok) { alert("Erro."); return; }
    loadHealth();
  } catch { alert("Erro de rede."); }
}

function healthSection(title, countLabel) {
  const sec = el("section", "health-sec");
  const head = el("div", "health-sec-head");
  head.appendChild(el("span", "health-sec-t", title));
  if (countLabel != null) head.appendChild(el("span", "health-count", String(countLabel)));
  sec.appendChild(head);
  return { sec, head };
}

function renderHealth(status, history, heavy, watch, deps) {
  const body = $("#health-body");
  if (!body) return;
  body.innerHTML = "";

  // ----- dependencias / servicos -----
  {
    const list = (deps && Array.isArray(deps.deps)) ? deps.deps : [];
    const okN = list.filter(d => d && d.ok && !d.warn).length;
    const s = healthSection("Dependências", list.length ? (okN + "/" + list.length) : null);
    if (!list.length) {
      s.sec.appendChild(el("div", "health-empty", "Sem status de dependências."));
    } else {
      const grid = el("div", "ch-grid");
      for (const d of list) {
        const cls = d.ok ? (d.warn ? "running" : "ok") : "fail";
        const chip = el("div", "ch-chip ch-" + cls);
        const line = el("div", "ch-line");
        line.appendChild(el("span", "ch-name", d.label || d.key));
        line.appendChild(el("span", "ch-state", d.ok ? (d.warn ? "atenção" : "ativo") : "off"));
        chip.appendChild(line);
        if (d.detail) chip.appendChild(el("div", "ch-sub", d.detail));
        grid.appendChild(chip);
      }
      s.sec.appendChild(grid);
    }
    body.appendChild(s.sec);
  }

  // ----- rodada atual -----
  const hasRun = !!(status && status.runId);
  const runStatus = (status && status.status || "").toLowerCase();
  const cur = healthSection("Rodada atual");
  if (hasRun) cur.head.appendChild(el("span", "run-badge " + (runStatus || "pending"), runStatus || "—"));
  if (!hasRun) {
    cur.sec.appendChild(el("div", "health-empty", "Nenhuma rodada registrada ainda."));
  } else {
    const meta = el("div", "run-meta");
    meta.appendChild(el("span", "run-id", "#" + status.runId));
    if (status.currentStep) meta.appendChild(el("span", "run-step", "passo: " + status.currentStep));
    const upd = status.updatedAt || status.startedAt;
    if (upd) meta.appendChild(el("span", "run-when", "atual. " + fmtClock(upd)));
    cur.sec.appendChild(meta);

    const grid = el("div", "ch-grid");
    const channels = status.channels || {};
    for (const key of CH_ORDER) grid.appendChild(renderChannelChip(key, channels[key]));
    cur.sec.appendChild(grid);
  }
  body.appendChild(cur.sec);

  // ----- barra de acoes de rodada -----
  {
    const isRunning = runStatus === "running";
    const skipPending = !!(status && status.skipPending);
    const bar = el("div", "run-action-bar");
    const btnRun = document.createElement("button");
    btnRun.className = "run-action-btn" + (isRunning ? " disabled" : "");
    btnRun.textContent = isRunning ? "▶ em execução…" : "▶ rodar agora";
    btnRun.disabled = isRunning;
    if (!isRunning) btnRun.addEventListener("click", runNow);
    const btnSkip = document.createElement("button");
    btnSkip.className = "run-action-btn" + (skipPending ? " skip-active" : "");
    btnSkip.textContent = skipPending ? "⊘ pular ativo  ×" : "⊘ pular próxima";
    btnSkip.addEventListener("click", toggleSkip);
    bar.appendChild(btnRun);
    bar.appendChild(btnSkip);
    body.appendChild(bar);
  }

  // ----- laya -----
  const laya = status && status.laya;
  if (laya) {
    const s = healthSection("Laya (filtro)");
    s.head.appendChild(el("span", "run-badge " + (laya.available ? "done" : "pending"), laya.available ? "ativo" : "off"));
    if (laya.available) {
      const g = el("div", "laya-grid");
      g.appendChild(layaStat(laya.filteredChats, "chats filtrados"));
      g.appendChild(layaStat(laya.filteredChunks, "chunks filtrados"));
      g.appendChild(layaStat(laya.qwenInputSavedPct != null ? laya.qwenInputSavedPct + "%" : "—", "input Qwen evitado"));
      s.sec.appendChild(g);
    } else {
      s.sec.appendChild(el("div", "health-empty", "Filtro Laya indisponível nesta rodada."));
    }
    body.appendChild(s.sec);
  }

  // ----- vigia de reunioes (daemon meeting-watch) -----
  {
    const w = watch || { running: false };
    const s = healthSection("Vigia de reuniões");
    const on = w.running === true;
    s.head.appendChild(el("span", "run-badge " + (on ? "done" : "fail"), on ? "ativo" : "parado"));
    if (!on) {
      s.sec.appendChild(el("div", "health-empty", w.deadReason ? ("Vigia parado — " + w.deadReason) : "Vigia de reuniões não está rodando."));
    } else {
      const STATE_TXT = { idle: "aguardando reunião", gravando: "gravando (whisper)", harvest: "gravando + coletando transcrição nativa" };
      const meta = el("div", "run-meta");
      meta.appendChild(el("span", "run-step", STATE_TXT[w.state] || w.state || "—"));
      if (w.teamsCdp) meta.appendChild(el("span", "run-when", "Teams nativo: ligado"));
      if (w.state === "harvest" && typeof w.harvestCount === "number") meta.appendChild(el("span", "run-when", w.harvestCount + " falas coletadas"));
      if (w.updatedAt) meta.appendChild(el("span", "run-when", "atual. " + fmtClock(w.updatedAt)));
      s.sec.appendChild(meta);
      if (w.lastMeeting && w.lastMeeting.label) {
        const src = w.lastMeeting.source === "teams-native" ? "transcrição nativa" : "whisper";
        const sub = el("div", "ch-sub", "última: " + w.lastMeeting.label + " · " + src + (w.lastMeeting.at ? " · " + fmtClock(w.lastMeeting.at) : ""));
        s.sec.appendChild(sub);
      }
    }
    body.appendChild(s.sec);
  }

  // ----- ultimas rodadas -----
  const hs = healthSection("Últimas rodadas", history.length);
  if (!history.length) {
    hs.sec.appendChild(el("div", "health-empty", "Sem histórico de rodadas."));
  } else {
    const list = el("div", "hist-list");
    for (const run of history.slice().reverse()) list.appendChild(renderHistRow(run));
    hs.sec.appendChild(list);
  }
  body.appendChild(hs.sec);

  // ----- fila de trabalho pesado -----
  const items = (heavy && heavy.items) || [];
  const hq = healthSection("Fila de trabalho pesado", items.length);
  if (!items.length) {
    hq.sec.appendChild(el("div", "health-empty", "Nada pesado na fila. 👍"));
  } else {
    const list = el("div", "heavy-list");
    for (const it of items) list.appendChild(renderHeavyItem(it));
    hq.sec.appendChild(list);
  }
  body.appendChild(hq.sec);
}

function openHealth() {
  HEALTH.open = true;
  $("#health-panel").hidden = false;
  loadHealth();
  if (HEALTH.poll) clearInterval(HEALTH.poll);
  HEALTH.poll = setInterval(() => { if (HEALTH.open) loadHealth(); }, 5000);
}
function closeHealth() {
  HEALTH.open = false;
  $("#health-panel").hidden = true;
  if (HEALTH.poll) { clearInterval(HEALTH.poll); HEALTH.poll = null; }
}

// ---------- wire up ----------
$("#search").addEventListener("input", e => { STATE.search = e.target.value.trim(); render(); });
$("#show-done").addEventListener("change", e => { STATE.showDone = e.target.checked; render(); });
$("#refresh").addEventListener("click", load);

// filtro rapido "novos": clica no stat -> mostra so os criados hoje; clica de novo limpa.
const novosWrap = $("#stat-novos-wrap");
const toggleNovos = () => {
  if (STATE.filter && STATE.filter.novo) { clearFilter(); return; }
  if (novosWrap && novosWrap.classList.contains("empty")) return;  // sem novos: nada a filtrar
  applyFilter({ novo: true, resumo: "novos de hoje" });
};
if (novosWrap) {
  novosWrap.addEventListener("click", toggleNovos);
  novosWrap.addEventListener("keydown", e => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggleNovos(); }
  });
}

// filtro rapido "hoje": clica no stat -> mostra so os cards com PRAZO para hoje
// (dueDate == hoje); clica de novo limpa. Nao confundir com "novos" (criados hoje).
const hojeWrap = $("#stat-hoje-wrap");
const toggleHoje = () => {
  if (STATE.filter && STATE.filter.prazo === "hoje") { clearFilter(); return; }
  if (hojeWrap && hojeWrap.classList.contains("empty")) return;  // nada com prazo hoje
  applyFilter({ prazo: "hoje", resumo: "prazo para hoje" });
};
if (hojeWrap) {
  hojeWrap.addEventListener("click", toggleHoje);
  hojeWrap.addEventListener("keydown", e => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggleHoje(); }
  });
}
$("#expand-all").addEventListener("click", toggleExpandAll);
$("#sort-prio").addEventListener("click", () => setSort("prio"));
$("#sort-date").addEventListener("click", () => setSort("data"));

// nova tarefa manual
$("#new-task").addEventListener("click", openModal);
$("#modal-close").addEventListener("click", closeModal);
$("#modal-cancel").addEventListener("click", closeModal);
$("#modal-backdrop").addEventListener("click", e => { if (e.target.id === "modal-backdrop") closeModal(); });
document.addEventListener("keydown", e => {
  if (e.key !== "Escape") return;
  if (!$("#modal-backdrop").hidden) closeModal();
  else if (AGENT.open) closeAgent();
  else if (HEALTH.open) closeHealth();
});

// painel de saude / rodada
$("#health-toggle").addEventListener("click", () => HEALTH.open ? closeHealth() : openHealth());
$("#health-close").addEventListener("click", closeHealth);
$("#health-refresh").addEventListener("click", loadHealth);

// agente
$("#agent-toggle").addEventListener("click", () => AGENT.open ? closeAgent() : openAgent());
$("#agent-close").addEventListener("click", closeAgent);
$("#agent-clear").addEventListener("click", clearAgent);
$("#tgt-local").addEventListener("click", () => setAgentTarget("local"));
$("#tgt-joule").addEventListener("click", () => setAgentTarget("joule"));
$("#agent-send").addEventListener("click", agentSend);
$("#agent-input").addEventListener("input", autosizeAgent);
$("#agent-input").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); agentSend(); }
});
$("#task-form").addEventListener("submit", async e => {
  e.preventDefault();
  const payload = {
    assunto: $("#f-assunto").value.trim(),
    pessoa: $("#f-pessoa").value.trim(),
    status: $("#f-status").value,
    prioridade: $("#f-prioridade").value,
    dueDate: $("#f-due").value || "",
    proxima_acao: $("#f-acao").value.trim(),
    notas: $("#f-notas").value.trim(),
  };
  if (!payload.assunto) { toast("Escreva o assunto"); return; }
  if (await createTask(payload)) closeModal();
});

tickClock();
setInterval(tickClock, 10000);
setAgentTarget(AGENT.target); // sincroniza toggle/placeholder com o alvo padrao (Joule)
// sincroniza o toggle de ordenacao com o modo persistido antes do 1o render
$("#sort-prio").classList.toggle("active", STATE.sort === "prio");
$("#sort-date").classList.toggle("active", STATE.sort === "data");
load();

// auto-refresh 1 min — mas NAO enquanto o usuario mexe: se ha um campo em foco
// (digitando notas, prazo, busca, modal, agente) o render() fecharia o card aberto
// e descartaria texto ainda nao salvo. Nesses casos pula o tick.
function autoRefresh() {
  const a = document.activeElement;
  if (a && /^(TEXTAREA|INPUT|SELECT)$/.test(a.tagName)) return;
  if (!$("#modal-backdrop").hidden) return;
  if (AGENT.open || AGENT.busy) return;
  load();
}
setInterval(autoRefresh, 60000);

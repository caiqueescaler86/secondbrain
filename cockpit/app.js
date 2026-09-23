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

let STATE = { tasks: [], search: "", showRef: false, showDone: false, open: new Set(), filter: null, sig: "", sort: (localStorage.getItem("sb-sort") === "data" ? "data" : "prio") };

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
const todayStr = () => new Date().toISOString().slice(0, 10);

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
    // Com filtro do agente ativo: ignora o gate de referencia/baixa (mostra o
    // que casar, mesmo referencia) e aplica o filtro estruturado.
    if (!matchFilter(task, f)) return false;
  } else {
    const offBoard = task.board && task.board !== "active";
    const isLow = offBoard || task.categoria === "referencia" || task.prioridade === "baixa";
    if (isLow && !STATE.showRef) return false;
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

  const top = el("div", "card-top");
  // Concluir em 1 clique, sem precisar expandir o card (parte externa).
  const quick = el("button", "card-check" + (task.done ? " on" : ""), "✓");
  quick.title = task.done ? "Reabrir (1 clique)" : "Concluir (1 clique)";
  quick.setAttribute("aria-label", quick.title);
  quick.addEventListener("click", e => { e.stopPropagation(); if (!task.done) celebrate(e.clientX, e.clientY); patch(task.sbid, { done: !task.done }); });
  top.appendChild(quick);
  top.appendChild(el("span", "badge st-" + (task.status || "x"), PREFIX[task.status] || task.status || "•"));
  if (task.prioridade) top.appendChild(el("span", "badge " + task.prioridade, task.prioridade));
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
    if (isOpen) STATE.open.add(task.sbid); else STATE.open.delete(task.sbid);
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

// Roteamento: comandos de filtro/limpar/duplicados vs pergunta normal.
const RE_CLEAR = /^\s*(limpa|limpar|tira\w*\s+o?\s*filtro|remove\w*\s+o?\s*filtro|mostrar?\s+tudo|tudo\s+de\s+novo|ver\s+tudo)/i;
const RE_DUPE  = /(duplicad|repetid|poss[íi]ve\w*\s+duplicad|tem\s+repetido|duplicat|iguais)/i;
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

  if (RE_FILTER.test(q)) askFilter(q, bubble);
  else if (AGENT.target === "joule") askJoule(q, bubble);
  else askLocal(q, bubble);
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

async function filterViaLocal(q) {
  const ctrl = new AbortController(); AGENT.ctrl = ctrl;
  try {
    const res = await fetch(LLAMA + "/v1/chat/completions", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "qwen-coder-local", stream: false, temperature: 0, max_tokens: 300,
        response_format: { type: "json_object" },
        messages: [{ role: "user", content: buildFilterPrompt(q) }],
      }),
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const j = await res.json();
    return j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
  } finally { AGENT.ctrl = null; }
}

function filterViaJoule(q) {
  return new Promise((resolve, reject) => {
    fetch("/api/joule", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: buildFilterPrompt(q) }),
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
    raw = (AGENT.target === "joule") ? await filterViaJoule(q) : await filterViaLocal(q);
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

// ---------- wire up ----------
$("#search").addEventListener("input", e => { STATE.search = e.target.value.trim(); render(); });
$("#show-ref").addEventListener("change", e => { STATE.showRef = e.target.checked; render(); });
$("#show-done").addEventListener("change", e => { STATE.showDone = e.target.checked; render(); });
$("#refresh").addEventListener("click", load);
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
});

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

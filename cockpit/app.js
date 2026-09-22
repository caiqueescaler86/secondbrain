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
  // Concluir em 1 clique, sem precisar expandir o card (parte externa).
  const quick = el("button", "card-check" + (task.done ? " on" : ""), "✓");
  quick.title = task.done ? "Reabrir (1 clique)" : "Concluir (1 clique)";
  quick.setAttribute("aria-label", quick.title);
  quick.addEventListener("click", e => { e.stopPropagation(); patch(task.sbid, { done: !task.done }); });
  top.appendChild(quick);
  top.appendChild(el("span", "badge st-" + (task.status || "x"), PREFIX[task.status] || task.status || "•"));
  if (task.prioridade) top.appendChild(el("span", "badge " + task.prioridade, task.prioridade));

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

function agentSend() {
  if (AGENT.busy) return;
  const inp = $("#agent-input");
  const q = inp.value.trim();
  if (!q) return;
  const hint = $("#agent-hint"); if (hint) hint.remove();
  addAgentBubble("user").textContent = q;
  inp.value = ""; autosizeAgent();
  const bubble = addAgentBubble("assistant");
  bubble.classList.add("typing");
  scrollAgentLog();
  setAgentBusy(true);
  if (AGENT.target === "joule") askJoule(q, bubble);
  else askLocal(q, bubble);
}

// ---------- wire up ----------
$("#search").addEventListener("input", e => { STATE.search = e.target.value.trim(); render(); });
$("#show-ref").addEventListener("change", e => { STATE.showRef = e.target.checked; render(); });
$("#show-done").addEventListener("change", e => { STATE.showDone = e.target.checked; render(); });
$("#refresh").addEventListener("click", load);

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
load();
setInterval(load, 60000); // auto-refresh 1 min

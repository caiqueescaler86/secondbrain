param(
    [int]$Port      = 9224,
    [int]$Days      = 2,
    [int]$MaxChats  = 200,
    [int]$MaxAudiosPerChat = 40,
    [string]$FirefoxExe     = "C:\Program Files\Mozilla Firefox\firefox.exe",
    [string]$FirefoxProfile = "C:\Users\I827769\AppData\Roaming\Mozilla\Firefox\Profiles\qyl4c5lr.default-release"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# SECONDBRAIN - WHATSAPP AUDIO EXTRACTOR (best-effort)
#
# Puxa os BYTES das notas de voz do WhatsApp Web e grava .ogg + sidecar .json
# em WhatsApp\audio-inbox\, pra o whatsapp-transcribe.ps1 transcrever depois.
#
# Reusa o MESMO padrao BiDi do whatsapp-collector.ps1 (Firefox, porta 9224).
# NAO modifica o collector. Roda DEPOIS dele, com o Firefox ainda no WhatsApp Web.
#
# Extracao silenciosa: Setup-SilentPlay hookea HTMLAudioElement.prototype.play
# para silenciar antes de chamar o original. O WhatsApp ainda baixa e descriptografa
# o audio (o CDN usa E2E — rede nao serve), o Setup-BlobCapture captura o blob
# resultante, e nos buscamos os bytes. Nao sai som pelas caixas/fone.
# Fallback: se o hook nao instalar, o fluxo de clique continua normalmente
# (audio pode tocar, mas a extracao ainda funciona).
# Tudo local.
# ============================================================

$BaseDir    = Join-Path $env:USERPROFILE "Documents\Joule\SecondBrain\WhatsApp"
$InboxDir   = Join-Path $BaseDir "audio-inbox"
$AudioState = Join-Path $BaseDir "whatsapp-audio-state.json"
# CORRECAO 3: checkpoint de recovery em arquivo SEPARADO. O whatsapp-audio-state.json
# e do transcritor (Save-AudioState o regrava a cada audio). Aqui NUNCA escrevemos
# nele; so LEMOS (via Load-ProcessedAudios) para dedup. O status da varredura de
# recovery mora aqui:
$AudioRecoveryState = Join-Path $BaseDir "whatsapp-audio-recovery-state.json"
New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null

$script:ws = $null
$script:context = $null
$script:nextId = 1
$script:sessionCreated = $false

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

# ---- BiDi (copiado do collector, sem alteracao de comportamento) -------------
function Test-Port {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $a = $c.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(800)) { $c.Close(); return $false }
        $c.EndConnect($a); $c.Close(); return $true
    } catch { if ($c) { try { $c.Close() } catch {} }; return $false }
}

# Reinicia o Firefox pra liberar a sessao BiDi orfã. Necessario porque, uma vez que
# o WS cai, o Firefox NAO libera a sessao e NAO deixa outro WS reusa-la -> session.new
# fica travado em "Maximum active sessions". Matar+reabrir zera as sessoes (0 ativas).
# Seguro na rodada: audio e o ULTIMO passo do WhatsApp; nada depois usa o Firefox.
function Restart-Firefox {
    Log "Reiniciando o Firefox para liberar a sessao BiDi..." Yellow
    try { Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    Start-Sleep -Seconds 2
    if (-not (Test-Path $FirefoxExe)) { throw "firefox.exe nao encontrado em $FirefoxExe (nao consigo reiniciar)." }
    Start-Process -FilePath $FirefoxExe -ArgumentList @(
        "-no-remote","-profile",$FirefoxProfile,
        "--remote-debugging-port=$Port","https://web.whatsapp.com/"
    )
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Port) { break }
        Start-Sleep -Milliseconds 800
    }
    if (-not (Test-Port)) { throw "BiDi nao voltou apos reiniciar o Firefox (porta $Port)." }
    Start-Sleep -Seconds 8   # deixa o WhatsApp Web comecar a carregar (Wait-Ready cuida do resto)
}

function Receive-WS([int]$Timeout = 30) {
    $buffer = New-Object byte[] 1048576
    $stream = New-Object System.IO.MemoryStream
    try {
        do {
            # Usa Task.Wait com timeout em vez de CancellationToken para ReceiveAsync.
            # Motivo: CancellationToken no ReceiveAsync coloca o WS em estado Aborted,
            # impedindo session.end posterior e vazando a sessao no Firefox.
            # Com Task.Wait, o WS permanece Open apos um timeout.
            $receiveTask = $script:ws.ReceiveAsync(
                [ArraySegment[byte]]::new($buffer),
                [System.Threading.CancellationToken]::None
            )
            if (-not $receiveTask.Wait($Timeout * 1000)) {
                # Timeout sem abortar o WS: envia Close frame para que o Firefox
                # encerre a sessao ao receber o fechamento do transport.
                try {
                    $script:ws.CloseOutputAsync(
                        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                        "Timeout",
                        [System.Threading.CancellationToken]::None
                    ).Wait(3000) | Out-Null
                } catch {}
                throw "Receive-WS timeout (${Timeout}s)"
            }
            $r = $receiveTask.GetAwaiter().GetResult()
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw "WebSocket fechado." }
            $stream.Write($buffer, 0, $r.Count)
        } while (-not $r.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($stream.ToArray())
    } finally { $stream.Dispose() }
}

function Bidi([string]$Method, [hashtable]$Params = @{}, [int]$Timeout = 30) {
    $id = $script:nextId; $script:nextId++
    $obj = @{ id=$id; method=$Method; params=$Params } | ConvertTo-Json -Compress -Depth 50
    $bytes = [Text.Encoding]::UTF8.GetBytes($obj)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([TimeSpan]::FromSeconds(10))
    try {
        $script:ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null
    } finally { $cts.Dispose() }
    while ($true) {
        $raw = Receive-WS $Timeout
        try { $m = $raw | ConvertFrom-Json } catch { continue }
        if ($m.id -ne $id) { continue }
        if ($m.type -eq "error") { throw "$($m.error): $($m.message)" }
        return $m
    }
}

function Close-Bidi {
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        # Tenta session.end sempre que o WS estiver aberto, mesmo que sessionCreated=false.
        # Motivo: se session.new foi enviado mas o Receive-WS fez timeout antes de ler
        # a resposta, o Firefox criou a sessao mas nosso flag ficou false. Sem o session.end
        # a sessao fica vazada no Firefox (impede novas sessoes). Enviar session.end e seguro
        # mesmo sem sessao ativa (Firefox retorna erro que suprimimos no catch).
        try {
            # Drena qualquer mensagem pendente no buffer (ex.: resposta tardia de session.new)
            # antes de enviar session.end, para evitar mistura de respostas.
            Bidi "session.end" @{} 6 | Out-Null
        } catch {}
    }
    if ($script:ws) { try { $script:ws.Dispose() } catch {} }
    $script:ws = $null; $script:context = $null; $script:sessionCreated = $false
}

function Connect-Bidi {
    # ATENCAO: nao reinicia o Firefox. Espera que o collector ja tenha aberto a
    # sessao. Se a porta nao estiver no ar, aborta (o audio e best-effort).
    Close-Bidi
    if (-not (Test-Port)) { throw "Firefox/BiDi nao esta no ar na porta $Port (rode o collector antes)." }

    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([TimeSpan]::FromSeconds(15))
    try {
        $script:ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port/session", $cts.Token).GetAwaiter().GetResult() | Out-Null
    } finally { $cts.Dispose() }

    # Cria a sessao BiDi. O Firefox so aceita 1 sessao ativa e NAO libera a anterior
    # quando o WS cai (comprovado: session.new segue bloqueado e getTree nao reusa a
    # orfã de outro WS). Por isso a recuperacao real e reiniciar o Firefox -- feita
    # pelo loop externo (Restart-Firefox) antes de reconectar. Aqui so criamos; se
    # ainda houver orfã, propaga o erro pro loop externo reiniciar o Firefox.
    Bidi "session.new" @{ capabilities=@{ alwaysMatch=@{} } } 15 | Out-Null
    $script:sessionCreated = $true

    for ($t = 0; $t -lt 15; $t++) {
        $tree = Bidi "browsingContext.getTree" @{} 15
        foreach ($c in $tree.result.contexts) {
            if ([string]$c.url -like "*web.whatsapp.com*") { $script:context = [string]$c.context; break }
        }
        if ($script:context) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $script:context) { throw "Aba do WhatsApp nao encontrada." }
    Log "Firefox BiDi conectado (audio)." Green
}

function JS([string]$Expression, [int]$Timeout = 15) {
    $r = Bidi "script.evaluate" @{ expression=$Expression; target=@{ context=$script:context }; awaitPromise=$false } $Timeout
    $v = $r.result.result
    if ($v.type -eq "string") { return [string]$v.value }
    if ($v.type -eq "number" -or $v.type -eq "boolean") { return $v.value }
    return $null
}

function JSJson([string]$Expression, [int]$Timeout = 15) {
    $raw = JS $Expression $Timeout
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return $null }
    return $raw | ConvertFrom-Json
}

# Eval ASSINCRONO: o JS do collector usa awaitPromise=$false e so devolve
# primitivos. Pra puxar o blob (fetch async) precisamos aguardar a Promise e
# receber uma string (base64). Receive-WS ja remonta payloads grandes.
function JSAsync([string]$Expression, [int]$Timeout = 60) {
    $r = Bidi "script.evaluate" @{ expression=$Expression; target=@{ context=$script:context }; awaitPromise=$true } $Timeout
    $v = $r.result.result
    if ($v.type -eq "string") { return [string]$v.value }
    return $null
}

# ---- Helpers de negocio ------------------------------------------------------
function SHA256-Text([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-","").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Load-ProcessedAudios {
    $set = @{}
    if (Test-Path $AudioState) {
        try {
            $j = Get-Content $AudioState -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.processed) { foreach ($p in $j.processed.PSObject.Properties) { $set[$p.Name] = $true } }
        } catch {}
    }
    # tambem considera OGGs ja no inbox (por nome = hash)
    Get-ChildItem -Path $InboxDir -File -Filter "*.ogg" -ErrorAction SilentlyContinue | ForEach-Object {
        $set[[IO.Path]::GetFileNameWithoutExtension($_.Name)] = $true
    }
    return $set
}

function Parse-MetaDate([string]$Meta) {
    if ([string]::IsNullOrWhiteSpace($Meta)) { return $null }
    if ($Meta -match '\[(\d{1,2}):(\d{2}),\s*(\d{1,2})/(\d{1,2})/(\d{2,4})\]') {
        $hh=[int]$matches[1]; $mm=[int]$matches[2]; $dd=[int]$matches[3]; $mo=[int]$matches[4]; $yy=[int]$matches[5]
        if ($yy -lt 100) { $yy += 2000 }
        try { return Get-Date -Year $yy -Month $mo -Day $dd -Hour $hh -Minute $mm -Second 0 } catch { return $null }
    }
    return $null
}

function Parse-MetaAuthor([string]$Meta) {
    if ([string]::IsNullOrWhiteSpace($Meta)) { return "" }
    if ($Meta -match '\]\s*(.+?)\s*:\s*$') { return ($matches[1]).Trim() }
    return ""
}

# --- reuso: navegacao (versoes enxutas do collector) ---
function Wait-Ready {
    $until = (Get-Date).AddSeconds(60)
    $code = @'
(() => JSON.stringify({pane:!!document.querySelector("#pane-side"),list:!!document.querySelector('[data-testid="chat-list"]'),titles:document.querySelectorAll('#pane-side [data-testid="cell-frame-title"]').length}))()
'@
    while ((Get-Date) -lt $until) {
        try { $s = JSJson $code 8; if ($s.pane -and $s.list -and [int]$s.titles -gt 0) { return } } catch {}
        Start-Sleep -Milliseconds 400
    }
    throw "WhatsApp nao ficou pronto."
}

function Reset-SidebarTop {
    $code = @'
(() => { const pane=document.querySelector("#pane-side"); if(!pane) return "false";
 const all=[pane,...pane.querySelectorAll("div")]; let s=null,best=0;
 for(const e of all){const d=e.scrollHeight-e.clientHeight; if(d>best&&e.clientHeight>200){best=d;s=e;}}
 if(!s) return "false"; s.scrollTop=0; s.dispatchEvent(new Event("scroll",{bubbles:true})); return "true"; })()
'@
    JS $code 8 | Out-Null; Start-Sleep -Milliseconds 250
}

function Get-VisibleChats {
    $code = @'
(() => {
 const clean=v=>(v||"").replace(/[‎‏‪-‮]/g,"").replace(/\s+/g," ").trim();
 const strip=v=>clean(v).replace(/^\d+\s+mensagens?\s+n[aã]o\s+lidas?\s*/i,"").replace(/^n[aã]o\s+lida\s+/i,"").trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return "[]";
 const out=[];
 for(const row of list.querySelectorAll('div[role="row"]')){
   const titleEl=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]');
   const name=titleEl?strip(titleEl.getAttribute("title")):""; if(!name) continue;
   out.push({name});
 }
 return JSON.stringify(out);
})()
'@
    # No Windows PowerShell 5.1, @(JSJson ...) inline aninha o [Object[]] do
    # ConvertFrom-Json (vira 1 item contendo o array). Usar variavel intermediaria.
    $rows = JSJson $code 10
    return @($rows)
}

function Scroll-Sidebar {
    $code = @'
(() => { const pane=document.querySelector("#pane-side"); if(!pane) return JSON.stringify({moved:false});
 const all=[pane,...pane.querySelectorAll("div")]; let s=null,best=0;
 for(const e of all){const d=e.scrollHeight-e.clientHeight; if(d>best&&e.clientHeight>200){best=d;s=e;}}
 if(!s) return JSON.stringify({moved:false});
 const before=s.scrollTop; s.scrollTop=Math.min(s.scrollTop+Math.max(450,s.clientHeight*.75),s.scrollHeight);
 s.dispatchEvent(new Event("scroll",{bubbles:true}));
 return JSON.stringify({moved:s.scrollTop!==before}); })()
'@
    return JSJson $code 8
}

function Click-Point([int]$X, [int]$Y) {
    $actions = @(@{ type="pointer"; id="mouse1"; parameters=@{ pointerType="mouse" }
        actions=@(
            @{ type="pointerMove"; x=$X; y=$Y; origin="viewport" },
            @{ type="pointerDown"; button=0 },
            @{ type="pointerUp";   button=0 }
        ) })
    Bidi "input.performActions" @{ context=$script:context; actions=$actions } 15 | Out-Null
}

function Click-Chat([string]$ChatName) {
    $safe = $ChatName | ConvertTo-Json -Compress
    $code = @"
(() => {
 const wanted=$safe;
 const clean=v=>(v||"").replace(/[‎‏‪-‮]/g,"").replace(/\s+/g," ").trim();
 const strip=v=>clean(v).replace(/^\d+\s+mensagens?\s+n[aã]o\s+lidas?\s*/i,"").replace(/^n[aã]o\s+lida\s+/i,"").trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return JSON.stringify({ok:false});
 for(const row of list.querySelectorAll('div[role="row"]')){
   const titleEl=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]');
   const name=titleEl?strip(titleEl.getAttribute("title")):""; if(name!==wanted) continue;
   const target=row.querySelector('[role="gridcell"]')||row.querySelector('[data-testid="cell-frame-container"]')||row;
   target.scrollIntoView({block:"center"});
   const r=target.getBoundingClientRect();
   return JSON.stringify({ok:true,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)});
 }
 return JSON.stringify({ok:false});
})()
"@
    $found = JSJson $code 8
    if (-not $found -or -not $found.ok) { return $false }
    try { Click-Point ([int]$found.x) ([int]$found.y); return $true } catch { return $false }
}

# Localiza as notas de voz visiveis no #main.
# Estrategia dupla:
#   1) Procura <audio> em todo o document (WA pode criar fora do #main).
#   2) Se nenhum <audio>, procura botoes play / icones audio-play em #main
#      (WA nao renderiza <audio> antes do play; o botao indica a nota de voz).
# Retorna: indice, meta, coords do botao play, hasSrc.
function Find-Audios {
    $code = @'
(() => {
 const clean=v=>(v||"").replace(/[‎‏‪-‮]/g,"").replace(/\s+/g," ").trim();
 const main=document.querySelector("#main"); if(!main) return "[]";
 const out=[];
 const seen=new Set();

 function getMeta(el){
   let meta="", node=el;
   for(let k=0;node&&k<20;k++,node=node.parentElement){
     if(node.getAttribute&&node.getAttribute("data-pre-plain-text")){meta=node.getAttribute("data-pre-plain-text");break;}
     const mp=node.querySelector?node.querySelector("[data-pre-plain-text]"):null;
     if(mp){meta=mp.getAttribute("data-pre-plain-text");break;}
   }
   return clean(meta);
 }

 function addEntry(clickTarget, meta, hasSrc){
   const r=clickTarget.getBoundingClientRect();
   if(r.width===0&&r.height===0) return; // fora da viewport (virtualized)
   const key=Math.round(r.left)+","+Math.round(r.top);
   if(seen.has(key)) return;
   seen.add(key);
   out.push({i:out.length, meta, hasSrc, x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
 }

 // === Estrategia 1: <audio> elements em todo o documento ===
 const allAudios=[...document.querySelectorAll('audio')];
 allAudios.forEach(au=>{
   const hasSrc=!!(au.currentSrc||au.src);
   // botao de play proximo ao audio
   const row=au.closest('[role="row"]')||au.closest('[data-testid="msg-container"]')||au.parentElement;
   let btn=null;
   if(row){ btn=row.querySelector('button[aria-label],span[data-icon="audio-play"],span[data-icon="audio-pause"]')||row.querySelector('button'); }
   const target=btn||au;
   const meta=getMeta(au);
   addEntry(target, meta, hasSrc);
 });

 // === Estrategia 2: botoes/icones de play no #main (quando nao ha <audio>) ===
 // WA usa span[data-icon="audio-play"] dentro de um button para cada nota de voz.
 const playSelectors=[
   'span[data-icon="audio-play"]',
   'span[data-icon="audio-pause"]',
   'span[data-icon="ptt-play"]',
   'span[data-icon="ptt-stop"]',
   'button[aria-label*="Reproduzir" i]',
   'button[aria-label*="Play" i]',
   '[data-testid="ptt-play-stop-btn"]',
   '[data-testid="audio-play-stop-btn"]'
 ].join(',');
 [...main.querySelectorAll(playSelectors)].forEach(el=>{
   // sobe ate o botao clicavel
   const btn=el.closest('button')||el.closest('[role="button"]')||el.parentElement;
   const container=el.closest('[data-testid="msg-container"]')||el.closest('[role="row"]')||el.parentElement;
   // verifica se ja ha audio carregado neste container
   const containerAudio=container?container.querySelector("audio"):null;
   const hasSrc=containerAudio?!!(containerAudio.currentSrc||containerAudio.src):false;
   const meta=getMeta(el);
   addEntry(btn, meta, hasSrc);
 });

 return JSON.stringify(out);
})()
'@
    # Mesmo workaround do Get-VisibleChats: variavel intermediaria evita o
    # array-in-array do PS5.1 ao usar @(JSJson ...) inline.
    $rows = JSJson $code 10
    return @($rows)
}

# --- Scroll de recovery (mesma deteccao robusta do collector/probe6) ---------
# Diferente do collector, o audio NAO salta para scrollTop=0: sobe em PASSOS
# (~85% da altura visivel, com sobreposicao) para cada nota de voz passar pela
# viewport e o blob poder ser adquirido. Ver whatsapp-scroll-top-detection.
function Measure-AudioScroll {
    $code = @'
(() => {
 const clean=v=>(v||"").replace(/[‎‏‪-‮]/g,"").replace(/\s+/g," ").trim();
 const main=document.querySelector("#main"); if(!main) return JSON.stringify({ok:false});
 let sc=null,best=0; for(const e of main.querySelectorAll("div")){ const d=e.scrollHeight-e.clientHeight; if(d>best && e.clientHeight>200){best=d;sc=e;} }
 const metas=[...main.querySelectorAll("[data-pre-plain-text]")];
 const oldest = metas.length? clean(metas[0].getAttribute("data-pre-plain-text")) : "";
 const spin = main.querySelector('[role="progressbar"], [data-icon="loading"], [aria-busy="true"]');
 return JSON.stringify({ok:true,rendered:metas.length,oldest,
   scrollable:!!sc, scrollTop: sc?Math.round(sc.scrollTop):0, scrollHeight: sc?sc.scrollHeight:0,
   clientHeight: sc?sc.clientHeight:0, overflow: sc?(sc.scrollHeight-sc.clientHeight):0, spinner:!!spin });
})()
'@
    return JSJson $code 10
}

# Sobe UM passo (~85% da viewport). Retorna o novo scrollTop (string) ou marcador.
function Scroll-AudioUpStep {
    $code = @'
(() => { const main=document.querySelector("#main"); if(!main) return "nomain"; let sc=null,best=0; for(const e of main.querySelectorAll("div")){ const d=e.scrollHeight-e.clientHeight; if(d>best && e.clientHeight>200){best=d;sc=e;} } if(!sc) return "noscroller"; const step=Math.max(200,Math.round(sc.clientHeight*0.85)); sc.scrollTop=Math.max(0,sc.scrollTop-step); sc.dispatchEvent(new Event("scroll",{bubbles:true})); return String(Math.round(sc.scrollTop)); })()
'@
    return [string](JS $code 8)
}

function Setup-SilentPlay {
    # Hookea a REPRODUCAO para silenciar ANTES de tocar. O WhatsApp ainda baixa +
    # descriptografa o audio (necessario para o blob ser criado); apenas nao sai som.
    # Idempotente. BLINDADO em 3 frentes para NUNCA vazar som no escritorio:
    #   (1) HTMLMediaElement.prototype.play -> forca muted/volume=0 (cobre <audio> e <video>);
    #   (2) enforcement: remuta todo <audio>/<video> a cada 300ms;
    #   (3) Web Audio: intercepta AudioNode.connect e insere ganho 0 antes do destino
    #       (unico caminho que escaparia do mute de elemento). Silencio garantido.
    # Retorna "installed"/"already"/"" e $script:silentOK indica se o silencio esta ativo.
    $script:silentOK = $false
    try {
        $r = JS @'
(() => {
  if (window._waSilentInstalled) return "already";
  window._waSilentInstalled = true;
  const mute = el => { try { el.muted = true; el.volume = 0; el.defaultMuted = true; } catch(e){} };
  // (1) play() sempre mutado (guarda o original pra restaurar no teardown)
  const proto = (window.HTMLMediaElement && HTMLMediaElement.prototype) || HTMLAudioElement.prototype;
  const origPlay = proto.play;
  window._waMediaProto = proto;
  window._waOrigPlay = origPlay;
  proto.play = function() { mute(this); return origPlay.apply(this, arguments); };
  // (2) enforcement periodico
  const sweep = () => { try { document.querySelectorAll("audio,video").forEach(mute); } catch(e){} };
  sweep();
  window._waSilentSweep = setInterval(sweep, 300);
  // (3) Web Audio: qualquer node que conecte no destino (alto-falante) passa por ganho 0
  try {
    if (window.AudioNode && AudioNode.prototype.connect && !AudioNode.prototype.__waMuted) {
      const origConnect = AudioNode.prototype.connect;
      window._waOrigConnect = origConnect;
      AudioNode.prototype.connect = function(dest) {
        try {
          if (dest && window.AudioDestinationNode && dest instanceof AudioDestinationNode) {
            const g = this.context.createGain(); g.gain.value = 0;
            origConnect.call(this, g);
            return origConnect.call(g, dest);
          }
        } catch(e){}
        return origConnect.apply(this, arguments);
      };
      AudioNode.prototype.__waMuted = true;
    }
  } catch(e){}
  return "installed";
})()
'@ 8
        if ($r -eq "installed" -or $r -eq "already") { $script:silentOK = $true }
    } catch { Log "AVISO: Setup-SilentPlay falhou; NAO vou disparar play (evita vazar som)." Red; $script:silentOK = $false }
    return $script:silentOK
}

# Confere que o silencio ainda esta ativo (o hook e o sweep). Chamado antes de
# CADA disparo de play. Se nao estiver, tenta reinstalar; se falhar, retorna
# $false e o chamador PULA o audio (prefere perder audio a vazar som).
function Assert-Silent {
    try {
        $ok = JS 'window._waSilentInstalled && !!window._waSilentSweep ? "1" : "0"' 5
        if ($ok -eq "1") { return $true }
    } catch {}
    # tenta reinstalar uma vez
    Setup-SilentPlay | Out-Null
    return [bool]$script:silentOK
}

# Remove o mute e restaura o WhatsApp Web ao normal (play/volume/Web Audio).
# CRITICO: PAUSA todos os audios ANTES de desmutar -> nenhum audio que ainda
# esteja tocando (mutado) volta a ter volume e vaza som ao restaurar.
function Teardown-SilentPlay {
    $code = @'
(() => {
  if (!window._waSilentInstalled) return "not-installed";
  // 1) para tudo que estiver tocando, AINDA mutado
  try { document.querySelectorAll("audio,video").forEach(el=>{ try{ el.pause(); el.currentTime=0; }catch(e){} }); } catch(e){}
  // 2) desliga o enforcement
  try { if (window._waSilentSweep) { clearInterval(window._waSilentSweep); window._waSilentSweep=null; } } catch(e){}
  // 3) restaura play() original
  try { if (window._waMediaProto && window._waOrigPlay) { window._waMediaProto.play = window._waOrigPlay; } } catch(e){}
  // 4) restaura Web Audio connect
  try { if (window._waOrigConnect && window.AudioNode) { AudioNode.prototype.connect = window._waOrigConnect; AudioNode.prototype.__waMuted = false; } } catch(e){}
  // 5) agora que esta tudo pausado, desmuta os elementos (volume normal)
  try { document.querySelectorAll("audio,video").forEach(el=>{ try{ el.muted=false; el.defaultMuted=false; el.volume=1; }catch(e){} }); } catch(e){}
  window._waSilentInstalled = false;
  return "restored";
})()
'@
    try {
        $r = JS $code 8
        if ($r -eq "restored") { Log "Mute removido: WhatsApp Web restaurado ao normal." Green; return $true }
        if ($r -eq "not-installed") { return $true }
    } catch {}
    Log "AVISO: nao consegui remover o mute agora (WS fora). Atualizar/reabrir o WhatsApp Web (F5) restaura o som." DarkYellow
    return $false
}

# Instala interceptor de URL.createObjectURL para capturar blob de audio.
# Idempotente: checa window._waBlobCapInstalled antes de instalar.
# O blob URL capturado fica em window._waBlobUrl (string) ou null.
function Setup-BlobCapture {
    JS @'
(() => {
 if(window._waBlobCapInstalled) return "already";
 window._waBlobCapInstalled=true;
 window._waBlobUrl=null;
 const orig=URL.createObjectURL.bind(URL);
 URL.createObjectURL=function(obj){
   const url=orig(obj);
   if(obj instanceof Blob){
     const t=obj.type||"";
     if(t.indexOf("audio")>=0||t.indexOf("ogg")>=0||t.indexOf("opus")>=0||t.indexOf("webm")>=0||t.indexOf("mpeg")>=0||t.indexOf("mp4")>=0||t===""){
       window._waBlobUrl=url;
     }
   }
   return url;
 };
 return "installed";
})()
'@ 8 | Out-Null
}

# Limpa o blob capturado antes de cada clique de play.
function Clear-BlobCapture {
    JS "window._waBlobUrl=null;" 5 | Out-Null
}

# Puxa os bytes do audio como base64.
# Estrategia 1: window._waBlobUrl interceptado via URL.createObjectURL.
# Estrategia 2: <audio> elements em todo o document (fallback).
# Polling de ate 12s em ambas as estrategias.
# Parametro $Index mantido por compatibilidade.
function Get-AudioBase64([int]$Index) {
    $code = @"
(async () => {
 // Polling ate 12s: verifica _waBlobUrl (interceptor) E <audio> no DOM
 for(let poll=0;poll<60;poll++){
   // Estrategia 1: blob URL capturado pelo interceptor
   const capturedUrl=window._waBlobUrl;
   if(capturedUrl&&capturedUrl.startsWith("blob:")){
     try{
       const resp=await fetch(capturedUrl);
       const buf=await resp.arrayBuffer();
       const bytes=new Uint8Array(buf);
       let bin=""; const chunk=0x8000;
       for(let p=0;p<bytes.length;p+=chunk){ bin+=String.fromCharCode.apply(null,bytes.subarray(p,p+chunk)); }
       window._waBlobUrl=null; // consome o blob capturado
       return btoa(bin);
     }catch(e){ window._waBlobUrl=null; }
   }
   // Estrategia 2: <audio> com src no documento
   const allAudios=[...document.querySelectorAll('audio')];
   const withSrc=allAudios.filter(a=>a.currentSrc||a.src);
   if(withSrc.length>0){
     const au=withSrc.find(a=>!a.paused)||withSrc[0];
     const src=au.currentSrc||au.src; if(src){
       try{
         const resp=await fetch(src);
         const buf=await resp.arrayBuffer();
         const bytes=new Uint8Array(buf);
         let bin=""; const chunk=0x8000;
         for(let p=0;p<bytes.length;p+=chunk){ bin+=String.fromCharCode.apply(null,bytes.subarray(p,p+chunk)); }
         try{au.pause();}catch(e){}
         return btoa(bin);
       }catch(e){}
     }
   }
   await new Promise(r=>setTimeout(r,200));
 }
 return ""; // audio nao apareceu em 12s
})()
"@
    return JSAsync $code 90
}

# FALLBACK 2: dispara o play VIA JS (mutado), sem depender do clique confiavel
# na coordenada. Autoplay mutado e permitido pelo browser, entao chamar .play()
# direto num <audio> forca o download/descriptografia do blob mesmo sem gesto do
# usuario e mesmo se o Click-Point tiver errado a coordenada. Estrategias, todas
# mutadas: (a) .click() nativo no botao de play mais proximo de (x,y);
# (b) dispatch de PointerEvents no botao; (c) muted+play() em <audio> proximos.
# Nao garante gesto "trusted" (React pode ignorar (a)/(b)), mas (c) funciona
# quando ha <audio>, e o conjunto cobre mais casos que o clique sozinho.
function Trigger-PlayJS([int]$X, [int]$Y) {
    $code = @"
(() => {
 const tx=$X, ty=$Y;
 const mute=el=>{try{el.muted=true;el.volume=0;el.defaultMuted=true;}catch(e){}};
 const near=el=>{const r=el.getBoundingClientRect(); if(r.width===0&&r.height===0) return 1e9;
   const cx=r.left+r.width/2, cy=r.top+r.height/2; return Math.hypot(cx-tx,cy-ty);};
 const main=document.querySelector("#main")||document;
 // 1) botao de play mais proximo do alvo
 const btnSel='span[data-icon="audio-play"],span[data-icon="ptt-play"],button[aria-label*="Reproduzir" i],button[aria-label*="Play" i],[data-testid="ptt-play-stop-btn"],[data-testid="audio-play-stop-btn"]';
 let best=null, bestD=1e9;
 [...main.querySelectorAll(btnSel)].forEach(el=>{const b=el.closest("button")||el.closest('[role="button"]')||el; const d=near(b); if(d<bestD){bestD=d;best=b;}});
 let acted=0;
 if(best && bestD<400){
   try{ best.click(); acted++; }catch(e){}
   try{
     const r=best.getBoundingClientRect(), cx=r.left+r.width/2, cy=r.top+r.height/2;
     for(const t of ["pointerdown","pointerup","click"]){
       best.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
     }
     acted++;
   }catch(e){}
 }
 // 2) forca muted+play em qualquer <audio> (cria blob mesmo sem gesto)
 [...document.querySelectorAll("audio")].forEach(au=>{ mute(au); try{ au.load&&au.load(); }catch(e){} try{ const p=au.play(); if(p&&p.catch)p.catch(()=>{}); acted++; }catch(e){} });
 return String(acted);
})()
"@
    try { JS $code 8 | Out-Null } catch {}
}

# FALLBACK 3: rola a mensagem de audio pra dentro da viewport do #main, pra o
# clique/coordenada voltar a funcionar em notas que estavam fora da tela.
function ScrollIntoView-Audio([int]$X, [int]$Y) {
    $code = @"
(() => {
 const tx=$X, ty=$Y;
 const main=document.querySelector("#main"); if(!main) return "false";
 const near=el=>{const r=el.getBoundingClientRect(); if(r.width===0&&r.height===0) return 1e9;
   const cx=r.left+r.width/2, cy=r.top+r.height/2; return Math.hypot(cx-tx,cy-ty);};
 const sel='span[data-icon="audio-play"],span[data-icon="ptt-play"],[data-testid="ptt-play-stop-btn"],[data-testid="audio-play-stop-btn"]';
 let best=null,bestD=1e9;
 [...main.querySelectorAll(sel)].forEach(el=>{const d=near(el); if(d<bestD){bestD=d;best=el;}});
 if(best){ best.scrollIntoView({block:"center"}); return "true"; }
 return "false";
})()
"@
    try { JS $code 6 | Out-Null } catch {}
}

# Tenta obter os bytes (base64) de UM audio em CAMADAS de fallback. TODO disparo
# de play e precedido por Assert-Silent: se o silencio nao estiver ativo, NAO
# dispara e retorna "" (prefere perder o audio a vazar som no escritorio).
#   Camada 0: ja tem src -> so busca o blob.
#   Camada 1: clique CONFIAVEL (Click-Point) no botao -> WA baixa/descriptografa.
#   Camada 2: play VIA JS mutado (Trigger-PlayJS) -> nao depende da coordenada.
#   Camada 3: scroll-into-view + clique confiavel de novo (pega fora da viewport).
function Wait-AudioSrc([int]$X, [int]$Y, [int]$MaxMs = 6000) {
    # Espera o <audio> mais proximo de (x,y) ganhar um src valido (blob:),
    # sinalizando que o WhatsApp Web inicializou o elemento. Mensagens antigas
    # precisam desse tempo apos scrollIntoView antes do clique ser util.
    $code = @"
(async()=>{
 const tx=$X, ty=$Y, deadline=Date.now()+$MaxMs;
 const near=el=>{const r=el.getBoundingClientRect();return Math.hypot(r.left+r.width/2-tx,r.top+r.height/2-ty);};
 while(Date.now()<deadline){
   const hits=[...document.querySelectorAll('audio')].filter(a=>near(a)<200);
   if(hits.some(a=>a.currentSrc||a.src)) return true;
   await new Promise(r=>setTimeout(r,300));
 }
 return false;
})()
"@
    try { JSAsync $code (([int]$MaxMs / 1000) + 4) | Out-Null } catch {}
}

function Acquire-Blob($au) {
    # Passo 0: se o elemento esta na viewport mas sem src (blob nao inicializado),
    # faz scrollIntoView + espera ate 6s o WA Web carregar o src. Para mensagens
    # antigas o WA precisa re-requisitar do IndexedDB/servidor apos o elemento
    # entrar na viewport — sem essa espera, as camadas de clique chegam cedo demais.
    if (-not $au.hasSrc) {
        ScrollIntoView-Audio ([int]$au.x) ([int]$au.y)
        Start-Sleep -Milliseconds 800
        Wait-AudioSrc ([int]$au.x) ([int]$au.y) 6000
    }
    # camada 0: blob ja disponivel (hasSrc original ou apos wait acima)
    $b = Get-AudioBase64 ([int]$au.i)
    if (-not [string]::IsNullOrWhiteSpace($b)) { return $b }
    # camadas que DISPARAM play: exigem silencio confirmado
    $layers = @(
        @{ name="clique confiavel"; act={ try { Click-Point ([int]$au.x) ([int]$au.y) } catch {} }; wait=3000 },
        @{ name="play via JS mutado"; act={ Trigger-PlayJS ([int]$au.x) ([int]$au.y) }; wait=2500 },
        @{ name="scroll+clique"; act={ ScrollIntoView-Audio ([int]$au.x) ([int]$au.y); Start-Sleep -Milliseconds 600; try { Click-Point ([int]$au.x) ([int]$au.y) } catch {} }; wait=3000 }
    )
    foreach ($layer in $layers) {
        if (-not (Assert-Silent)) {
            Log "  audio #$($au.i): silencio NAO confirmado -> pulando (nao vou arriscar vazar som)." Red
            return ""
        }
        try { Clear-BlobCapture } catch {}
        & $layer.act
        Start-Sleep -Milliseconds $layer.wait
        $b = Get-AudioBase64 ([int]$au.i)
        if (-not [string]::IsNullOrWhiteSpace($b)) { return $b }
    }
    return ""
}

# ---- RUN ---------------------------------------------------------------------
$cutoff = (Get-Date).AddDays(-$Days)
$done   = Load-ProcessedAudios
$saved  = 0; $skipped = 0; $noblob = 0; $outWin = 0

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "WHATSAPP AUDIO EXTRACTOR (best-effort, silencioso)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$seen         = @{}    # persiste entre reconexoes -> retoma de onde parou
$chatClasses  = @{}    # persiste entre reconexoes -> classe (5 estados) por chat visitado
$sidebarEndedByList = $false   # true so quando a sidebar terminou por fim-de-lista real (nao MaxChats/erro)
$maxReconnect = 8    # o WS do Firefox cai a cada ~90s; cada queda custa 1 reinicio+retomada. Margem p/ varrer a lista toda.
$reconnects   = 0
$completed    = $false

while (-not $completed -and $reconnects -le $maxReconnect) {
    try {
        Connect-Bidi
        Wait-Ready
        # GATE DE SEGURANCA: sem silencio confirmado, aborta esta rodada de audio
        # inteira (nunca dispara play). Melhor perder audios do que vazar som.
        if (-not (Setup-SilentPlay)) { throw "SILENCIO nao instalou; abortando extracao de audio (evita vazar som)." }
        Setup-BlobCapture
        Reset-SidebarTop
        if ($reconnects -gt 0) { Log "Retomando varredura ($($seen.Count) chats ja vistos serao pulados)." Cyan }

        $noMove = 0

        while ($seen.Count -lt $MaxChats) {
            $visible = @(Get-VisibleChats)

            foreach ($item in $visible) {
                $name = ([string]$item.name).Trim()
                if (-not $name) { continue }
                $key = $name.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true

                try {
                    if (-not (Click-Chat $name)) { $chatClasses[$key] = "OPEN_FAIL"; continue }
                    Start-Sleep -Milliseconds 900

                    # RECOVERY POR SCROLL (mesma mecanica do coletor/probe6): sobe o #main
                    # em PASSOS, processando os audios de cada viewport, ate CUTOFF real,
                    # TOPO real ou teto. Cada nota de voz PRECISA passar pela viewport para
                    # o blob ser adquirido -> por isso passos incrementais (nao salto p/ 0).
                    # A aquisicao (Acquire-Blob 0-3), o gate de silencio e o dedup por hash
                    # sao os mesmos de antes; o scroll e adicionado POR CIMA.
                    $chatClass  = "INDETERMINATE"
                    $chatSaved  = 0          # SO saves NOVOS neste chat/rodada -> teto = recovery progressivo
                    $maxSteps   = 45
                    $topStable  = 0
                    $prevHeight = -1
                    $prevOldest = "__init__"
                    Log "[$($seen.Count)] $name : varrendo audios (scroll-up ate cutoff/topo)" Cyan

                    for ($step = 0; $step -lt $maxSteps; $step++) {
                        # 1) processa os audios renderizados nesta viewport
                        $audios = @(Find-Audios)
                        foreach ($au in $audios) {
                            # filtro por data (quando o meta traz a data)
                            $dt = Parse-MetaDate ([string]$au.meta)
                            if ($dt -and $dt -lt $cutoff) { $outWin++; continue }

                            $author = Parse-MetaAuthor ([string]$au.meta)
                            # heuristica de direcao: sem marcador confiavel, assume "in" (recebido)
                            $direction = "in"
                            $preId = SHA256-Text "$name|$([string]$au.meta)|$direction|idx:$($au.i)"

                            # se ja processado (por meta) pula cedo
                            if ($done.ContainsKey($preId)) { $skipped++; continue }

                            $b64 = Acquire-Blob $au
                            if ([string]::IsNullOrWhiteSpace($b64)) {
                                $noblob++
                                Log "  audio #$($au.i): blob nao disponivel apos todos os fallbacks (pulado)" DarkYellow
                                continue
                            }

                            $bytes = [Convert]::FromBase64String($b64)
                            $shaBytes = [Security.Cryptography.SHA256]::Create()
                            $hash = ([BitConverter]::ToString($shaBytes.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
                            $shaBytes.Dispose()

                            # dedup autoritativo por conteudo (cobre reencontro entre viewports
                            # sobrepostos e entre rodadas via .ogg do inbox) -> zero perda/zero dup
                            if ($done.ContainsKey($hash)) { $skipped++; continue }

                            $ogg  = Join-Path $InboxDir "$hash.ogg"
                            [IO.File]::WriteAllBytes($ogg, $bytes)

                            $side = [pscustomobject]@{
                                chat      = $name
                                meta      = [string]$au.meta
                                author    = $author
                                direction = $direction
                                timestamp = $(if ($dt) { $dt.ToString("o") } else { $null })
                                source    = "whatsapp-audio"
                                extractedAt = (Get-Date).ToString("o")
                            }
                            [IO.File]::WriteAllText((Join-Path $InboxDir "$hash.json"), ($side | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)

                            $done[$hash] = $true
                            $done[$preId] = $true
                            $saved++
                            $chatSaved++
                            Log "  salvo audio #$($au.i) ($([math]::Round($bytes.Length/1024,1)) KB)" Green
                        }

                        # 2) mede o estado do scroll (deteccao robusta do probe6)
                        $m = Measure-AudioScroll
                        if (-not $m -or -not $m.ok) { $chatClass = "CDP_ERROR"; break }

                        # 3) CUTOFF real: a mensagem mais antiga renderizada ja passou da janela
                        $oldDt = Parse-MetaDate ([string]$m.oldest)
                        if ($oldDt -and $oldDt -lt $cutoff) { $chatClass = "CUTOFF_REACHED"; break }

                        # 4) CORRECAO 4: teto de saves NOVOS por chat = INCOMPLETO (pode haver
                        #    mais audios na janela nao extraidos). Equivalente a SCROLL_LIMIT ->
                        #    checkpoint de audio NAO avanca -> proxima rodada refaz (dedup pula
                        #    os ja salvos e continua dos proximos = recovery progressivo).
                        if ($chatSaved -ge $MaxAudiosPerChat) { $chatClass = "SCROLL_LIMIT_REACHED"; break }

                        # 5) TOPO real confirmado (probe6): scrollTop fixo <=5 + scrollHeight
                        #    congelado + oldest congelado, 3x seguidas, ciente de spinner
                        $atTopNow     = ([int]$m.scrollTop -le 5)
                        $heightFrozen = ($prevHeight -ge 0 -and [int]$m.scrollHeight -le $prevHeight)
                        $oldestFrozen = ($prevOldest -eq [string]$m.oldest)
                        if ($atTopNow -and $heightFrozen -and $oldestFrozen -and -not $m.spinner) {
                            $topStable++
                            if ($topStable -ge 3) { $chatClass = "HISTORY_TOP_REACHED"; break }
                        } else {
                            $topStable = 0
                        }
                        $prevHeight = [int]$m.scrollHeight
                        $prevOldest = [string]$m.oldest

                        # 6) sobe um passo (~85% da viewport, com sobreposicao)
                        $r = [string](Scroll-AudioUpStep)
                        if ($r -eq "noscroller" -or $r -eq "nomain") {
                            # chat curto: tudo cabe na viewport -> ja processamos tudo
                            $chatClass = "HISTORY_TOP_REACHED"; break
                        }
                        Start-Sleep -Milliseconds 700   # deixa lazy-load + render antes da proxima medicao
                    }
                    if ($chatClass -eq "INDETERMINATE") { $chatClass = "SCROLL_LIMIT_REACHED" }  # estourou maxSteps
                    $chatClasses[$key] = $chatClass
                    Log "  $name -> $chatClass ($chatSaved audio(s) novos)" DarkGray
                }
                catch {
                    # Se o WS morreu, PROPAGA para o loop externo reconectar e retomar
                    # (o $seen preserva o progresso). Outros erros: loga e segue.
                    if (-not $script:ws -or $script:ws.State -notin @(
                            [System.Net.WebSockets.WebSocketState]::Open,
                            [System.Net.WebSockets.WebSocketState]::CloseReceived)) {
                        throw "WS_DOWN"
                    }
                    Log "Falha em ${name}: $($_.Exception.Message)" DarkYellow
                    continue
                }
            }

            # Fim da lista = quando a barra nao rola mais (2x seguidas), nao por
            # estagnacao de novos (apos reconexao o topo esta todo em $seen).
            $move = Scroll-Sidebar
            if (-not $move -or -not $move.moved) { $noMove++ } else { $noMove = 0; Start-Sleep -Milliseconds 220 }
            if ($noMove -ge 2) { $sidebarEndedByList = $true; break }

            # Keep-alive: session.status a cada ~55s evita o Firefox fechar o WS por inatividade.
            if ((-not $script:_lastKA) -or ((Get-Date) - $script:_lastKA).TotalSeconds -gt 55) {
                try { Bidi "session.status" @{} 5 | Out-Null } catch {}
                $script:_lastKA = Get-Date
            }
        }

        $completed = $true
    }
    catch {
        $msg = $_.Exception.Message
        Close-Bidi
        # QUALQUER falha (WS caiu, sessao orfã bloqueando session.new, WhatsApp nao
        # pronto) recupera do mesmo jeito: reinicia o Firefox (unica forma de liberar
        # a sessao BiDi) e RETOMA de onde parou ($seen persiste). Firefox limpo => a
        # proxima Connect-Bidi cria a sessao sem "Maximum active sessions".
        if ($reconnects -lt $maxReconnect) {
            $reconnects++
            Log "Falha ($msg). Reiniciando Firefox e retomando ($reconnects/$maxReconnect)..." Yellow
            try { Restart-Firefox } catch { Log "Restart-Firefox falhou: $($_.Exception.Message)" Red }
            continue
        }
        Log "ERRO: $msg" Red
        break
    }
}

# SEMPRE remove o mute ao terminar (restaura o WhatsApp Web). Se o WS caiu,
# tenta reconectar UMA vez so pra fazer o teardown -- nunca deixa o WhatsApp mudo.
try {
    if (-not $script:ws -or $script:ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        try { Connect-Bidi } catch {}
    }
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and $script:context) {
        Teardown-SilentPlay | Out-Null
    } else {
        Log "AVISO: WS fora no fim; nao deu pra remover o mute via script. Um F5 no WhatsApp Web restaura o som." DarkYellow
    }
} catch {}

Close-Bidi

Write-Host ""
Write-Host ("Audios salvos: $saved | Pulados: $skipped | Fora da janela (-Days $Days): $outWin | Sem blob: $noblob | Reconexoes: $reconnects") -ForegroundColor Green
Write-Host ("Inbox: $InboxDir") -ForegroundColor DarkGray

# ---- CHECKPOINT DE RECOVERY (CORRECAO 3: arquivo SEPARADO) -------------------
# NUNCA escreve no whatsapp-audio-state.json (do transcritor). Este arquivo so
# registra o STATUS honesto da varredura de audio. So marca "avancado" quando a
# varredura foi completa E toda limpa (todo chat em CUTOFF/TOP) E sem cap batido.
# Caso contrario preserva o lastSuccessfulRun anterior -> proxima rodada refaz a
# janela (dedup pula os ja salvos). Espelha o gate do coletor (§11/§14).
try {
    $audioAllClean = $true
    foreach ($k in $chatClasses.Keys) {
        if ($chatClasses[$k] -notin @("CUTOFF_REACHED","HISTORY_TOP_REACHED")) { $audioAllClean = $false; break }
    }
    $audioTraversalComplete = ($sidebarEndedByList -and $completed)
    $canAdvanceAudio = ($audioTraversalComplete -and $audioAllClean -and $seen.Count -gt 0)

    # preserva lastSuccessfulRun anterior quando NAO pode avancar
    $prevLast = $null
    if (Test-Path $AudioRecoveryState) {
        try { $prevLast = (Get-Content $AudioRecoveryState -Raw | ConvertFrom-Json).lastSuccessfulRun } catch {}
    }
    $lastRun = if ($canAdvanceAudio) { (Get-Date).ToString("o") } else { $prevLast }

    $classesObj = [ordered]@{}
    foreach ($k in ($chatClasses.Keys | Sort-Object)) { $classesObj[$k] = $chatClasses[$k] }

    $recovery = [ordered]@{
        version           = 1
        updatedAt         = (Get-Date).ToString("o")
        lastSuccessfulRun = $lastRun
        traversalComplete = $audioTraversalComplete
        allClean          = $audioAllClean
        markAdvanced      = $canAdvanceAudio
        cutoffDays        = $Days
        chatsSeen         = $seen.Count
        reconnects        = $reconnects
        saved             = $saved
        skipped           = $skipped
        noblob            = $noblob
        outWin            = $outWin
        chatClasses       = $classesObj
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($AudioRecoveryState, (($recovery | ConvertTo-Json -Depth 6)), $utf8NoBom)

    if ($canAdvanceAudio) {
        Write-Host ("Recovery de audio COMPLETO (varredura limpa) -> checkpoint avancado.") -ForegroundColor Green
    } else {
        Write-Host ("Recovery de audio INCOMPLETO (traversal=$audioTraversalComplete clean=$audioAllClean) -> checkpoint NAO avancou; proxima rodada refaz a janela.") -ForegroundColor Yellow
    }
} catch {
    Write-Host ("AVISO: falha ao gravar $AudioRecoveryState : $($_.Exception.Message)") -ForegroundColor DarkYellow
}

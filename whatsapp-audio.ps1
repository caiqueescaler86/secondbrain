param(
    [int]$Port      = 9224,
    [int]$Days      = 2,
    [int]$MaxChats  = 200,
    [int]$MaxAudiosPerChat = 40
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

    # session.new cria a sessao BiDi. Deve rodar DEPOIS do collector (que faz Restart-Firefox),
    # pois o Firefox precisa estar com 0 sessoes ativas. Rodar standalone (sem collector antes)
    # falha com "Maximum active sessions" porque alguma sessao anterior ainda esta retida.
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

function Setup-SilentPlay {
    # Hookea HTMLAudioElement.prototype.play para silenciar ANTES de chamar o original.
    # O WhatsApp ainda baixa + descriptografa o audio (necessario para o blob ser criado);
    # apenas nao toca pelas caixas/fone. Idempotente. Fallback: se falhar, segue com som.
    try {
        JS @'
(() => {
  if (window._waSilentInstalled) return "already";
  window._waSilentInstalled = true;
  const orig = HTMLAudioElement.prototype.play;
  HTMLAudioElement.prototype.play = function() {
    try { this.muted = true; this.volume = 0; } catch(e) {}
    return orig.call(this);
  };
  return "installed";
})()
'@ 8 | Out-Null
    } catch { Log "AVISO: Setup-SilentPlay falhou (audio pode tocar); seguindo." DarkYellow }
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

# ---- RUN ---------------------------------------------------------------------
$cutoff = (Get-Date).AddDays(-$Days)
$done   = Load-ProcessedAudios
$saved  = 0; $skipped = 0; $noblob = 0

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "WHATSAPP AUDIO EXTRACTOR (best-effort)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

try {
    Connect-Bidi
    Wait-Ready
    Setup-SilentPlay
    Setup-BlobCapture
    Reset-SidebarTop

    $seen = @{}
    $sidebarDone = $false
    $stagnant = 0

    while (-not $sidebarDone -and $seen.Count -lt $MaxChats) {
        $visible = @(Get-VisibleChats)
        $newVisible = 0

        foreach ($item in $visible) {
            $name = ([string]$item.name).Trim()
            if (-not $name) { continue }
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true; $newVisible++

            try {
                if (-not (Click-Chat $name)) { continue }
                Start-Sleep -Milliseconds 900

                $audios = @(Find-Audios)
                if (-not $audios -or $audios.Count -eq 0) { continue }

                Log "[$($seen.Count)] $name : $($audios.Count) audio(s)" Cyan
                $count = 0

                foreach ($au in $audios) {
                    if ($count -ge $MaxAudiosPerChat) { break }
                    $count++

                    # filtro por data (quando o meta traz a data)
                    $dt = Parse-MetaDate ([string]$au.meta)
                    if ($dt -and $dt -lt $cutoff) { continue }

                    $author = Parse-MetaAuthor ([string]$au.meta)
                    # heuristica de direcao: sem marcador confiavel, assume "in" (recebido)
                    $direction = "in"
                    $preId = SHA256-Text "$name|$([string]$au.meta)|$direction|idx:$($au.i)"

                    # se ja processado (por meta) pula cedo
                    if ($done.ContainsKey($preId)) { $skipped++; continue }

                    # garante blob: se nao tem src, da play (clique confiavel) e espera
                    if (-not $au.hasSrc) {
                        try { Clear-BlobCapture } catch {}
                        try { Click-Point ([int]$au.x) ([int]$au.y) } catch {}
                        Start-Sleep -Milliseconds 2000
                    }

                    $b64 = Get-AudioBase64 ([int]$au.i)
                    if ([string]::IsNullOrWhiteSpace($b64)) {
                        # tenta mais uma vez apos novo play
                        try { Clear-BlobCapture } catch {}
                        try { Click-Point ([int]$au.x) ([int]$au.y) } catch {}
                        Start-Sleep -Milliseconds 1500
                        $b64 = Get-AudioBase64 ([int]$au.i)
                    }
                    if ([string]::IsNullOrWhiteSpace($b64)) {
                        $noblob++
                        Log "  audio #$($au.i): blob nao disponivel (pulado)" DarkYellow
                        continue
                    }

                    $bytes = [Convert]::FromBase64String($b64)
                    $shaBytes = [Security.Cryptography.SHA256]::Create()
                    $hash = ([BitConverter]::ToString($shaBytes.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
                    $shaBytes.Dispose()

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
                    Log "  salvo audio #$($au.i) ($([math]::Round($bytes.Length/1024,1)) KB)" Green
                }
            }
            catch {
                Log "Falha em ${name}: $($_.Exception.Message)" DarkYellow
                # Se o WS morreu (Aborted/Closed), interrompe o loop graciosamente
                # em vez de propagar erro para fora com sessao vazada.
                if (-not $script:ws -or $script:ws.State -notin @(
                        [System.Net.WebSockets.WebSocketState]::Open,
                        [System.Net.WebSockets.WebSocketState]::CloseReceived)) {
                    Log "WebSocket encerrado pelo servidor. Encerrando varredura." Yellow
                    $sidebarDone = $true
                    break
                }
                continue
            }
        }

        if ($newVisible -eq 0) { $stagnant++ } else { $stagnant = 0 }
        $move = Scroll-Sidebar
        if (-not $move -or -not $move.moved -or $stagnant -ge 2) { $sidebarDone = $true }
        else { Start-Sleep -Milliseconds 220 }

        # Keep-alive: envia session.status a cada ~60s para evitar que o Firefox
        # encerre o WebSocket por inatividade (timeout ~1min40s observado).
        if ((-not $script:_lastKA) -or ((Get-Date) - $script:_lastKA).TotalSeconds -gt 55) {
            try { Bidi "session.status" @{} 5 | Out-Null } catch {}
            $script:_lastKA = Get-Date
        }
    }
}
catch {
    Log "ERRO: $($_.Exception.Message)" Red
}
finally {
    Close-Bidi
}

Write-Host ""
Write-Host ("Audios salvos: $saved | Pulados: $skipped | Sem blob: $noblob") -ForegroundColor Green
Write-Host ("Inbox: $InboxDir") -ForegroundColor DarkGray

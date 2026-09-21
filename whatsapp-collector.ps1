param(
    [int]$Port = 9224,
    [int]$BootstrapDays = 90,
    [int]$OverlapHours = 24,
    [int]$MaxChats = 500,
    [int]$MaxScrollsPerChat = 120,
    [switch]$ResetState
)

$ErrorActionPreference = "Stop"

# ============================================================
# SECONDBRAIN - WHATSAPP COLLECTOR V9 STATEFUL
#
# 1a execucao:
#   - percorre a lista de chats
#   - em cada chat, sobe o historico ate a data de corte
#   - padrao: ultimos 90 dias
#
# Proximas execucoes:
#   - usa lastSuccessfulRun - OverlapHours como janela
#   - revisita apenas chats cuja atividade da sidebar pode ser nova
#   - deduplica por SHA256
#
# Persistencia:
#   whatsapp-messages.jsonl = base append-only
#   whatsapp-state.json     = estado do sincronismo
#
# Nao depende de "Nao lidas".
# Nao envia nada para Joule/Copilot.
# Tudo fica local.
# ============================================================

$FirefoxPath = "C:\Program Files\Mozilla Firefox\firefox.exe"
$FirefoxProfile = "C:\Users\I827769\AppData\Roaming\Mozilla\Firefox\Profiles\qyl4c5lr.default-release"

$BaseDir = Join-Path $env:USERPROFILE "Documents\Joule\SecondBrain\WhatsApp"
$StateFile = Join-Path $BaseDir "whatsapp-state.json"
$MessagesFile = Join-Path $BaseDir "whatsapp-messages.jsonl"
$RunFile = Join-Path $BaseDir ("whatsapp-run-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$script:ws = $null
$script:context = $null
$script:nextId = 1
$script:sessionCreated = $false

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

function Test-Port {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $a = $c.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(800)) {
            $c.Close()
            return $false
        }
        $c.EndConnect($a)
        $c.Close()
        return $true
    }
    catch {
        if ($c) { try { $c.Close() } catch {} }
        return $false
    }
}

function Wait-Port([int]$Seconds = 40) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        if (Test-Port) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Restart-Firefox {
    Log "Reiniciando Firefox/BiDi..." Yellow
    Stop-Process -Name firefox -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $args = "-no-remote -profile `"$FirefoxProfile`" --remote-debugging-port=$Port https://web.whatsapp.com/"
    Start-Process -FilePath $FirefoxPath -ArgumentList $args
    if (-not (Wait-Port 40)) { throw "Firefox nao abriu a porta $Port." }
}

function Receive-WS([int]$Timeout = 20) {
    $buffer = New-Object byte[] 1048576
    $stream = New-Object System.IO.MemoryStream
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([TimeSpan]::FromSeconds($Timeout))
    try {
        do {
            $r = $script:ws.ReceiveAsync(
                [ArraySegment[byte]]::new($buffer),
                $cts.Token
            ).GetAwaiter().GetResult()
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw "WebSocket fechado."
            }
            $stream.Write($buffer, 0, $r.Count)
        } while (-not $r.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    finally {
        $stream.Dispose()
        $cts.Dispose()
    }
}

function Bidi([string]$Method, [hashtable]$Params = @{}, [int]$Timeout = 20) {
    $id = $script:nextId
    $script:nextId++
    $obj = @{ id=$id; method=$Method; params=$Params } | ConvertTo-Json -Compress -Depth 50
    $bytes = [Text.Encoding]::UTF8.GetBytes($obj)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([TimeSpan]::FromSeconds(10))
    try {
        $script:ws.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token
        ).GetAwaiter().GetResult() | Out-Null
    }
    finally { $cts.Dispose() }

    while ($true) {
        $raw = Receive-WS $Timeout
        try { $m = $raw | ConvertFrom-Json } catch { continue }
        if ($m.id -ne $id) { continue }
        if ($m.type -eq "error") { throw "$($m.error): $($m.message)" }
        return $m
    }
}

function Close-Bidi {
    if ($script:sessionCreated -and $script:ws -and
        $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try { Bidi "session.end" @{} 4 | Out-Null } catch {}
    }
    if ($script:ws) { try { $script:ws.Dispose() } catch {} }
    $script:ws = $null
    $script:context = $null
    $script:sessionCreated = $false
}

function Connect-Bidi {
    Close-Bidi
    if (-not (Test-Port)) { Restart-Firefox }

    for ($attempt=1; $attempt -le 3; $attempt++) {
        try {
            $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
            $cts = New-Object System.Threading.CancellationTokenSource
            $cts.CancelAfter([TimeSpan]::FromSeconds(15))
            try {
                $script:ws.ConnectAsync(
                    [Uri]"ws://127.0.0.1:$Port/session",
                    $cts.Token
                ).GetAwaiter().GetResult() | Out-Null
            } finally { $cts.Dispose() }

            Bidi "session.new" @{ capabilities=@{ alwaysMatch=@{} } } 15 | Out-Null
            $script:sessionCreated = $true

            # Apos um kill forcado, o Firefox pode reabrir na tela de "restaurar sessao"
            # e ignorar a URL passada na linha de comando. Por isso nao dependemos dela:
            # procuramos a aba do WhatsApp e, se nao existir, forcamos a navegacao de um
            # contexto existente ate o WhatsApp Web, com algumas tentativas.
            for ($t = 0; $t -lt 25; $t++) {
                $tree = Bidi "browsingContext.getTree" @{} 15

                foreach ($c in $tree.result.contexts) {
                    if ([string]$c.url -like "*web.whatsapp.com*") {
                        $script:context = [string]$c.context
                        break
                    }
                }
                if ($script:context) { break }

                if ($tree.result.contexts.Count -gt 0) {
                    $first = [string]$tree.result.contexts[0].context
                    try {
                        Bidi "browsingContext.navigate" @{
                            context = $first
                            url     = "https://web.whatsapp.com/"
                            wait    = "none"
                        } 15 | Out-Null
                    } catch {}
                }
                Start-Sleep -Seconds 1
            }

            if (-not $script:context) { throw "Aba do WhatsApp nao encontrada." }
            Log "Firefox BiDi conectado." Green
            return
        }
        catch {
            Log "BiDi: $($_.Exception.Message)" Yellow
            Close-Bidi
            Restart-Firefox
            Start-Sleep -Seconds 2
        }
    }
    throw "Falha ao conectar ao Firefox."
}

function JS([string]$Expression, [int]$Timeout = 15) {
    $r = Bidi "script.evaluate" @{
        expression=$Expression
        target=@{ context=$script:context }
        awaitPromise=$false
    } $Timeout
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

function Wait-Ready {
    Log "Esperando WhatsApp..." DarkGray
    $until = (Get-Date).AddSeconds(120)
    $code = @'
(() => JSON.stringify({
  pane:!!document.querySelector("#pane-side"),
  list:!!document.querySelector('[data-testid="chat-list"]'),
  titles:document.querySelectorAll('#pane-side [data-testid="cell-frame-title"]').length
}))()
'@
    while ((Get-Date) -lt $until) {
        try {
            $s = JSJson $code 8
            if ($s.pane -and $s.list -and [int]$s.titles -gt 0) {
                Log "WhatsApp pronto. Chats visiveis=$($s.titles)" Green
                return
            }
        } catch {}
        Start-Sleep -Milliseconds 400
    }
    throw "WhatsApp nao ficou pronto."
}

function Ensure-Connected {
    # Timeouts do CancellationTokenSource podem deixar o WebSocket em estado
    # 'Aborted' permanente. Se isso acontecer, reconecta e revalida a pagina
    # em vez de derrubar o run inteiro.
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { return }
    Log "Conexao BiDi caiu; reconectando..." Yellow
    Connect-Bidi
    Wait-Ready
}

function SHA256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Normalize-Chat([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $x = $Name.Trim()
    $x = $x -replace '^\d+\s+mensagens?\s+n[aã]o\s+lidas?\s*', ''
    $x = $x -replace '^n[aã]o\s+lida\s+', ''
    return (($x -replace '\s+',' ').Trim())
}

function Load-State {
    if ($ResetState) {
        if (Test-Path $StateFile) {
            Copy-Item $StateFile ($StateFile + ".bak-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        }
        return $null
    }

    if (Test-Path $StateFile) {
        try { return Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Log "State corrompido; iniciando bootstrap." Yellow }
    }
    return $null
}

function Save-State($State) {
    $json = $State | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($StateFile, $json, [Text.Encoding]::UTF8)
}

function Get-KnownIds {
    $set = @{}
    if (-not (Test-Path $MessagesFile)) { return $set }

    Log "Carregando IDs ja armazenados..." DarkGray
    foreach ($line in [IO.File]::ReadLines($MessagesFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $m = $line | ConvertFrom-Json
            if ($m.id) { $set[[string]$m.id] = $true }
        } catch {}
    }
    Log "IDs conhecidos: $($set.Count)" DarkGray
    return $set
}

function Append-Messages([array]$Messages, [hashtable]$Known) {
    $added = 0
    foreach ($m in $Messages) {
        if (-not $m.id) { continue }
        if ($Known.ContainsKey([string]$m.id)) { continue }
        $line = $m | ConvertTo-Json -Compress -Depth 10
        [IO.File]::AppendAllText(
            $MessagesFile,
            $line + [Environment]::NewLine,
            [Text.Encoding]::UTF8
        )
        $Known[[string]$m.id] = $true
        $added++
    }
    return $added
}

function Reset-SidebarTop {
    $code = @'
(() => {
  const pane=document.querySelector("#pane-side");
  if(!pane) return "false";
  const all=[pane,...pane.querySelectorAll("div")];
  let s=null,best=0;
  for(const e of all){
    const d=e.scrollHeight-e.clientHeight;
    if(d>best && e.clientHeight>200){best=d;s=e;}
  }
  if(!s) return "false";
  s.scrollTop=0;
  s.dispatchEvent(new Event("scroll",{bubbles:true}));
  return "true";
})()
'@
    JS $code 8 | Out-Null
    Start-Sleep -Milliseconds 250
}

function Get-VisibleChats {
    $code = @'
(() => {
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const strip=v=>clean(v)
   .replace(/^\d+\s+mensagens?\s+n[aã]o\s+lidas?\s*/i,"")
   .replace(/^n[aã]o\s+lida\s+/i,"")
   .trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return "[]";
 // WhatsApp Web nao expoe mais o nome via innerText: o titulo do contato
 // fica no atributo "title" do primeiro span[title] dentro de cell-frame-title.
 // O ultimo span[title] da linha e o preview da ultima mensagem.
 const out=[];
 for(const row of list.querySelectorAll('div[role="row"]')){
   const titleEl=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]');
   const name=titleEl?strip(titleEl.getAttribute("title")):"";
   if(!name) continue;
   const spans=[...row.querySelectorAll('span[title]')];
   const preview=spans.length>1?clean(spans[spans.length-1].getAttribute("title")):"";
   out.push({
     name,
     key:name.toLocaleLowerCase("pt-BR"),
     time:"",
     preview
   });
 }
 return JSON.stringify(out);
})()
'@
    # Variavel intermediaria: no Windows PowerShell 5.1, @(JSJson ...) inline
    # aninha o [Object[]] do ConvertFrom-Json (vira 1 item contendo o array).
    $rows = JSJson $code 10
    return @($rows)
}

function Scroll-Sidebar {
    $code = @'
(() => {
 const pane=document.querySelector("#pane-side");
 if(!pane) return JSON.stringify({moved:false});
 const all=[pane,...pane.querySelectorAll("div")];
 let s=null,best=0;
 for(const e of all){
   const d=e.scrollHeight-e.clientHeight;
   if(d>best && e.clientHeight>200){best=d;s=e;}
 }
 if(!s) return JSON.stringify({moved:false});
 const before=s.scrollTop;
 s.scrollTop=Math.min(s.scrollTop+Math.max(450,s.clientHeight*.75),s.scrollHeight);
 s.dispatchEvent(new Event("scroll",{bubbles:true}));
 return JSON.stringify({moved:s.scrollTop!==before,top:s.scrollTop,max:s.scrollHeight-s.clientHeight});
})()
'@
    return JSJson $code 8
}

function Click-Chat([string]$ChatName) {
    $safe = $ChatName | ConvertTo-Json -Compress
    $code = @"
(() => {
 const wanted=$safe;
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const strip=v=>clean(v)
   .replace(/^\d+\s+mensagens?\s+n[aã]o\s+lidas?\s*/i,"")
   .replace(/^n[aã]o\s+lida\s+/i,"")
   .trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return JSON.stringify({ok:false});
 for(const row of list.querySelectorAll('div[role="row"]')){
   const titleEl=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]');
   const name=titleEl?strip(titleEl.getAttribute("title")):"";
   if(name!==wanted) continue;
   const target=row.querySelector('[role="gridcell"]')||row.querySelector('[data-testid="cell-frame-container"]')||row;
   target.scrollIntoView({block:"center"});
   const r=target.getBoundingClientRect();
   return JSON.stringify({ok:true,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)});
 }
 return JSON.stringify({ok:false});
})()
"@
    $found = JSJson $code 8
    if (-not $found -or -not $found.ok) { return [pscustomobject]@{ ok = $false } }

    # Clique REAL (trusted) via WebDriver BiDi. Eventos sinteticos (.click) NAO
    # abrem a conversa no WhatsApp Web atual; input.performActions gera evento real.
    try {
        $actions = @(
            @{
                type = "pointer"; id = "mouse1"; parameters = @{ pointerType = "mouse" }
                actions = @(
                    @{ type="pointerMove"; x=[int]$found.x; y=[int]$found.y; origin="viewport" },
                    @{ type="pointerDown"; button=0 },
                    @{ type="pointerUp";   button=0 }
                )
            }
        )
        Bidi "input.performActions" @{ context=$script:context; actions=$actions } 15 | Out-Null
        return [pscustomobject]@{ ok = $true }
    }
    catch {
        return [pscustomobject]@{ ok = $false }
    }
}

function Wait-ChatMessages([int]$Milliseconds = 2200) {
    $until = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $until) {
        $s = JSJson @'
(() => {
 const m=document.querySelector("#main");
 if(!m) return JSON.stringify({ok:false,count:0});
 const n=m.querySelectorAll('[data-pre-plain-text],.selectable-text').length;
 return JSON.stringify({ok:n>0,count:n});
})()
'@ 8
        if ($s.ok) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Get-OldestMeta {
    $code = @'
(() => {
 const main=document.querySelector("#main");
 if(!main) return "";
 const a=[...main.querySelectorAll("[data-pre-plain-text]")];
 return a.length ? (a[0].getAttribute("data-pre-plain-text")||"") : "";
})()
'@
    return [string](JS $code 8)
}

function Parse-MetaDate([string]$Meta) {
    if ([string]::IsNullOrWhiteSpace($Meta)) { return $null }

    # WhatsApp costuma expor: [HH:mm, DD/MM/YYYY] Autor:
    if ($Meta -match '\[(\d{1,2}):(\d{2}),\s*(\d{1,2})/(\d{1,2})/(\d{2,4})\]') {
        $hh=[int]$matches[1]; $mm=[int]$matches[2]
        $dd=[int]$matches[3]; $mo=[int]$matches[4]; $yy=[int]$matches[5]
        if ($yy -lt 100) { $yy += 2000 }
        try { return Get-Date -Year $yy -Month $mo -Day $dd -Hour $hh -Minute $mm -Second 0 }
        catch { return $null }
    }
    return $null
}

function Parse-MetaAuthor([string]$Meta) {
    if ([string]::IsNullOrWhiteSpace($Meta)) { return "" }
    # Formato: [HH:mm, DD/MM/YYYY] Autor:  -> autor fica entre o "]" e o ultimo ":"
    if ($Meta -match '\]\s*(.+?)\s*:\s*$') { return ($matches[1]).Trim() }
    return ""
}

function Scroll-ChatUp {
    $code = @'
(() => {
 const main=document.querySelector("#main");
 if(!main) return JSON.stringify({moved:false});
 const markers=[...main.querySelectorAll('[data-pre-plain-text],.selectable-text')];
 if(!markers.length) return JSON.stringify({moved:false});
 let e=markers[0],s=null;
 for(let i=0;e&&i<25;i++,e=e.parentElement){
   if(e.scrollHeight>e.clientHeight+100){s=e;break;}
 }
 if(!s) return JSON.stringify({moved:false});
 const before=s.scrollTop;
 s.scrollTop=0;
 s.dispatchEvent(new Event("scroll",{bubbles:true}));
 return JSON.stringify({moved:s.scrollTop!==before,count:markers.length});
})()
'@
    return JSJson $code 8
}

function Collect-Loaded([string]$ChatName) {
    $safe = $ChatName | ConvertTo-Json -Compress
    $code = @"
(() => {
 const chat=$safe;
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const main=document.querySelector("#main");
 if(!main) return "[]";
 const out=[],seen=new Set();

 function dir(e){
   // 1) marcadores antigos (se voltarem em algum build)
   let x=e;
   for(let i=0;x&&i<12;i++,x=x.parentElement){
     if(x.classList&&x.classList.contains("message-in")) return "in";
     if(x.classList&&x.classList.contains("message-out")) return "out";
   }
   // 2) heuristica best-effort: minhas mensagens ficam alinhadas a direita
   try{
     const mr=main.getBoundingClientRect();
     const r=e.getBoundingClientRect();
     if(mr.width>0 && r.width>0){
       const center=((r.left+r.right)/2)-mr.left;
       if(center > mr.width*0.55) return "out";
       if(center < mr.width*0.45) return "in";
     }
   }catch(_){}
   return "";
 }

 const metas=[...main.querySelectorAll("[data-pre-plain-text]")];
 if(metas.length){
   metas.forEach((e,i)=>{
     const meta=clean(e.getAttribute("data-pre-plain-text"));
     let parts=[...e.querySelectorAll(".selectable-text")].map(x=>clean(x.innerText||x.textContent)).filter(Boolean);
     let text=clean([...new Set(parts)].join(" "));
     if(!text) text=clean(e.innerText);
     if(!text) return;
     const k=meta+"|"+text+"|"+dir(e);
     if(seen.has(k)) return; seen.add(k);
     out.push({chat,meta,text,direction:dir(e),domIndex:i});
   });
 } else {
   [...main.querySelectorAll(".selectable-text")].forEach((e,i)=>{
     const text=clean(e.innerText||e.textContent);
     if(!text) return;
     const k=text+"|"+dir(e);
     if(seen.has(k)) return; seen.add(k);
     out.push({chat,meta:"",text,direction:dir(e),domIndex:i});
   });
 }
 return JSON.stringify(out);
})()
"@
    $msgs = JSJson $code 15
    return @($msgs)
}

function Convert-LoadedMessages([string]$ChatName, [array]$Raw, [datetime]$Cutoff) {
    $out = New-Object System.Collections.ArrayList

    foreach ($r in $Raw) {
        $dt = Parse-MetaDate ([string]$r.meta)

        # Sem timestamp estruturado: preserva no bootstrap/delta.
        # A deduplicacao evita regravar o mesmo item.
        if ($dt -and $dt -lt $Cutoff) { continue }

        $basis = "$ChatName|$([string]$r.meta)|$([string]$r.direction)|$([string]$r.text)"
        $id = SHA256 $basis

        [void]$out.Add([pscustomobject]@{
            id        = $id
            chat      = $ChatName
            timestamp = $(if ($dt) { $dt.ToString("o") } else { $null })
            author    = Parse-MetaAuthor ([string]$r.meta)
            meta      = [string]$r.meta
            direction = [string]$r.direction
            text      = [string]$r.text
            capturedAt= (Get-Date).ToString("o")
        })
    }

    return @($out)
}

# ---------------- RUN ----------------

$state = Load-State
$isBootstrap = ($null -eq $state)

if ($isBootstrap) {
    $cutoff = (Get-Date).AddDays(-$BootstrapDays)
    $state = [pscustomobject]@{
        version = 9
        bootstrapDays = $BootstrapDays
        bootstrapCutoff = $cutoff.ToString("o")
        bootstrapComplete = $false
        lastSuccessfulRun = $null
        chats = @{}
    }
} else {
    if ($state.lastSuccessfulRun) {
        $last = [datetime]::Parse([string]$state.lastSuccessfulRun)
        $cutoff = $last.AddHours(-$OverlapHours)
    } else {
        $cutoff = [datetime]::Parse([string]$state.bootstrapCutoff)
    }
}

$known = Get-KnownIds
$runStarted = Get-Date
$runResults = New-Object System.Collections.ArrayList
$seenChats = @{}
$totalAdded = 0

try {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "WHATSAPP COLLECTOR V9 - STATEFUL" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    if ($isBootstrap) {
        Log "BOOTSTRAP: coletando ate $($cutoff.ToString('dd/MM/yyyy HH:mm')) (ultimos $BootstrapDays dias)." Yellow
    } else {
        Log "DELTA: corte seguro $($cutoff.ToString('dd/MM/yyyy HH:mm')) (overlap ${OverlapHours}h)." Yellow
    }

    Connect-Bidi
    Wait-Ready
    Reset-SidebarTop

    $sidebarDone = $false
    $stagnantRounds = 0

    while (-not $sidebarDone -and $seenChats.Count -lt $MaxChats) {
        try { $visible = @(Get-VisibleChats) }
        catch { Ensure-Connected; $visible = @(Get-VisibleChats) }
        $newVisible = 0

        foreach ($item in $visible) {
            $name = Normalize-Chat ([string]$item.name)
            if (-not $name) { continue }

            $key = $name.ToLowerInvariant()
            if ($seenChats.ContainsKey($key)) { continue }

            $seenChats[$key] = $true
            $newVisible++

          try {
            # No delta, se a sidebar mostra uma data/hora antiga, ainda podemos
            # visitar; a deduplicacao e o cutoff garantem seguranca.
            # Isso privilegia completude sobre heuristica fragil de UI.

            $click = Click-Chat $name
            if (-not $click.ok) {
                Log "Nao consegui abrir: $name" DarkYellow
                continue
            }

            if (-not (Wait-ChatMessages 2200)) {
                Log "Sem mensagens detectaveis: $name" DarkYellow
                continue
            }

            Log "[$($seenChats.Count)] $name" Cyan

            # Bootstrap sobe ate encontrar mensagem anterior ao cutoff.
            # Delta sobe pouco e para assim que encontra a janela de overlap.
            $scrollLimit = $(if ($isBootstrap) { $MaxScrollsPerChat } else { 12 })
            $scrolls = 0
            $reachedCutoff = $false
            $lastOldest = ""

            while ($scrolls -lt $scrollLimit) {
                $oldestMeta = Get-OldestMeta
                $oldestDate = Parse-MetaDate $oldestMeta

                if ($oldestDate -and $oldestDate -le $cutoff) {
                    $reachedCutoff = $true
                    break
                }

                $scroll = Scroll-ChatUp
                if (-not $scroll.moved) { break }

                Start-Sleep -Milliseconds 260
                $scrolls++

                $newOldest = Get-OldestMeta
                if ($newOldest -eq $lastOldest -and $newOldest) {
                    Start-Sleep -Milliseconds 350
                }
                $lastOldest = $newOldest
            }

            $raw = @(Collect-Loaded $name)
            $messages = @(Convert-LoadedMessages $name $raw $cutoff)
            $added = Append-Messages $messages $known
            $totalAdded += $added

            $lastTimestamp = $null
            foreach ($m in $messages) {
                if ($m.timestamp) {
                    if (-not $lastTimestamp -or [datetime]$m.timestamp -gt [datetime]$lastTimestamp) {
                        $lastTimestamp = $m.timestamp
                    }
                }
            }

            $chatState = [pscustomobject]@{
                lastSeenAt = (Get-Date).ToString("o")
                lastMessageAt = $lastTimestamp
                lastPreview = [string]$item.preview
                addedThisRun = $added
            }

            # PSCustomObject de JSON nao aceita indexacao como hashtable de forma confiavel.
            # Reconstroi chats como hashtable quando necessario.
            if ($state.chats -isnot [hashtable]) {
                $h = @{}
                if ($state.chats) {
                    foreach ($p in $state.chats.PSObject.Properties) {
                        $h[$p.Name] = $p.Value
                    }
                }
                $state.chats = $h
            }
            $state.chats[$key] = $chatState
            Save-State $state

            [void]$runResults.Add([pscustomobject]@{
                chat=$name
                loaded=$raw.Count
                inWindow=$messages.Count
                added=$added
                scrolls=$scrolls
                reachedCutoff=$reachedCutoff
            })

            Log "OK ${name}: loaded=$($raw.Count) | janela=$($messages.Count) | NOVAS=$added | scrolls=$scrolls" Green
          }
          catch {
            Log "Falha em ${name}: $($_.Exception.Message)" DarkYellow
            Ensure-Connected
            continue
          }
        }

        if ($newVisible -eq 0) { $stagnantRounds++ } else { $stagnantRounds=0 }

        try { $move = Scroll-Sidebar }
        catch { Ensure-Connected; $move = Scroll-Sidebar }
        if (-not $move -or -not $move.moved -or $stagnantRounds -ge 2) {
            $sidebarDone = $true
        } else {
            Start-Sleep -Milliseconds 220
        }
    }

    $state.bootstrapComplete = $true
    $state.lastSuccessfulRun = (Get-Date).ToString("o")
    Save-State $state

    $runSummary = [pscustomobject]@{
        version=9
        mode=$(if ($isBootstrap) {"bootstrap"} else {"delta"})
        startedAt=$runStarted.ToString("o")
        finishedAt=(Get-Date).ToString("o")
        cutoff=$cutoff.ToString("o")
        uniqueChatsVisited=$seenChats.Count
        newMessages=$totalAdded
        messagesFile=$MessagesFile
        stateFile=$StateFile
        chats=@($runResults)
    }

    $runJson = $runSummary | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($RunFile, $runJson, [Text.Encoding]::UTF8)
    $runJson | Set-Clipboard

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "SYNC CONCLUIDO" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "Modo             : $(if ($isBootstrap) {'BOOTSTRAP 90 DIAS'} else {'DELTA'})"
    Write-Host "Chats unicos     : $($seenChats.Count)"
    Write-Host "Mensagens novas  : $totalAdded"
    Write-Host "Base             : $MessagesFile"
    Write-Host "Estado           : $StateFile"
    Write-Host "Resumo da rodada : $RunFile"
    Write-Host ""
}
catch {
    Log "ERRO: $($_.Exception.Message)" Red
    Log "Estado parcial preservado. lastSuccessfulRun NAO foi avancado." Yellow
    try { Save-State $state } catch {}
}
finally {
    Close-Bidi
}

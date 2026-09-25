param([int]$Port = 9224, [int]$MaxScrolls = 20, [int]$MaxChats = 4)
$ErrorActionPreference = "Stop"
$OutDir = "C:\Users\I827769\Documents\Joule\SecondBrain\_cdp_probe"
$Log = Join-Path $OutDir ("probe-" + (Get-Date -Format "HHmmss") + ".jsonl")
$script:ws=$null; $script:context=$null; $script:nextId=1; $script:sessionCreated=$false

function W([string]$t){ Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $t" }
function Emit($o){ ($o | ConvertTo-Json -Compress -Depth 20) | Out-File -FilePath $Log -Append -Encoding utf8 }

function Receive-WS([int]$Timeout=20){
  $buffer=New-Object byte[] 1048576; $stream=New-Object System.IO.MemoryStream
  $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds($Timeout))
  try{
    do{
      $r=$script:ws.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cts.Token).GetAwaiter().GetResult()
      if($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close){ throw "WS closed" }
      $stream.Write($buffer,0,$r.Count)
    } while(-not $r.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($stream.ToArray())
  } finally { $stream.Dispose(); $cts.Dispose() }
}
function Bidi([string]$Method,[hashtable]$Params=@{},[int]$Timeout=20){
  $id=$script:nextId; $script:nextId++
  $obj=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Compress -Depth 50
  $bytes=[Text.Encoding]::UTF8.GetBytes($obj)
  $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(10))
  try{ $script:ws.SendAsync([ArraySegment[byte]]::new($bytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()|Out-Null } finally { $cts.Dispose() }
  while($true){ $raw=Receive-WS $Timeout; try{$m=$raw|ConvertFrom-Json}catch{continue}; if($m.id -ne $id){continue}; if($m.type -eq "error"){throw "$($m.error): $($m.message)"}; return $m }
}
function JS([string]$Expr,[int]$Timeout=15){
  $r=Bidi "script.evaluate" @{expression=$Expr;target=@{context=$script:context};awaitPromise=$false} $Timeout
  $v=$r.result.result
  if($v.type -eq "string"){return [string]$v.value}
  if($v.type -eq "number" -or $v.type -eq "boolean"){return $v.value}
  return $null
}
function JSJson([string]$Expr,[int]$Timeout=15){ $raw=JS $Expr $Timeout; if([string]::IsNullOrWhiteSpace([string]$raw)){return $null}; return $raw|ConvertFrom-Json }

# --- connect (READ-ONLY; NUNCA reinicia o Firefox) ---
$script:ws=New-Object System.Net.WebSockets.ClientWebSocket
$cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(15))
try{ $script:ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port/session",$cts.Token).GetAwaiter().GetResult()|Out-Null } finally { $cts.Dispose() }
Bidi "session.new" @{capabilities=@{alwaysMatch=@{}}} 15 | Out-Null
$script:sessionCreated=$true
$tree=Bidi "browsingContext.getTree" @{} 15
foreach($c in $tree.result.contexts){ if([string]$c.url -like "*web.whatsapp.com*"){ $script:context=[string]$c.context; break } }
if(-not $script:context){ W "Aba WhatsApp NAO encontrada. Contextos:"; foreach($c in $tree.result.contexts){ W ("  " + [string]$c.url) }; throw "sem contexto WA" }
W "Conectado. context=$script:context  log=$Log"

# readiness
$ready = JSJson '(()=>JSON.stringify({pane:!!document.querySelector("#pane-side"),titles:document.querySelectorAll(String.fromCharCode(35)+"pane-side [data-testid=\"cell-frame-title\"]").length}))()' 8
W ("Ready pane=" + $ready.pane + " titles=" + $ready.titles)

# lista visivel de chats (nome only)
$listCode = @'
(() => {
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return "[]";
 const out=[];
 for(const row of list.querySelectorAll('div[role="row"]')){
   const t=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]');
   const name=t?clean(t.getAttribute("title")):"";
   if(name) out.push(name);
 }
 return JSON.stringify(out);
})()
'@
$chats = @(JSJson $listCode 10)
W ("Chats visiveis: " + $chats.Count)

# metrica do chat aberto: conta bolhas e data mais antiga
$measureCode = @'
(() => {
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const main=document.querySelector("#main");
 if(!main) return JSON.stringify({ok:false});
 const metas=[...main.querySelectorAll("[data-pre-plain-text]")];
 const sel=main.querySelectorAll(".selectable-text").length;
 const oldest = metas.length? clean(metas[0].getAttribute("data-pre-plain-text")) : "";
 const newest = metas.length? clean(metas[metas.length-1].getAttribute("data-pre-plain-text")) : "";
 // detecta topo: cabecalho de sistema/criptografia no comeco do #main
 const bodyTxt = clean(main.innerText).slice(0,400);
 const encTop = /mensagens.*(protegidas|criptografia)|end-to-end|Voce criou este grupo|Este grupo foi criado|entrou usando o link|As mensagens e as chamadas/i.test(bodyTxt);
 return JSON.stringify({ok:true,metas:metas.length,sel,oldest,newest,encTop});
})()
'@

# abre um chat pelo nome (click trusted) - necessario p/ carregar historico
function Open-Chat([string]$name){
  $safe = $name | ConvertTo-Json -Compress
  $code = @"
(() => {
 const wanted=$safe;
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return JSON.stringify({ok:false});
 for(const row of list.querySelectorAll('div[role="row"]')){
   const t=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]');
   const name=t?clean(t.getAttribute("title")):"";
   if(name!==wanted) continue;
   const target=row.querySelector('[role="gridcell"]')||row;
   target.scrollIntoView({block:"center"});
   const r=target.getBoundingClientRect();
   return JSON.stringify({ok:true,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)});
 }
 return JSON.stringify({ok:false});
})()
"@
  $f = JSJson $code 8
  if(-not $f -or -not $f.ok){ return $false }
  $actions=@(@{type="pointer";id="mouse1";parameters=@{pointerType="mouse"};actions=@(@{type="pointerMove";x=[int]$f.x;y=[int]$f.y;origin="viewport"},@{type="pointerDown";button=0},@{type="pointerUp";button=0})})
  Bidi "input.performActions" @{context=$script:context;actions=$actions} 15 | Out-Null
  Start-Sleep -Milliseconds 1200
  return $true
}

$scrollUpCode = @'
(() => {
 const main=document.querySelector("#main");
 if(!main) return JSON.stringify({moved:false});
 const markers=[...main.querySelectorAll('[data-pre-plain-text],.selectable-text')];
 if(!markers.length) return JSON.stringify({moved:false});
 let e=markers[0],s=null;
 for(let i=0;e&&i<25;i++,e=e.parentElement){ if(e.scrollHeight>e.clientHeight+100){s=e;break;} }
 if(!s) return JSON.stringify({moved:false});
 const before=s.scrollTop;
 s.scrollTop=0;
 s.dispatchEvent(new Event("scroll",{bubbles:true}));
 return JSON.stringify({moved:s.scrollTop!==before,before,after:s.scrollTop});
})()
'@

# escolhe chats: prioriza nomes conhecidos como movimentados
$targets = @()
$busyHints = @("Dudown","Escava","CX CSP","CURVA","Alessandra","Cantu")
foreach($h in $busyHints){ foreach($c in $chats){ if($c -like "*$h*" -and $targets -notcontains $c){ $targets += $c; break } } }
foreach($c in $chats){ if($targets.Count -ge $MaxChats){break}; if($targets -notcontains $c){ $targets += $c } }
$targets = $targets | Select-Object -First $MaxChats
W ("Alvos: " + ($targets -join " | "))

foreach($chat in $targets){
  W "==== CHAT: $chat ===="
  if(-not (Open-Chat $chat)){ W "  nao abriu, pulando"; Emit @{ev="open_fail";chat=$chat}; continue }
  Start-Sleep -Milliseconds 800
  $prevOldest=""; $stagnant=0
  for($k=0;$k -le $MaxScrolls;$k++){
    $t0=Get-Date
    $m = JSJson $measureCode 10
    if(-not $m -or -not $m.ok){ W "  measure falhou k=$k"; Emit @{ev="measure_fail";chat=$chat;k=$k}; break }
    # lazy-load probe: mede de novo apos 600ms sem rolar
    Start-Sleep -Milliseconds 600
    $m2 = JSJson $measureCode 10
    $lazyGain = [int]$m2.metas - [int]$m.metas
    Emit @{ev="scroll_step";chat=$chat;k=$k;metas=[int]$m.metas;sel=[int]$m.sel;oldest=[string]$m.oldest;newest=[string]$m.newest;encTop=[bool]$m.encTop;lazyGain=$lazyGain;ms=((Get-Date)-$t0).TotalMilliseconds}
    W ("  k={0,2} metas={1,4} oldest='{2}' encTop={3} lazyGain={4}" -f $k,[int]$m2.metas,[string]$m2.oldest,[bool]$m2.encTop,$lazyGain)
    if([string]$m2.oldest -eq $prevOldest -and $prevOldest -ne ""){ $stagnant++ } else { $stagnant=0 }
    $prevOldest=[string]$m2.oldest
    if($stagnant -ge 3){ W "  -> topo real (oldest estavel 3x)"; Emit @{ev="top_reached";chat=$chat;k=$k;oldest=[string]$m2.oldest}; break }
    if($k -eq $MaxScrolls){ break }
    $sc = JSJson $scrollUpCode 8
    if(-not $sc.moved){ $stagnant++; if($stagnant -ge 3){ W "  -> scroll nao move (topo)"; Emit @{ev="scroll_stuck";chat=$chat;k=$k}; break } }
    Start-Sleep -Milliseconds 300
  }
}

# encerra sessao BiDi (NAO fecha o browser)
try{ if($script:sessionCreated){ Bidi "session.end" @{} 4 | Out-Null } }catch{}
try{ $script:ws.Dispose() }catch{}
W "FIM. log=$Log"

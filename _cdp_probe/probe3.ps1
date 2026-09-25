param([int]$Port = 9224, [int]$MaxScrolls = 28)
$ErrorActionPreference = "Stop"
$OutDir = "C:\Users\I827769\Documents\Joule\SecondBrain\_cdp_probe"
$Log = Join-Path $OutDir ("probe3-" + (Get-Date -Format "HHmmss") + ".jsonl")
$script:ws=$null; $script:context=$null; $script:nextId=1; $script:sessionCreated=$false
function W([string]$t){ Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $t" }
function Emit($o){ ($o | ConvertTo-Json -Compress -Depth 20) | Out-File -FilePath $Log -Append -Encoding utf8 }
function Receive-WS([int]$Timeout=20){ $buffer=New-Object byte[] 1048576; $stream=New-Object System.IO.MemoryStream; $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds($Timeout)); try{ do{ $r=$script:ws.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cts.Token).GetAwaiter().GetResult(); if($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close){throw "WS closed"}; $stream.Write($buffer,0,$r.Count) } while(-not $r.EndOfMessage); return [Text.Encoding]::UTF8.GetString($stream.ToArray()) } finally { $stream.Dispose(); $cts.Dispose() } }
function Bidi([string]$Method,[hashtable]$Params=@{},[int]$Timeout=20){ $id=$script:nextId; $script:nextId++; $obj=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Compress -Depth 50; $bytes=[Text.Encoding]::UTF8.GetBytes($obj); $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(10)); try{ $script:ws.SendAsync([ArraySegment[byte]]::new($bytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()|Out-Null } finally { $cts.Dispose() }; while($true){ $raw=Receive-WS $Timeout; try{$m=$raw|ConvertFrom-Json}catch{continue}; if($m.id -ne $id){continue}; if($m.type -eq "error"){throw "$($m.error): $($m.message)"}; return $m } }
function JS([string]$Expr,[int]$Timeout=15){ $r=Bidi "script.evaluate" @{expression=$Expr;target=@{context=$script:context};awaitPromise=$false} $Timeout; $v=$r.result.result; if($v.type -eq "string"){return [string]$v.value}; if($v.type -eq "number" -or $v.type -eq "boolean"){return $v.value}; return $null }
function JSJson([string]$Expr,[int]$Timeout=15){ $raw=JS $Expr $Timeout; if([string]::IsNullOrWhiteSpace([string]$raw)){return $null}; return $raw|ConvertFrom-Json }

$script:ws=New-Object System.Net.WebSockets.ClientWebSocket
$cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(15))
try{ $script:ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port/session",$cts.Token).GetAwaiter().GetResult()|Out-Null } finally { $cts.Dispose() }
Bidi "session.new" @{capabilities=@{alwaysMatch=@{}}} 15 | Out-Null
$script:sessionCreated=$true
$tree=Bidi "browsingContext.getTree" @{} 15
foreach($c in $tree.result.contexts){ if([string]$c.url -like "*web.whatsapp.com*"){ $script:context=[string]$c.context; break } }
if(-not $script:context){ throw "sem contexto WA" }
W "Conectado. log=$Log"

# nomes juntos por newline (sem aninhamento de array)
$namesCode = @'
(() => {
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side");
 if(!list) return "";
 const out=[];
 for(const row of list.querySelectorAll('div[role="row"]')){ const t=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]'); const name=t?clean(t.getAttribute("title")):""; if(name) out.push(name); }
 return out.join("\n");
})()
'@
$sidebarScroll = @'
(() => { const pane=document.querySelector("#pane-side"); if(!pane) return "false"; const all=[pane,...pane.querySelectorAll("div")]; let s=null,best=0; for(const e of all){ const d=e.scrollHeight-e.clientHeight; if(d>best && e.clientHeight>200){best=d;s=e;} } if(!s) return "false"; const b=s.scrollTop; s.scrollTop=Math.min(s.scrollTop+700,s.scrollHeight); s.dispatchEvent(new Event("scroll",{bubbles:true})); return (s.scrollTop!==b)?"true":"false"; })()
'@
$allNames = New-Object System.Collections.Generic.HashSet[string]
for($i=0;$i -lt 25;$i++){
  $raw = [string](JS $namesCode 8)
  foreach($n in ($raw -split "`n")){ $n=$n.Trim(); if($n){ [void]$allNames.Add($n) } }
  if((JS $sidebarScroll 8) -ne "true"){ break }
  Start-Sleep -Milliseconds 250
}
W ("Chats enumerados: " + $allNames.Count)
JS '(()=>{const p=document.querySelector("#pane-side");if(p){const a=[p,...p.querySelectorAll("div")];let s=null,b=0;for(const e of a){const d=e.scrollHeight-e.clientHeight;if(d>b&&e.clientHeight>200){b=d;s=e;}}if(s)s.scrollTop=0;}return "ok";})()' 8 | Out-Null
Start-Sleep -Milliseconds 400

$busyHints=@("Dudown","Alessandra Aguiar","CURVA","Denis Herval","Netshoes","Cintia Swift")
$targets=@()
foreach($h in $busyHints){ foreach($n in $allNames){ if($n -like "*$h*" -and $targets -notcontains $n){ $targets+=$n; break } } }
W ("Alvos: " + ($targets -join "  ||  "))
Emit @{ev="enum";count=$allNames.Count;targets=$targets}

$measure = @'
(() => { const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim(); const main=document.querySelector("#main"); if(!main) return JSON.stringify({ok:false}); const metas=[...main.querySelectorAll("[data-pre-plain-text]")]; const oldest=metas.length?clean(metas[0].getAttribute("data-pre-plain-text")):""; const top=clean(main.innerText).slice(0,300); const encTop=/(protegidas com|criptografia de ponta|end-to-end|Este grupo foi criado|criou este grupo|adicionou voce|As mensagens e as chamadas s)/i.test(top); return JSON.stringify({ok:true,rendered:metas.length,oldest,encTop}); })()
'@
$scrollUp = @'
(() => { const main=document.querySelector("#main"); if(!main) return JSON.stringify({moved:false}); const mk=[...main.querySelectorAll('[data-pre-plain-text],.selectable-text')]; if(!mk.length) return JSON.stringify({moved:false}); let e=mk[0],s=null; for(let i=0;e&&i<25;i++,e=e.parentElement){ if(e.scrollHeight>e.clientHeight+100){s=e;break;} } if(!s) return JSON.stringify({moved:false}); const b=s.scrollTop; s.scrollTop=0; s.dispatchEvent(new Event("scroll",{bubbles:true})); return JSON.stringify({moved:s.scrollTop!==b}); })()
'@
function Open-Chat([string]$name){
  $safe=$name|ConvertTo-Json -Compress
  $code=@"
(() => { const wanted=$safe; const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim(); const list=document.querySelector('#pane-side [data-testid="chat-list"]')||document.querySelector("#pane-side"); if(!list) return JSON.stringify({ok:false}); for(const row of list.querySelectorAll('div[role="row"]')){ const t=row.querySelector('[data-testid="cell-frame-title"] span[title]')||row.querySelector('span[title]'); const name=t?clean(t.getAttribute("title")):""; if(name!==wanted) continue; const tg=row.querySelector('[role="gridcell"]')||row; tg.scrollIntoView({block:"center"}); const r=tg.getBoundingClientRect(); return JSON.stringify({ok:true,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}); } return JSON.stringify({ok:false}); })()
"@
  for($try=0;$try -lt 30;$try++){
    $f=JSJson $code 8
    if($f -and $f.ok){ $actions=@(@{type="pointer";id="mouse1";parameters=@{pointerType="mouse"};actions=@(@{type="pointerMove";x=[int]$f.x;y=[int]$f.y;origin="viewport"},@{type="pointerDown";button=0},@{type="pointerUp";button=0})}); Bidi "input.performActions" @{context=$script:context;actions=$actions} 15 | Out-Null; Start-Sleep -Milliseconds 1400; return $true }
    if((JS $sidebarScroll 8) -ne "true"){ return $false }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

foreach($chat in $targets){
  W "==== $chat ===="
  if(-not (Open-Chat $chat)){ W "  nao abriu"; Emit @{ev="open_fail";chat=$chat}; continue }
  # volta a sidebar pro topo pra achar o proximo depois
  Start-Sleep -Milliseconds 900
  $prev=""; $stag=0
  for($k=0;$k -le $MaxScrolls;$k++){
    $m=JSJson $measure 10
    if(-not $m -or -not $m.ok){ Emit @{ev="measure_fail";chat=$chat;k=$k}; break }
    Start-Sleep -Milliseconds 700
    $m2=JSJson $measure 10
    Emit @{ev="step";chat=$chat;k=$k;rendered=[int]$m2.rendered;oldest=[string]$m2.oldest;encTop=[bool]$m2.encTop}
    W ("  k={0,2} rendered={1,3} oldest='{2}' encTop={3}" -f $k,[int]$m2.rendered,[string]$m2.oldest,[bool]$m2.encTop)
    if([string]$m2.oldest -eq $prev -and $prev -ne ""){ $stag++ } else { $stag=0 }
    $prev=[string]$m2.oldest
    if($stag -ge 3){ W "  -> TOPO (oldest estavel 3x) encTop=$($m2.encTop)"; Emit @{ev="top";chat=$chat;k=$k;encTop=[bool]$m2.encTop;oldest=$prev}; break }
    if($k -eq $MaxScrolls){ W "  -> HIT_LIMIT sem estabilizar (ainda havia historico)"; Emit @{ev="hit_limit";chat=$chat;k=$k;oldest=$prev}; break }
    $sc=JSJson $scrollUp 8
    if(-not $sc.moved){ $stag++ }
    Start-Sleep -Milliseconds 300
  }
  JS '(()=>{const p=document.querySelector("#pane-side");if(p){const a=[p,...p.querySelectorAll("div")];let s=null,b=0;for(const e of a){const d=e.scrollHeight-e.clientHeight;if(d>b&&e.clientHeight>200){b=d;s=e;}}if(s)s.scrollTop=0;}return "ok";})()' 8 | Out-Null
  Start-Sleep -Milliseconds 400
}
try{ if($script:sessionCreated){ Bidi "session.end" @{} 4 | Out-Null } }catch{}
try{ $script:ws.Dispose() }catch{}
W "FIM. log=$Log"

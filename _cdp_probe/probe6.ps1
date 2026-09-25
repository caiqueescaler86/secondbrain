param([int]$Port = 9224, [int]$MaxScrolls = 40, [int]$CutoffDays = 8)
$ErrorActionPreference = "Stop"
$OutDir = "C:\Users\I827769\Documents\Joule\SecondBrain\_cdp_probe"
$Log = Join-Path $OutDir ("probe6-" + (Get-Date -Format "HHmmss") + ".jsonl")
$script:ws=$null; $script:context=$null; $script:nextId=1; $script:sessionCreated=$false
function W([string]$t){ Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $t" }
function Emit($o){ ($o | ConvertTo-Json -Compress -Depth 20) | Out-File -FilePath $Log -Append -Encoding utf8 }
function Receive-WS([int]$Timeout=20){ $buffer=New-Object byte[] 1048576; $stream=New-Object System.IO.MemoryStream; $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds($Timeout)); try{ do{ $r=$script:ws.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cts.Token).GetAwaiter().GetResult(); if($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close){throw "WS_CLOSED"}; $stream.Write($buffer,0,$r.Count) } while(-not $r.EndOfMessage); return [Text.Encoding]::UTF8.GetString($stream.ToArray()) } finally { $stream.Dispose(); $cts.Dispose() } }
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
W "Conectado. cutoff=$CutoffDays d  log=$Log"

$namesCode = @'
(() => { const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim(); const list=document.querySelector('#pane-side'); if(!list) return ""; const out=[]; for(const row of list.querySelectorAll('div[role="row"]')){ const t=row.querySelector('span[title]'); const name=t?clean(t.getAttribute("title")):""; if(name) out.push(name);} return out.join("\n"); })()
'@
$sidebarScroll = @'
(() => { const pane=document.querySelector("#pane-side"); if(!pane) return "false"; const all=[pane,...pane.querySelectorAll("div")]; let s=null,best=0; for(const e of all){ const d=e.scrollHeight-e.clientHeight; if(d>best && e.clientHeight>200){best=d;s=e;} } if(!s) return "false"; const b=s.scrollTop; s.scrollTop=Math.min(s.scrollTop+700,s.scrollHeight); s.dispatchEvent(new Event("scroll",{bubbles:true})); return (s.scrollTop!==b)?"true":"false"; })()
'@
$allNames = New-Object System.Collections.Generic.HashSet[string]
for($i=0;$i -lt 25;$i++){ $raw=[string](JS $namesCode 8); foreach($n in ($raw -split "`n")){ $n=$n.Trim(); if($n){ [void]$allNames.Add($n) } }; if((JS $sidebarScroll 8) -ne "true"){ break }; Start-Sleep -Milliseconds 200 }
JS '(()=>{const p=document.querySelector("#pane-side");if(p){const a=[p,...p.querySelectorAll("div")];let s=null,b=0;for(const e of a){const d=e.scrollHeight-e.clientHeight;if(d>b&&e.clientHeight>200){b=d;s=e;}}if(s)s.scrollTop=0;}return "ok";})()' 8 | Out-Null
Start-Sleep -Milliseconds 400
W ("Chats: " + $allNames.Count)

# alvos: 1 movimentado (Dudown) + curtos p/ ver TOPO real com detector robusto
$busyHints=@("Denis Herval","Carina","Cintia Swift","Ericka")
$targets=@()
foreach($h in $busyHints){ foreach($n in $allNames){ if($n -like "*$h*" -and $targets -notcontains $n){ $targets+=$n; break } } }
$targets = $targets | Select-Object -First 4
W ("Alvos: " + ($targets -join "  ||  "))
Emit @{ev="enum";count=$allNames.Count;targets=$targets;cutoffDays=$CutoffDays}

# ---- MEASURE com detector de container ROBUSTO (varre todos os div de #main) ----
$measure = @'
(() => {
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const main=document.querySelector("#main"); if(!main) return JSON.stringify({ok:false});
 // container robusto: maior overflow com clientHeight decente
 let sc=null,best=0; for(const e of main.querySelectorAll("div")){ const d=e.scrollHeight-e.clientHeight; if(d>best && e.clientHeight>200){best=d;sc=e;} }
 const metas=[...main.querySelectorAll("[data-pre-plain-text]")];
 const oldest = metas.length? clean(metas[0].getAttribute("data-pre-plain-text")) : "";
 const spin = main.querySelector('[role="progressbar"], [data-icon="loading"], [aria-busy="true"]');
 const scrollable = !!sc;
 return JSON.stringify({ok:true,rendered:metas.length,oldest,
   scrollable, scrollTop: sc?Math.round(sc.scrollTop):0, scrollHeight: sc?sc.scrollHeight:0, clientHeight: sc?sc.clientHeight:0,
   overflow: sc?(sc.scrollHeight-sc.clientHeight):0, spinner: !!spin });
})()
'@
$scrollUp = @'
(() => { const main=document.querySelector("#main"); if(!main) return "nomain"; let sc=null,best=0; for(const e of main.querySelectorAll("div")){ const d=e.scrollHeight-e.clientHeight; if(d>best && e.clientHeight>200){best=d;sc=e;} } if(!sc) return "noscroller"; sc.scrollTop=0; sc.dispatchEvent(new Event("scroll",{bubbles:true})); return String(Math.round(sc.scrollTop)); })()
'@
function Open-Chat([string]$name){
  $safe=$name|ConvertTo-Json -Compress
  $code=@"
(() => { const wanted=$safe; const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim(); const list=document.querySelector('#pane-side'); if(!list) return JSON.stringify({ok:false}); for(const row of list.querySelectorAll('div[role="row"]')){ const t=row.querySelector('span[title]'); const name=t?clean(t.getAttribute("title")):""; if(name!==wanted) continue; const tg=row.querySelector('[role="gridcell"]')||row; tg.scrollIntoView({block:"center"}); const r=tg.getBoundingClientRect(); return JSON.stringify({ok:true,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}); } return JSON.stringify({ok:false}); })()
"@
  for($try=0;$try -lt 30;$try++){
    $f=JSJson $code 8
    if($f -and $f.ok){ $actions=@(@{type="pointer";id="mouse1";parameters=@{pointerType="mouse"};actions=@(@{type="pointerMove";x=[int]$f.x;y=[int]$f.y;origin="viewport"},@{type="pointerDown";button=0},@{type="pointerUp";button=0})}); Bidi "input.performActions" @{context=$script:context;actions=$actions} 15 | Out-Null; Start-Sleep -Milliseconds 1400; return $true }
    if((JS $sidebarScroll 8) -ne "true"){ return $false }
    Start-Sleep -Milliseconds 250
  }
  return $false
}
function Parse-Meta([string]$m){ if($m -match '\[(\d{1,2}):(\d{2}),\s*(\d{1,2})/(\d{1,2})/(\d{2,4})\]'){ $yy=[int]$matches[5]; if($yy -lt 100){$yy+=2000}; return Get-Date -Year $yy -Month ([int]$matches[4]) -Day ([int]$matches[3]) -Hour ([int]$matches[1]) -Minute ([int]$matches[2]) -Second 0 }; return $null }
$cutoffDate = (Get-Date).AddDays(-$CutoffDays)

foreach($chat in $targets){
  W "==== $chat ===="
  $class="INDETERMINATE"; $reason=""
  try{
    if(-not (Open-Chat $chat)){ Emit @{ev="result";chat=$chat;class="OPEN_FAIL"}; W "  OPEN_FAIL"; continue }
    Start-Sleep -Milliseconds 900
    $prevOldest=""; $pinnedStable=0
    for($k=0;$k -le $MaxScrolls;$k++){
      $m = JSJson $measure 10
      if(-not $m -or -not $m.ok){ Start-Sleep -Milliseconds 500; $m=JSJson $measure 10 }
      if(-not $m -or -not $m.ok){ $class="CDP_ERROR"; $reason="measure_null"; break }
      $od = Parse-Meta ([string]$m.oldest)
      Emit @{ev="step";chat=$chat;k=$k;rendered=[int]$m.rendered;oldest=[string]$m.oldest;scrollable=[bool]$m.scrollable;scrollTop=[int]$m.scrollTop;scrollHeight=[int]$m.scrollHeight;overflow=[int]$m.overflow;spinner=[bool]$m.spinner}
      W ("  k={0,2} old='{1}' scr={2} sT={3,-6} sH={4,-7} ovf={5,-6} spin={6} rnd={7}" -f $k,[string]$m.oldest,[bool]$m.scrollable,[int]$m.scrollTop,[int]$m.scrollHeight,[int]$m.overflow,[bool]$m.spinner,[int]$m.rendered)

      if($od -and $od -le $cutoffDate){ $class="CUTOFF_REACHED"; $reason=("oldest "+$m.oldest); break }
      # TOPO A: nao ha container rolavel MAS ha mensagens -> historico cabe na tela = topo
      if((-not [bool]$m.scrollable) -and [int]$m.rendered -gt 0){ $class="HISTORY_TOP_REACHED"; $reason="sem overflow + mensagens (historico cabe na tela)"; break }
      if((-not [bool]$m.scrollable) -and [int]$m.rendered -eq 0){ $class="INDETERMINATE"; $reason="sem container e sem mensagens"; break }

      $shBefore=[int]$m.scrollHeight
      JS $scrollUp 8 | Out-Null
      Start-Sleep -Milliseconds 1000
      $m2 = JSJson $measure 10
      if(-not $m2 -or -not $m2.ok){ $class="CDP_ERROR"; $reason="measure2_null"; break }
      $grew = ([int]$m2.scrollHeight -gt ($shBefore + 40))
      $movedOldest = ([string]$m2.oldest -ne $prevOldest)
      $pinned = ([int]$m2.scrollTop -le 5)
      $busy = [bool]$m2.spinner
      $prevOldest=[string]$m2.oldest
      if($busy){ Start-Sleep -Milliseconds 1200; $pinnedStable=0; Emit @{ev="lazywait";chat=$chat;k=$k}; continue }
      # TOPO B: preso no topo (scrollTop~0) + scrollHeight NAO cresce + data NAO avanca -> confirma 3x
      if($pinned -and (-not $grew) -and (-not $movedOldest)){ $pinnedStable++ } else { $pinnedStable=0 }
      if($pinnedStable -ge 3){ $class="HISTORY_TOP_REACHED"; $reason="scrollTop fixo em 0 + sH estavel + data estavel (3x), sem spinner"; break }
      if($k -eq $MaxScrolls){ if($grew -or $movedOldest){ $class="SCROLL_LIMIT_REACHED"; $reason="ainda crescendo/movendo no limite" } else { $class="INDETERMINATE"; $reason="estagnou sem confirmar topo" }; break }
      Start-Sleep -Milliseconds 250
    }
  } catch { $class="CDP_ERROR"; $reason=$_.Exception.Message }
  Emit @{ev="result";chat=$chat;class=$class;reason=$reason}
  W ("  => $class ($reason)")
  try{ JS '(()=>{const p=document.querySelector("#pane-side");if(p){const a=[p,...p.querySelectorAll("div")];let s=null,b=0;for(const e of a){const d=e.scrollHeight-e.clientHeight;if(d>b&&e.clientHeight>200){b=d;s=e;}}if(s)s.scrollTop=0;}return "ok";})()' 8 | Out-Null }catch{}
  Start-Sleep -Milliseconds 400
}
try{ if($script:sessionCreated){ Bidi "session.end" @{} 4 | Out-Null } }catch{}
try{ $script:ws.Dispose() }catch{}
W "FIM. log=$Log"

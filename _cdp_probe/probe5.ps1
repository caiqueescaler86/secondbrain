param([int]$Port = 9224)
$ErrorActionPreference = "Stop"
$OutDir = "C:\Users\I827769\Documents\Joule\SecondBrain\_cdp_probe"
$Log = Join-Path $OutDir ("probe5-" + (Get-Date -Format "HHmmss") + ".json")
$script:ws=$null; $script:context=$null; $script:nextId=1; $script:sessionCreated=$false
function W([string]$t){ Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $t" }
function Receive-WS([int]$Timeout=20){ $buffer=New-Object byte[] 1048576; $stream=New-Object System.IO.MemoryStream; $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds($Timeout)); try{ do{ $r=$script:ws.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cts.Token).GetAwaiter().GetResult(); if($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close){throw "WS_CLOSED"}; $stream.Write($buffer,0,$r.Count) } while(-not $r.EndOfMessage); return [Text.Encoding]::UTF8.GetString($stream.ToArray()) } finally { $stream.Dispose(); $cts.Dispose() } }
function Bidi([string]$Method,[hashtable]$Params=@{},[int]$Timeout=20){ $id=$script:nextId; $script:nextId++; $obj=@{id=$id;method=$Method;params=$Params}|ConvertTo-Json -Compress -Depth 50; $bytes=[Text.Encoding]::UTF8.GetBytes($obj); $cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(10)); try{ $script:ws.SendAsync([ArraySegment[byte]]::new($bytes),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()|Out-Null } finally { $cts.Dispose() }; while($true){ $raw=Receive-WS $Timeout; try{$m=$raw|ConvertFrom-Json}catch{continue}; if($m.id -ne $id){continue}; if($m.type -eq "error"){throw "$($m.error): $($m.message)"}; return $m } }
function JS([string]$Expr,[int]$Timeout=15){ $r=Bidi "script.evaluate" @{expression=$Expr;target=@{context=$script:context};awaitPromise=$false} $Timeout; $v=$r.result.result; if($v.type -eq "string"){return [string]$v.value}; return $null }

$script:ws=New-Object System.Net.WebSockets.ClientWebSocket
$cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(15))
try{ $script:ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port/session",$cts.Token).GetAwaiter().GetResult()|Out-Null } finally { $cts.Dispose() }
Bidi "session.new" @{capabilities=@{alwaysMatch=@{}}} 15 | Out-Null
$script:sessionCreated=$true
$tree=Bidi "browsingContext.getTree" @{} 15
foreach($c in $tree.result.contexts){ if([string]$c.url -like "*web.whatsapp.com*"){ $script:context=[string]$c.context; break } }
if(-not $script:context){ throw "sem contexto WA" }
W "Conectado."

# abre CURVA (grupo curto -> topo instantaneo)
$open = @'
(() => { const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim(); const list=document.querySelector('#pane-side'); for(const row of list.querySelectorAll('div[role="row"]')){ const t=row.querySelector('span[title]'); const name=t?clean(t.getAttribute("title")):""; if(name==="CURVA"){ const tg=row.querySelector('[role="gridcell"]')||row; tg.scrollIntoView({block:"center"}); const r=tg.getBoundingClientRect(); return JSON.stringify({ok:true,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)});} } return JSON.stringify({ok:false}); })()
'@
$f = (JS $open 8) | ConvertFrom-Json
if($f.ok){ $actions=@(@{type="pointer";id="m";parameters=@{pointerType="mouse"};actions=@(@{type="pointerMove";x=[int]$f.x;y=[int]$f.y;origin="viewport"},@{type="pointerDown";button=0},@{type="pointerUp";button=0})}); Bidi "input.performActions" @{context=$script:context;actions=$actions} 15 | Out-Null; Start-Sleep -Milliseconds 1600 }
W "CURVA aberto. Dump do DOM do topo:"

# DUMP: todos os data-icon, elementos de sistema, container rolavel, textos-chave
$dump = @'
(() => {
 const clean=v=>(v||"").replace(/[\u200e\u200f\u202a-\u202e]/g,"").replace(/\s+/g," ").trim();
 const main=document.querySelector("#main"); if(!main) return JSON.stringify({ok:false});
 // 1) todos os data-icon presentes
 const icons=[...new Set([...main.querySelectorAll("[data-icon]")].map(e=>e.getAttribute("data-icon")))];
 // 2) container rolavel (qualquer elemento com overflow e altura)
 const scrollers=[...main.querySelectorAll("div")].filter(e=>e.scrollHeight>e.clientHeight+50).map(e=>({cls:(e.className||"").slice(0,40),sh:e.scrollHeight,ch:e.clientHeight}));
 // 3) elementos cujo texto tem palavras de sistema/criptografia
 const kw=/(criptografia|protegidas|ponta a ponta|end-to-end|criou o grupo|criou este grupo|adicionou|entrou usando|Voc[eê] criou|As mensagens)/i;
 const sys=[];
 for(const e of main.querySelectorAll("div,span")){ const t=clean(e.textContent); if(t && t.length<160 && kw.test(t) && !sys.includes(t)){ sys.push(t); if(sys.length>=6) break; } }
 // 4) role=row primeiro item (inicio do historico?)
 const rows=[...main.querySelectorAll('[role="row"]')];
 const firstRowTxt = rows.length? clean(rows[0].textContent).slice(0,140):"";
 // 5) data-pre-plain-text count
 const metas=main.querySelectorAll("[data-pre-plain-text]").length;
 return JSON.stringify({ok:true,icons,scrollers:scrollers.slice(0,4),sys,firstRowTxt,metas,rows:rows.length});
})()
'@
$d = JS $dump 12
$d | Out-File -FilePath $Log -Encoding utf8
W "Dump salvo em $Log"
$d
try{ if($script:sessionCreated){ Bidi "session.end" @{} 4 | Out-Null } }catch{}
try{ $script:ws.Dispose() }catch{}
W "FIM."

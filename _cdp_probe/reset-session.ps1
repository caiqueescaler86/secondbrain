param([int]$Port=9224)
$ErrorActionPreference="Stop"
$ws=New-Object System.Net.WebSockets.ClientWebSocket
$cts=New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter([TimeSpan]::FromSeconds(10))
$ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port/session",$cts.Token).GetAwaiter().GetResult()|Out-Null
function Send($obj){ $b=[Text.Encoding]::UTF8.GetBytes(($obj|ConvertTo-Json -Compress -Depth 20)); $c=New-Object System.Threading.CancellationTokenSource; $c.CancelAfter(5000); $ws.SendAsync([ArraySegment[byte]]::new($b),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$c.Token).GetAwaiter().GetResult()|Out-Null }
function Recv(){ $buf=New-Object byte[] 65536; $c=New-Object System.Threading.CancellationTokenSource; $c.CancelAfter(8000); $r=$ws.ReceiveAsync([ArraySegment[byte]]::new($buf),$c.Token).GetAwaiter().GetResult(); return [Text.Encoding]::UTF8.GetString($buf,0,$r.Count) }
# tenta encerrar a sessao existente nesta conexao
Send @{id=1;method="session.end";params=@{}}
Write-Host ("end: " + (Recv))
$ws.Dispose()
Write-Host "reset ok"

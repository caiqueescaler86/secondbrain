param(
    [int]$Port = 8787,
    [switch]$Open
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch {}

# ============================================================
# SECONDBRAIN - COCKPIT (servidor web local)
#
# HttpListener em http://127.0.0.1:<Port>/ servindo a SPA e uma
# mini-API sobre processed\tasks.json. 100% local, loopback.
# ============================================================

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebDir    = Join-Path $Root "cockpit"
$Processed = Join-Path $Root "processed"
$TasksFile = Join-Path $Processed "tasks.json"

# Arquivos do painel de saude/rodada (produzidos por secondbrain-run.ps1 e outros
# processos). Podem NAO existir ainda -> os handlers tratam ausencia sem quebrar.
$RunStatusFile  = Join-Path $Processed "run-status.json"
$RunHistoryFile = Join-Path $Processed "run-history.jsonl"
$HeavyQueueFile = Join-Path $Processed "heavy-queue.json"
$MeetingWatchFile = Join-Path $Processed "meeting-watch.json"

if (-not (Test-Path $Processed)) { New-Item -ItemType Directory -Path $Processed -Force | Out-Null }

# UTF-8 sem BOM: evita que ferramentas externas (json.load, etc.) tropecem
# no BOM no inicio do arquivo.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $TasksFile)) { [System.IO.File]::WriteAllText($TasksFile, "[]", $script:Utf8NoBom) }

# --- lock simples para leitura/escrita coerente do store --------------------
$script:StoreLock = [System.Object]::new()

function Read-Tasks {
    [System.Threading.Monitor]::Enter($script:StoreLock)
    try {
        $raw = [System.IO.File]::ReadAllText($TasksFile, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json
        return @($parsed)
    }
    catch { return @() }
    finally { [System.Threading.Monitor]::Exit($script:StoreLock) }
}

function Write-Tasks($tasks) {
    # Escrita atomica: grava em temp e move por cima (nao corrompe se cair).
    [System.Threading.Monitor]::Enter($script:StoreLock)
    try {
        $json = @($tasks) | ConvertTo-Json -Depth 20
        if ([string]::IsNullOrWhiteSpace($json)) { $json = "[]" }
        if ($json -notmatch '^\s*\[') { $json = "[$json]" }
        $tmp = "$TasksFile.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
        [System.IO.File]::Copy($tmp, $TasksFile, $true)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    finally { [System.Threading.Monitor]::Exit($script:StoreLock) }
}

function Rollover-Tasks($tasks) {
    # Vencidas e abertas -> dueDate = hoje. Retorna $true se mudou algo.
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $changed = $false
    foreach ($t in $tasks) {
        if (-not $t.done -and $t.dueDate -and ([string]$t.dueDate) -lt $today) {
            $t.dueDate = $today
            if ($t.PSObject.Properties.Name -contains "updatedAt") {
                $t.updatedAt = (Get-Date).ToString("o")
            }
            $changed = $true
        }
    }
    return $changed
}

# --- identidade / schema (espelha secondbrain-run.ps1) -----------------------
# Mesma normalizacao e sbid do orquestrador: assim a tarefa manual casa com a
# consolidacao de identidade (pessoa+assunto) e nunca vira card orfao no merge.
function Normalize-Text([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    $s = $s.ToLowerInvariant()
    $norm = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $s = $sb.ToString()
    $s = $s -replace '[^\w\s]', ' '
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

function New-SBID([string]$pessoa, [string]$assunto) {
    $key = (Normalize-Text $pessoa) + "|" + (Normalize-Text $assunto)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))
        $hex = -join ($bytes | ForEach-Object { $_.ToString("x2") })
        return "sb-" + $hex.Substring(0, 12)
    }
    finally { $sha.Dispose() }
}

function Get-ManualCategory([string]$status) {
    switch ($status) {
        "fazer"      { "fazer" }
        "responder"  { "responder" }
        "cobrar"     { "cobrar" }
        "aguardando" { "aguardando" }
        "preparar"   { "preparar" }
        "risco"      { "risco" }
        "referencia" { "referencia" }
        default      { "fazer" }
    }
}

function Get-ManualPrefix([string]$status) {
    switch ($status) {
        "fazer"      { "Fazer" }
        "responder"  { "Responder" }
        "cobrar"     { "Cobrar" }
        "aguardando" { "Aguardando" }
        "preparar"   { "Preparar" }
        "risco"      { "Risco" }
        "referencia" { "Ref" }
        default      { "Fazer" }
    }
}

function Resolve-ManualBoard([string]$categoria, [string]$prioridade) {
    if ($categoria -eq "referencia") { return "referencia" }
    return "active"
}

# --- MIME + estaticos --------------------------------------------------------
function Get-Mime($path) {
    switch ([IO.Path]::GetExtension($path).ToLower()) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".svg"  { "image/svg+xml" }
        ".ico"  { "image/x-icon" }
        ".png"  { "image/png" }
        default { "application/octet-stream" }
    }
}

function Send-Bytes($ctx, [int]$status, [byte[]]$bytes, [string]$contentType) {
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $contentType
    $ctx.Response.Headers["Cache-Control"] = "no-store"
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Text($ctx, [int]$status, [string]$text, [string]$contentType = "text/plain; charset=utf-8") {
    Send-Bytes $ctx $status ([Text.Encoding]::UTF8.GetBytes($text)) $contentType
}

function Send-Json($ctx, [int]$status, $obj) {
    $json = $obj | ConvertTo-Json -Depth 20
    if ($null -eq $obj -or [string]::IsNullOrWhiteSpace($json)) { $json = "[]" }
    if (($obj -is [array]) -and ($json -notmatch '^\s*\[')) { $json = "[$json]" }
    Send-Text $ctx $status $json "application/json; charset=utf-8"
}

function Serve-Static($ctx, [string]$relPath) {
    if ([string]::IsNullOrWhiteSpace($relPath) -or $relPath -eq "/") { $relPath = "index.html" }
    $relPath = $relPath.TrimStart("/")
    $full = Join-Path $WebDir $relPath
    # Impede path traversal fora de cockpit\.
    $fullResolved = [IO.Path]::GetFullPath($full)
    if (-not $fullResolved.StartsWith([IO.Path]::GetFullPath($WebDir))) {
        Send-Text $ctx 403 "Forbidden"; return
    }
    if (-not (Test-Path $fullResolved)) { Send-Text $ctx 404 "Not found: $relPath"; return }
    $bytes = [System.IO.File]::ReadAllBytes($fullResolved)
    Send-Bytes $ctx 200 $bytes (Get-Mime $fullResolved)
}

# --- API ---------------------------------------------------------------------
function Handle-GetTasks($ctx) {
    $tasks = Read-Tasks
    if (Rollover-Tasks $tasks) { Write-Tasks $tasks }
    Send-Json $ctx 200 @($tasks)
}

# --- Painel de saude / rodada (somente leitura) ------------------------------
# Le arquivos produzidos pela rodada e por outros processos. Eles podem NAO
# existir ainda -> devolve um default vazio, nunca quebra. Envia o JSON CRU do
# arquivo (sem reserializar) para preservar exatamente a estrutura contratada.
function Send-RawJson($ctx, [string]$path, [string]$fallback) {
    $text = $fallback
    try {
        if (Test-Path $path) {
            $raw = [System.IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $text = $raw }
        }
    }
    catch {}
    Send-Text $ctx 200 $text "application/json; charset=utf-8"
}

function Handle-RunStatus($ctx) {
    # Regra de obsolescencia: run-status.json fica "running" ate o fim. Se o
    # processo dono (pid) morreu (timeout da Tarefa Agendada, crash), o arquivo
    # mente "rodando" pra sempre. Aqui detectamos o pid morto e marcamos "morta"
    # em vez de mostrar rodada-zumbi. Deteccao por PROCESSO (nao por tempo): o
    # passo Meetings roda longo sem atualizar status e nao pode virar falso morto.
    $text = "{}"
    try {
        if (Test-Path $RunStatusFile) {
            $raw = [System.IO.File]::ReadAllText($RunStatusFile, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $text = $raw
                try {
                    $st = $raw | ConvertFrom-Json
                    if ([string]$st.status -eq "running") {
                        $alive = $false
                        if ($st.PSObject.Properties['pid'] -and $st.pid) {
                            $alive = [bool](Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)
                        } else {
                            # rodada antiga sem pid: fallback por tempo (>90min = morta)
                            try { $age = ((Get-Date) - [datetime]::Parse([string]$st.updatedAt)).TotalMinutes } catch { $age = 999 }
                            $alive = ($age -lt 90)
                        }
                        if (-not $alive) {
                            $st | Add-Member -NotePropertyName status     -NotePropertyValue "morta" -Force
                            $st | Add-Member -NotePropertyName deadReason -NotePropertyValue "processo encerrado (timeout/crash) em '$([string]$st.currentStep)'" -Force
                            $text = ($st | ConvertTo-Json -Depth 8)
                        }
                    }
                } catch {}
            }
        }
    } catch {}
    # Acrescenta flag de skip pendente (cockpit pode pedir pra pular a proxima rodada).
    try {
        $skipFlag = Join-Path $Processed "skip-next-run.flag"
        $st2 = $text | ConvertFrom-Json
        $st2 | Add-Member -NotePropertyName skipPending -NotePropertyValue ([bool](Test-Path $skipFlag)) -Force
        $text = ($st2 | ConvertTo-Json -Depth 8)
    } catch {}
    Send-Text $ctx 200 $text "application/json; charset=utf-8"
}
function Handle-HeavyQueue($ctx) { Send-RawJson $ctx $HeavyQueueFile '{"items":[]}' }

function Handle-MeetingWatch($ctx) {
    # Vigia de reunioes: meeting-watch.json diz running=true enquanto o daemon
    # vive. Se o pid morreu (crash, reboot sem autostart), o arquivo mente. Aqui
    # detectamos o pid morto e marcamos running=false pra nao mostrar vigia-zumbi.
    $text = '{"running":false}'
    try {
        if (Test-Path $MeetingWatchFile) {
            $raw = [System.IO.File]::ReadAllText($MeetingWatchFile, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $text = $raw
                try {
                    $mw = $raw | ConvertFrom-Json
                    if ($mw.running -eq $true -and $mw.PSObject.Properties['pid'] -and $mw.pid) {
                        $alive = [bool](Get-Process -Id ([int]$mw.pid) -ErrorAction SilentlyContinue)
                        if (-not $alive) {
                            $mw | Add-Member -NotePropertyName running    -NotePropertyValue $false -Force
                            $mw | Add-Member -NotePropertyName deadReason -NotePropertyValue "processo encerrado (crash ou reboot sem autostart)" -Force
                            $text = ($mw | ConvertTo-Json -Depth 8)
                        }
                    }
                } catch {}
            }
        }
    } catch {}
    Send-Text $ctx 200 $text "application/json; charset=utf-8"
}

# Conexao TCP com timeout curto: porta aberta responde em ~ms; porta fechada
# so espera o timeout. Usado pra checar servicos locais sem overhead de HTTP.
function Test-TcpPort([string]$TargetHost, [int]$Port, [int]$Ms = 350) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($Ms, $false) -and $client.Connected) {
            $client.EndConnect($iar); return $true
        }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch {} }
}

# Painel de dependencias: status ao vivo de tudo que o SecondBrain precisa.
# Probes cockpit-side (TCP + processo), sem tocar em voz/joule/copilot/whatsapp.
function Handle-Deps($ctx) {
    $deps = @()

    $deps += [ordered]@{ key = "llama"; label = "LLM local (llama :19001)"; ok = (Test-TcpPort "127.0.0.1" 19001); detail = "extracao de tarefas / analise" }
    $deps += [ordered]@{ key = "teams"; label = "Teams: transcricao nativa (CDP :9225)"; ok = (Test-TcpPort "127.0.0.1" 9225); detail = "nomes em tempo real, sem esperar o Copilot" }

    # Gravacao local da reuniao (whisper.cpp): a garantia 100% local (audio do
    # sistema + mic), backup do Teams nativo. Checa o binario + o modelo.
    $whisperBin = $null
    foreach ($wp in @("$Root\whisper\Release\whisper-cli.exe", "$Root\whisper\whisper-cli.exe", "C:\whisper\Release\whisper-cli.exe", "C:\whisper\whisper-cli.exe", "C:\whisper\bin\whisper-cli.exe")) {
        if (Test-Path $wp) { $whisperBin = $wp; break }
    }
    $modelOk = (Test-Path "$Root\whisper\models\ggml-medium.bin") -or (Test-Path "C:\whisper\models\ggml-medium.bin") -or (Test-Path "C:\whisper\ggml-medium.bin")
    $wdetail = if (-not $whisperBin) { "whisper-cli.exe nao encontrado (rode setup-whisper)" } elseif (-not $modelOk) { "binario ok, modelo ggml-medium ausente" } else { "grava 100% local (backup do Teams nativo)" }
    $deps += [ordered]@{ key = "record"; label = "Gravacao local (whisper)"; ok = ([bool]$whisperBin -and $modelOk); warn = ([bool]$whisperBin -and -not $modelOk); detail = $wdetail }

    # Apps CDP (Joule / Copilot / WhatsApp) nas portas 9222-9224.
    $cdpUp = 0; foreach ($p in 9222, 9223, 9224) { if (Test-TcpPort "127.0.0.1" $p 250) { $cdpUp++ } }
    $deps += [ordered]@{ key = "cdp"; label = "Apps CDP (Joule/Copilot/WhatsApp)"; ok = ($cdpUp -gt 0); warn = ($cdpUp -lt 3); detail = "$cdpUp de 3 portas ativas" }

    # Voz: conta so os processos RAIZ do voice_listen.py. O listener sobe 2
    # processos python (principal + filho worker/bandeja); contar os dois daria
    # falso "gatilho duplo". Instancia real = voice cujo PAI nao e outro voice.
    $vn = 0
    try {
        $vprocs = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine -match 'voice_listen\.py' })
        $vids = @($vprocs | ForEach-Object { [int]$_.ProcessId })
        $vn = @($vprocs | Where-Object { $vids -notcontains [int]$_.ParentProcessId }).Count
    } catch {}
    $vdetail = if ($vn -eq 0) { "parada" } elseif ($vn -eq 1) { "Ctrl+Shift+B - hey secondbrain" } else { "$vn instancias (risco de gatilho duplo)" }
    $deps += [ordered]@{ key = "voice"; label = "Voz (atalho + wake word)"; ok = ($vn -ge 1); warn = ($vn -gt 1); detail = $vdetail }

    $obj = [ordered]@{ updatedAt = (Get-Date).ToString("o"); deps = $deps }
    Send-Text $ctx 200 ($obj | ConvertTo-Json -Depth 6) "application/json; charset=utf-8"
}


function Handle-RunHistory($ctx) {
    # JSONL: uma rodada finalizada por linha. Devolve as ultimas ~20 como array.
    if (-not (Test-Path $RunHistoryFile)) { Send-Text $ctx 200 "[]" "application/json; charset=utf-8"; return }
    try {
        $lines = @(Get-Content $RunHistoryFile -Encoding UTF8 -ErrorAction Stop |
                   Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -eq 0) { Send-Text $ctx 200 "[]" "application/json; charset=utf-8"; return }
        if ($lines.Count -gt 20) { $lines = $lines[($lines.Count - 20)..($lines.Count - 1)] }
        $json = "[" + ($lines -join ",") + "]"
        Send-Text $ctx 200 $json "application/json; charset=utf-8"
    }
    catch {
        Send-Text $ctx 200 "[]" "application/json; charset=utf-8"
    }
}

# --- cerebro compartilhado: cria uma tarefa a partir de campos ja estruturados.
# Usado por /api/task (modal) e por /api/capture (voz/agente). Retorna
# @{ code = 201|400|409; task=...; error=... } (o chamador faz Send-Json).
function New-ManualTask($fields, [string]$origem = "manual") {
    $assunto = ("" + $fields.assunto).Trim()
    if (-not $assunto) { return @{ code = 400; error = "assunto obrigatorio" } }

    $pessoa       = ("" + $fields.pessoa).Trim()
    $status       = ("" + $fields.status).Trim();     if (-not $status) { $status = "fazer" }
    $prioridade   = ("" + $fields.prioridade).Trim(); if (-not $prioridade) { $prioridade = "media" }
    $proxima_acao = ("" + $fields.proxima_acao).Trim()
    $notas        = ("" + $fields.notas).Trim()
    $resumo       = ("" + $fields.resumo).Trim()
    $dueDate      = ("" + $fields.dueDate).Trim()
    if ($dueDate) {
        try { $dueDate = ([datetime]::Parse($dueDate)).ToString("yyyy-MM-dd") } catch { $dueDate = $null }
    } else { $dueDate = $null }

    $categoria = Get-ManualCategory $status
    $prefixo   = Get-ManualPrefix $status
    $board     = Resolve-ManualBoard $categoria $prioridade
    $sbid      = New-SBID $pessoa $assunto
    $nowIso    = (Get-Date).ToString("o")

    $tasks = Read-Tasks
    $existing = $tasks | Where-Object { $_.sbid -eq $sbid -and -not $_.done } | Select-Object -First 1
    if ($existing) { return @{ code = 409; error = "Ja existe uma tarefa com essa pessoa+assunto"; task = $existing } }

    $titulo = if ($pessoa) { "$pessoa - $assunto" } else { $assunto }

    $new = [pscustomobject]@{
        sbid         = $sbid
        titulo       = $titulo
        prefixo      = $prefixo
        canal        = "manual"
        fontes       = @($origem)
        pessoa       = $pessoa
        assunto      = $assunto
        resumo       = $resumo
        proxima_acao = $proxima_acao
        responsavel  = ""
        status       = $status
        tipo         = ""
        categoria    = $categoria
        prioridade   = $prioridade
        prazo        = $dueDate
        risco        = ""
        reuniao_em   = $null
        dueDate      = $dueDate
        board        = $board
        snoozedUntil = $null
        done         = $false
        notas        = $notas
        userTouched  = $nowIso
        createdAt    = $nowIso
        updatedAt    = $nowIso
        history      = @("[$nowIso] criado ($origem)")
    }

    $tasks = @($tasks) + @($new)
    Write-Tasks $tasks
    return @{ code = 201; task = $new }
}

function Handle-CreateTask($ctx) {
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()

    $in = $null
    try { $in = $body | ConvertFrom-Json } catch { Send-Json $ctx 400 @{ error = "JSON invalido" }; return }

    $origem = ("" + $in.origem).Trim(); if (-not $origem) { $origem = "manual" }
    $fields = @{
        assunto      = $in.assunto
        pessoa       = $in.pessoa
        status       = $in.status
        prioridade   = $in.prioridade
        proxima_acao = $in.proxima_acao
        notas        = $in.notas
        resumo       = $in.resumo
        dueDate      = $in.dueDate
    }
    $r = New-ManualTask $fields $origem
    if ($r.code -eq 201)     { Send-Json $ctx 201 $r.task }
    elseif ($r.code -eq 409) { Send-Json $ctx 409 @{ error = $r.error; task = $r.task } }
    else                     { Send-Json $ctx 400 @{ error = $r.error } }
}

function Handle-PostTask($ctx, [string]$sbid) {
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()

    $patch = $null
    try { $patch = $body | ConvertFrom-Json } catch { Send-Json $ctx 400 @{ error = "JSON invalido" }; return }

    $tasks = Read-Tasks
    $task = $tasks | Where-Object { $_.sbid -eq $sbid } | Select-Object -First 1
    if (-not $task) { Send-Json $ctx 404 @{ error = "sbid nao encontrado" }; return }

    $allowed = @("done", "snoozedUntil", "prioridade", "notas", "status", "dueDate")
    $history = @()
    foreach ($name in $patch.PSObject.Properties.Name) {
        if ($allowed -notcontains $name) { continue }
        $newVal = $patch.$name
        if ($task.PSObject.Properties.Name -contains $name) {
            $old = $task.$name
            $task.$name = $newVal
        }
        else {
            $task | Add-Member -NotePropertyName $name -NotePropertyValue $newVal -Force
            $old = $null
        }
        $history += "${name}: '$old' -> '$newVal'"
    }

    # Marca que o usuario tocou (o orquestrador preserva isso no merge).
    $touched = (Get-Date).ToString("o")
    if ($task.PSObject.Properties.Name -contains "updatedAt") { $task.updatedAt = $touched }
    else { $task | Add-Member -NotePropertyName "updatedAt" -NotePropertyValue $touched -Force }
    if ($task.PSObject.Properties.Name -contains "userTouched") { $task.userTouched = $touched }
    else { $task | Add-Member -NotePropertyName "userTouched" -NotePropertyValue $touched -Force }

    if ($task.PSObject.Properties.Name -notcontains "history") {
        $task | Add-Member -NotePropertyName "history" -NotePropertyValue @() -Force
    }
    $task.history = @($task.history) + @("[$touched] " + ($history -join "; "))

    Write-Tasks $tasks
    Send-Json $ctx 200 $task
}

# --- Joule (assincrono) ------------------------------------------------------
# O Joule Desktop e dirigido por CDP (joule-terminal.ps1) e a resposta pode
# levar varios minutos em consultas pesadas (executivo multi-cliente: le
# e-mail/calendario via tool-call). Como o HttpListener
# e single-thread, NAO da pra proxiar inline (travaria o cockpit inteiro).
# Solucao: POST /api/joule dispara um processo separado e volta na hora com um
# id; o browser faz poll em GET /api/joule/{id}. O board nunca congela.
$JouleScript = Join-Path $Root "joule-terminal.ps1"
$JouleTmp    = Join-Path $Processed "joule-jobs"
if (-not (Test-Path $JouleTmp)) { New-Item -ItemType Directory -Path $JouleTmp -Force | Out-Null }
$script:JouleJobs   = @{}
$script:JouleMaxSec = 450   # guarda-chuva de seguranca: so mata se o processo pendurar (acima do -TimeoutSec interno, que devolve resposta/erro proprio antes)

function Handle-JouleAsk($ctx) {
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()

    $in = $null
    try { $in = $body | ConvertFrom-Json } catch { Send-Json $ctx 400 @{ error = "JSON invalido" }; return }

    $prompt = ("" + $in.prompt).Trim()
    if (-not $prompt) { Send-Json $ctx 400 @{ error = "prompt vazio" }; return }

    if (-not (Test-Path $JouleScript)) { Send-Json $ctx 500 @{ error = "joule-terminal.ps1 nao encontrado" }; return }

    # Injeta o caminho do store como referencia (Joule le o arquivo local sozinho).
    $full = $prompt + "`r`n`r`nUse o arquivo " + $TasksFile + " (minhas tarefas/pendencias do SecondBrain, em JSON) como referencia para responder."

    $id       = "j-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
    $promptFp = Join-Path $JouleTmp "$id.in.txt"
    $outFp    = Join-Path $JouleTmp "$id.out.txt"
    $errFp    = Join-Path $JouleTmp "$id.err.txt"
    [System.IO.File]::WriteAllText($promptFp, $full, $script:Utf8NoBom)

    try {
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $JouleScript,
                "-PromptFile", $promptFp,
                "-TimeoutSec", "420"
            ) `
            -RedirectStandardOutput $outFp `
            -RedirectStandardError  $errFp `
            -WindowStyle Hidden `
            -PassThru
    }
    catch {
        Send-Json $ctx 500 @{ error = "Nao consegui iniciar o Joule: " + $_.Exception.Message }; return
    }

    $script:JouleJobs[$id] = [pscustomobject]@{
        Proc      = $proc
        OutFile   = $outFp
        ErrFile   = $errFp
        InFile    = $promptFp
        StartedAt = Get-Date
    }
    Send-Json $ctx 202 @{ id = $id; status = "pending" }
}

function Cleanup-JouleJob($job) {
    foreach ($f in @($job.InFile, $job.OutFile, $job.ErrFile)) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
}

function Handle-JoulePoll($ctx, [string]$id) {
    $job = $script:JouleJobs[$id]
    if (-not $job) { Send-Json $ctx 404 @{ error = "job desconhecido"; status = "error" }; return }

    $proc = $job.Proc
    $exited = $false
    try { $exited = $proc.HasExited } catch { $exited = $true }

    if (-not $exited) {
        # Guarda-chuva de tempo: se estourar, mata e devolve erro.
        if (((Get-Date) - $job.StartedAt).TotalSeconds -gt $script:JouleMaxSec) {
            try { $proc.Kill() } catch {}
            $script:JouleJobs.Remove($id)
            Cleanup-JouleJob $job
            Send-Json $ctx 200 @{ status = "error"; error = "Joule demorou demais (timeout)." }
            return
        }
        Send-Json $ctx 200 @{ status = "pending" }
        return
    }

    # Terminou: le a saida.
    $out = ""; $err = ""
    try { if (Test-Path $job.OutFile) { $out = ([System.IO.File]::ReadAllText($job.OutFile, [Text.Encoding]::UTF8)).Trim() } } catch {}
    try { if (Test-Path $job.ErrFile) { $err = ([System.IO.File]::ReadAllText($job.ErrFile, [Text.Encoding]::UTF8)).Trim() } } catch {}

    $script:JouleJobs.Remove($id)
    Cleanup-JouleJob $job

    if ($out) {
        Send-Json $ctx 200 @{ status = "done"; text = $out }
    }
    elseif ($err) {
        Send-Json $ctx 200 @{ status = "error"; error = $err }
    }
    else {
        Send-Json $ctx 200 @{ status = "error"; error = "Joule nao retornou resposta." }
    }
}

function Handle-RunNow($ctx) {
    # Bloqueia se ja ha rodada viva (PID ativo no run-status.json).
    try {
        if (Test-Path $RunStatusFile) {
            $rs = [System.IO.File]::ReadAllText($RunStatusFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ([string]$rs.status -eq "running" -and $rs.pid) {
                $alive = [bool](Get-Process -Id ([int]$rs.pid) -ErrorAction SilentlyContinue)
                if ($alive) { Send-Json $ctx 409 @{ error = "rodada em execucao (PID $($rs.pid))" }; return }
            }
        }
    } catch {}
    $ps1 = Join-Path $Root "secondbrain-run.ps1"
    $proc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ps1) `
        -WindowStyle Hidden `
        -PassThru
    Send-Json $ctx 202 @{ status = "started"; pid = $proc.Id }
}

function Handle-ToggleSkip($ctx) {
    $skipFlag = Join-Path $Processed "skip-next-run.flag"
    if (Test-Path $skipFlag) {
        Remove-Item $skipFlag -Force -ErrorAction SilentlyContinue
        Send-Json $ctx 200 @{ skipPending = $false }
    } else {
        [System.IO.File]::WriteAllText($skipFlag, (Get-Date).ToString("o"), $script:Utf8NoBom)
        Send-Json $ctx 200 @{ skipPending = $true }
    }
}

# --- servidor ----------------------------------------------------------------
$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "Nao consegui abrir $prefix" -ForegroundColor Red
    Write-Host "Se for 'Access denied', rode UMA vez (como admin):" -ForegroundColor Yellow
    Write-Host "  netsh http add urlacl url=$prefix user=$env:USERNAME" -ForegroundColor Yellow
    throw
}

Write-Host ""
Write-Host "  SECONDBRAIN COCKPIT" -ForegroundColor Cyan
Write-Host "  $prefix" -ForegroundColor Green
Write-Host "  store: $TasksFile" -ForegroundColor DarkGray
Write-Host "  Ctrl+C para parar." -ForegroundColor DarkGray
Write-Host ""

if ($Open) { Start-Process $prefix }

try {
    while ($listener.IsListening) {
        # NAO usar GetContext() sincrono: ele BLOQUEIA em chamada nativa ate
        # chegar uma request, e o Ctrl+C do PowerShell (processado so entre
        # instrucoes) nunca consegue interromper -> o cockpit nao parava.
        # GetContextAsync + WaitOne(300ms) devolve o controle ao PS a cada 300ms,
        # deixando o Ctrl+C ser processado entre as iteracoes (o finally para o
        # listener). Sem isso, so fechando a janela/matando o processo.
        $task = $listener.GetContextAsync()
        while (-not ([System.IAsyncResult]$task).AsyncWaitHandle.WaitOne(300)) { }
        $ctx = $task.GetAwaiter().GetResult()
        try {
            $method = $ctx.Request.HttpMethod
            $path = $ctx.Request.Url.AbsolutePath

            if ($method -eq "GET" -and $path -eq "/api/tasks") {
                Handle-GetTasks $ctx
            }
            elseif ($method -eq "GET" -and $path -eq "/api/run-status") {
                Handle-RunStatus $ctx
            }
            elseif ($method -eq "GET" -and $path -eq "/api/run-history") {
                Handle-RunHistory $ctx
            }
            elseif ($method -eq "GET" -and $path -eq "/api/heavy-queue") {
                Handle-HeavyQueue $ctx
            }
            elseif ($method -eq "GET" -and $path -eq "/api/meeting-watch") {
                Handle-MeetingWatch $ctx
            }
            elseif ($method -eq "GET" -and $path -eq "/api/deps") {
                Handle-Deps $ctx
            }
            elseif ($method -eq "POST" -and $path -eq "/api/task") {
                Handle-CreateTask $ctx
            }
            elseif ($method -eq "POST" -and $path -eq "/api/run-now") {
                Handle-RunNow $ctx
            }
            elseif ($method -eq "POST" -and $path -eq "/api/skip-next-run") {
                Handle-ToggleSkip $ctx
            }
            elseif ($method -eq "POST" -and $path -eq "/api/joule") {
                Handle-JouleAsk $ctx
            }
            elseif ($method -eq "GET" -and $path -like "/api/joule/*") {
                $jid = [System.Uri]::UnescapeDataString($path.Substring("/api/joule/".Length))
                Handle-JoulePoll $ctx $jid
            }
            elseif ($method -eq "POST" -and $path -like "/api/task/*") {
                $sbid = [System.Uri]::UnescapeDataString($path.Substring("/api/task/".Length))
                Handle-PostTask $ctx $sbid
            }
            elseif ($method -eq "GET") {
                Serve-Static $ctx $path
            }
            else {
                Send-Text $ctx 405 "Method not allowed"
            }
        }
        catch {
            try { Send-Text $ctx 500 ("Erro: " + $_.Exception.Message) } catch {}
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}

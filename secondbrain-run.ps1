param(
    [switch]$SkipJoule,
    [switch]$SkipCopilot,
    [switch]$SkipWhatsApp,
    [switch]$SkipAudio,
    [switch]$SkipMeetings,
    [switch]$SkipCockpit,
    [switch]$OpenCockpit,
    [int]$Port = 8787,
    [string]$Date = "",
    [switch]$DryRun,
    [switch]$InitialLoad,
    [ValidateSet("joule","local")]
    [string]$WhatsAppEngine = "local"
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch {}

# ============================================================
# SECONDBRAIN - ORQUESTRADOR (entrada unica)
#
# Roda a rodada inteira sozinho:
#   1) Coleta de cada canal (Joule / Copilot / WhatsApp), isolado
#      por try/catch: se um falha, os outros seguem.
#   2) Consolidacao DETERMINISTICA em PowerShell (sem 2a LLM):
#      normaliza, calcula SB-ID, dedup, prioriza, categoriza,
#      define due date e prefixo.
#   3) Merge no store vivo (processed\tasks.json) preservando o
#      estado que o usuario setou no cockpit (done/snooze/notas).
#   4) Roll-over de vencidas -> hoje.
#   5) Abre o cockpit local (-OpenCockpit).
#
# Tudo local. Nada sai para a nuvem alem das chamadas naturais
# dos canais Joule/Copilot.
# ============================================================

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$PromptsDir = Join-Path $Root "prompts"
$LogsDir    = Join-Path $Root "logs"
$RawDir     = Join-Path $Root "raw"
$Processed  = Join-Path $Root "processed"
$TasksFile  = Join-Path $Processed "tasks.json"
$LastRunFile = Join-Path $Processed "last-run.json"

$JoulePs    = Join-Path $Root "joule-terminal.ps1"
$CopilotPs  = Join-Path $Root "copilot-terminal.ps1"
$CollectPs  = Join-Path $Root "whatsapp-collector.ps1"
$AudioPs    = Join-Path $Root "whatsapp-audio.ps1"
$TranscribePs = Join-Path $Root "whatsapp-transcribe.ps1"
$AnalyzePs  = Join-Path $Root "analyze-whatsapp.ps1"
$MeetingDetectorPs = Join-Path $Root "meeting-detector.ps1"
$CockpitPs  = Join-Path $Root "cockpit.ps1"

foreach ($d in @($LogsDir, $RawDir, $Processed)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$ts      = (Get-Date).ToString("yyyyMMdd-HHmmss")
$LogFile = Join-Path $LogsDir "run-$ts.log"

# UTF-8 sem BOM para os artefatos JSON (evita BOM que quebra parsers externos).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- data-base ---------------------------------------------------------------
$baseDate = if ($Date) { [datetime]::Parse($Date) } else { (Get-Date).Date }
$today    = $baseDate.ToString("yyyy-MM-dd")

# ============================================================
# LOG
# ============================================================
function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] $Text"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

Log "=== SecondBrain run $ts ===" Cyan
Log ("Modo: " + $(if ($InitialLoad) { "CARGA INICIAL" } else { "diario" }) + $(if ($DryRun) { " (DryRun)" } else { "" }) + " | data-base: $today") Cyan

# ============================================================
# PREFLIGHT - garante que os apps dos canais estao ABERTOS
#
# Pedido do usuario: "se nao tiver aberto, que abra sozinho para garantir e
# nao falhar". Cada canal ja auto-abre seu app (bridge do Joule/Copilot,
# Restart-Firefox do collector), mas aqui a gente ABRE proativamente e loga o
# estado de tudo de cara (nunca silencioso) pra reduzir cold-start/timeout e
# deixar visivel o que esta no ar. Tudo best-effort e NAO-FATAL: se algo aqui
# falhar, os canais seguem (cada um tenta abrir de novo). whatsapp-collector.ps1
# NAO e tocado - reutilizamos os MESMOS args do Firefox que ele espera.
# ============================================================
function Test-TcpPort([string]$AppHost, [int]$AppPort, [int]$TimeoutMs = 800) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect($AppHost, $AppPort, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok) { $c.EndConnect($iar) }
        $c.Close()
        return $ok
    } catch { return $false }
}

Log "Preflight: conferindo apps dos canais (abre sozinho se estiver fechado)..." Cyan

# --- Joule Desktop (CDP :9222) -----------------------------------------------
if (-not $SkipJoule) {
    if (Test-TcpPort '127.0.0.1' 9222) {
        Log "  Joule Desktop: JA ABERTO (:9222)." Green
    } else {
        $jouleExe = Join-Path $env:LOCALAPPDATA "Programs\Joule Desktop\Joule Desktop.exe"
        $jouleProc = Get-Process -Name "Joule Desktop" -ErrorAction SilentlyContinue
        if ($jouleProc -and $jouleProc[0].Path) { $jouleExe = $jouleProc[0].Path }
        if (Test-Path $jouleExe) {
            try {
                Start-Process -FilePath $jouleExe -ArgumentList @("--remote-debugging-address=127.0.0.1", "--remote-debugging-port=9222")
                Log "  Joule Desktop: fechado -> abrindo com CDP (:9222)." Yellow
                # Aguarda a porta CDP ficar disponivel (max 45s), igual ao Firefox/WhatsApp.
                # Sem essa espera, o canal Joule dispara a query antes do app estar pronto.
                $jouleDeadline = (Get-Date).AddSeconds(45)
                while ((Get-Date) -lt $jouleDeadline) {
                    if (Test-TcpPort '127.0.0.1' 9222 500) { Log "  Joule Desktop: CDP ativo." Green; break }
                    Start-Sleep -Milliseconds 800
                }
            } catch { Log "  Joule Desktop: falha ao abrir ($($_.Exception.Message)); o canal tenta de novo." DarkYellow }
        } else {
            Log "  Joule Desktop: exe nao encontrado; o canal Joule tenta abrir sozinho." DarkYellow
        }
    }
}

# --- Firefox / WhatsApp Web (BiDi :9224) -------------------------------------
# Abrir AQUI (com os MESMOS args do collector) deixa o WhatsApp Web ja
# carregado antes do collector E do extrator de audio -> reduz o caso de 0
# audios por aba nao-pronta. Se ja estiver no ar, nao mexe.
if (-not $SkipWhatsApp) {
    if (Test-TcpPort '127.0.0.1' 9224) {
        Log "  Firefox/WhatsApp: JA ABERTO (:9224)." Green
    } else {
        $ffPath    = "C:\Program Files\Mozilla Firefox\firefox.exe"
        $ffProfile = "C:\Users\I827769\AppData\Roaming\Mozilla\Firefox\Profiles\qyl4c5lr.default-release"
        if (Test-Path $ffPath) {
            try {
                $ffArgs = "-no-remote -profile `"$ffProfile`" --remote-debugging-port=9224 https://web.whatsapp.com/"
                Start-Process -FilePath $ffPath -ArgumentList $ffArgs
                Log "  Firefox/WhatsApp: fechado -> abrindo WhatsApp Web (BiDi :9224)." Yellow
                # da um tempo pro WhatsApp Web carregar antes do collector conectar
                $ffDeadline = (Get-Date).AddSeconds(30)
                while ((Get-Date) -lt $ffDeadline) {
                    if (Test-TcpPort '127.0.0.1' 9224 500) { break }
                    Start-Sleep -Milliseconds 700
                }
            } catch { Log "  Firefox/WhatsApp: falha ao abrir ($($_.Exception.Message)); o collector tenta de novo." DarkYellow }
        } else {
            Log "  Firefox/WhatsApp: firefox.exe nao encontrado; o collector tenta abrir sozinho." DarkYellow
        }
    }
}

# --- Microsoft 365 Copilot (CDP :9223) ---------------------------------------
# NAO abrimos aqui de proposito: o bridge do copilot-terminal.ps1 MATA e
# relanca o M365Copilot pra conseguir a porta de debug; abrir antes so seria
# desperdicado. So logamos o estado.
if (-not $SkipCopilot) {
    if (Test-TcpPort '127.0.0.1' 9223) {
        Log "  Copilot Desktop: JA ABERTO com CDP (:9223)." Green
    } else {
        Log "  Copilot Desktop: sem CDP; o canal Copilot abre/relanca sozinho (pode demorar ~30s)." Yellow
    }
}

# ============================================================
# HELPERS DE CONSOLIDACAO
# ============================================================
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

function Get-SBID([string]$pessoa, [string]$assunto, [string]$categoria) {
    # Identidade ESTAVEL: so pessoa + assunto. O status/categoria NAO entra na
    # identidade, senao a mesma tarefa vira card novo toda vez que muda de
    # situacao (ex.: "aguardando" -> "responder") e o card antigo fica orfao.
    # (o parametro $categoria fica so por compatibilidade de chamada)
    $key = (Normalize-Text $pessoa) + "|" + (Normalize-Text $assunto)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))
        $hex = -join ($bytes | ForEach-Object { $_.ToString("x2") })
        return "sb-" + $hex.Substring(0, 12)
    }
    finally { $sha.Dispose() }
}

function Get-Category([string]$status, [string]$canal, [string]$tipo) {
    if ($canal -eq "whatsapp" -and $tipo -eq "pessoal") { return "whatsapp-pessoal" }
    switch ($status) {
        "fazer"      { return "fazer" }
        "responder"  { return "responder" }
        "cobrar"     { return "cobrar" }
        "aguardando" { return "aguardando" }
        "preparar"   { return "preparar" }
        "risco"      { return "risco" }
        "referencia" {
            if ($canal -eq "whatsapp" -and $tipo -eq "trabalho") { return "whatsapp-trabalho" }
            return "referencia"
        }
        default {
            if ($canal -eq "whatsapp" -and $tipo -eq "trabalho") { return "whatsapp-trabalho" }
            return "fazer"
        }
    }
}

function Get-Prefix([string]$status, [string]$tipo) {
    if ($tipo -eq "pessoal") { return "Pessoal" }
    switch ($status) {
        "fazer"      { return "Fazer" }
        "responder"  { return "Responder" }
        "cobrar"     { return "Cobrar" }
        "aguardando" { return "Aguardando" }
        "preparar"   { return "Preparar" }
        "risco"      { return "Risco" }
        default      { return "Fazer" }
    }
}

function Next-BusinessDay([datetime]$from) {
    $d = $from.AddDays(1)
    while ($d.DayOfWeek -eq 'Saturday' -or $d.DayOfWeek -eq 'Sunday') { $d = $d.AddDays(1) }
    return $d
}

function Get-DueDate([string]$status, [string]$prazo, [string]$reuniaoEm) {
    if ($prazo -and $prazo -ne "null") {
        try { return ([datetime]::Parse($prazo)).ToString("yyyy-MM-dd") } catch { }
    }
    switch ($status) {
        "responder"  { return $today }
        "cobrar"     { return $today }
        "fazer"      { return $today }
        "risco"      { return $today }
        "aguardando" { return (Next-BusinessDay $baseDate).ToString("yyyy-MM-dd") }
        "preparar" {
            if ($reuniaoEm -and $reuniaoEm -ne "null") {
                try { return ([datetime]::Parse($reuniaoEm)).AddDays(-1).ToString("yyyy-MM-dd") } catch { }
            }
            return $today
        }
        "referencia" { return $null }
        default      { return $today }
    }
}

function Prio-Rank([string]$p) {
    switch ($p) { "alta" { 3 } "media" { 2 } "baixa" { 1 } default { 2 } }
}

function Extract-JsonArray([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $clean = $text -replace '```json', '' -replace '```', ''
    $start = $clean.IndexOf('[')
    if ($start -lt 0) { return $null }
    $body = $clean.Substring($start)

    # 1) array completo (primeiro '[' ate o ultimo ']')
    $end = $body.LastIndexOf(']')
    if ($end -gt 0) {
        try { return @($body.Substring(0, $end + 1) | ConvertFrom-Json) } catch {}
    }

    # 2) reparo p/ resposta truncada (Joule/Copilot as vezes cortam saidas
    #    longas): recua ate o ultimo objeto '}' completo e fecha o array ali,
    #    salvando os itens integros em vez de perder a rodada inteira.
    $lastObj = $body.LastIndexOf('}')
    while ($lastObj -gt 0) {
        try { return @(($body.Substring(0, $lastObj + 1) + ']') | ConvertFrom-Json) } catch {}
        $lastObj = $body.LastIndexOf('}', $lastObj - 1)
    }
    return $null
}

# Roda um scriptblock capturando o stdout (Write-Output) como texto e
# separando erros (ErrorRecord) do PowerShell. Logs via Write-Host/stderr
# do proprio canal aparecem no console e nao poluem o texto capturado.
function Invoke-Capture([scriptblock]$Block) {
    $outAcc = New-Object System.Text.StringBuilder
    $errAcc = New-Object System.Text.StringBuilder
    $results = & $Block 2>&1
    foreach ($item in $results) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            [void]$errAcc.AppendLine($item.ToString())
        }
        elseif ($item -is [System.Management.Automation.WarningRecord]) {
            # ignora
        }
        else {
            [void]$outAcc.AppendLine([string]$item)
        }
    }
    return [pscustomobject]@{ Text = $outAcc.ToString(); Err = $errAcc.ToString() }
}

# Captura + extrai o array JSON, com retry curto quando o Joule da o soluco de
# governanca ("politicas da sua organizacao" / "organization policies") - que e
# transitorio. Nao repete em outros erros (ex.: LLM local lento), pra nao
# reprocessar analises caras a toa.
function Invoke-JsonWithRetry([scriptblock]$Block, [int]$Tries = 2, [int]$WaitSec = 6) {
    $cap = $null
    for ($i = 1; $i -le $Tries; $i++) {
        $cap = Invoke-Capture $Block
        $arr = Extract-JsonArray $cap.Text
        if ($null -ne $arr) {
            return [pscustomobject]@{ Text = $cap.Text; Err = $cap.Err; Arr = $arr }
        }
        $isPolicy = $cap.Text -match '(?i)pol[ií]tic.{0,40}organiza|organization.{0,20}polic'
        if ($isPolicy -and $i -lt $Tries) {
            Log "  soluco de governanca do Joule; nova tentativa em ${WaitSec}s..." DarkYellow
            Start-Sleep -Seconds $WaitSec
            continue
        }
        break
    }
    return [pscustomobject]@{ Text = $cap.Text; Err = $cap.Err; Arr = $null }
}

# ============================================================
# JANELAS
# Se houver um run anterior com sucesso, expande a janela para cobrir o gap
# (ex.: computador ficou desligado 2 dias -> busca 48h em vez de 24h).
# Tetos: Joule 14 dias, Copilot 72h, WhatsApp 14 dias (evita sobrecarga).
# ============================================================
if ($InitialLoad) {
    $jouleWindow   = "os ultimos 14 dias (e-mails) e o proximo dia util (calendario)"
    $copilotWindow = "os ultimos 7 dias (Teams, transcricoes e e-mails)"
    $waDays        = 90
    $meetingAhead  = 7
}
else {
    # Calcula gap real desde o ultimo run bem-sucedido.
    if ($lastSuccessRun) {
        try {
            $gapHours = [int]([datetime]::UtcNow - [datetime]::Parse($lastSuccessRun)).TotalHours
        } catch { $gapHours = 24 }
    } else { $gapHours = 24 }

    $jouleHours    = [math]::Min([math]::Max(72,  $gapHours), 14 * 24)
    $copilotHours  = [math]::Min([math]::Max(24,  $gapHours), 72)
    $waDaysGap     = [math]::Min([math]::Max(2,   [math]::Ceiling($gapHours / 24)), 14)
    $jouleDays     = [math]::Ceiling($jouleHours / 24)

    $jouleWindow   = "os ultimos $jouleDays dias (e-mails) e o proximo dia util (calendario)"
    $copilotWindow = "as ultimas $copilotHours horas (Teams, transcricoes e e-mails)"
    $waDays        = $waDaysGap
    $meetingAhead  = 1

    if ($gapHours -gt 25) {
        Log ("Gap desde ultimo run: ${gapHours}h -> janela expandida: Joule=${jouleDays}d Copilot=${copilotHours}h WA=${waDaysGap}d") Yellow
    }
}

$channelStatus = [ordered]@{}
$allItems = New-Object System.Collections.ArrayList

# ============================================================
# CANAL: JOULE
# ============================================================
if (-not $SkipJoule) {
    try {
        $tpl = Get-Content (Join-Path $PromptsDir "joule.md") -Raw -Encoding UTF8
        $prompt = $tpl -replace '\{\{JANELA\}\}', $jouleWindow
        Log "Joule: consultando e-mail/calendario ($jouleWindow)..." Cyan

        $cap = Invoke-JsonWithRetry { & $JoulePs -Prompt $prompt -TimeoutSec 240 }
        $rawFile = Join-Path $RawDir "joule-$ts.txt"
        [System.IO.File]::WriteAllText($rawFile, $cap.Text, [Text.Encoding]::UTF8)

        $arr = $cap.Arr
        if ($null -eq $arr) {
            throw "JSON nao extraido da resposta do Joule." + $(if ($cap.Err) { " " + $cap.Err } else { "" })
        }
        foreach ($it in $arr) { [void]$allItems.Add($it) }
        $channelStatus["Joule"] = "OK ($($arr.Count) itens)"
        Log "Joule OK: $($arr.Count) itens." Green
    }
    catch {
        $channelStatus["Joule"] = "FALHOU: $($_.Exception.Message)"
        Log "Joule FALHOU: $($_.Exception.Message)" Red
    }
}
else { $channelStatus["Joule"] = "pulado" }

# ============================================================
# CANAL: COPILOT
# ============================================================
if (-not $SkipCopilot) {
    try {
        $tpl = Get-Content (Join-Path $PromptsDir "copilot.md") -Raw -Encoding UTF8
        $prompt = $tpl -replace '\{\{JANELA\}\}', $copilotWindow
        Log "Copilot: consultando Teams/transcricoes/e-mail ($copilotWindow)..." Cyan

        # 360s: a busca do M365 Copilot sobre 24h de Teams+transcricoes+e-mail e
        # lenta e estourava os 240s (falha calada em Teams/e-mails). Mais folga.
        $cap = Invoke-Capture { & $CopilotPs -Prompt $prompt -TimeoutSec 360 }
        $rawFile = Join-Path $RawDir "copilot-$ts.txt"
        [System.IO.File]::WriteAllText($rawFile, $cap.Text, [Text.Encoding]::UTF8)

        $arr = Extract-JsonArray $cap.Text
        if ($null -eq $arr) {
            throw "JSON nao extraido da resposta do Copilot." + $(if ($cap.Err) { " " + $cap.Err } else { "" })
        }
        foreach ($it in $arr) { [void]$allItems.Add($it) }
        $channelStatus["Copilot"] = "OK ($($arr.Count) itens)"
        Log "Copilot OK: $($arr.Count) itens." Green
    }
    catch {
        $channelStatus["Copilot"] = "FALHOU: $($_.Exception.Message)"
        Log "Copilot FALHOU: $($_.Exception.Message)" Red
    }
}
else { $channelStatus["Copilot"] = "pulado" }

# ============================================================
# CANAL: WHATSAPP (coletor incremental + analise JSON local)
# ============================================================
# O motor local do WhatsApp (e reunioes) depende do llama-server. Se ele
# estiver fechado, sobe sozinho aqui (start-llama.ps1 e idempotente: nao
# duplica se ja estiver no ar). Assim a rodada agendada nao falha calada
# so porque o llama nao estava aberto.
if (-not $SkipWhatsApp -and $WhatsAppEngine -eq 'local') {
    try {
        $StartLlamaPs = Join-Path $Root "start-llama.ps1"
        if (Test-Path $StartLlamaPs) {
            Log "Garantindo llama-server local no ar (auto-start se fechado)..." Cyan
            & $StartLlamaPs | Out-Null
            # espera a porta responder (o modelo 30B demora a carregar); best-effort
            $deadline = (Get-Date).AddSeconds(90); $llamaUp = $false
            while ((Get-Date) -lt $deadline) {
                try {
                    $tc = New-Object Net.Sockets.TcpClient
                    $iar = $tc.BeginConnect('127.0.0.1', 19001, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(1000)) { $tc.EndConnect($iar); $llamaUp = $true; $tc.Close(); break }
                    $tc.Close()
                } catch {}
                Start-Sleep -Milliseconds 800
            }
            if ($llamaUp) { Log "llama-server pronto (:19001)." Green }
            else { Log "llama-server nao respondeu em 90s; a analise local pode falhar/esperar mais." Yellow }
        }
    } catch { Log "Aviso: falha ao garantir llama-server: $($_.Exception.Message)" Yellow }
}

if (-not $SkipWhatsApp) {
    try {
        Log "WhatsApp: coletando mensagens (Firefox pode reiniciar)..." Cyan
        try {
            $capCollect = Invoke-Capture { & $CollectPs }
            if ($capCollect.Err) { Log "WhatsApp coletor (avisos): $($capCollect.Err.Trim())" DarkGray }
        }
        catch {
            Log "WhatsApp coletor: $($_.Exception.Message) - seguindo com a base existente." Yellow
        }

        # Audios (notas de voz): extrai bytes do WhatsApp Web e transcreve local
        # com whisper.cpp. Best-effort e nao-fatal: se qualquer passo falhar, o
        # canal WhatsApp segue com o texto normal.
        if (-not $SkipAudio) {
            try {
                Log "WhatsApp: extraindo notas de voz (best-effort)..." Cyan
                $capAudio = Invoke-Capture { & $AudioPs -Days $waDays }
                if ($capAudio.Err) { Log "WhatsApp audio extrator (avisos): $($capAudio.Err.Trim())" DarkGray }
            }
            catch { Log "WhatsApp audio extrator: $($_.Exception.Message) - seguindo." Yellow }

            try {
                Log "WhatsApp: transcrevendo audios com whisper local..." Cyan
                $capTr = Invoke-Capture { & $TranscribePs -Quiet }
                if ($capTr.Text) { Log ("WhatsApp transcricao: " + ($capTr.Text.Trim() -split "`n" | Select-Object -Last 1)) DarkGray }
                if ($capTr.Err) { Log "WhatsApp transcricao (avisos): $($capTr.Err.Trim())" DarkGray }
            }
            catch { Log "WhatsApp transcricao: $($_.Exception.Message) - seguindo sem audios." Yellow }
        }

        $waEngineLabel = if ($WhatsAppEngine -eq 'joule') { "via Joule" } else { "com LLM local" }
        Log "WhatsApp: analisando ultimos $waDays dias $waEngineLabel..." Cyan
        $cap = Invoke-JsonWithRetry { & $AnalyzePs -Days $waDays -Json -Engine $WhatsAppEngine }
        $rawFile = Join-Path $RawDir "whatsapp-$ts.json"
        [System.IO.File]::WriteAllText($rawFile, $cap.Text, [Text.Encoding]::UTF8)

        $arr = $cap.Arr
        if ($null -eq $arr) {
            throw "JSON nao extraido da analise do WhatsApp." + $(if ($cap.Err) { " " + $cap.Err } else { "" })
        }
        foreach ($it in $arr) { [void]$allItems.Add($it) }
        $channelStatus["WhatsApp"] = "OK ($($arr.Count) itens)"
        Log "WhatsApp OK: $($arr.Count) itens." Green
    }
    catch {
        $channelStatus["WhatsApp"] = "FALHOU: $($_.Exception.Message)"
        Log "WhatsApp FALHOU: $($_.Exception.Message)" Red
    }
}
else { $channelStatus["WhatsApp"] = "pulado" }

# ============================================================
# CANAL: MEETINGS (detector de reuniao: calendario + transcricoes locais)
# ============================================================
if (-not $SkipMeetings) {
    try {
        Log "Meetings: lendo calendario (proximos $meetingAhead dia(s)) e transcricoes..." Cyan
        $cap = Invoke-Capture { & $MeetingDetectorPs -Ahead $meetingAhead -Json }
        $rawFile = Join-Path $RawDir "meetings-$ts.json"
        [System.IO.File]::WriteAllText($rawFile, $cap.Text, [Text.Encoding]::UTF8)

        $arr = Extract-JsonArray $cap.Text
        if ($null -eq $arr) {
            throw "JSON nao extraido do detector de reuniao." + $(if ($cap.Err) { " " + $cap.Err } else { "" })
        }
        foreach ($it in $arr) { [void]$allItems.Add($it) }
        $channelStatus["Meetings"] = "OK ($($arr.Count) itens)"
        Log "Meetings OK: $($arr.Count) itens." Green
    }
    catch {
        $channelStatus["Meetings"] = "FALHOU: $($_.Exception.Message)"
        Log "Meetings FALHOU: $($_.Exception.Message)" Red
    }
}
else { $channelStatus["Meetings"] = "pulado" }

Log "Total de itens crus coletados: $($allItems.Count)." Gray

# ============================================================
# CONSOLIDACAO DETERMINISTICA
# ============================================================
$consolidated = @{}   # sbid -> objeto consolidado

foreach ($raw in $allItems) {
    if ($null -eq $raw) { continue }

    $status = ([string]$raw.status).ToLower().Trim()
    if ([string]::IsNullOrWhiteSpace($status)) { $status = "fazer" }
    $canal  = ([string]$raw.canal).ToLower().Trim()
    $tipo   = ([string]$raw.tipo).ToLower().Trim()
    if ([string]::IsNullOrWhiteSpace($tipo)) { $tipo = "trabalho" }

    $pessoa  = if ($raw.pessoa -and "$($raw.pessoa)" -ne "null") { [string]$raw.pessoa } else { "" }
    $assunto = if ($raw.assunto -and "$($raw.assunto)" -ne "null") { [string]$raw.assunto } else { "(sem assunto)" }
    $prio    = ([string]$raw.prioridade).ToLower().Trim()
    if ($prio -notin @("alta", "media", "baixa")) { $prio = "media" }

    $categoria = Get-Category $status $canal $tipo
    $sbid      = Get-SBID $pessoa $assunto $categoria
    $prazoStr  = if ($raw.prazo -and "$($raw.prazo)" -ne "null") { [string]$raw.prazo } else { "" }
    $reuniao   = if ($raw.reuniao_em -and "$($raw.reuniao_em)" -ne "null") { [string]$raw.reuniao_em } else { "" }
    $dueDate   = Get-DueDate $status $prazoStr $reuniao
    $prefixo   = Get-Prefix $status $tipo
    $fonte     = if ($raw.fonte -and "$($raw.fonte)" -ne "null") { [string]$raw.fonte } else { $canal }

    if ($consolidated.ContainsKey($sbid)) {
        # Colapsa mesma pendencia vinda de canais diferentes.
        $ex = $consolidated[$sbid]
        if ($ex.fontes -notcontains $fonte) { $ex.fontes += $fonte }
        if ($ex.canais -notcontains $canal) { $ex.canais += $canal }
        # mantem a maior prioridade
        if ((Prio-Rank $prio) -gt (Prio-Rank $ex.prioridade)) { $ex.prioridade = $prio }
        # mantem o menor prazo (mais cedo)
        if ($dueDate -and (-not $ex.dueDate -or $dueDate -lt $ex.dueDate)) { $ex.dueDate = $dueDate }
        # preenche campos que estavam vazios
        if (-not $ex.resumo -and $raw.resumo) { $ex.resumo = [string]$raw.resumo }
        if (-not $ex.proxima_acao -and $raw.proxima_acao) { $ex.proxima_acao = [string]$raw.proxima_acao }
        if (-not $ex.risco -and $raw.risco -and "$($raw.risco)" -ne "null") { $ex.risco = [string]$raw.risco }
    }
    else {
        $consolidated[$sbid] = [pscustomobject]@{
            sbid         = $sbid
            titulo       = $assunto
            prefixo      = $prefixo
            canal        = $canal
            canais       = @($canal)
            fontes       = @($fonte)
            pessoa       = $pessoa
            assunto      = $assunto
            resumo       = if ($raw.resumo -and "$($raw.resumo)" -ne "null") { [string]$raw.resumo } else { "" }
            proxima_acao = if ($raw.proxima_acao -and "$($raw.proxima_acao)" -ne "null") { [string]$raw.proxima_acao } else { "" }
            responsavel  = if ($raw.responsavel -and "$($raw.responsavel)" -ne "null") { [string]$raw.responsavel } else { "eu" }
            status       = $status
            tipo         = $tipo
            categoria    = $categoria
            prioridade   = $prio
            prazo        = $prazoStr
            risco        = if ($raw.risco -and "$($raw.risco)" -ne "null") { [string]$raw.risco } else { "" }
            reuniao_em   = $reuniao
            dueDate      = $dueDate
        }
    }
}

$consList = @($consolidated.Values)
Log "Consolidados (unicos por SB-ID): $($consList.Count)." Gray

# Snapshot de AUDITORIA: o consolidado COMPLETO desta rodada (util p/ debug da
# consolidacao). O snapshot "oficial" (consolidated-$ts.json) e o INCREMENTO,
# gravado apos o merge -- so o que e novo/alterado desde a ultima rodada c/ sucesso.
$consFullFile = Join-Path $Processed "consolidated-$ts.full.json"
[System.IO.File]::WriteAllText($consFullFile, (@($consList) | ConvertTo-Json -Depth 20), $Utf8NoBom)
Log "Snapshot completo (auditoria): $consFullFile" DarkGray

# ============================================================
# BOARD (visibilidade) + carga inicial
# ============================================================
function Resolve-Board($item) {
    # O status NAO decide mais visibilidade. So sai da tela principal o que e
    # genuinamente sem acao: categoria "referencia" ou prioridade "baixa".
    # Media E alta (inclusive na carga inicial) ficam no board ativo -- e isso
    # que garante que uma pendencia real nunca fique escondida num canto quieto.
    if ($item.categoria -eq "referencia") { return "referencia" }
    if ($item.prioridade -eq "baixa")     { return "review" }
    return "active"
}

# ============================================================
# MERGE NO STORE (preservando estado do cockpit)
# ============================================================
function Read-Store {
    if (-not (Test-Path $TasksFile)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($TasksFile, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    }
    catch { return @() }
}

function Write-Store($tasks) {
    $json = @($tasks) | ConvertTo-Json -Depth 20
    if ([string]::IsNullOrWhiteSpace($json)) { $json = "[]" }
    if ($json -notmatch '^\s*\[') { $json = "[$json]" }
    $tmp = "$TasksFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $Utf8NoBom)
    [System.IO.File]::Copy($tmp, $TasksFile, $true)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# Estado global do orquestrador: o timestamp da ULTIMA rodada com sucesso
# (consolidou + gravou o store sem erro fatal). Serve de marco p/ o snapshot
# incremental ("o que mudou desde entao"). DryRun NAO avanca esse marco.
function Read-LastSuccessRun {
    if (-not (Test-Path $LastRunFile)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($LastRunFile, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        if ($obj -and $obj.lastSuccessRun) { return [string]$obj.lastSuccessRun }
        return $null
    }
    catch { return $null }
}

function Write-LastSuccessRun([string]$iso) {
    $json = ([pscustomobject]@{ lastSuccessRun = $iso }) | ConvertTo-Json -Depth 5
    $tmp = "$LastRunFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $Utf8NoBom)
    [System.IO.File]::Copy($tmp, $LastRunFile, $true)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$nowIso = (Get-Date).ToString("o")
$stats = @{ new = 0; updated = 0; rolled = 0; review = 0 }
$reviewItems = New-Object System.Collections.ArrayList

$store = Read-Store

# Marco da ultima rodada com sucesso (o store atual reflete esse estado, pois so
# gravamos o store em rodada bem-sucedida e nao-DryRun). Usado como "desde quando"
# do snapshot incremental; avancado no fim, so em caso de sucesso e sem DryRun.
$lastSuccessRun = Read-LastSuccessRun
Log ("Ultima rodada com sucesso: " + $(if ($lastSuccessRun) { $lastSuccessRun } else { "(nenhuma)" })) DarkGray

# Itens do snapshot INCREMENTAL: novos ou com conteudo alterado desde a ultima
# rodada com sucesso (comparados por SB-ID contra o store anterior a este merge).
$deltaItems = New-Object System.Collections.ArrayList

# --- Consistencia de identidade (idempotente) -------------------------------
# A identidade agora e pessoa+assunto (sem status). Recalcula o sbid de cada
# card e funde duplicatas antigas (mesmo assunto que tinha sido separado por
# status). Depois de estabilizado, roda sem efeito colateral.
if (@($store).Count -gt 0) {
    $byNew = [ordered]@{}
    foreach ($t in $store) {
        $nid = Get-SBID $t.pessoa $t.assunto $null
        if ($byNew.Contains($nid)) {
            $keep = $byNew[$nid]
            # vencedor = nao-concluido > maior prioridade > mais recente
            $takeNew = $false
            if ($keep.done -and -not $t.done) { $takeNew = $true }
            elseif ((-not $keep.done) -eq (-not $t.done)) {
                if ((Prio-Rank $t.prioridade) -gt (Prio-Rank $keep.prioridade)) { $takeNew = $true }
                elseif ([string]$t.updatedAt -gt [string]$keep.updatedAt) { $takeNew = $true }
            }
            $winner = if ($takeNew) { $t } else { $keep }
            $loser  = if ($takeNew) { $keep } else { $t }
            $winner.fontes = @(@($winner.fontes) + @($loser.fontes) | Select-Object -Unique)
            if ($loser.notas -and -not $winner.notas) { $winner.notas = $loser.notas }
            $winner.sbid = $nid
            $byNew[$nid] = $winner
        }
        else {
            $t.sbid = $nid
            $byNew[$nid] = $t
        }
    }
    $store = @($byNew.Values)
}

$byId = @{}
foreach ($t in $store) { if ($t.sbid) { $byId[$t.sbid] = $t } }

foreach ($c in $consList) {
    $board = Resolve-Board $c
    if ($board -eq "review") { [void]$reviewItems.Add($c); $stats.review++ }

    if ($byId.ContainsKey($c.sbid)) {
        $ex = $byId[$c.sbid]
        $userTouched = ($ex.PSObject.Properties.Name -contains 'userTouched') -and $ex.userTouched

        # Delta: antes de sobrescrever, compara o conteudo semantico do card
        # existente (= estado da ultima rodada c/ sucesso) com o consolidado desta
        # rodada. Se algo relevante mudou, entra no snapshot incremental. Campos
        # derivados de data (dueDate) ficam de fora: rolam sozinhos todo dia e
        # poluiriam o incremento. Este e o sinal mais confiavel aqui, ja que os
        # itens consolidados nao carregam timestamp por-item.
        $changed = (
            [string]$ex.titulo       -ne [string]$c.titulo       -or
            [string]$ex.prefixo      -ne [string]$c.prefixo      -or
            [string]$ex.status       -ne [string]$c.status       -or
            [string]$ex.categoria    -ne [string]$c.categoria    -or
            [string]$ex.prioridade   -ne [string]$c.prioridade   -or
            [string]$ex.resumo       -ne [string]$c.resumo       -or
            [string]$ex.proxima_acao -ne [string]$c.proxima_acao -or
            [string]$ex.prazo        -ne [string]$c.prazo        -or
            [string]$ex.risco        -ne [string]$c.risco        -or
            [string]$ex.reuniao_em   -ne [string]$c.reuniao_em
        )
        if ($changed) { [void]$deltaItems.Add($c) }

        # Atualiza conteudo, PRESERVA estado do usuario (done/snooze/notas).
        $ex.titulo       = $c.titulo
        $ex.prefixo      = $c.prefixo
        $ex.canal        = $c.canal
        $ex.pessoa       = $c.pessoa
        $ex.assunto      = $c.assunto
        $ex.resumo       = $c.resumo
        $ex.proxima_acao = $c.proxima_acao
        $ex.responsavel  = $c.responsavel
        $ex.status       = $c.status
        $ex.tipo         = $c.tipo
        $ex.categoria    = $c.categoria
        $ex.prazo        = $c.prazo
        $ex.risco        = $c.risco
        $ex.reuniao_em   = $c.reuniao_em
        $ex.board        = $board

        # fontes = uniao
        $mergedFontes = @($ex.fontes) + @($c.fontes) | Select-Object -Unique
        $ex.fontes = @($mergedFontes)

        # prioridade / prazo: so sobrescreve se o usuario NAO ajustou a mao
        if (-not $userTouched) {
            $ex.prioridade = $c.prioridade
            if (-not $ex.done) { $ex.dueDate = $c.dueDate }
        }

        $ex.updatedAt = $nowIso
        $stats.updated++
    }
    else {
        $new = [pscustomobject]@{
            sbid         = $c.sbid
            titulo       = $c.titulo
            prefixo      = $c.prefixo
            canal        = $c.canal
            fontes       = @($c.fontes)
            pessoa       = $c.pessoa
            assunto      = $c.assunto
            resumo       = $c.resumo
            proxima_acao = $c.proxima_acao
            responsavel  = $c.responsavel
            status       = $c.status
            tipo         = $c.tipo
            categoria    = $c.categoria
            prioridade   = $c.prioridade
            prazo        = $c.prazo
            risco        = $c.risco
            reuniao_em   = $c.reuniao_em
            dueDate      = $c.dueDate
            board        = $board
            snoozedUntil = $null
            done         = $false
            notas        = ""
            userTouched  = $null
            createdAt    = $nowIso
            updatedAt    = $nowIso
            history      = @("[$nowIso] criado ($($c.canal))")
        }
        $store = @($store) + @($new)
        $byId[$c.sbid] = $new
        $stats.new++
        [void]$deltaItems.Add($c)   # item novo desde a ultima rodada -> entra no incremento
    }
}

# --- roll-over: vencidas e abertas -> hoje ----------------------------------
foreach ($t in $store) {
    if (-not $t.done -and $t.dueDate -and ([string]$t.dueDate) -lt $today) {
        $t.dueDate = $today
        $t.updatedAt = $nowIso
        $stats.rolled++
    }
}

# --- recalcula o board de TODO o store --------------------------------------
# CRITICO p/ visibilidade: o loop de merge so atualiza o board dos cards
# coletados NESTA rodada. Um card antigo (ex.: media marcado 'review' antes do
# ajuste de visibilidade) que nao foi recoletado ficaria preso num board
# obsoleto e sumiria da tela. Recalcular aqui cura o store inteiro toda rodada.
foreach ($t in $store) {
    if (-not $t.done) { $t.board = Resolve-Board $t }
}

# --- snapshot incremental desta rodada --------------------------------------
# consolidated-$ts.json = SO o incremento (novos/alterados desde a ultima rodada
# c/ sucesso). O store (tasks.json) continua sendo gravado COMPLETO logo abaixo;
# o cockpit le o store, nunca o snapshot. Guarda de array/vazio igual ao Write-Store.
$consFile  = Join-Path $Processed "consolidated-$ts.json"
$deltaJson = @($deltaItems) | ConvertTo-Json -Depth 20
if ([string]::IsNullOrWhiteSpace($deltaJson)) { $deltaJson = "[]" }
if ($deltaJson -notmatch '^\s*\[') { $deltaJson = "[$deltaJson]" }
[System.IO.File]::WriteAllText($consFile, $deltaJson, $Utf8NoBom)
$sinceLabel = if ($lastSuccessRun) { $lastSuccessRun } else { "(primeira execucao)" }
Log ("Snapshot incremental: $consFile ($($deltaItems.Count) itens novos/alterados desde $sinceLabel)") DarkGray

# --- grava (respeitando DryRun) ---------------------------------------------
if ($DryRun) {
    Log "DryRun: store NAO alterado e marco de sucesso NAO avancado. (consolidated-$ts.json gerado)" Yellow
}
else {
    Write-Store $store
    Log "Store atualizado: $TasksFile" Green
    # Rodada bem-sucedida: avanca o marco. Proxima rodada mede o incremento a partir daqui.
    Write-LastSuccessRun $nowIso
    Log "Marco de ultima rodada com sucesso atualizado: $nowIso" DarkGray
}

if ($InitialLoad -and $reviewItems.Count -gt 0) {
    $reviewFile = Join-Path $Processed "initial-review.json"
    [System.IO.File]::WriteAllText($reviewFile, (@($reviewItems) | ConvertTo-Json -Depth 20), $Utf8NoBom)
    Log "Revisao inicial (baixa prioridade / referencia): $reviewFile ($($reviewItems.Count) itens)" Yellow
}

# ============================================================
# SUMARIO
# ============================================================
Log "" Gray
Log "===== SUMARIO DA RODADA =====" Cyan
foreach ($k in $channelStatus.Keys) {
    $v = $channelStatus[$k]
    $col = if ($v -like "OK*") { "Green" } elseif ($v -like "FALHOU*") { "Red" } else { "DarkGray" }
    Log ("  {0,-9}: {1}" -f $k, $v) $col
}
Log ("  Novas: {0} | Atualizadas: {1} | Roladas: {2} | Revisao: {3}" -f $stats.new, $stats.updated, $stats.rolled, $stats.review) Gray
Log ("  Snapshot incremental: {0} itens novos/alterados desde {1}" -f $deltaItems.Count, $sinceLabel) Gray
Log "=============================" Cyan

# ============================================================
# COCKPIT
# ============================================================
if ($OpenCockpit -and -not $SkipCockpit) {
    $portUp = $false
    try {
        Invoke-WebRequest "http://127.0.0.1:$Port/api/tasks" -UseBasicParsing -TimeoutSec 2 | Out-Null
        $portUp = $true
    }
    catch { $portUp = $false }

    if (-not $portUp) {
        Log "Subindo cockpit em http://127.0.0.1:$Port/ ..." Cyan
        Start-Process powershell -ArgumentList @(
            "-NoExit", "-ExecutionPolicy", "Bypass",
            "-File", "`"$CockpitPs`"", "-Port", "$Port"
        ) | Out-Null
        Start-Sleep -Seconds 2
    }
    else {
        Log "Cockpit ja esta no ar em http://127.0.0.1:$Port/." Gray
    }

    Start-Process "http://127.0.0.1:$Port/"
    Log "Cockpit aberto no navegador." Green
}

Log "Fim da rodada." Cyan

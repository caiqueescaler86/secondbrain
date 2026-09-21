param(
    [int]$Ahead = 1,          # reservado: integracao futura com calendario Outlook
    [switch]$Json,
    [string]$Endpoint    = "http://127.0.0.1:19001",
    [string]$Model       = "",
    [int]$ChunkChars     = 7000,
    [double]$Temperature = 0.1,
    [int]$MaxTokens      = 1500,
    [int]$TimeoutSec     = 900,
    [string]$ApiKey      = ""
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# SECONDBRAIN - MEETING DETECTOR
#
# Le Meetings\*.json (sidecars gerados pelo record-meeting.ps1),
# processa os nao-vistos com LLM local (llama-server :19001) e
# devolve um array JSON no schema do cockpit (canal="meetings").
#
# Contrato: stdout = array JSON; logs = stderr (mesmo padrao dos
# outros canais para que o secondbrain-run.ps1 capture corretamente).
# ============================================================

$Root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$MeetingsDir = Join-Path $Root "Meetings"
$StateFile   = Join-Path $MeetingsDir "meeting-state.json"

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    if ($Json) { [Console]::Error.WriteLine("[$((Get-Date).ToString('HH:mm:ss'))] $Text") }
    else       { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color }
}

# --- Estado de dedup --------------------------------------------------------
$state = [pscustomobject]@{ version = 1; updatedAt = ""; processed = [pscustomobject]@{} }
if (Test-Path $StateFile) {
    try   { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Log "AVISO: nao consegui ler meeting-state.json; reprocessando tudo." Yellow }
}
if (-not $state.processed) {
    $state | Add-Member -NotePropertyName processed -NotePropertyValue ([pscustomobject]@{}) -Force
}

# --- Sidecars nao processados -----------------------------------------------
$sidecars = @(
    Get-ChildItem "$MeetingsDir\*.json" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @("meeting-state.json","watch-state.json") }
)
$toProcess = @($sidecars | Where-Object { -not ($state.processed.PSObject.Properties[$_.BaseName]) })

Log "Meetings encontradas: $($sidecars.Count) | Novas: $($toProcess.Count)" Cyan

if ($toProcess.Count -eq 0) {
    if ($Json) { Write-Output "[]" }
    else       { Log "Nada novo a processar." Gray }
    exit 0
}

# --- Detecta modelo llama ---------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Model)) {
    try {
        $hdrs = @{}; if ($ApiKey) { $hdrs["Authorization"] = "Bearer $ApiKey" }
        $models = Invoke-RestMethod -Uri "$Endpoint/v1/models" -Method Get -Headers $hdrs -TimeoutSec 10
        $Model  = [string]$models.data[0].id
        Log "Modelo detectado: $Model" Gray
    } catch {
        $Model = "local-model"
        Log "Nao consegui listar modelos; usando '$Model' (llama.cpp ignora o campo)." Yellow
    }
}

# --- LLM streaming (mesmo padrao de analyze-whatsapp.ps1) -------------------
function Invoke-LocalStream([string]$sys, [string]$usr) {
    $body = @{
        model       = $Model
        temperature = $Temperature
        max_tokens  = $MaxTokens
        stream      = $true
        messages    = @(
            @{ role = "system"; content = $sys },
            @{ role = "user";   content = $usr }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $sb = New-Object System.Text.StringBuilder
    $resp = $null; $rdr = $null
    try {
        $req = [Net.HttpWebRequest]::Create("$Endpoint/v1/chat/completions")
        $req.Method         = "POST"
        $req.ContentType    = "application/json; charset=utf-8"
        $req.Timeout        = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.ContentLength  = $bytes.Length
        if ($ApiKey) { $req.Headers.Add("Authorization", "Bearer $ApiKey") }
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        $resp = $req.GetResponse()
        $rdr  = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        while (-not $rdr.EndOfStream) {
            $line = $rdr.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line) -or -not $line.StartsWith("data:")) { continue }
            $data = $line.Substring(5).Trim()
            if ($data -eq "[DONE]") { break }
            try { $j = $data | ConvertFrom-Json } catch { continue }
            $delta = [string]$j.choices[0].delta.content
            if ($delta) { [Console]::Error.Write($delta); [void]$sb.Append($delta) }
        }
    } catch { throw "Falha ao chamar LLM local: $($_.Exception.Message)" }
    finally {
        if ($rdr)  { try { $rdr.Close()  } catch {} }
        if ($resp) { try { $resp.Close() } catch {} }
    }
    return $sb.ToString()
}

function Get-JsonItems([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $c = $text -replace '```json','' -replace '```',''
    $s = $c.IndexOf('['); $e = $c.LastIndexOf(']')
    if ($s -ge 0 -and $e -gt $s) { $c = $c.Substring($s, ($e - $s + 1)) }
    try { return @($c | ConvertFrom-Json) } catch { return @() }
}

# --- Prompts ----------------------------------------------------------------
$sysPrompt = @"
Voce e um extrator de action items de transcricoes de reuniao. Responda SOMENTE com um array JSON valido, sem texto antes/depois, sem cercas de codigo.
Regras:
- Extraia apenas o que exige acao: tarefas, followups, decisoes, prazos, riscos, quem vai fazer o que.
- Nao invente. Se faltar informacao, use null.
- "eu" = a pessoa que gravou/participou da reuniao (dono da conta).
- status: fazer|responder|cobrar|aguardando|risco|referencia.
- tipo: pessoal|trabalho. prioridade: alta|media|baixa.
- Ignore conversa social sem acao.
- canal: sempre "meetings". fonte: sempre "transcricao".
"@

$questionTpl = @"
Analise a transcricao abaixo (reuniao: {{LABEL}}, data: {{DATA}}, duracao: ~{{DUR}} min) e devolva um array JSON. Cada item:
{"canal":"meetings","tipo":"trabalho","pessoa":"Nome ou null","assunto":"curto","resumo":"1-2 frases","proxima_acao":"verbo + objeto","responsavel":"eu ou nome","status":"fazer|responder|cobrar|aguardando|risco|referencia","prazo":"YYYY-MM-DD ou null","prioridade":"alta|media|baixa","risco":"texto ou null","fonte":"transcricao","reuniao_em":null}
Se nao houver nada acionavel, devolva [].
"@

# --- Processa cada sidecar --------------------------------------------------
$allItems = New-Object System.Collections.ArrayList

foreach ($file in $toProcess) {
    $id = $file.BaseName
    Log "Processando: $id" Cyan
    try {
        $sidecar    = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $transcript = [string]$sidecar.transcript
        $label      = if ($sidecar.label)       { [string]$sidecar.label }       else { $id }
        $started    = if ($sidecar.startedAt)   { [string]$sidecar.startedAt }   else { "" }
        $durMin     = if ($sidecar.durationSec) { [math]::Round([int]$sidecar.durationSec / 60) } else { 0 }
        $dataStr    = if ($started) {
            try { ([datetimeoffset]::Parse($started)).ToString("yyyy-MM-dd HH:mm") } catch { $started }
        } else { "desconhecida" }

        if ([string]::IsNullOrWhiteSpace($transcript)) {
            Log "  $id: transcricao vazia — nada a analisar." Yellow
        } else {
            $transcriptLen = $transcript.Length
            Log "  $id: $transcriptLen chars, enviando ao LLM..." Gray

            # Quebra em lotes se o transcript for maior que o budget
            $chunks = @()
            if ($transcriptLen -le $ChunkChars) {
                $chunks = @($transcript)
            } else {
                $pos = 0
                while ($pos -lt $transcriptLen) {
                    $len = [math]::Min($ChunkChars, $transcriptLen - $pos)
                    if ($len -lt ($transcriptLen - $pos)) {
                        $sp = $transcript.LastIndexOf(' ', $pos + $len, $len)
                        if ($sp -gt $pos) { $len = $sp - $pos }
                    }
                    $chunks += $transcript.Substring($pos, $len)
                    $pos += $len
                }
            }

            Log "  $id: $($chunks.Count) lote(s)" Gray
            $meetingItems = New-Object System.Collections.ArrayList
            $ci = 0
            foreach ($chunk in $chunks) {
                $ci++
                Log "  Lote $ci/$($chunks.Count) (~$([math]::Round($chunk.Length/1000))k chars)..." Gray
                [Console]::Error.WriteLine("")
                $q   = $questionTpl -replace '{{LABEL}}',$label -replace '{{DATA}}',$dataStr -replace '{{DUR}}',$durMin
                $uc  = $q + "`n`n=== TRANSCRICAO ===`n" + $chunk
                $raw = Invoke-LocalStream $sysPrompt $uc
                $items = Get-JsonItems $raw
                foreach ($it in $items) { [void]$meetingItems.Add($it) }
                Log "  Lote ${ci}: $(@($items).Count) item(ns)." Gray
            }

            Log "  $id: $($meetingItems.Count) item(ns) extraidos." Green
            foreach ($it in $meetingItems) { [void]$allItems.Add($it) }
        }

        # Marca como processado independente do resultado
        $state.processed | Add-Member -NotePropertyName $id -NotePropertyValue $true -Force

    } catch {
        Log "  ERRO processando $id: $($_.Exception.Message)" Red
        # Nao marca como processado: nova tentativa na proxima rodada
    }
}

# --- Salva estado -----------------------------------------------------------
$state.updatedAt = (Get-Date).ToString("o")
try {
    $stateJson = $state | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StateFile, $stateJson, [Text.Encoding]::UTF8)
} catch { Log "AVISO: nao consegui salvar meeting-state.json: $($_.Exception.Message)" Yellow }

# --- Emite resultado --------------------------------------------------------
$result = if ($allItems.Count -gt 0) { (@($allItems) | ConvertTo-Json -Depth 20) } else { "[]" }
Log "JSON valido: $($allItems.Count) itens." Cyan

if ($Json) { Write-Output $result }
else {
    Write-Host "`nResultado:" -ForegroundColor Green
    Write-Host $result
}

param(
    [string]$WhisperDir = "C:\whisper",
    [string]$Model      = "ggml-medium.bin",
    [string]$Lang       = "pt",
    [int]$Threads       = 8,
    [switch]$KeepWav,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# SECONDBRAIN - WHATSAPP TRANSCRIBER
#
# Parte ROBUSTA e independente do pipeline de audio:
#   - le audios de WhatsApp\audio-inbox\ (ogg/opus/m4a/mp3/wav)
#   - transcodifica com ffmpeg -> WAV 16 kHz mono
#   - transcreve local com whisper.cpp (whisper-cli.exe)
#   - faz APPEND no whatsapp-messages.jsonl no MESMO schema do collector
#     (assim o analyze-whatsapp.ps1 pega de graca)
#
# Idempotente: cada audio e identificado pelo SHA256 do conteudo; audios
# ja transcritos ficam em whatsapp-audio-state.json e sao pulados.
#
# NAO depende do extrator (whatsapp-audio.ps1). Funciona tambem com audios
# arrastados manualmente para a pasta audio-inbox\ (com ou sem sidecar .json).
# Tudo local.
# ============================================================

$BaseDir      = Join-Path $env:USERPROFILE "Documents\Joule\SecondBrain\WhatsApp"
$InboxDir     = Join-Path $BaseDir "audio-inbox"
$MessagesFile = Join-Path $BaseDir "whatsapp-messages.jsonl"
$AudioState   = Join-Path $BaseDir "whatsapp-audio-state.json"

New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    if ($Quiet) { return }
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

# ---- Descoberta de ferramentas ----------------------------------------------
function Resolve-Whisper {
    $candidates = @(
        (Join-Path $WhisperDir "whisper-cli.exe"),
        (Join-Path $WhisperDir "main.exe"),
        (Join-Path $WhisperDir "Release\whisper-cli.exe"),
        (Join-Path $WhisperDir "bin\whisper-cli.exe")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $found = Get-ChildItem -Path $WhisperDir -Recurse -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Resolve-Model {
    if (Test-Path $Model) { return (Resolve-Path $Model).Path }
    $candidates = @(
        (Join-Path $WhisperDir "models\$Model"),
        (Join-Path $WhisperDir $Model)
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Resolve-Ffmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---- Helpers -----------------------------------------------------------------
function SHA256-File([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace("-","").ToLowerInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function SHA256-Text([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Load-AudioState {
    if (Test-Path $AudioState) {
        try {
            $j = Get-Content $AudioState -Raw -Encoding UTF8 | ConvertFrom-Json
            $h = @{}
            if ($j.processed) {
                foreach ($p in $j.processed.PSObject.Properties) { $h[$p.Name] = $p.Value }
            }
            return $h
        } catch { Log "State de audio corrompido; recomecando." Yellow }
    }
    return @{}
}

function Save-AudioState([hashtable]$Processed) {
    $obj = [pscustomobject]@{
        version   = 1
        updatedAt = (Get-Date).ToString("o")
        processed = $Processed
    }
    [IO.File]::WriteAllText($AudioState, ($obj | ConvertTo-Json -Depth 10), [Text.Encoding]::UTF8)
}

function Get-KnownIds {
    $set = @{}
    if (-not (Test-Path $MessagesFile)) { return $set }
    foreach ($line in [IO.File]::ReadLines($MessagesFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $m = $line | ConvertFrom-Json; if ($m.id) { $set[[string]$m.id] = $true } } catch {}
    }
    return $set
}

function Read-Sidecar([string]$AudioPath) {
    # Sidecar opcional: <audio>.json com chat/meta/timestamp/author/direction.
    $side = [IO.Path]::ChangeExtension($AudioPath, ".json")
    if (Test-Path $side) {
        try { return Get-Content $side -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return $null
}

# ---- Preflight ---------------------------------------------------------------
$whisper = Resolve-Whisper
$modelPath = Resolve-Model
$ffmpeg  = Resolve-Ffmpeg

if (-not $ffmpeg)     { throw "ffmpeg nao encontrado no PATH. (esperado ja instalado)" }
if (-not $whisper)    { throw "whisper-cli.exe nao encontrado em '$WhisperDir'. Rode setup-whisper.ps1 primeiro." }
if (-not $modelPath)  { throw "Modelo '$Model' nao encontrado (em '$WhisperDir\models\'). Rode setup-whisper.ps1 primeiro." }

$audios = Get-ChildItem -Path $InboxDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^\.(ogg|opus|m4a|mp3|wav|aac|mp4)$' } |
    Sort-Object LastWriteTime

if (-not $audios -or $audios.Count -eq 0) {
    Log "Nada em audio-inbox. Nada a transcrever." DarkGray
    Write-Host ("Transcritos: 0 | Pulados: 0 | Falhas: 0") -ForegroundColor Green
    return
}

Log "whisper: $whisper" DarkGray
Log "modelo : $modelPath" DarkGray
Log "audios : $($audios.Count) em $InboxDir" Cyan

$processed = Load-AudioState
$known     = Get-KnownIds

$nOk = 0; $nSkip = 0; $nFail = 0

foreach ($a in $audios) {
    try {
        $hash = SHA256-File $a.FullName
        if ($processed.ContainsKey($hash)) {
            $nSkip++
            Log "pulado (ja transcrito): $($a.Name)" DarkGray
            continue
        }

        # sidecar (opcional)
        $side = Read-Sidecar $a.FullName
        $chat      = if ($side -and $side.chat)      { [string]$side.chat }      else { [IO.Path]::GetFileNameWithoutExtension($a.Name) }
        $meta      = if ($side -and $side.meta)      { [string]$side.meta }      else { "" }
        $author    = if ($side -and $side.author)    { [string]$side.author }    else { "" }
        $direction = if ($side -and $side.direction) { [string]$side.direction } else { "in" }
        $timestamp = if ($side -and $side.timestamp) { [string]$side.timestamp } else { $a.LastWriteTime.ToString("o") }

        # 1) transcodifica -> WAV 16 kHz mono
        $wav = Join-Path $env:TEMP ("wa-" + $hash.Substring(0,16) + ".wav")
        & $ffmpeg -y -hide_banner -loglevel error -i $a.FullName -ar 16000 -ac 1 -f wav $wav 2>$null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $wav)) { throw "ffmpeg falhou ao converter." }

        # 2) whisper.cpp -> texto
        $outBase = Join-Path $env:TEMP ("wa-" + $hash.Substring(0,16))
        $txtFile = "$outBase.txt"
        & $whisper -m $modelPath -f $wav -l $Lang -t $Threads -otxt -of $outBase -nt -np 2>$null | Out-Null
        if (-not (Test-Path $txtFile)) { throw "whisper nao gerou transcricao." }

        $transcript = ((Get-Content $txtFile -Raw -Encoding UTF8) -replace '\s+', ' ').Trim()

        # limpeza
        Remove-Item $txtFile -Force -ErrorAction SilentlyContinue
        if (-not $KeepWav) { Remove-Item $wav -Force -ErrorAction SilentlyContinue }

        if ([string]::IsNullOrWhiteSpace($transcript)) {
            # audio vazio/ruido: marca como processado pra nao repetir, mas nao grava linha
            $processed[$hash] = @{ file = $a.Name; at = (Get-Date).ToString("o"); empty = $true }
            Save-AudioState $processed
            $nSkip++
            Log "vazio (sem fala detectada): $($a.Name)" DarkYellow
            continue
        }

        # 3) registro no schema do jsonl (id estavel = baseado no AUDIO, nao na transcricao)
        $id = SHA256-Text "$chat|$meta|$direction|audio:$hash"
        $record = [pscustomobject]@{
            id         = $id
            chat       = $chat
            timestamp  = $timestamp
            author     = $author
            meta       = $meta
            direction  = $direction
            text       = "🎤 " + $transcript
            capturedAt = (Get-Date).ToString("o")
        }

        # 4) append deduplicado (mesma tecnica do collector: UTF8, uma linha)
        if (-not $known.ContainsKey($id)) {
            $line = $record | ConvertTo-Json -Compress -Depth 10
            [IO.File]::AppendAllText($MessagesFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
            $known[$id] = $true
        }

        $processed[$hash] = @{ file = $a.Name; at = (Get-Date).ToString("o"); id = $id; chars = $transcript.Length }
        Save-AudioState $processed
        $nOk++
        $preview = if ($transcript.Length -gt 60) { $transcript.Substring(0,60) + "..." } else { $transcript }
        Log "OK $($a.Name) [$chat] -> $preview" Green
    }
    catch {
        $nFail++
        Log "FALHA em $($a.Name): $($_.Exception.Message)" Red
    }
}

Write-Host ""
Write-Host ("Transcritos: $nOk | Pulados: $nSkip | Falhas: $nFail") -ForegroundColor Green
Write-Host ("Base: $MessagesFile") -ForegroundColor DarkGray

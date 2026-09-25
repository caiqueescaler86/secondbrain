# ============================================================
# TESTE L/M - recovery real de audio + transcricao (whisper)
#
# Rode ESTE script NO SEU TERMINAL (nao dentro do Claude: o whisper-cli.exe
# esta bloqueado por ACE dentro do processo do Claude). Ele NAO mexe em nada
# de producao: le o .jsonl e reporta; as unicas escritas sao as normais do
# transcritor (inbox/state), como numa rodada real.
#
# O que valida:
#   L) transcricao REAL: pega o que ja esta em WhatsApp\audio-inbox\, transcreve
#      com whisper e mostra as linhas de audio que entrariam no .jsonl.
#   M) recovery de ~8 dias: confirma que o extrator+transcritor recuperam audio
#      ANTIGO (alem dos "1-2 dias" do comportamento antigo) na MESMA janela do texto.
#
# Uso:
#   .\test-audio-recovery.ps1                 # so transcreve o inbox atual (L)
#   .\test-audio-recovery.ps1 -RunExtractor   # extrai (scroll-up ao vivo) + transcreve (L+M)
#   .\test-audio-recovery.ps1 -Days 8          # janela de 8 dias (recovery de folga)
# ============================================================
param(
    [switch]$RunExtractor,
    [int]$Days = 8,
    [string]$WhisperDir = "C:\whisper",
    [string]$Model = "ggml-medium.bin"
)
$ErrorActionPreference = "Stop"
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Join-Path $env:USERPROFILE "Documents\Joule\SecondBrain\WhatsApp"
$Inbox   = Join-Path $BaseDir "audio-inbox"
$Jsonl   = Join-Path $BaseDir "whatsapp-messages.jsonl"
$Mic     = [string]([char]0xD83C + [char]0xDFA4)   # marcador de audio no text, construido em runtime

function Count-Jsonl {
    $total = 0; $mic = 0; $micLines = @()
    if (Test-Path $Jsonl) {
        foreach ($l in [IO.File]::ReadLines($Jsonl)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $total++
            if ($l.Contains($Mic)) { $mic++; $micLines += $l }
        }
    }
    return [pscustomobject]@{ total=$total; mic=$mic; lines=$micLines }
}

Write-Host "== TESTE L/M - recovery de audio ==" -ForegroundColor Cyan
Write-Host "Inbox: $Inbox" -ForegroundColor DarkGray

$b = Count-Jsonl
Write-Host "Linhas no .jsonl ANTES: $($b.total) (audio: $($b.mic))" -ForegroundColor DarkGray

if ($RunExtractor) {
    Write-Host "`n[M] Rodando extrator (scroll-up ao vivo, janela $Days dias)..." -ForegroundColor Yellow
    & (Join-Path $Root "whatsapp-audio.ps1") -Days $Days
    $rec = Join-Path $BaseDir "whatsapp-audio-recovery-state.json"
    if (Test-Path $rec) {
        Write-Host "`nCheckpoint de recovery de audio (whatsapp-audio-recovery-state.json):" -ForegroundColor Cyan
        Get-Content $rec -Raw | Write-Host
    }
}

$oggs = @(Get-ChildItem $Inbox -Filter *.ogg -File -ErrorAction SilentlyContinue)
Write-Host "`n.ogg no inbox aguardando transcricao: $($oggs.Count)" -ForegroundColor DarkGray

Write-Host "`n[L] Transcrevendo com whisper ($WhisperDir / $Model)..." -ForegroundColor Yellow
& (Join-Path $Root "whatsapp-transcribe.ps1") -WhisperDir $WhisperDir -Model $Model

$a = Count-Jsonl
$novas = $a.mic - $b.mic
Write-Host "`n== RESULTADO ==" -ForegroundColor Cyan
Write-Host "Linhas no .jsonl DEPOIS: $($a.total) (era $($b.total)) | audio: $($a.mic) (era $($b.mic))" -ForegroundColor Green
Write-Host "Novas transcricoes de audio: $novas" -ForegroundColor Green

if ($novas -gt 0) {
    $novasLines = $a.lines | Select-Object -Last $novas
    Write-Host "`nAmostra (essas linhas serao analisadas 1x na proxima rodada, via offset):" -ForegroundColor Cyan
    $novasLines | Select-Object -Last 5 | ForEach-Object {
        try {
            $o = $_ | ConvertFrom-Json
            $t = [string]$o.text; if ($t.Length -gt 70) { $t = $t.Substring(0,70) + "..." }
            Write-Host ("  [$($o.chat)] $($o.timestamp)  ->  $t") -ForegroundColor Gray
        } catch {}
    }
    $datas = $novasLines | ForEach-Object { try { ($_ | ConvertFrom-Json).timestamp } catch {} } | Sort-Object
    if ($datas.Count -gt 0) {
        Write-Host "`n[M] Faixa de datas das transcricoes (confirme audio ANTIGO, alem de 1-2 dias):" -ForegroundColor Cyan
        Write-Host ("  mais antiga: {0}" -f $datas[0]) -ForegroundColor Gray
        Write-Host ("  mais nova  : {0}" -f $datas[-1]) -ForegroundColor Gray
    }
}

Write-Host "`nOFFSET: apos a proxima rodada do secondbrain-run.ps1, analysisOffset avanca de $($b.total) -> $($a.total)." -ForegroundColor DarkCyan
Write-Host "Cada linha nova vira pendencia UMA unica vez. Nada de producao foi sobrescrito por este teste." -ForegroundColor DarkGray

param(
    [string]$WhisperDir = "C:\whisper",
    [string]$Model      = "ggml-medium.bin",
    [string]$BinUrl     = "",   # opcional: URL do zip do whisper.cpp (win x64)
    [string]$ModelUrl   = "",   # opcional: URL do modelo ggml
    [switch]$SkipBin,
    [switch]$SkipModel
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ============================================================
# SECONDBRAIN - SETUP WHISPER.CPP (uma vez)
#   - baixa o binario Windows x64 do whisper.cpp -> C:\whisper\
#   - baixa o modelo ggml (padrao: medium) -> C:\whisper\models\
#   - valida que whisper-cli.exe roda
#
# Espelha o layout do llama (C:\llama-cpu\). Tudo local, CPU.
# Se o download corporativo bloquear, use as instrucoes manuais no final.
# ============================================================

$ModelsDir = Join-Path $WhisperDir "models"
New-Item -ItemType Directory -Path $WhisperDir -Force | Out-Null
New-Item -ItemType Directory -Path $ModelsDir  -Force | Out-Null

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

function Find-WhisperCli {
    $c = Get-ChildItem -Path $WhisperDir -Recurse -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.FullName }
    $m = Get-ChildItem -Path $WhisperDir -Recurse -Filter "main.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.FullName }
    return $null
}

# ---- 1) Binario -------------------------------------------------------------
if (-not $SkipBin -and -not (Find-WhisperCli)) {
    try {
        if (-not $BinUrl) {
            Log "Procurando binario Windows x64 nos builds do whisper.cpp..." Cyan
            # Os releases semver (vX.Y.Z) nao anexam mais binarios; os builds de
            # CI (tags "bNNNN") ainda trazem whisper-bin-x64.zip. Pega o mais
            # recente que tenha o zip CPU x64 (evita cublas/blas/cuda).
            $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=40" -Headers @{ "User-Agent"="secondbrain" }
            $asset = $null; $relTag = ""
            foreach ($rel in $rels) {
                $a = $rel.assets | Where-Object { $_.name -eq "whisper-bin-x64.zip" } | Select-Object -First 1
                if (-not $a) {
                    $a = $rel.assets | Where-Object { $_.name -like "*bin-x64*.zip" -and $_.name -notlike "*cublas*" -and $_.name -notlike "*cuda*" -and $_.name -notlike "*blas*" } | Select-Object -First 1
                }
                if ($a) { $asset = $a; $relTag = $rel.tag_name; break }
            }
            if (-not $asset) { throw "Nao achei 'whisper-bin-x64.zip' em nenhum dos ultimos 40 releases/builds." }
            $BinUrl = $asset.browser_download_url
            Log "Build $relTag : $($asset.name)" DarkGray
        }
        $zip = Join-Path $env:TEMP "whisper-bin-x64.zip"
        Log "Baixando binario: $BinUrl" Cyan
        Invoke-WebRequest -Uri $BinUrl -OutFile $zip -UseBasicParsing
        Log "Extraindo em $WhisperDir..." Cyan
        Expand-Archive -Path $zip -DestinationPath $WhisperDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    catch {
        Log "Falha ao baixar/extrair binario: $($_.Exception.Message)" Red
        Log "Baixe manual: https://github.com/ggml-org/whisper.cpp/releases (asset whisper-bin-x64.zip) e extraia em $WhisperDir" Yellow
    }
}
else { if (-not $SkipBin) { Log "whisper-cli.exe ja presente; pulando binario." DarkGray } }

# ---- 2) Modelo --------------------------------------------------------------
$modelPath = Join-Path $ModelsDir $Model
if (-not $SkipModel -and -not (Test-Path $modelPath)) {
    try {
        if (-not $ModelUrl) {
            $ModelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$Model"
        }
        Log "Baixando modelo (pode demorar; medium ~1,5 GB): $ModelUrl" Cyan
        Invoke-WebRequest -Uri $ModelUrl -OutFile $modelPath -UseBasicParsing
        Log "Modelo salvo em $modelPath" Green
    }
    catch {
        Log "Falha ao baixar modelo: $($_.Exception.Message)" Red
        Log "Baixe manual: $ModelUrl  ->  $modelPath" Yellow
    }
}
else { if (-not $SkipModel) { Log "Modelo ja presente: $modelPath" DarkGray } }

# ---- 3) Validacao -----------------------------------------------------------
$cli = Find-WhisperCli
Write-Host ""
if ($cli -and (Test-Path $modelPath)) {
    Log "OK: whisper-cli em $cli" Green
    Log "OK: modelo em $modelPath" Green
    Write-Host ""
    Write-Host "Teste rapido (gere um wav e rode):" -ForegroundColor Cyan
    Write-Host "  & `"$cli`" -m `"$modelPath`" -l pt -f <arquivo.wav> -nt" -ForegroundColor DarkGray
    Write-Host "Depois: .\whatsapp-transcribe.ps1" -ForegroundColor DarkGray
}
else {
    Log "Setup incompleto." Yellow
    if (-not $cli)                 { Log " - falta o binario whisper-cli.exe em $WhisperDir" Yellow }
    if (-not (Test-Path $modelPath)) { Log " - falta o modelo $modelPath" Yellow }
}

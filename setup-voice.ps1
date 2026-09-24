param(
    [switch]$NoAutoStart
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ============================================================
# SECONDBRAIN - SETUP VOICE (uma vez)
#
#   Prepara o listener de voz ("Jarvis"), que roda NO PROCESSO DO
#   USUARIO (o whisper-cli tem ACE Deny quando lancado pelo Claude).
#
#   1) Acha um Python 3 e cria um venv isolado em voice\.venv.
#   2) Instala voice\requirements.txt (openWakeWord, sounddevice,
#      pynput, numpy, requests, onnxruntime).
#   3) Baixa os modelos pre-treinados do openWakeWord ("hey jarvis").
#   4) Resolve o whisper-cli.exe e o modelo (prefere o LOCAL do projeto
#      em SecondBrain\whisper, que evita o Deny do C:\) e grava
#      voice\config.json com os caminhos.
#   5) A menos que -NoAutoStart: cria um atalho na pasta Inicializar
#      (pythonw.exe voice_listen.py) -> sobe o listener a cada logon.
#
# Maquina corporativa: pip (proxy), Python e a pasta Inicializar podem
# estar bloqueados por GPO. Cada passo degrada com fallback claro.
# Nada de audio sai da maquina; so o pip baixa pacotes.
# ============================================================

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$VoiceDir   = Join-Path $Root "voice"
$VenvDir    = Join-Path $VoiceDir ".venv"
$ReqFile    = Join-Path $VoiceDir "requirements.txt"
$ListenPy   = Join-Path $VoiceDir "voice_listen.py"
$ConfigFile = Join-Path $VoiceDir "config.json"
$PromptFile = Join-Path $Root "prompts\criar-tarefa.md"

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

if (-not (Test-Path $ListenPy)) {
    Log "voice_listen.py nao encontrado em $VoiceDir. Abortando." Red
    exit 1
}

# ============================================================
# 1) PYTHON + VENV
# ============================================================
Write-Host ""
Write-Host "===== PYTHON / VENV =====" -ForegroundColor Cyan

function Resolve-Python {
    # 1) launcher 'py -3'  2) python no PATH  3) caminhos comuns
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $v = & $pyLauncher.Source -3 -c "import sys; print(sys.version.split()[0])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) { return @{ Cmd = $pyLauncher.Source; Args = @("-3"); Ver = $v } }
        } catch {}
    }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $v = & $py.Source -c "import sys; print(sys.version.split()[0])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v -and $v -notmatch '^2\.') { return @{ Cmd = $py.Source; Args = @(); Ver = $v } }
        } catch {}
    }
    foreach ($cand in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
        "C:\Python313\python.exe", "C:\Python312\python.exe", "C:\Python311\python.exe"
    )) {
        if (Test-Path $cand) {
            try {
                $v = & $cand -c "import sys; print(sys.version.split()[0])" 2>$null
                if ($LASTEXITCODE -eq 0 -and $v) { return @{ Cmd = $cand; Args = @(); Ver = $v } }
            } catch {}
        }
    }
    return $null
}

$VenvPy  = Join-Path $VenvDir "Scripts\python.exe"
$VenvPyw = Join-Path $VenvDir "Scripts\pythonw.exe"

if (Test-Path $VenvPy) {
    Log "venv ja existe em $VenvDir; reutilizando." DarkGray
}
else {
    $py = Resolve-Python
    if (-not $py) {
        Log "[X] Python 3 nao encontrado." Red
        Write-Host ""
        Write-Host "FALLBACK: instale o Python 3 (winget install Python.Python.3.12) e rode de novo." -ForegroundColor Yellow
        Write-Host "  (marque 'Add python.exe to PATH' no instalador)" -ForegroundColor Yellow
        exit 1
    }
    Log "Python encontrado: $($py.Cmd) $($py.Args -join ' ') (v$($py.Ver))" Green
    Log "Criando venv em $VenvDir ..." Cyan
    & $py.Cmd @($py.Args + @("-m", "venv", $VenvDir))
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $VenvPy)) {
        Log "[X] Falha ao criar o venv." Red
        exit 1
    }
    Log "[OK] venv criado." Green
}

# ============================================================
# 2) DEPENDENCIAS (pip)
# ============================================================
Write-Host ""
Write-Host "===== DEPENDENCIAS (pip) =====" -ForegroundColor Cyan
try {
    Log "Atualizando pip..." Cyan
    & $VenvPy -m pip install --upgrade pip 2>&1 | Out-Null
    Log "Instalando requirements (pode demorar)..." Cyan
    & $VenvPy -m pip install -r $ReqFile
    if ($LASTEXITCODE -ne 0) { throw "pip retornou codigo $LASTEXITCODE" }
    Log "[OK] Dependencias instaladas." Green
}
catch {
    Log "[X] Falha no pip: $($_.Exception.Message)" Red
    Write-Host ""
    Write-Host "FALLBACK (proxy da empresa bloqueando o pip?):" -ForegroundColor Yellow
    Write-Host "  Ative o venv e instale manualmente:" -ForegroundColor Yellow
    Write-Host "    $VenvDir\Scripts\Activate.ps1" -ForegroundColor Yellow
    Write-Host "    pip install -r `"$ReqFile`"" -ForegroundColor Yellow
    Write-Host "  (ou configure o proxy: pip install --proxy http://usuario:senha@proxy:porta -r ...)" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
# 3) MODELOS DO OPENWAKEWORD ("hey jarvis")
# ============================================================
Write-Host ""
Write-Host "===== WAKE WORD (openWakeWord) =====" -ForegroundColor Cyan
try {
    Log "Baixando modelos pre-treinados do openWakeWord..." Cyan
    & $VenvPy -c "import openwakeword.utils as u; u.download_models()"
    if ($LASTEXITCODE -ne 0) { throw "download_models retornou $LASTEXITCODE" }
    # valida que o modelo 'hey_jarvis' carrega
    & $VenvPy -c "from openwakeword.model import Model; Model(wakeword_models=['hey_jarvis'], inference_framework='onnx'); print('ok')"
    if ($LASTEXITCODE -ne 0) { throw "modelo 'hey_jarvis' nao carregou" }
    Log "[OK] Motor da wake word pronto (fallback 'hey jarvis' disponivel)." Green
}
catch {
    Log "[!] Wake word indisponivel: $($_.Exception.Message)" DarkYellow
    Log "    Sem problema: o listener ainda funciona so com Ctrl+Shift+B." DarkYellow
}

# Modelos CUSTOM ("hey SB" / "hey SecondBrain"): sao treinados no Colab e
# largados em voice\models\ como .onnx. Aqui a gente so escaneia o que ja
# existe e popula o config; se ainda nao houver nenhum, a wake word cai no
# pre-treinado 'hey jarvis' (e o Ctrl+Shift+B funciona sempre).
$ModelsDir = Join-Path $VoiceDir "models"
New-Item -ItemType Directory -Path $ModelsDir -Force | Out-Null

$customModels = @()
foreach ($mf in @(Get-ChildItem -Path $ModelsDir -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -in @(".onnx", ".tflite") })) {
    # caminho relativo a voice\ (o voice_listen.py resolve a partir de HERE)
    $customModels += ("models\" + $mf.Name)
}

if ($customModels.Count -gt 0) {
    Log "[OK] Modelos custom encontrados: $($customModels -join ', ')" Green
}
else {
    Log "[i] Nenhum modelo custom em $ModelsDir ainda." DarkYellow
    Log "    Ate treinar 'hey SB'/'hey SecondBrain' no Colab, a wake word usa 'hey jarvis'." DarkYellow
    Log "    (Ctrl+Shift+B funciona independente disso.)" DarkYellow
}

# ============================================================
# 4) WHISPER + MODELO -> config.json
#    Prefere o whisper LOCAL do projeto (SecondBrain\whisper), que
#    evita o ACE Deny do C:\ quando o processo e do usuario.
# ============================================================
Write-Host ""
Write-Host "===== WHISPER =====" -ForegroundColor Cyan

$WhisperDir = if (Test-Path (Join-Path $Root "whisper\Release\whisper-cli.exe")) { Join-Path $Root "whisper" } else { "C:\whisper" }

$whisper = $null
foreach ($c in @(
    (Join-Path $WhisperDir "Release\whisper-cli.exe"),
    (Join-Path $WhisperDir "whisper-cli.exe"),
    (Join-Path $WhisperDir "bin\whisper-cli.exe")
)) {
    if (Test-Path $c) { $whisper = $c; break }
}
if (-not $whisper) {
    $f = Get-ChildItem -Path $WhisperDir -Recurse -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $whisper = $f.FullName }
}
if ($whisper) { Log "[OK] whisper-cli: $whisper" Green }
else          { Log "[X] whisper-cli.exe nao encontrado em $WhisperDir. Rode setup-whisper.ps1." Yellow }

$model = $null
foreach ($m in @(
    (Join-Path $WhisperDir "models\ggml-medium.bin"),
    (Join-Path $WhisperDir "ggml-medium.bin"),
    "C:\whisper\models\ggml-medium.bin"
)) {
    if (Test-Path $m) { $model = $m; break }
}
if ($model) { Log "[OK] modelo: $model" Green }
else        { Log "[X] modelo ggml-medium.bin ausente. Rode setup-whisper.ps1." Yellow }

# Grava voice\config.json (o voice_listen.py le isto).
$cfg = [ordered]@{
    cockpit_url        = "http://127.0.0.1:8787"
    llama_url          = "http://127.0.0.1:19001"
    prompt_file        = $PromptFile
    whisper_exe        = ("" + $whisper)
    whisper_model      = ("" + $model)
    whisper_lang       = "pt"
    whisper_threads    = 8
    wakeword           = "hey_jarvis"
    wakeword_models    = @($customModels)
    wakeword_framework = "onnx"
    wakeword_threshold = 0.5
    enable_wakeword    = $true
    hotkey             = "<ctrl>+<shift>+b"
    sample_rate        = 16000
    silence_ms         = 2000
    max_record_ms      = 20000
    start_timeout_ms   = 6000
    llama_timeout_s    = 120
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ConfigFile, ($cfg | ConvertTo-Json -Depth 5), $utf8NoBom)
Log "[OK] config gravado: $ConfigFile" Green

# ============================================================
# 5) AUTO-START NO LOGON (atalho na pasta Inicializar)
#    schtasks e bloqueado por GPO nesta maquina -> vamos direto ao
#    atalho .lnk (mesmo padrao do setup-meeting.ps1). pythonw.exe roda
#    sem janela de console.
# ============================================================
Write-Host ""
if ($NoAutoStart) {
    Log "-NoAutoStart: pulando atalho de logon." DarkGray
}
else {
    Write-Host "===== AUTO-START (logon) =====" -ForegroundColor Cyan
    if (-not (Test-Path $VenvPyw)) {
        Log "[X] pythonw.exe do venv ausente ($VenvPyw); pulando atalho." Yellow
    }
    else {
        $lnk = $null
        try {
            $startup = [Environment]::GetFolderPath('Startup')
            $lnk = Join-Path $startup "SecondBrain-Voice.lnk"
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($lnk)
            $sc.TargetPath       = $VenvPyw
            $sc.Arguments        = "`"$ListenPy`""
            $sc.WorkingDirectory = $VoiceDir
            $sc.WindowStyle      = 7   # minimizado (pythonw nao tem console mesmo)
            $sc.Description      = "SecondBrain - listener de voz (Jarvis, captura local)"
            $sc.Save()
        } catch { $lnk = $null }

        if ($lnk -and (Test-Path $lnk)) {
            Log "[OK] Auto-start via pasta Inicializar: $lnk" Green
            Log "    Sobe o listener a cada logon. Para LIGAR AGORA sem deslogar:" Green
            Log "    Start-Process `"$VenvPyw`" -ArgumentList '`"$ListenPy`"'" DarkGray
        }
        else {
            Write-Host ""
            Write-Host "FALLBACK MANUAL (pasta Inicializar bloqueada):" -ForegroundColor Yellow
            Write-Host "  Inicie o listener manualmente (deixe rodando):" -ForegroundColor Yellow
            Write-Host "    `"$VenvPyw`" `"$ListenPy`"" -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

# ============================================================
# RESUMO
# ============================================================
Write-Host ""
Write-Host "===== RESUMO =====" -ForegroundColor Cyan
Write-Host "  Gatilhos : Ctrl+Shift+B  +  wake word 'hey jarvis'" -ForegroundColor Gray
Write-Host "  Whisper  : $(if($whisper){'pronto ('+$whisper+')'}else{'FALTA (setup-whisper.ps1)'})" -ForegroundColor Gray
Write-Host "  Fluxo    : falar -> whisper local (pt) -> extrai tarefa (llama) -> card no cockpit" -ForegroundColor Gray
Write-Host "  Log      : $(Join-Path $VoiceDir 'voice.log')" -ForegroundColor Gray
Write-Host ""
Write-Host "Teste agora (sem esperar o logon):" -ForegroundColor Cyan
Write-Host "  Start-Process `"$VenvPyw`" -ArgumentList '`"$ListenPy`"'" -ForegroundColor DarkGray
Write-Host "  Depois: Ctrl+Shift+B, fale, aguarde 2s de silencio, e veja o card no cockpit (⟳)." -ForegroundColor DarkGray

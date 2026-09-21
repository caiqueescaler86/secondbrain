param(
    [int]$MaxMinutes = 180,
    [string]$Label    = "reuniao",
    [string]$StopFlag = $null,
    [switch]$KeepAudio   # guarda o WAV mixado em Meetings\<base>.wav p/ reouvir (ocupa disco)
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# SECONDBRAIN - RECORD MEETING (gravacao local de reuniao)
#
# Grava a reuniao inteira NA PROPRIA MAQUINA (nada sai pra nuvem):
#   - audio do SISTEMA (o que os outros falam) via NAudio
#     WasapiLoopbackCapture -> sys.wav  (pega o endpoint de render,
#     entao funciona ate de fone de ouvido).
#   - MICROFONE (voce) via NAudio WaveInEvent -> mic.wav
#   - mixa+normaliza com ffmpeg -> out.wav (16 kHz mono)
#   - transcreve local com whisper.cpp (mesmo padrao do
#     whatsapp-transcribe.ps1) e grava em Meetings\ um .txt + um .json
#     no schema que o meeting-detector.ps1 ingere.
#
# Salvaguarda legal (maquina corporativa): SEMPRE aparece uma janelinha
# "gravando" sempre-no-topo com botao Parar. Fechar/Parar encerra limpo.
#
# Se a NAudio.dll nao existir (rode setup-meeting.ps1), DEGRADA para
# so-microfone via ffmpeg dshow, avisando que o audio dos outros
# participantes NAO sera capturado.
#
# Logs vao pra STDERR; stdout fica limpo.
# ============================================================

$Root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$MeetingsDir = Join-Path $Root "Meetings"
$LibDir      = Join-Path $Root "lib"
$NAudioDll   = Join-Path $LibDir "NAudio.dll"

$WhisperDir = "C:\whisper"
$Model      = "ggml-medium.bin"
$Lang       = "auto"
$Threads    = 8

# Nome do dispositivo dshow para o modo degradado (so-microfone).
$DshowMic   = 'Microphone Array (Intel Smart Sound)'

New-Item -ItemType Directory -Path $MeetingsDir -Force | Out-Null

function Log([string]$Text) {
    [Console]::Error.WriteLine("[$((Get-Date).ToString('HH:mm:ss'))] $Text")
}

# ---- Descoberta de ferramentas (mesmo padrao do whatsapp-transcribe.ps1) -----
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
    # winget instala em WindowsApps ou em Links; procura robusto.
    $probe = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\ffmpeg.exe"),
        "C:\ProgramData\chocolatey\bin\ffmpeg.exe"
    )
    foreach ($p in $probe) { if (Test-Path $p) { return $p } }
    $wg = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages") -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wg) { return $wg.FullName }
    return "ffmpeg"   # ultima cartada: confia no PATH
}

# ---- Nome de arquivo seguro --------------------------------------------------
$startedAt = Get-Date
$ts        = $startedAt.ToString("yyyyMMdd-HHmmss")
$safeLabel = ($Label -replace '[^\w\-]+', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = "reuniao" }
$baseName  = "$ts-$safeLabel"

$tmpStamp = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$sysWav   = Join-Path $env:TEMP ("mtg-$tmpStamp-sys.wav")
$micWav   = Join-Path $env:TEMP ("mtg-$tmpStamp-mic.wav")
$outWav   = Join-Path $env:TEMP ("mtg-$tmpStamp-out.wav")

$ffmpeg = Resolve-Ffmpeg
Log "ffmpeg: $ffmpeg"

# ============================================================
# INDICADOR SEMPRE-NO-TOPO (WinForms) - salvaguarda de consentimento
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-Indicator {
    # Bloqueia ate a janela fechar (Parar, X, StopFlag ou MaxMinutes).
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form              = New-Object System.Windows.Forms.Form
    $form.Text         = "SecondBrain - gravacao local"
    $form.TopMost      = $true
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.StartPosition   = 'Manual'
    $form.ClientSize   = New-Object System.Drawing.Size(300, 88)
    $form.BackColor    = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ShowInTaskbar = $true

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($wa.Right - 316), ($wa.Bottom - 108))

    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.AutoSize  = $false
    $lbl.Size      = New-Object System.Drawing.Size(280, 30)
    $lbl.Location  = New-Object System.Drawing.Point(12, 12)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80)
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lbl.Text      = [char]0x25CF + " Gravando reuniao (local)"
    $form.Controls.Add($lbl)

    $sub           = New-Object System.Windows.Forms.Label
    $sub.AutoSize  = $false
    $sub.Size      = New-Object System.Drawing.Size(190, 20)
    $sub.Location  = New-Object System.Drawing.Point(12, 44)
    $sub.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $sub.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $sub.Text      = "audio fica so nesta maquina"
    $form.Controls.Add($sub)

    $btn           = New-Object System.Windows.Forms.Button
    $btn.Text      = "Parar"
    $btn.Size      = New-Object System.Drawing.Size(80, 30)
    $btn.Location  = New-Object System.Drawing.Point(208, 44)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
    $btn.FlatStyle = 'Flat'
    $btn.Add_Click({ $form.Close() })
    $form.Controls.Add($btn)

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        try {
            if ($script:StopFlag -and (Test-Path $script:StopFlag)) { $form.Close(); return }
            if (((Get-Date) - $script:startedAt).TotalMinutes -ge $script:MaxMinutes) { $form.Close(); return }
        } catch {}
    })
    $timer.Start()

    [void]$form.ShowDialog()
    $timer.Stop()
    $form.Dispose()
}

# ============================================================
# MODO 1: NAUDIO (sistema + microfone simultaneos)
# ============================================================
$recordedWithNAudio = $false
$useNAudio = Test-Path $NAudioDll

if ($useNAudio) {
    try {
        Add-Type -Path $NAudioDll
        $csharp = @"
using System;
using NAudio.Wave;
using NAudio.CoreAudioApi;

public class SbDualRecorder
{
    WasapiLoopbackCapture sysCap;
    WaveInEvent micCap;
    WaveFileWriter sysWriter;
    WaveFileWriter micWriter;
    public bool SysOk, MicOk, SysDone, MicDone;
    public string Err = "";

    public void Start(string sysPath, string micPath)
    {
        try {
            sysCap = new WasapiLoopbackCapture();
            sysWriter = new WaveFileWriter(sysPath, sysCap.WaveFormat);
            sysCap.DataAvailable += (s, e) => { if (sysWriter != null) sysWriter.Write(e.Buffer, 0, e.BytesRecorded); };
            sysCap.RecordingStopped += (s, e) => { if (sysWriter != null) { sysWriter.Dispose(); sysWriter = null; } SysDone = true; try { sysCap.Dispose(); } catch {} };
            sysCap.StartRecording();
            SysOk = true;
        } catch (Exception ex) { SysOk = false; SysDone = true; Err += "sys:" + ex.Message + "; "; }

        try {
            micCap = new WaveInEvent();
            micCap.WaveFormat = new WaveFormat(16000, 1);
            micWriter = new WaveFileWriter(micPath, micCap.WaveFormat);
            micCap.DataAvailable += (s, e) => { if (micWriter != null) micWriter.Write(e.Buffer, 0, e.BytesRecorded); };
            micCap.RecordingStopped += (s, e) => { if (micWriter != null) { micWriter.Dispose(); micWriter = null; } MicDone = true; try { micCap.Dispose(); } catch {} };
            micCap.StartRecording();
            MicOk = true;
        } catch (Exception ex) { MicOk = false; MicDone = true; Err += "mic:" + ex.Message + "; "; }
    }

    public void Stop()
    {
        try { if (sysCap != null && SysOk) sysCap.StopRecording(); } catch { SysDone = true; }
        try { if (micCap != null && MicOk) micCap.StopRecording(); } catch { MicDone = true; }
        int w = 0;
        while ((!SysDone || !MicDone) && w < 60) { System.Threading.Thread.Sleep(100); w++; }
    }
}
"@
        Add-Type -TypeDefinition $csharp -ReferencedAssemblies $NAudioDll -Language CSharp

        $rec = New-Object SbDualRecorder
        $rec.Start($sysWav, $micWav)
        if (-not $rec.SysOk) { Log "AVISO: captura do audio do sistema falhou ($($rec.Err)). Seguindo so com o que der." }
        if (-not $rec.MicOk) { Log "AVISO: captura do microfone falhou ($($rec.Err))." }
        if (-not $rec.SysOk -and -not $rec.MicOk) { throw "NAudio nao conseguiu abrir nem sistema nem microfone: $($rec.Err)" }

        Log "Gravando (NAudio): sistema+microfone. Feche a janelinha ou clique Parar para encerrar."
        Show-Indicator
        Log "Encerrando gravacao..."
        $rec.Stop()
        $recordedWithNAudio = $true
    }
    catch {
        Log "NAudio indisponivel/falhou: $($_.Exception.Message)"
        $useNAudio = $false
    }
}
else {
    Log "NAudio.dll NAO encontrada em '$NAudioDll'. Rode setup-meeting.ps1 para instalar."
}

# ============================================================
# MODO 2 (DEGRADADO): so-microfone via ffmpeg dshow
# ============================================================
if (-not $recordedWithNAudio) {
    Log "DEGRADANDO para so-microfone (ffmpeg dshow). ATENCAO: o audio dos OUTROS participantes NAO sera capturado."

    # tenta descobrir um dispositivo de audio dshow real; cai no nome padrao.
    $micName = $DshowMic
    try {
        $listing = & $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1
        $audioNames = @()
        $inAudio = $false
        foreach ($line in $listing) {
            $s = [string]$line
            if ($s -match 'DirectShow audio devices') { $inAudio = $true; continue }
            if ($s -match 'DirectShow video devices') { $inAudio = $false; continue }
            if ($inAudio -and $s -match '"([^"]+)"') { $audioNames += $matches[1] }
        }
        if ($audioNames.Count -gt 0) {
            $match = $audioNames | Where-Object { $_ -match '(?i)micro|mic' } | Select-Object -First 1
            if (-not $match) { $match = $audioNames[0] }
            $micName = $match
        }
    } catch { Log "Nao consegui enumerar dispositivos dshow; usando nome padrao '$DshowMic'." }
    Log "Dispositivo de microfone (dshow): $micName"

    # inicia ffmpeg com stdin redirecionado para poder mandar 'q' (parada limpa).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $ffmpeg
    $psi.Arguments = "-y -hide_banner -loglevel error -f dshow -i audio=`"$micName`" -ar 16000 -ac 1 `"$outWav`""
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Log "ERRO: nao consegui iniciar o ffmpeg para gravar o microfone: $($_.Exception.Message)"
        Log "Verifique se o ffmpeg esta instalado e o nome do dispositivo de audio."
        exit 1
    }

    Log "Gravando (so-microfone). Feche a janelinha ou clique Parar para encerrar."
    Show-Indicator
    Log "Encerrando gravacao (enviando 'q' ao ffmpeg)..."
    try { $proc.StandardInput.WriteLine("q"); $proc.StandardInput.Flush() } catch {}
    if (-not $proc.WaitForExit(10000)) { try { $proc.Kill() } catch {} }
}

# ============================================================
# MIXAGEM / NORMALIZACAO -> out.wav (16 kHz mono)
# ============================================================
$durationSec = [int][math]::Round(((Get-Date) - $startedAt).TotalSeconds)

function Has-Audio([string]$Path) {
    return (Test-Path $Path) -and ((Get-Item $Path).Length -gt 1024)
}

if ($recordedWithNAudio) {
    $haveSys = Has-Audio $sysWav
    $haveMic = Has-Audio $micWav
    try {
        if ($haveSys -and $haveMic) {
            & $ffmpeg -y -hide_banner -loglevel error -i $micWav -i $sysWav -filter_complex "amix=inputs=2:duration=longest" -ar 16000 -ac 1 $outWav 2>$null
        }
        elseif ($haveMic) {
            Log "Sem audio de sistema utilizavel; mixando so o microfone."
            & $ffmpeg -y -hide_banner -loglevel error -i $micWav -ar 16000 -ac 1 $outWav 2>$null
        }
        elseif ($haveSys) {
            Log "Sem audio de microfone utilizavel; mixando so o audio do sistema."
            & $ffmpeg -y -hide_banner -loglevel error -i $sysWav -ar 16000 -ac 1 $outWav 2>$null
        }
        else {
            Log "ERRO: nenhum audio foi capturado."
        }
    }
    catch { Log "Falha ao mixar com ffmpeg: $($_.Exception.Message)" }
}

# limpa os WAVs de entrada
Remove-Item $sysWav -Force -ErrorAction SilentlyContinue
Remove-Item $micWav -Force -ErrorAction SilentlyContinue

if (-not (Has-Audio $outWav)) {
    Log "ERRO: out.wav vazio/inexistente. Nada a transcrever."
    Remove-Item $outWav -Force -ErrorAction SilentlyContinue
    if ($StopFlag -and (Test-Path $StopFlag)) { Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue }
    exit 1
}

# ============================================================
# TRANSCRICAO (whisper.cpp) - mesmo padrao do whatsapp-transcribe.ps1
# ============================================================
$whisper   = Resolve-Whisper
$modelPath = Resolve-Model

$transcript = ""
if (-not $whisper)   { Log "AVISO: whisper-cli.exe nao encontrado (rode setup-whisper.ps1). Salvando so o audio." }
elseif (-not $modelPath) { Log "AVISO: modelo '$Model' nao encontrado (rode setup-whisper.ps1). Salvando so o audio." }
else {
    Log "whisper: $whisper"
    Log "modelo : $modelPath"
    Log "Transcrevendo (pode demorar em reunioes longas)..."
    $outBase = Join-Path $env:TEMP ("mtg-$tmpStamp")
    $txtFile = "$outBase.txt"
    # 2>&1 | Out-Null e o try/catch protegem contra $ErrorActionPreference="Stop"
    # converter stderr do exe nativo em error record terminante (bug PS5.1).
    try { & $whisper -m $modelPath -f $outWav -l $Lang -t $Threads -otxt -of $outBase -nt -np 2>&1 | Out-Null }
    catch { Log "AVISO: whisper encerrou com erro (pode haver transcricao parcial): $($_.Exception.Message)" }
    if (Test-Path $txtFile) {
        $transcript = ((Get-Content $txtFile -Raw -Encoding UTF8) -replace '\s+', ' ').Trim()
        Remove-Item $txtFile -Force -ErrorAction SilentlyContinue
    }
    else { Log "AVISO: whisper nao gerou transcricao." }
}

# ============================================================
# SAIDA -> Meetings\<base>.txt + <base>.json (schema do meeting-detector.ps1)
# ============================================================
$source = if ($recordedWithNAudio) { "naudio-sys+mic" } else { "ffmpeg-mic-only" }

$txtPath  = Join-Path $MeetingsDir "$baseName.txt"
$jsonPath = Join-Path $MeetingsDir "$baseName.json"

# -KeepAudio: preserva o WAV mixado ao lado da transcricao (p/ reouvir trechos).
# Default: nao guarda (audio e temporario). Tudo local, nada vai pra nuvem.
$wavPath = $null
if ($KeepAudio) {
    $wavPath = Join-Path $MeetingsDir "$baseName.wav"
    try { Copy-Item $outWav $wavPath -Force; Log "Audio guardado: $wavPath" }
    catch { Log "AVISO: falhou guardar o WAV: $($_.Exception.Message)"; $wavPath = $null }
}

[IO.File]::WriteAllText($txtPath, $transcript, [Text.Encoding]::UTF8)

# meeting-detector.ps1 le: $j.transcript (obrigatorio) e $j.label (opcional).
# Demais chaves (startedAt/durationSec/source) sao contexto util e inofensivo.
$sidecar = [pscustomobject]@{
    label       = $safeLabel
    startedAt   = $startedAt.ToString("o")
    durationSec = $durationSec
    source      = $source
    audioKept   = [bool]$wavPath
    audioPath   = $wavPath
    transcript  = $transcript
}
[IO.File]::WriteAllText($jsonPath, ($sidecar | ConvertTo-Json -Depth 10), [Text.Encoding]::UTF8)

# limpa temporarios
Remove-Item $outWav -Force -ErrorAction SilentlyContinue
if ($StopFlag -and (Test-Path $StopFlag)) { Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue }

Log "Pronto. Transcricao: $txtPath"
Log "Sidecar: $jsonPath (label=$safeLabel, ${durationSec}s, fonte=$source)"
if ([string]::IsNullOrWhiteSpace($transcript)) { Log "OBS: transcricao vazia (sem fala detectada ou whisper ausente)." }

param(
    [string]$Launcher = "C:\llama-cpu\launcher.bat",   # o MESMO launcher do atalho do Desktop
    [string]$Exe   = "C:\llama-cpu\llama-server.exe",   # fallback se o launcher sumir
    [string]$Model = "C:\Users\I827769\.cache\huggingface\hub\models--PaoloOrange--Qwen3-Coder-30B-A3B-Instruct-Q4_K_M-GGUF\snapshots\61fc593027b4ffa5a78e3a5ba7615bc569821974\qwen3-coder-30b-a3b-instruct-q4_k_m.gguf",
    [int]$Threads  = 8,
    [int]$Ctx      = 32768,
    [string]$BindHost = "0.0.0.0",   # INTENCIONAL: expor na LAN (NAT protege). NAO trocar p/ 127.0.0.1.
    [int]$Port     = 19001,
    [string]$Alias = "qwen-coder-local"
)

# ============================================================
# SECONDBRAIN - START LLAMA (auto-start no logon)
#
# Sobe o llama-server LOCAL usando o MESMO launcher do Desktop
# (C:\llama-cpu\launcher.bat). Idempotente: se ja houver algo
# escutando em :Port, sai sem fazer nada -> seguro rodar a cada logon
# e tambem na mao. So sobe "se nao estiver aberto". Janela escondida.
#
# BindHost=0.0.0.0 e PROPOSITAL (acesso pela LAN; sem API key). Nao e bug.
# ============================================================

$ErrorActionPreference = "Stop"
$logDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir ("llama-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
function Log([string]$m){
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    Write-Host $line
    try { [IO.File]::AppendAllText($log, $line + "`r`n", [Text.Encoding]::UTF8) } catch {}
}

# 1) Ja esta no ar? (porta respondendo) -> nao sobe outro
$alive = $false
try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect("127.0.0.1", $Port, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(1500)) { $c.EndConnect($iar); $alive = $true }
    $c.Close()
} catch { $alive = $false }
if ($alive) { Log "llama-server ja escutando em :$Port -> nada a fazer."; return }

# 2) Ha um llama-server.exe orfao (subindo, ainda sem porta)? evita duplicar
$proc = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape("--port $Port") }
if ($proc) { Log "llama-server.exe ja em execucao (PID $($proc.ProcessId)) -> nada a fazer."; return }

# 3) Nao esta aberto -> sobe (escondido).
#    Prefere o launcher.bat do Desktop; se sumir, cai no exe direto com os mesmos args.
if (Test-Path $Launcher) {
    Log "Subindo llama via launcher do Desktop: $Launcher (escondido)"
    Start-Process -FilePath "cmd.exe" -ArgumentList '/c', "`"$Launcher`"" -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $Launcher)
    Log "llama-server iniciado pelo launcher."
}
elseif ((Test-Path $Exe) -and (Test-Path $Model)) {
    $args = @('-m', $Model, '-t', $Threads, '-c', $Ctx, '--host', $BindHost, '--port', $Port, '-a', $Alias)
    Log "launcher.bat ausente; subindo llama-server direto: --host $BindHost --port $Port"
    Start-Process -FilePath $Exe -ArgumentList $args -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $Exe)
    Log "llama-server iniciado (fallback direto)."
}
else {
    Log "[X] nem launcher ($Launcher) nem exe/modelo encontrados. Nada feito."
}



# ============================================================
# VOICE LISTENER (Jarvis) - idempotente, igual ao llama
# ============================================================
$VoiceDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "voice"
$VenvPyw  = Join-Path $VoiceDir ".venv\Scripts\pythonw.exe"
$ListenPy = Join-Path $VoiceDir "voice_listen.py"

if (-not (Test-Path $VenvPyw) -or -not (Test-Path $ListenPy)) {
    Log "Voice listener: venv ou voice_listen.py ausente - rode setup-voice.ps1 primeiro."
}
else {
    # Ja esta rodando?
    $voiceProc = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -like "*voice_listen.py*" }
    if ($voiceProc) {
        Log "Voice listener ja em execucao (PID $($voiceProc.ProcessId)) -> nada a fazer."
    }
    else {
        Log "Subindo voice listener (Jarvis)..."
        Start-Process -FilePath $VenvPyw -ArgumentList $ListenPy -WorkingDirectory $VoiceDir -WindowStyle Hidden
        Log "Voice listener iniciado (Ctrl+Shift+B + hey jarvis)."
    }
}

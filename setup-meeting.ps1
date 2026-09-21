param(
    [switch]$NoAutoStart
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ============================================================
# SECONDBRAIN - SETUP MEETING (uma vez)
#
#   1) Baixa a NAudio 1.10.0 (build monolitico net472, com
#      WasapiLoopbackCapture + WaveInEvent numa DLL so) do nuget e
#      extrai lib/net472/NAudio.dll -> SecondBrain\lib\NAudio.dll.
#   2) Valida dependencias (NAudio carrega e enumera dispositivos;
#      whisper-cli; ffmpeg; Outlook COM) e imprime um checklist.
#   3) A menos que -NoAutoStart: registra uma Tarefa Agendada que sobe o
#      meeting-watch.ps1 no logon (usuario atual, sem admin). E ISSO que
#      torna a gravacao automatica.
#
# Maquina corporativa: download, COM e Task Scheduler podem estar
# bloqueados por GPO. Cada passo degrada com mensagem clara e fallback
# manual. Nada sai da maquina alem do download da NAudio.
# ============================================================

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibDir    = Join-Path $Root "lib"
$NAudioDll = Join-Path $LibDir "NAudio.dll"
$WatchPs   = Join-Path $Root "meeting-watch.ps1"
$NuGetUrl  = "https://www.nuget.org/api/v2/package/NAudio/1.10.0"
$TaskName  = "SecondBrain-MeetingWatch"

New-Item -ItemType Directory -Path $LibDir -Force | Out-Null

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

# ============================================================
# 1) NAUDIO
# ============================================================
if (Test-Path $NAudioDll) {
    Log "NAudio.dll ja presente em $NAudioDll; pulando download." DarkGray
}
else {
    $nupkg = Join-Path $env:TEMP "naudio-1.10.0.nupkg.zip"
    $ok = $false
    try {
        Log "Baixando NAudio 1.10.0 do nuget..." Cyan
        Invoke-WebRequest -Uri $NuGetUrl -OutFile $nupkg -UseBasicParsing
        Log "Extraindo lib/net472/NAudio.dll..." Cyan
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
        try {
            # NAudio 1.10.0 NAO tem net472: traz net35, netstandard2.0, netcoreapp3.0, uap10.0.
            # Pro PowerShell 5.1 (.NET Framework) o build limpo p/ Add-Type e o net35 (sem deps).
            $prefer = @(
                'lib/net472/NAudio.dll','lib/net47/NAudio.dll','lib/net462/NAudio.dll',
                'lib/net461/NAudio.dll','lib/net46/NAudio.dll','lib/net45/NAudio.dll',
                'lib/net40/NAudio.dll','lib/net35/NAudio.dll'
            )
            $entry = $null
            foreach ($p in $prefer) {
                $entry = $zip.Entries | Where-Object { $_.FullName -ieq $p } | Select-Object -First 1
                if ($entry) { break }
            }
            if (-not $entry) {
                # qualquer build .NET Framework (net<digito>...) — evita netstandard/netcoreapp/uap,
                # que exigem facades/deps e quebram o Add-Type do PS 5.1.
                $entry = $zip.Entries | Where-Object { $_.FullName -match '(?i)lib/net[0-9][^/]*/NAudio\.dll$' } | Select-Object -First 1
            }
            if (-not $entry) {
                $entry = $zip.Entries | Where-Object { $_.FullName -match '(?i)/NAudio\.dll$' } | Select-Object -First 1
            }
            if (-not $entry) {
                $names = (($zip.Entries | ForEach-Object { $_.FullName }) -join ', ')
                throw ("NAudio.dll nao encontrada no pacote. Conteudo: " + $names)
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $NAudioDll, $true)
            Log "Build extraido: $($entry.FullName)" DarkGray
            $ok = $true
        }
        finally { $zip.Dispose() }
        Remove-Item $nupkg -Force -ErrorAction SilentlyContinue
        Log "NAudio.dll instalada em $NAudioDll" Green
    }
    catch {
        Log "Falha ao baixar/extrair NAudio: $($_.Exception.Message)" Red
        Write-Host ""
        Write-Host "FALLBACK MANUAL (download bloqueado pela empresa?):" -ForegroundColor Yellow
        Write-Host "  1) Em outra maquina, baixe: $NuGetUrl" -ForegroundColor Yellow
        Write-Host "  2) Renomeie o arquivo .nupkg para .zip e abra." -ForegroundColor Yellow
        Write-Host "  3) Copie 'lib\net472\NAudio.dll' de dentro do zip para:" -ForegroundColor Yellow
        Write-Host "     $NAudioDll" -ForegroundColor Yellow
        Write-Host "  (Sem a NAudio a gravacao ainda funciona, mas so com o microfone.)" -ForegroundColor DarkYellow
        Write-Host ""
    }
}

# ============================================================
# 2) VALIDACAO / CHECKLIST
# ============================================================
Write-Host ""
Write-Host "===== CHECKLIST DE DEPENDENCIAS =====" -ForegroundColor Cyan

# 2a) NAudio carrega + enumera dispositivos
$naudioOk = $false
if (Test-Path $NAudioDll) {
    try {
        Add-Type -Path $NAudioDll
        $en = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
        $render  = @($en.EnumerateAudioEndPoints([NAudio.CoreAudioApi.DataFlow]::Render,  [NAudio.CoreAudioApi.DeviceState]::Active))
        $capture = @($en.EnumerateAudioEndPoints([NAudio.CoreAudioApi.DataFlow]::Capture, [NAudio.CoreAudioApi.DeviceState]::Active))
        Log "[OK] NAudio carrega e enumera audio: $($render.Count) saida(s), $($capture.Count) entrada(s)." Green
        $naudioOk = $true
    }
    catch { Log "[X] NAudio.dll presente mas falhou ao carregar/enumerar: $($_.Exception.Message)" Red }
}
else { Log "[X] NAudio.dll ausente -> gravacao so-microfone (veja fallback acima)." Yellow }

# 2b) whisper-cli
$whisper = $null
foreach ($c in @("C:\whisper\whisper-cli.exe", "C:\whisper\Release\whisper-cli.exe", "C:\whisper\bin\whisper-cli.exe")) {
    if (Test-Path $c) { $whisper = $c; break }
}
if (-not $whisper) {
    $f = Get-ChildItem -Path "C:\whisper" -Recurse -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $whisper = $f.FullName }
}
if ($whisper) { Log "[OK] whisper-cli: $whisper" Green }
else          { Log "[X] whisper-cli.exe nao encontrado. Rode setup-whisper.ps1." Yellow }

# 2c) modelo
$model = "C:\whisper\models\ggml-medium.bin"
if (Test-Path $model) { Log "[OK] modelo: $model" Green }
else                  { Log "[X] modelo ggml-medium.bin ausente em C:\whisper\models\. Rode setup-whisper.ps1." Yellow }

# 2d) ffmpeg
$ffmpeg = $null
$cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($cmd) { $ffmpeg = $cmd.Source }
if (-not $ffmpeg) {
    $wg = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages") -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wg) { $ffmpeg = $wg.FullName }
}
if ($ffmpeg) { Log "[OK] ffmpeg: $ffmpeg" Green }
else         { Log "[X] ffmpeg nao encontrado. Instale via 'winget install Gyan.FFmpeg'." Yellow }

# 2e) Outlook COM (best-effort)
try {
    $ol = New-Object -ComObject Outlook.Application
    $ns = $ol.GetNamespace("MAPI")
    $cal = $ns.GetDefaultFolder(9)
    $items = $cal.Items
    $items.Sort("[Start]")
    $items.IncludeRecurrences = $true
    $now = Get-Date
    $filter = "[Start] >= '{0}'" -f $now.ToString("g")
    $next = $items.Restrict($filter) | Select-Object -First 1
    if ($next) {
        $subj = try { [string]$next.Subject } catch { "(sem titulo)" }
        $st   = try { ([datetime]$next.Start).ToString("dd/MM HH:mm") } catch { "?" }
        Log "[OK] Outlook COM abre. Proxima reuniao: '$subj' em $st." Green
    }
    else { Log "[OK] Outlook COM abre (sem proximas reunioes no filtro)." Green }
    $ns = $null; $ol = $null
}
catch {
    Log "[!] Outlook COM indisponivel (GPO?): $($_.Exception.Message)" DarkYellow
    Log "    Sem problema: o watcher detecta reuniao pelo uso do microfone." DarkYellow
}

# ============================================================
# 3) TAREFA AGENDADA (auto-start no logon)
# ============================================================
Write-Host ""
if ($NoAutoStart) {
    Log "-NoAutoStart: pulando registro da tarefa agendada." DarkGray
}
else {
    Write-Host "===== AUTO-START (logon) =====" -ForegroundColor Cyan
    $tr = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchPs`""
    $registered = $false
    try {
        # schtasks: ONLOGON no usuario atual nao exige admin.
        $out = & schtasks.exe /Create /TN $TaskName /SC ONLOGON /RL LIMITED /F /TR $tr 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "[OK] Tarefa '$TaskName' registrada: sobe o meeting-watch.ps1 a cada logon." Green
            Log "    E isto que torna a gravacao AUTOMATICA. Para iniciar agora sem deslogar:" Green
            Log "    schtasks /Run /TN $TaskName" DarkGray
            $registered = $true
        }
        else {
            throw ("schtasks retornou: " + ($out -join ' '))
        }
    }
    catch {
        Log "[X] Task Scheduler bloqueado (GPO): $($_.Exception.Message)" Yellow
        # Fallback SEM Task Scheduler: atalho na pasta Inicializar (roda no logon,
        # nao exige admin e a GPO raramente bloqueia isto).
        $lnk = $null
        try {
            $startup = [Environment]::GetFolderPath('Startup')
            $lnk = Join-Path $startup "SecondBrain-MeetingWatch.lnk"
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($lnk)
            $sc.TargetPath       = (Get-Command powershell.exe).Source
            $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchPs`""
            $sc.WorkingDirectory = $Root
            $sc.WindowStyle      = 7   # minimizado
            $sc.Description       = "SecondBrain - vigia de reunioes (grava/transcreve local)"
            $sc.Save()
        } catch { $lnk = $null }

        if ($lnk -and (Test-Path $lnk)) {
            Log "[OK] Auto-start via pasta Inicializar (sem Task Scheduler): $lnk" Green
            Log "    Sobe o meeting-watch.ps1 a cada logon. Para LIGAR AGORA sem deslogar:" Green
            Log "    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$WatchPs'" DarkGray
            $registered = $true
        }
        else {
            Write-Host ""
            Write-Host "FALLBACK MANUAL (Task Scheduler e pasta Inicializar bloqueados):" -ForegroundColor Yellow
            Write-Host "  Inicie o watcher manualmente (deixe rodando em segundo plano):" -ForegroundColor Yellow
            Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File `"$WatchPs`"" -ForegroundColor Yellow
            Write-Host "  Ou crie a tarefa pela GUI (taskschd.msc): gatilho 'Ao fazer logon', acao acima." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    if (-not $registered) {
        Log "Sem auto-start: lembre de iniciar o meeting-watch.ps1 manualmente apos cada logon." DarkYellow
    }
}

# ============================================================
# RESUMO
# ============================================================
Write-Host ""
Write-Host "===== RESUMO =====" -ForegroundColor Cyan
$mode = if ($naudioOk) { "COMPLETA (sistema + microfone)" } else { "SO-MICROFONE (instale a NAudio p/ capturar os outros)" }
Write-Host "  Gravacao : $mode" -ForegroundColor Gray
Write-Host "  Transcr. : $(if($whisper){'whisper.cpp pronto'}else{'FALTA whisper (setup-whisper.ps1)'})" -ForegroundColor Gray
Write-Host "  Saidas   : $(Join-Path $Root 'Meetings')\<data>-<label>.txt/.json (o meeting-detector.ps1 ingere)" -ForegroundColor Gray
Write-Host ""
Write-Host "Teste manual de gravacao agora:" -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\record-meeting.ps1`" -Label teste" -ForegroundColor DarkGray

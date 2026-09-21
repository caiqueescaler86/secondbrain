param(
    [int]$PollSec    = 20,
    [int]$MaxMinutes = 180
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# SECONDBRAIN - MEETING WATCH (dispara a gravacao sozinho)
#
# Loop de fundo. A cada poll, decide se ha uma reuniao/ligacao AO VIVO
# combinando dois sinais (best-effort):
#   1) MICROFONE em uso agora: le o ConsentStore do Windows
#      (HKCU:\...\CapabilityAccessManager\ConsentStore\microphone e
#      \microphone\NonPackaged). App com LastUsedTimeStop == 0 esta com
#      o microfone AGORA. Se for um app de chamada conhecido
#      (Teams/ms-teams/Chrome/Edge/Slack/Zoom) -> ligacao ao vivo.
#   2) CALENDARIO (Outlook COM, best-effort): ha reuniao acontecendo
#      agora? Se sim, usa o assunto como -Label. Se o COM estiver
#      bloqueado por GPO, ignora silenciosamente e trabalha so com o mic.
#
# Politica: gravar TODAS as reunioes (o Teams nao auto-transcreve neste
# tenant). Ao detectar reuniao ao vivo e nao estar gravando -> inicia
# record-meeting.ps1 (passa -StopFlag e -Label). Quando o microfone e
# liberado / reuniao acaba -> cria o StopFlag; o record-meeting encerra,
# mixa e transcreve sozinho.
#
# Nunca grava em dobro: um record por instancia de reuniao.
# Logs vao pra STDERR.
# ============================================================

$Root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$MeetingsDir = Join-Path $Root "Meetings"
$RecordPs    = Join-Path $Root "record-meeting.ps1"
$WatchState  = Join-Path $MeetingsDir "watch-state.json"

New-Item -ItemType Directory -Path $MeetingsDir -Force | Out-Null

function Log([string]$Text) {
    [Console]::Error.WriteLine("[$((Get-Date).ToString('HH:mm:ss'))] $Text")
}

$MicBase = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"

# apps de chamada conhecidos (o nome da chave no ConsentStore usa '#'
# no lugar de '\' para nao-empacotados; empacotados usam o PFN).
$CallAppPatterns = @(
    'teams', 'ms-teams', 'msteams', 'MSTeams',
    'chrome', 'msedge', 'edge',
    'slack', 'zoom', 'webex', 'GoTo', 'discord'
)

function Is-CallApp([string]$Name) {
    foreach ($p in $CallAppPatterns) {
        if ($Name -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

# ---- Sinal 1: microfone em uso AGORA por um app de chamada -------------------
function Get-LiveMicApp {
    # retorna o nome do app de chamada usando o microfone agora, ou $null.
    $keys = @()
    try { $keys += Get-ChildItem -Path $MicBase -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne 'NonPackaged' } } catch {}
    try { $keys += Get-ChildItem -Path (Join-Path $MicBase "NonPackaged") -ErrorAction SilentlyContinue } catch {}

    foreach ($k in $keys) {
        try {
            $props = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            # LastUsedTimeStop == 0 => em uso neste momento.
            if ($props.PSObject.Properties.Name -notcontains 'LastUsedTimeStop') { continue }
            $stop = [int64]$props.LastUsedTimeStop
            if ($stop -ne 0) { continue }

            $name = $k.PSChildName
            # nao-empacotado: caminho com '#'; pega o executavel do fim.
            $leaf = ($name -split '#')[-1]
            if ((Is-CallApp $name) -or (Is-CallApp $leaf)) {
                return $leaf
            }
        } catch {}
    }
    return $null
}

# ---- Sinal 2: reuniao no calendario acontecendo agora (Outlook COM) ----------
function Get-CalendarSubjectNow {
    # best-effort; devolve o assunto da reuniao em curso, ou $null.
    try {
        $ol = New-Object -ComObject Outlook.Application
        $ns = $ol.GetNamespace("MAPI")
        $cal = $ns.GetDefaultFolder(9)   # olFolderCalendar
        $items = $cal.Items
        $items.Sort("[Start]")
        $items.IncludeRecurrences = $true

        $now  = Get-Date
        $from = $now.AddHours(-4)
        $to   = $now.AddHours(4)
        $filter = "[Start] >= '{0}' AND [Start] <= '{1}'" -f $from.ToString("g"), $to.ToString("g")
        $restricted = $items.Restrict($filter)

        $subject = $null
        $n = 0
        foreach ($appt in $restricted) {
            $n++; if ($n -gt 200) { break }
            try {
                $start = [datetime]$appt.Start
                $end   = [datetime]$appt.End
                if ($now -ge $start -and $now -le $end) {
                    $allDay = $false; try { $allDay = [bool]$appt.AllDayEvent } catch {}
                    if ($allDay) { continue }
                    $s = [string]$appt.Subject
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $subject = $s; break }
                }
            } catch { continue }
        }
        $ns = $null; $ol = $null
        return $subject
    }
    catch {
        return $null
    }
}

# ---- Estado (persistente, best-effort) --------------------------------------
function Save-WatchState([bool]$Recording, [string]$StopFlag, [int]$ProcId, [string]$Label) {
    try {
        $obj = [pscustomobject]@{
            version   = 1
            updatedAt = (Get-Date).ToString("o")
            recording = $Recording
            stopFlag  = $StopFlag
            pid       = $ProcId
            label     = $Label
        }
        [IO.File]::WriteAllText($WatchState, ($obj | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    } catch {}
}

# ---- Preflight ---------------------------------------------------------------
if (-not (Test-Path $RecordPs)) {
    Log "ERRO: record-meeting.ps1 nao encontrado em $RecordPs. Abortando."
    exit 1
}

$naudioOk = Test-Path (Join-Path $Root "lib\NAudio.dll")
if (-not $naudioOk) {
    Log "AVISO: lib\NAudio.dll ausente. A gravacao vai DEGRADAR para so-microfone (rode setup-meeting.ps1 para captura completa)."
}

# limpa estado antigo (recomeco limpo)
Save-WatchState $false $null 0 ""

Log "Meeting-watch iniciado. Poll a cada ${PollSec}s. Ctrl+C para parar."
Log "Gravacao completa (sistema+mic): $(if($naudioOk){'ativa'}else{'INDISPONIVEL - so microfone'})."

# ---- Loop --------------------------------------------------------------------
$recording   = $false
$stopFlag    = $null
$proc        = $null
$curLabel    = ""
$releaseHits = 0        # polls consecutivos sem microfone (debounce de parada)
$releaseNeed = 2        # exige 2 polls livres antes de parar

while ($true) {
    try {
        # se estava gravando e o processo morreu sozinho (MaxMinutes/erro), reseta.
        if ($recording -and $proc -and $proc.HasExited) {
            Log "record-meeting encerrou por conta propria (exit=$($proc.ExitCode)). Pronto para a proxima."
            $recording = $false; $stopFlag = $null; $proc = $null; $curLabel = ""
            Save-WatchState $false $null 0 ""
        }

        $micApp   = Get-LiveMicApp
        $micLive  = [bool]$micApp

        if (-not $recording) {
            if ($micLive) {
                # deriva o label do assunto do calendario, se houver.
                $label = "reuniao"
                $subj  = Get-CalendarSubjectNow
                if (-not [string]::IsNullOrWhiteSpace($subj)) {
                    $label = ($subj -replace '[^\w\-]+', '-').Trim('-')
                    if ([string]::IsNullOrWhiteSpace($label)) { $label = "reuniao" }
                    if ($label.Length -gt 40) { $label = $label.Substring(0, 40) }
                }

                $stopFlag = Join-Path $env:TEMP ("mtg-stop-" + (Get-Date).ToString("yyyyMMddHHmmss") + ".flag")
                Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue

                Log "Reuniao ao vivo detectada (mic: $micApp) -> iniciando gravacao. Label='$label'."
                $recArgs = @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", $RecordPs,
                    "-MaxMinutes", $MaxMinutes,
                    "-Label", $label,
                    "-StopFlag", $stopFlag
                )
                try {
                    $proc = Start-Process -FilePath "powershell" -ArgumentList $recArgs -PassThru -WindowStyle Minimized
                    $recording = $true; $curLabel = $label; $releaseHits = 0
                    Save-WatchState $true $stopFlag $proc.Id $label
                }
                catch {
                    Log "Falha ao iniciar record-meeting.ps1: $($_.Exception.Message)"
                    $stopFlag = $null; $proc = $null
                }
            }
        }
        else {
            # gravando: se o microfone foi liberado por polls suficientes, para.
            if (-not $micLive) {
                $releaseHits++
                if ($releaseHits -ge $releaseNeed) {
                    Log "Microfone liberado / reuniao terminou -> sinalizando parada (StopFlag)."
                    if ($stopFlag) {
                        try { New-Item -ItemType File -Path $stopFlag -Force | Out-Null } catch {}
                    }
                    # aguarda o record-meeting encerrar (mixa+transcreve).
                    $waited = 0
                    while ($proc -and -not $proc.HasExited -and $waited -lt 300) {
                        Start-Sleep -Seconds 3; $waited += 3
                    }
                    if ($proc -and -not $proc.HasExited) {
                        Log "record-meeting ainda processando (transcricao longa); seguindo o monitoramento."
                    }
                    $recording = $false; $stopFlag = $null; $proc = $null; $curLabel = ""; $releaseHits = 0
                    Save-WatchState $false $null 0 ""
                }
            }
            else {
                $releaseHits = 0
            }
        }
    }
    catch {
        Log "Erro no loop (seguindo): $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollSec
}

param(
    [string[]]$Times = @("07:55", "13:25"),   # horarios da rodada diaria (manha + tarde)
    [switch]$OpenCockpit,                       # abrir o navegador na rodada agendada (padrao: nao)
    [switch]$Remove                             # remover o agendamento
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# SECONDBRAIN - AGENDAMENTO DA RODADA DIARIA (Task Scheduler)
#
# Registra uma tarefa que roda o secondbrain-run.ps1 nos horarios
# pedidos (padrao: 07:55 e 13:25). Nivel USUARIO, SEM admin.
#
#   .\setup-schedule.ps1                 # registra 2x/dia (manha+tarde)
#   .\setup-schedule.ps1 -Times 08:00    # so de manha
#   .\setup-schedule.ps1 -OpenCockpit    # abre o cockpit na rodada agendada
#   .\setup-schedule.ps1 -Remove         # remove o agendamento
#
# A rodada agendada e best-effort: se Joule/Copilot/llama nao estiverem
# abertos, esses canais falham (nao-fatal) e WhatsApp/Meetings seguem.
# ============================================================

$TaskName = "SecondBrain - Rodada diaria"
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunPs    = Join-Path $Root "secondbrain-run.ps1"

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
}

if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Log "Agendamento removido: '$TaskName'." Green
    } catch { Log "Nada para remover (ou falha): $($_.Exception.Message)" Yellow }
    return
}

if (-not (Test-Path $RunPs)) { throw "Nao achei secondbrain-run.ps1 em $Root" }

# Argumentos do PowerShell 5.1 rodando o orquestrador (janela oculta, sem profile)
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RunPs`""
if ($OpenCockpit) { $psArgs += " -OpenCockpit" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs -WorkingDirectory $Root

# Um gatilho diario por horario pedido
$triggers = @()
foreach ($t in $Times) {
    try { $when = [datetime]::Parse($t) } catch { throw "Horario invalido: '$t' (use HH:mm, ex 07:55)." }
    $triggers += New-ScheduledTaskTrigger -Daily -At $when
}

# Roda como o usuario atual, sem privilegio elevado, so quando logado (permite COM/Outlook/UI)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null

Log "Agendado: '$TaskName' em $($Times -join ', ') (diario)." Green
if ($OpenCockpit) { Log "A rodada agendada vai ABRIR o cockpit no navegador." DarkGray }
else { Log "A rodada agendada roda em segundo plano (nao abre navegador). Use 'cockpit' pra ver, ou -OpenCockpit." DarkGray }
Log "Conferir/ajustar: Agendador de Tarefas do Windows -> '$TaskName'. Remover: .\setup-schedule.ps1 -Remove" DarkGray

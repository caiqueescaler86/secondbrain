param(
    [int]$Port = 8787,
    [switch]$Reset
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================
# COCKPIT DEMO — semeia tasks.json de exemplo e abre o cockpit.
# So para ver a aparencia. Use -Reset para limpar e voltar a [].
#   .\cockpit-demo.ps1            # semeia exemplo + abre
#   .\cockpit-demo.ps1 -Reset     # limpa o store (volta a vazio)
# ============================================================

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Processed = Join-Path $Root "processed"
$TasksFile = Join-Path $Processed "tasks.json"
$CockpitPs = Join-Path $Root "cockpit.ps1"
if (-not (Test-Path $Processed)) { New-Item -ItemType Directory -Path $Processed -Force | Out-Null }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($Reset) {
    [System.IO.File]::WriteAllText($TasksFile, "[]", $Utf8NoBom)
    Write-Host "Store limpo: $TasksFile" -ForegroundColor Yellow
    return
}

$today    = (Get-Date).ToString("yyyy-MM-dd")
$ontem    = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
$amanha   = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
$now      = (Get-Date).ToString("o")
$reuniao  = (Get-Date).AddDays(1).ToString("yyyy-MM-ddTHH:mm")

function New-Task($sbid, $pessoa, $assunto, $acao, $status, $tipo, $cat, $prio, $due, $risco, $fontes, $board, $resumo) {
    [pscustomobject]@{
        sbid = $sbid; titulo = $assunto; prefixo = ""; canal = $fontes[0]; fontes = $fontes
        pessoa = $pessoa; assunto = $assunto; resumo = $resumo; proxima_acao = $acao
        responsavel = "eu"; status = $status; tipo = $tipo; categoria = $cat
        prioridade = $prio; prazo = ""; risco = $risco; reuniao_em = ""
        dueDate = $due; snoozedUntil = $null; done = $false; notas = ""; userTouched = $null
        createdAt = $now; updatedAt = $now; history = @("[$now] demo")
    }
}

$demo = @(
    (New-Task "sb-demo00000001" "Maria (ACME)" "Revisar proposta comercial" "Enviar proposta revisada ate hoje" "fazer" "trabalho" "fazer" "alta" $today "" @("email") "active" "Cliente pediu ajuste de escopo e novo preco."),
    (New-Task "sb-demo00000002" "Carlos (Diretoria)" "Aprovar orcamento Q4" "Responder e-mail com numeros consolidados" "responder" "trabalho" "responder" "alta" $today "" @("email","teams") "active" "Diretoria aguarda retorno para fechar o trimestre."),
    (New-Task "sb-demo00000003" "Joao (TI)" "Liberacao de acesso ao ambiente" "Cobrar a liberacao do acesso" "cobrar" "trabalho" "cobrar" "media" $ontem "Pode atrasar o onboarding do cliente" @("whatsapp") "active" "Ja pedi ha 3 dias, sem retorno."),
    (New-Task "sb-demo00000004" "Fornecedor X" "Contrato de renovacao" "Aguardando minuta revisada do juridico" "aguardando" "trabalho" "aguardando" "media" $amanha "" @("email") "active" "Juridico ficou de mandar ate amanha."),
    (New-Task "sb-demo00000005" "Equipe CS" "Reuniao de QBR com cliente" "Preparar deck do QBR" "preparar" "trabalho" "preparar" "alta" $today "" @("calendario") "active" "QBR trimestral; revisar metricas de adocao."),
    (New-Task "sb-demo00000006" "Cliente Beta" "Risco de churn" "Agendar call de retencao com urgencia" "risco" "trabalho" "risco" "alta" $today "NPS caiu e reduziram uso na ultima semana" @("teams","transcricao") "active" "Sinais de insatisfacao na ultima reuniao."),
    (New-Task "sb-demo00000007" "Ana" "Aniversario da sobrinha" "Comprar presente" "fazer" "pessoal" "whatsapp-pessoal" "media" $amanha "" @("whatsapp") "active" "Festa no fim de semana."),
    (New-Task "sb-demo00000008" "Grupo Projeto Y" "Ajuste no cronograma" "Confirmar nova data com o time" "fazer" "trabalho" "whatsapp-trabalho" "media" $today "" @("whatsapp") "active" "Time pediu para adiar entrega em 2 dias."),
    (New-Task "sb-demo00000009" "RH" "Politica de home office" "Ler quando sobrar tempo" "referencia" "trabalho" "referencia" "baixa" $null "" @("email") "referencia" "Comunicado geral, sem acao imediata.")
)

$json = @($demo) | ConvertTo-Json -Depth 20
$tmp = "$TasksFile.tmp"
[System.IO.File]::WriteAllText($tmp, $json, $Utf8NoBom)
[System.IO.File]::Copy($tmp, $TasksFile, $true)
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Semeados $($demo.Count) itens de exemplo em $TasksFile" -ForegroundColor Green
Write-Host "Abrindo o cockpit... (Ctrl+C para parar; depois rode com -Reset para limpar)" -ForegroundColor Cyan
Write-Host ""

& $CockpitPs -Port $Port -Open

param(
    [int]$Days = 8,
    [ValidateSet("joule","local")]
    [string]$Engine = "local",
    [int]$JouleTimeoutSec = 300,
    [string]$Endpoint = "http://127.0.0.1:19001",
    [string]$Model = "",
    [int]$MaxChars = 45000,
    [int]$ChunkChars = 7000,
    [string]$Question = "",
    [string]$OnlyChat = "",
    [string]$SinceIso = "",
    [double]$Temperature = 0.3,
    [int]$MaxTokens = 1500,
    [int]$TimeoutSec = 900,
    [string]$ApiKey = "",
    [switch]$Json,
    [switch]$Save
)

$ErrorActionPreference = "Stop"

# Acentos corretos no console (PS 5.1 usa a code page OEM por padrao).
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch {}

# ============================================================
# SECONDBRAIN - ANALISE WHATSAPP (Joule ou LLM local)
#
# Le a base local whatsapp-messages.jsonl (ultimos N dias),
# monta o contexto e pede uma analise de pendencias.
#
#   -Engine joule (padrao): manda o contexto para o Joule
#     (Claude via CDP local, mesma ponte do canal Joule). E mais
#     rapido/robusto, MAS o CONTEUDO das conversas de WhatsApp sai
#     para o Joule (nuvem SAP corporativa).
#   -Engine local: usa a LLM local (llama.cpp em 127.0.0.1);
#     nada sai da maquina, porem mais lento e menos confiavel.
#
# Objetivo tipico: definir pendencias e quem esta pendente
# comigo, gerando uma lista de to-do.
# ============================================================

$BaseDir = Join-Path $env:USERPROFILE "Documents\Joule\SecondBrain\WhatsApp"
$ScriptRoot = Split-Path $BaseDir -Parent
$MessagesFile = Join-Path $BaseDir "whatsapp-messages.jsonl"

function Log([string]$Text, [ConsoleColor]$Color = "Gray") {
    # Em modo -Json o stdout precisa ficar limpo (so o JSON): logs vao pra stderr.
    if ($Json) {
        [Console]::Error.WriteLine("[$((Get-Date).ToString('HH:mm:ss'))] $Text")
    }
    else {
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color
    }
}

if (-not (Test-Path $MessagesFile)) {
    throw "Base nao encontrada: $MessagesFile. Rode o whatsapp-collector.ps1 primeiro."
}

# --- Carrega e filtra as mensagens ------------------------------------------
$cutoff = (Get-Date).AddDays(-$Days)

# Marca d'agua: se informado, descarta mensagens cujo instante de envio e anterior/igual
# ao ultimo instante de analise bem-sucedida (evita realimentar mensagens ja processadas).
$sinceOffset = $null
if (-not [string]::IsNullOrWhiteSpace($SinceIso)) {
    try { $sinceOffset = [datetimeoffset]::Parse($SinceIso) } catch {}
    if (-not $sinceOffset) { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] AVISO: -SinceIso '$SinceIso' nao foi parseado; ignorando." -ForegroundColor Yellow }
}

$sinceLabel = if ($sinceOffset) { " | marca dagua: desde $($sinceOffset.ToString('yyyy-MM-dd HH:mm zzz'))" } else { "" }
Log "Lendo base e filtrando ultimos $Days dias (a partir de $($cutoff.ToString('yyyy-MM-dd HH:mm')))$sinceLabel..." Cyan

$records = New-Object System.Collections.ArrayList
$total = 0

foreach ($line in [System.IO.File]::ReadLines($MessagesFile)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $total++
    try { $r = $line | ConvertFrom-Json } catch { continue }

    if (-not $r.timestamp) { continue }
    $dt = $null
    try { $dt = [datetimeoffset]::Parse([string]$r.timestamp) } catch {}
    if (-not $dt) { continue }
    if ($dt.LocalDateTime -lt $cutoff) { continue }
    # Marca d'agua: descarta mensagens ja processadas na ultima analise bem-sucedida.
    if ($sinceOffset -and $dt -le $sinceOffset) { continue }

    if ($OnlyChat -and ([string]$r.chat) -notlike "*$OnlyChat*") { continue }
    if ([string]::IsNullOrWhiteSpace([string]$r.text)) { continue }

    [void]$records.Add([pscustomobject]@{
        chat      = [string]$r.chat
        dt        = $dt
        author    = [string]$r.author
        direction = [string]$r.direction
        text      = (([string]$r.text) -replace '\s+', ' ')
    })
}

Log "Base: $total linhas. No periodo: $($records.Count) mensagens." Gray

if ($records.Count -eq 0) {
    throw "Nenhuma mensagem no periodo. Aumente -Days ou rode o coletor."
}

# --- Monta o transcript, priorizando as mensagens mais recentes -------------
function Format-Line($m) {
    $who =
        if ($m.direction -eq "out") { "EU" }
        elseif ($m.author) { $m.author }
        else { "?" }
    return ("  [{0}] {1}: {2}" -f $m.dt.ToString("dd/MM HH:mm"), $who, $m.text)
}

# Ordena tudo por data desc, acumula ate MaxChars (mantem o mais recente).
$byRecent = $records | Sort-Object dt -Descending
$kept = New-Object System.Collections.ArrayList
$chars = 0
foreach ($m in $byRecent) {
    $len = (Format-Line $m).Length + 1
    if ($chars + $len -gt $MaxChars) { break }
    [void]$kept.Add($m)
    $chars += $len
}

if ($kept.Count -lt $records.Count) {
    Log "Contexto truncado para caber em $MaxChars chars: usando as $($kept.Count) mensagens mais recentes." Yellow
}

# Reagrupa por chat, cronologico dentro de cada chat.
$sb = New-Object System.Text.StringBuilder
foreach ($grp in ($kept | Group-Object chat | Sort-Object Name)) {
    [void]$sb.AppendLine("### Chat: $($grp.Name)")
    foreach ($m in ($grp.Group | Sort-Object dt)) {
        [void]$sb.AppendLine((Format-Line $m))
    }
    [void]$sb.AppendLine("")
}
$transcript = $sb.ToString()

# --- Descobre o modelo se nao informado (so no engine local) ----------------
if ($Engine -eq 'local' -and [string]::IsNullOrWhiteSpace($Model)) {
    try {
        $headers = @{}
        if ($ApiKey) { $headers["Authorization"] = "Bearer $ApiKey" }
        $models = Invoke-RestMethod -Uri "$Endpoint/v1/models" -Method Get -Headers $headers -TimeoutSec 10
        $Model = [string]$models.data[0].id
        Log "Modelo detectado: $Model" Gray
    }
    catch {
        $Model = "local-model"
        Log "Nao consegui listar modelos; usando '$Model' (llama.cpp ignora o campo)." Yellow
    }
}
elseif ($Engine -eq 'joule') { $Model = "Joule" }

# --- Monta o prompt ----------------------------------------------------------
if ($Json) {
    # Modo estruturado: carrega instrucoes do template prompts/whatsapp.md,
    # injetando data/hora atual (o modelo local nao conhece a data) e o periodo.
    $waPromptFile = Join-Path $ScriptRoot "prompts\whatsapp.md"
    if (Test-Path $waPromptFile) {
        $hoje = (Get-Date).ToString("dd/MM/yyyy")
        $hora = (Get-Date).ToString("HH:mm")
        $system = (Get-Content $waPromptFile -Raw -Encoding UTF8) `
                  -replace '\{\{HOJE\}\}', $hoje `
                  -replace '\{\{HORA\}\}', $hora `
                  -replace '\{\{DIAS\}\}', [string]$Days
    } else {
        # Fallback: instrucoes minimas caso o template nao exista.
        $system = @"
Voce e um extrator de pendencias de conversas de WhatsApp. Responda SOMENTE com um array JSON valido, sem texto antes/depois, sem cercas de codigo.
Regras:
- Linhas 'EU:' sao mensagens minhas (direction=out); as demais sao da outra pessoa.
- Nao invente. Se faltar informacao, use null.
- status: responder|cobrar|aguardando|fazer|risco|referencia.
- tipo: pessoal|trabalho. prioridade: alta|media|baixa.
- Ignore conversa social sem acao.
"@
    }
    # $Question vazio: o schema e instrucoes ja estao no $system (template).
    # A linha "=== CONVERSAS ===" com os dados e acrescentada por cada lote abaixo.
    $Question = ""
    if ($Temperature -gt 0.2) { $Temperature = 0.1 }
}
elseif ([string]::IsNullOrWhiteSpace($Question)) {
    $Question = @"
Com base nas conversas abaixo (ultimos $Days dias), gere:

1. MINHAS PENDENCIAS: o que EU preciso responder ou fazer (coisas em que a bola esta comigo). Formato de to-do com [ ], agrupado por chat, com o que ficou combinado.
2. PENDENTE COMIGO: quem esta devendo resposta/acao PARA MIM, por chat, dizendo o que estou esperando.
3. PRAZOS E DATAS combinados, se houver.

Seja objetivo. Cite o chat e a pessoa. Ignore conversa social sem acao.
"@
}

if (-not $Json) {
    $system = @"
Voce e um assistente que analisa transcricoes de WhatsApp para organizar pendencias e responsaveis.
Regras:
- Linhas marcadas com 'EU:' sao mensagens que o proprio usuario enviou. As demais sao de outras pessoas (o nome vem antes dos dois pontos).
- 'in' = mensagem recebida, 'out' = enviada por mim (ja refletido no rotulo EU).
- Responda em portugues do Brasil, direto ao ponto, em markdown.
- Nao invente compromissos que nao estejam no texto. Se algo estiver ambiguo, diga que esta ambiguo.
"@
}

$userContent = $Question + "`n`n=== CONVERSAS ===`n" + $transcript

$answer = $null

# --- Helpers do engine local -------------------------------------------------
# Uma chamada de streaming ao llama.cpp local; devolve o texto completo.
function Invoke-LocalStream([string]$system, [string]$userContent) {
    $body = @{
        model = $Model
        temperature = $Temperature
        max_tokens = $MaxTokens
        stream = $true
        messages = @(
            @{ role = "system"; content = $system },
            @{ role = "user";   content = $userContent }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    # UTF-8 explicito para nao corromper acentos no corpo da requisicao.
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)

    $answerSb = New-Object System.Text.StringBuilder
    $resp = $null
    $reader = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("$Endpoint/v1/chat/completions")
        $req.Method = "POST"
        $req.ContentType = "application/json; charset=utf-8"
        if ($ApiKey) { $req.Headers.Add("Authorization", "Bearer $ApiKey") }
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.ContentLength = $bytes.Length

        $reqStream = $req.GetRequestStream()
        $reqStream.Write($bytes, 0, $bytes.Length)
        $reqStream.Close()

        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (-not $line.StartsWith("data:")) { continue }

            $data = $line.Substring(5).Trim()
            if ($data -eq "[DONE]") { break }

            try { $j = $data | ConvertFrom-Json } catch { continue }
            $delta = [string]$j.choices[0].delta.content
            if ($delta) {
                if ($Json) { [Console]::Error.Write($delta) }
                else { Write-Host -NoNewline $delta }
                [void]$answerSb.Append($delta)
            }
        }
    }
    catch {
        throw "Falha ao chamar a LLM local em $Endpoint. O llama-server esta rodando? Erro: $($_.Exception.Message)"
    }
    finally {
        if ($reader) { try { $reader.Close() } catch {} }
        if ($resp)   { try { $resp.Close() }   catch {} }
    }

    return $answerSb.ToString()
}

# Extrai um array JSON tolerante de um texto (lote truncado -> array vazio).
function Get-JsonItems([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $c = $text -replace '```json', '' -replace '```', ''
    $s = $c.IndexOf('[')
    $e = $c.LastIndexOf(']')
    if ($s -ge 0 -and $e -gt $s) { $c = $c.Substring($s, ($e - $s + 1)) }
    try { return @($c | ConvertFrom-Json) } catch { return @() }
}

if ($Engine -eq 'local') {
    Log "Engine local. Periodo: $($records.Count) msgs; janela util p/ modo texto: $($kept.Count) (cap $MaxChars)." Cyan

    if ($Json) {
        # --- Modo estruturado: quebra em LOTES pequenos por chat/orcamento de
        #     chars. Cada lote gera um JSON curto que nao trunca; junta tudo no
        #     final. Cobre o PERIODO INTEIRO ($records), nao so o truncado.
        $ordered = $records | Sort-Object chat, dt
        $batches = New-Object System.Collections.ArrayList
        $cur = New-Object System.Text.StringBuilder
        $curChat = $null
        $curLen = 0
        foreach ($m in $ordered) {
            $line = Format-Line $m
            if ($curLen -gt 0 -and ($curLen + $line.Length + 80) -gt $ChunkChars) {
                [void]$batches.Add($cur.ToString())
                $cur = New-Object System.Text.StringBuilder
                $curChat = $null
                $curLen = 0
            }
            if ($m.chat -ne $curChat) {
                [void]$cur.AppendLine("### Chat: $($m.chat)")
                $curChat = $m.chat
                $curLen += ("### Chat: " + $m.chat).Length + 1
            }
            [void]$cur.AppendLine($line)
            $curLen += $line.Length + 1
        }
        if ($curLen -gt 0) { [void]$batches.Add($cur.ToString()) }

        Log "Dividido em $($batches.Count) lote(s) de ate ~$ChunkChars chars (modelo local, streaming em stderr)." Cyan
        [Console]::Error.WriteLine("--- gerando JSON por lote (streaming em stderr) ---")

        $allItems = New-Object System.Collections.ArrayList
        $idx = 0
        foreach ($batch in $batches) {
            $idx++
            Log "Lote $idx/$($batches.Count) (~$([math]::Round($batch.Length/1000))k chars)..." Gray
            [Console]::Error.WriteLine("")
            [Console]::Error.WriteLine("### lote $idx/$($batches.Count)")
            $uc = $Question + "`n`n=== CONVERSAS ===`n" + $batch
            $raw = Invoke-LocalStream $system $uc
            $items = Get-JsonItems $raw
            foreach ($it in $items) { [void]$allItems.Add($it) }
            Log "Lote ${idx}: $(@($items).Count) item(ns)." Gray
        }

        $answer = (@($allItems) | ConvertTo-Json -Depth 20)
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "[]" }
    }
    else {
        # Modo interativo/manual: uma chamada so com o transcript inteiro.
        Log "Modelo local e lento (~10 tok/s); a resposta aparece em streaming abaixo." Gray
        Write-Host ""
        Write-Host "==================== ANALISE ====================" -ForegroundColor Green
        $answer = Invoke-LocalStream $system $userContent
    }
}
else {
    # Engine = joule: manda o MESMO contexto para o Joule (Claude via CDP local),
    # reaproveitando a ponte joule-terminal.ps1 (mesma do canal Joule da rodada).
    $JoulePs = Join-Path $ScriptRoot "joule-terminal.ps1"
    if (-not (Test-Path $JoulePs)) {
        throw "Nao achei joule-terminal.ps1 em $ScriptRoot (necessario para -Engine joule)."
    }

    # Joule usa um unico campo de conteudo (sem role 'system'): concatena as
    # instrucoes do sistema + a pergunta + as conversas num prompt so.
    $fullPrompt = $system + "`n`n" + $userContent

    Log "Enviando $($kept.Count) mensagens (~$([math]::Round($fullPrompt.Length/1000))k chars) para o Joule (CDP local)..." Cyan
    Log "O conteudo do WhatsApp vai para o Joule (nuvem SAP). Analise no modelo do Joule." DarkYellow
    if ($Json) { [Console]::Error.WriteLine("--- perguntando ao Joule (nova conversa) ---") }
    else {
        Write-Host ""
        Write-Host "==================== ANALISE (Joule) ====================" -ForegroundColor Green
    }

    # -NewThread: conversa limpa, sem misturar com o canal Joule (e-mail/agenda).
    $answer = (& $JoulePs -Prompt $fullPrompt -NewThread -TimeoutSec $JouleTimeoutSec | Out-String)
    if (-not $Json -and $answer) { Write-Host $answer }
}

$answer = [string]$answer
if ([string]::IsNullOrWhiteSpace($answer)) {
    throw "A analise (engine=$Engine) retornou resposta vazia."
}

if ($Json) {
    # Extracao tolerante: remove cercas ```json e pega do primeiro [ ao ultimo ].
    $clean = $answer -replace '```json', '' -replace '```', ''
    $start = $clean.IndexOf('[')
    $end = $clean.LastIndexOf(']')
    if ($start -ge 0 -and $end -gt $start) {
        $clean = $clean.Substring($start, $end - $start + 1)
    }
    # Valida; se falhar, ainda emite o melhor esforco (o orquestrador trata).
    try {
        $parsed = $clean | ConvertFrom-Json
        $clean = ($parsed | ConvertTo-Json -Depth 20)
        # ConvertTo-Json de 1 item nao gera array; garante colchetes.
        if ($clean -notmatch '^\s*\[') { $clean = "[$clean]" }
        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("JSON valido: $(@($parsed).Count) itens.")
    }
    catch {
        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("AVISO: JSON possivelmente invalido; emitindo melhor esforco.")
    }

    if ($Save) {
        $outFile = Join-Path $BaseDir ("analysis-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
        [System.IO.File]::WriteAllText($outFile, $clean, [Text.Encoding]::UTF8)
        Log "Salvo em: $outFile" Green
    }

    # UNICA saida no stdout: o JSON.
    Write-Output $clean
    return
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Green

if ($Save) {
    $outFile = Join-Path $BaseDir ("analysis-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".md")
    $header = "# Analise WhatsApp - ultimos $Days dias`n`nGerado em $(Get-Date -Format 'yyyy-MM-dd HH:mm') | modelo: $Model | $($kept.Count) mensagens`n`n"
    [System.IO.File]::WriteAllText($outFile, $header + $answer, [Text.Encoding]::UTF8)
    Log "Salvo em: $outFile" Green
}

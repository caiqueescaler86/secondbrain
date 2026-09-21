param(
    [string]$Prompt,
    [int]$TimeoutSec = 120,
    [string]$Model = "GPT 5.6 Think"   # modelo alvo no seletor do Copilot; "" = nao mexe
)

$global:CopilotPort = 9223
$global:CopilotApp =
    "shell:AppsFolder\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe!Microsoft.MicrosoftOfficeHub"

function Enable-CopilotDebug {
    $key =
        "HKCU:\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments"

    # Em maquina gerenciada (enterprise) essa chave de policy pode estar
    # bloqueada. Se ja houver porta CDP ativa, nao precisamos escrever nada.
    try {
        New-Item -Path $key -Force -ErrorAction Stop | Out-Null

        New-ItemProperty `
            -Path $key `
            -Name "M365Copilot.exe" `
            -Value "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$global:CopilotPort" `
            -PropertyType String `
            -Force -ErrorAction Stop | Out-Null
    }
    catch {
        if (-not (Test-CopilotCDP)) {
            throw "Nao consegui habilitar o debug do Copilot (chave de policy bloqueada) e a porta CDP $global:CopilotPort nao esta ativa. Rode uma vez como admin ou inicie o Copilot com o debug ja ligado."
        }
        # Porta ja ativa: seguimos.
    }
}

function Test-CopilotCDP {
    try {
        Invoke-WebRequest `
            "http://127.0.0.1:$global:CopilotPort/json/version" `
            -UseBasicParsing `
            -TimeoutSec 2 | Out-Null

        return $true
    }
    catch {
        return $false
    }
}

function Start-CopilotBridge {
    Enable-CopilotDebug

    if (Test-CopilotCDP) {
        return
    }

    $running = Get-Process M365Copilot -ErrorAction SilentlyContinue

    if ($running) {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Start-Process $global:CopilotApp

    $deadline = (Get-Date).AddSeconds(30)

    do {
        Start-Sleep -Milliseconds 500

        if (Test-CopilotCDP) {
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Copilot abriu, mas a porta CDP $global:CopilotPort nao apareceu."
}

function Get-CopilotTargets {
    Start-CopilotBridge

    $content = (
        Invoke-WebRequest `
            "http://127.0.0.1:$global:CopilotPort/json/list" `
            -UseBasicParsing `
            -TimeoutSec 3
    ).Content

    $parsed = ConvertFrom-Json -InputObject $content
    $result = @()

    foreach ($target in $parsed) {
        if (
            $target.type -eq "page" -and
            $target.title -like "*Copilot*" -and
            $target.webSocketDebuggerUrl
        ) {
            $result += $target
        }
    }

    return $result
}

# --- CDP de baixo nivel: uma conexao persistente, qualquer metodo ------------
# O editor do Copilot (Fluent UI / React) ignora .focus()/execCommand/click
# sinteticos. So responde a input CONFIAVEL via CDP: clique real de mouse
# para focar, Input.insertText para digitar, Input.dispatchKeyEvent p/ Enter.

$script:CdpWs = $null
$script:CdpCts = $null
$script:CdpId = 0

function Open-CopilotSession {
    param([int]$TimeoutSec = 180)

    $targets = @(Get-CopilotTargets)

    if ($targets.Count -eq 0) {
        throw "Nenhum renderer do Copilot encontrado."
    }

    foreach ($target in $targets) {
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))

        try {
            $url = [string]$target.webSocketDebuggerUrl
            $ws.ConnectAsync([Uri]$url, $cts.Token).GetAwaiter().GetResult() | Out-Null

            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                throw "socket nao abriu"
            }

            $script:CdpWs = $ws
            $script:CdpCts = $cts

            # So aceita o renderer que realmente tem o editor do Copilot.
            $hasEditor = Send-CDP "Runtime.evaluate" @{
                returnByValue = $true
                expression = '(()=>!!(document.querySelector(''[contenteditable="true"][aria-label="Message Copilot"]'')||document.querySelector(''[contenteditable="true"]'')))()'
            }

            if ($hasEditor) {
                return
            }

            # Renderer errado: fecha e tenta o proximo.
            try { $ws.Dispose() } catch {}
            try { $cts.Dispose() } catch {}
            $script:CdpWs = $null
            $script:CdpCts = $null
        }
        catch {
            try { $ws.Dispose() } catch {}
            try { $cts.Dispose() } catch {}
            $script:CdpWs = $null
            $script:CdpCts = $null
        }
    }

    throw "Nenhum renderer ativo do Copilot com editor respondeu."
}

function Close-CopilotSession {
    if ($script:CdpWs) { try { $script:CdpWs.Dispose() } catch {} }
    if ($script:CdpCts) { try { $script:CdpCts.Dispose() } catch {} }
    $script:CdpWs = $null
    $script:CdpCts = $null
}

function Send-CDP {
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [hashtable]$Params = @{}
    )

    if (-not $script:CdpWs) {
        throw "Sessao CDP nao esta aberta."
    }

    $ct = $script:CdpCts.Token
    $script:CdpId++
    $myId = $script:CdpId

    $request = @{
        id = $myId
        method = $Method
        params = $Params
    } | ConvertTo-Json -Compress -Depth 30

    $bytes = [Text.Encoding]::UTF8.GetBytes($request)

    try {
        $script:CdpWs.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $ct
        ).GetAwaiter().GetResult() | Out-Null

        while ($script:CdpWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $buffer = New-Object byte[] 1048576
            $stream = [IO.MemoryStream]::new()

            do {
                $received = $script:CdpWs.ReceiveAsync(
                    [ArraySegment[byte]]::new($buffer),
                    $ct
                ).GetAwaiter().GetResult()

                if ($received.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw "Renderer encerrou a conexao."
                }

                $stream.Write($buffer, 0, $received.Count)
            } while (-not $received.EndOfMessage)

            $raw = [Text.Encoding]::UTF8.GetString($stream.ToArray())

            try { $message = $raw | ConvertFrom-Json } catch { continue }

            # Eventos (sem id) e respostas de outros comandos: ignora.
            if ($message.id -ne $myId) { continue }

            if ($message.result.exceptionDetails) {
                $description = $message.result.exceptionDetails.exception.description
                if (-not $description) {
                    $description = $message.result.exceptionDetails.text
                }
                throw $description
            }

            return $message.result.result.value
        }
    }
    catch [System.OperationCanceledException] {
        throw "Timeout esperando resposta do Copilot."
    }
}

function Set-CopilotModel {
    param([string]$Target)

    # Best-effort e NAO-FATAL: garante que o seletor de modelo do Copilot
    # esteja no modelo alvo (ex.: "GPT 5.6 Think"). O modelo PERSISTE entre
    # sessoes, entao no caso normal o botao ja esta certo e a gente so confere
    # e sai. So abre o menu e clica se tiver saido do alvo. Se algo falhar,
    # segue com o modelo atual (nunca derruba a pergunta).
    if ([string]::IsNullOrWhiteSpace($Target)) { return }

    # tokens do alvo (ex.: "gpt","5.6","think"); um item casa se contiver TODOS
    $tokensJson = (($Target.ToLowerInvariant() -split '\s+' | Where-Object { $_ }) | ConvertTo-Json -Compress)
    if ($tokensJson -notmatch '^\s*\[') { $tokensJson = "[$tokensJson]" }

    try {
        # 1) Botao do seletor + estado atual
        $btnRaw = Send-CDP "Runtime.evaluate" @{
            returnByValue = $true
            expression = @"
(() => {
  const toks = $tokensJson;
  const b = document.querySelector('[aria-label="Model Selector"]');
  if (!b) return JSON.stringify({ok:false});
  const cur = (b.innerText||b.textContent||"").replace(/\s+/g," ").trim();
  const low = cur.toLowerCase();
  const already = toks.every(t => low.includes(t));
  const r = b.getBoundingClientRect();
  return JSON.stringify({ok:true, cur, already, x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
})()
"@
        }
        $btn = $btnRaw | ConvertFrom-Json
        if (-not $btn.ok) { return }                       # sem seletor: nada a fazer
        if ($btn.already) { return }                       # ja no modelo alvo: nao mexe

        # 2) Abre o menu (clique confiavel no botao)
        Send-CDP "Input.dispatchMouseEvent" @{ type="mousePressed";  x=[int]$btn.x; y=[int]$btn.y; button="left"; clickCount=1 } | Out-Null
        Send-CDP "Input.dispatchMouseEvent" @{ type="mouseReleased"; x=[int]$btn.x; y=[int]$btn.y; button="left"; clickCount=1 } | Out-Null
        Start-Sleep -Milliseconds 700

        # 3) Acha o item cujo texto contem TODOS os tokens do alvo
        $itemRaw = Send-CDP "Runtime.evaluate" @{
            returnByValue = $true
            expression = @"
(() => {
  const toks = $tokensJson;
  const items = [...document.querySelectorAll('[role="menuitemradio"],[role="menuitemcheckbox"],[role="menuitem"],[role="option"]')];
  let best = null, bestLen = 1e9;
  for (const el of items) {
    const t = (el.innerText||el.textContent||"").replace(/\s+/g," ").trim();
    const low = t.toLowerCase();
    if (toks.every(k => low.includes(k)) && t.length < bestLen) { best = el; bestLen = t.length; }
  }
  if (!best) return JSON.stringify({ok:false});
  const r = best.getBoundingClientRect();
  return JSON.stringify({ok:true, text:(best.innerText||"").replace(/\s+/g," ").trim(), x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
})()
"@
        }
        $item = $itemRaw | ConvertFrom-Json
        if ($item.ok) {
            Send-CDP "Input.dispatchMouseEvent" @{ type="mousePressed";  x=[int]$item.x; y=[int]$item.y; button="left"; clickCount=1 } | Out-Null
            Send-CDP "Input.dispatchMouseEvent" @{ type="mouseReleased"; x=[int]$item.x; y=[int]$item.y; button="left"; clickCount=1 } | Out-Null
            Start-Sleep -Milliseconds 400
        } else {
            # nao achou o item: fecha o menu (Escape) e segue com o modelo atual
            Send-CDP "Input.dispatchKeyEvent" @{ type="keyDown"; key="Escape"; code="Escape"; windowsVirtualKeyCode=27; nativeVirtualKeyCode=27 } | Out-Null
            Send-CDP "Input.dispatchKeyEvent" @{ type="keyUp";   key="Escape"; code="Escape"; windowsVirtualKeyCode=27; nativeVirtualKeyCode=27 } | Out-Null
        }
    }
    catch {
        # best-effort: qualquer erro aqui nao pode derrubar a pergunta
    }
}

function Ask-Copilot {
    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [int]$TimeoutSec = 120
    )

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        $Prompt = Read-Host "Voce"
    }

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        return
    }

    Open-CopilotSession -TimeoutSec ($TimeoutSec + 60)

    # Garante o modelo alvo (best-effort; usa o -Model do script, default "GPT 5.6 Think").
    Set-CopilotModel -Target $Model

    try {
        # 1) Coords do editor + contagem/ids das respostas existentes.
        $prep = Send-CDP "Runtime.evaluate" @{
            returnByValue = $true
            expression = @'
(() => {
  const e = document.querySelector('[contenteditable="true"][aria-label="Message Copilot"]') || document.querySelector('[contenteditable="true"]');
  if (!e) return JSON.stringify({ok:false});
  e.scrollIntoView({block:"center"});
  const r = e.getBoundingClientRect();
  const replies = [...document.querySelectorAll('[data-testid="markdown-reply"]')];
  const ids = replies.map(el => el.getAttribute("data-message-id")).filter(Boolean);
  return JSON.stringify({ok:true, count:replies.length, ids, x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
})()
'@
        }

        $p = $prep | ConvertFrom-Json
        if (-not $p.ok) {
            throw "Editor do Copilot nao encontrado."
        }

        # 2) Clique REAL de mouse para focar o editor (foco confiavel).
        Send-CDP "Input.dispatchMouseEvent" @{ type="mousePressed";  x=[int]$p.x; y=[int]$p.y; button="left"; clickCount=1 } | Out-Null
        Send-CDP "Input.dispatchMouseEvent" @{ type="mouseReleased"; x=[int]$p.x; y=[int]$p.y; button="left"; clickCount=1 } | Out-Null
        Start-Sleep -Milliseconds 250

        # 3) Limpa qualquer residuo no editor: Ctrl+A depois Delete.
        Send-CDP "Input.dispatchKeyEvent" @{ type="keyDown"; key="a"; code="KeyA"; windowsVirtualKeyCode=65; nativeVirtualKeyCode=65; modifiers=2 } | Out-Null
        Send-CDP "Input.dispatchKeyEvent" @{ type="keyUp";   key="a"; code="KeyA"; windowsVirtualKeyCode=65; nativeVirtualKeyCode=65; modifiers=2 } | Out-Null
        Send-CDP "Input.dispatchKeyEvent" @{ type="keyDown"; key="Delete"; code="Delete"; windowsVirtualKeyCode=46; nativeVirtualKeyCode=46 } | Out-Null
        Send-CDP "Input.dispatchKeyEvent" @{ type="keyUp";   key="Delete"; code="Delete"; windowsVirtualKeyCode=46; nativeVirtualKeyCode=46 } | Out-Null
        Start-Sleep -Milliseconds 150

        # 4) Digita o prompt com Input.insertText (confiavel).
        Send-CDP "Input.insertText" @{ text = $Prompt } | Out-Null
        Start-Sleep -Milliseconds 400

        # 5) Confirma que o editor recebeu o texto (o botao Send so surge com conteudo).
        $check = Send-CDP "Runtime.evaluate" @{
            returnByValue = $true
            expression = '(()=>{const e=document.querySelector(''[contenteditable="true"][aria-label="Message Copilot"]'')||document.querySelector(''[contenteditable="true"]'');return (e&&(e.innerText||"").trim().length>0);})()'
        }
        if (-not $check) {
            throw "Nao consegui inserir o texto no editor do Copilot."
        }

        # 6) Envia com Enter (keyDown + keyUp).
        Send-CDP "Input.dispatchKeyEvent" @{ type="keyDown"; key="Enter"; code="Enter"; windowsVirtualKeyCode=13; nativeVirtualKeyCode=13 } | Out-Null
        Send-CDP "Input.dispatchKeyEvent" @{ type="keyUp";   key="Enter"; code="Enter"; windowsVirtualKeyCode=13; nativeVirtualKeyCode=13 } | Out-Null

        # 7) Aguarda a resposta nova estabilizar (poll dentro do renderer).
        $existingJson = ($p.ids | ConvertTo-Json -Compress)
        if ([string]::IsNullOrWhiteSpace($existingJson)) { $existingJson = "[]" }
        # ConvertTo-Json de um unico item nao gera array; forca colchetes.
        if ($existingJson -notmatch '^\s*\[') { $existingJson = "[$existingJson]" }
        $existingCount = [int]$p.count
        $timeoutMs = $TimeoutSec * 1000

        $poll = Send-CDP "Runtime.evaluate" @{
            awaitPromise = $true
            returnByValue = $true
            expression = @"
(async () => {
    const existingIds = new Set($existingJson);
    const existingCount = $existingCount;
    const timeoutMs = $timeoutMs;

    return await new Promise(resolve => {
        const started = Date.now();
        let lastText = "", lastId = null, stableSince = null;

        const finish = value => { clearInterval(timer); resolve(value); };

        const timer = setInterval(() => {
            const replies = [...document.querySelectorAll('[data-testid="markdown-reply"]')];
            let candidate = null;

            for (const reply of replies) {
                const id = reply.getAttribute("data-message-id");
                if (id && !existingIds.has(id)) { candidate = reply; }
            }
            if (!candidate && replies.length > existingCount) {
                candidate = replies[replies.length - 1];
            }

            if (candidate) {
                const text = (candidate.innerText || candidate.textContent || "").replace(/\s+/g, " ").trim();
                const id = candidate.getAttribute("data-message-id");
                if (text && (text !== lastText || id !== lastId)) {
                    lastText = text; lastId = id; stableSince = Date.now();
                }
                // Se a resposta parece um array JSON AINDA nao fechado (comeca com
                // "[" mas nao terminou com "]"), o Copilot ainda esta gerando -> nao
                // fecha cedo (era o caso do capturar so "["). "[]" ja fecha, ok.
                const t = text || "";
                const jsonOpenIncomplete = t.startsWith("[") && !t.endsWith("]");
                if (text && !jsonOpenIncomplete && stableSince && (Date.now() - stableSince) >= 4000) {
                    finish({ ok:true, text, messageId:id });
                    return;
                }
            }

            if (Date.now() - started > timeoutMs) {
                if (lastText) { finish({ ok:true, text:lastText, messageId:lastId, partial:true }); }
                else { finish({ ok:false, error:"Timeout esperando resposta do Copilot." }); }
            }
        }, 250);
    });
})()
"@
        }

        if (-not $poll) {
            throw "Copilot nao retornou resultado."
        }
        if (-not $poll.ok) {
            throw $poll.error
        }

        return $poll.text
    }
    finally {
        Close-CopilotSession
    }
}

function Start-CopilotTerminal {
    Start-CopilotBridge

    Write-Host ""
    Write-Host "Microsoft Copilot"
    Write-Host "-----------------"
    Write-Host "exit = sair"
    Write-Host ""

    while ($true) {
        $question = Read-Host "Voce"

        if ([string]::IsNullOrWhiteSpace($question)) {
            continue
        }

        switch ($question.ToLower()) {
            "exit" { return }
            "quit" { return }
            "sair" { return }
        }

        try {
            $answer = Ask-Copilot -Prompt $question

            Write-Host ""
            Write-Host "Copilot:"
            Write-Host ""
            Write-Host $answer
            Write-Host ""
        }
        catch {
            Write-Host ""
            Write-Host "Erro: $($_.Exception.Message)"
            Write-Host ""
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    try {
        Start-CopilotBridge
        Ask-Copilot -Prompt $Prompt -TimeoutSec $TimeoutSec
    }
    catch {
        Write-Error $_.Exception.Message
    }
}
else {
    try {
        Start-CopilotTerminal
    }
    catch {
        Write-Error $_.Exception.Message
    }
}

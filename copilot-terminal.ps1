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

    # A chave so eh LIDA pelo WebView2 quando o M365Copilot INICIA. Em maquina
    # gerenciada (enterprise) a policy fica read-only (GPO): reescrever lanca
    # "Requested registry access is not allowed". Mas se a chave JA tem a porta
    # certa, nao precisamos escrever nada - basta relancar o app que ele sobe
    # com o CDP ligado. So falhamos se a chave NAO estiver correta E nao der
    # para escrever E nao houver porta ativa.
    $expected = "--remote-debugging-port=$global:CopilotPort"

    $current = $null
    try {
        $current = (Get-ItemProperty -Path $key -Name "M365Copilot.exe" -ErrorAction Stop)."M365Copilot.exe"
    } catch {}

    if ($current -and ($current -match [regex]::Escape($expected))) {
        return   # ja configurada: relancar o app basta.
    }

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

function Test-CopilotSuspended {
    # Retorna $true se o unico target disponivel tem appstate=suspended na URL.
    # Nesse estado o WebView esta congelado: a porta CDP responde mas o JS nao roda.
    try {
        $content = (Invoke-WebRequest "http://127.0.0.1:$global:CopilotPort/json/list" -UseBasicParsing -TimeoutSec 3).Content
        $targets = ConvertFrom-Json -InputObject $content
        $pages = @($targets | Where-Object { $_.type -eq "page" -and $_.title -like "*Copilot*" })
        if ($pages.Count -eq 0) { return $true }   # sem page = suspenso / nao carregado
        foreach ($p in $pages) {
            if ($p.url -notmatch 'appstate=suspended') { return $false }
        }
        return $true   # todos suspensos
    } catch { return $true }
}

function Start-CopilotBridge {
    Enable-CopilotDebug

    # Porta CDP aberta NAO garante que o app esta ativo: o M365Copilot pode estar
    # suspenso (appstate=suspended na URL do target), caso em que o WebView congela
    # e qualquer tentativa de interacao falha silenciosamente. Precisa relançar.
    if (Test-CopilotCDP -and -not (Test-CopilotSuspended)) {
        return
    }

    # Suspenso ou sem porta: mata e relanca.
    $running = Get-Process M365Copilot -ErrorAction SilentlyContinue
    if ($running) {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Start-Process $global:CopilotApp

    $deadline = (Get-Date).AddSeconds(40)

    do {
        Start-Sleep -Milliseconds 600

        if (Test-CopilotCDP -and -not (Test-CopilotSuspended)) {
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Copilot abriu, mas a porta CDP $global:CopilotPort nao ficou ativa (nao-suspensa)."
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

    # Cold-start / pos-relaunch o app passa por about:blank -> "Microsoft Copilot"
    # -> chat pronto (editor presente). Em vez de uma tentativa unica, repetimos
    # a busca do renderer com editor por ate ~45s, absorvendo essa transicao.
    $deadline = (Get-Date).AddSeconds(45)

    do {
        $targets = @(Get-CopilotTargets)

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
                    # Mantem o renderer "ativo/focado" para o WebView2 nao
                    # estrangular timers nem virtualizar/colapsar a resposta
                    # quando a janela fica em segundo plano. Essa e a CAUSA RAIZ
                    # do timeout: com a janela atras, o node da resposta some do
                    # DOM e readLast() lia "" a rodada inteira -> timeout sem
                    # texto. setFocusEmulationEnabled faz document.hasFocus()==true
                    # e desliga o throttle de background. Best-effort (dominios
                    # podem faltar): qualquer erro aqui e ignorado.
                    try { Send-CDP "Emulation.setFocusEmulationEnabled" @{ enabled = $true } | Out-Null } catch {}
                    try { Send-CDP "Page.enable" @{} | Out-Null } catch {}
                    try { Send-CDP "Page.setWebLifecycleState" @{ state = "active" } | Out-Null } catch {}
                    return
                }

                # Renderer errado / chat ainda carregando: fecha e tenta o proximo.
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

        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 800
    } while ($true)

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

function Restart-CopilotApp {
    # O WebView2 do M365Copilot pode travar num estado morto: o editor aceita o
    # texto mas a geracao nunca comeca (sawStop=false, copy=0, editorLen>0). Nesse
    # caso a UNICA coisa que destrava e reiniciar o app inteiro. Fecha a sessao CDP
    # obsoleta, derruba o processo (mesma descoberta usada por Start-CopilotBridge),
    # relanca com o debug ligado (reaproveita Enable-CopilotDebug) e espera a porta
    # CDP voltar ativa (nao-suspensa).
    Close-CopilotSession

    $running = Get-Process M365Copilot -ErrorAction SilentlyContinue
    if ($running) {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Enable-CopilotDebug
    Start-Process $global:CopilotApp

    $deadline = (Get-Date).AddSeconds(90)

    do {
        Start-Sleep -Milliseconds 800

        if (Test-CopilotCDP -and -not (Test-CopilotSuspended)) {
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Copilot nao voltou apos reiniciar o app (porta CDP $global:CopilotPort nao ficou ativa)."
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

    # Wrapper resiliente: se o WebView travar (editor preenchido, geracao nunca
    # comeca) reinicia o app e retenta UMA vez. No maximo 2 tentativas no total.
    $maxAttempts = 2

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $result = Invoke-CopilotAsk -Prompt $Prompt -TimeoutSec $TimeoutSec

        if (-not $result.wedged) {
            return $result.text
        }

        if ($attempt -lt $maxAttempts) {
            Write-Host "Copilot travado (editor preenchido, geracao nao iniciou) -> reiniciando o app e retentando ($attempt/$maxAttempts)..."
            Restart-CopilotApp
        }
    }

    throw "Copilot travado: a geracao nao iniciou mesmo apos reiniciar o app (editor preenchido, sem resposta)."
}

function Invoke-CopilotAsk {
    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [int]$TimeoutSec = 120
    )

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
  const copyCount = document.querySelectorAll('[data-testid="CopyButtonTestId"]').length;
  return JSON.stringify({ok:true, count:replies.length, ids, copyCount, x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
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

        # 6) Envia. No chat recem-carregado (pos-relaunch) o handler de Enter as
        # vezes ainda nao esta pronto e a mensagem fica digitada sem enviar. O
        # clique REAL no botao Send (aria-label="Send") e confiavel; Enter fica
        # como fallback se o botao nao aparecer.
        $sendBtn = Send-CDP "Runtime.evaluate" @{
            returnByValue = $true
            expression = @'
(() => {
  const b = document.querySelector('button[aria-label="Send"]') || document.querySelector('button[aria-label="Enviar"]');
  if (!b || b.disabled) return JSON.stringify({ok:false});
  const r = b.getBoundingClientRect();
  return JSON.stringify({ok:true, x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
})()
'@
        }
        $sb = $null
        try { $sb = $sendBtn | ConvertFrom-Json } catch {}

        if ($sb -and $sb.ok) {
            Send-CDP "Input.dispatchMouseEvent" @{ type="mousePressed";  x=[int]$sb.x; y=[int]$sb.y; button="left"; clickCount=1 } | Out-Null
            Send-CDP "Input.dispatchMouseEvent" @{ type="mouseReleased"; x=[int]$sb.x; y=[int]$sb.y; button="left"; clickCount=1 } | Out-Null
        } else {
            Send-CDP "Input.dispatchKeyEvent" @{ type="keyDown"; key="Enter"; code="Enter"; windowsVirtualKeyCode=13; nativeVirtualKeyCode=13 } | Out-Null
            Send-CDP "Input.dispatchKeyEvent" @{ type="keyUp";   key="Enter"; code="Enter"; windowsVirtualKeyCode=13; nativeVirtualKeyCode=13 } | Out-Null
        }

        # 6b) Confirma que a GERACAO COMECOU (botao Stop aparece). Se em ~10s nao
        # apareceu, o Send nao pegou (editor ainda com texto): reenvia UMA vez
        # (clique no Send de novo, senao Enter). Isso mata o modo de falha em que
        # o texto ficava digitado e a rodada dava timeout sem resposta nenhuma.
        $genStarted = $false
        $startDeadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 400
            $genStarted = [bool](Send-CDP "Runtime.evaluate" @{
                returnByValue = $true
                expression = '(()=>!!(document.querySelector(''button[aria-label="Stop"]'')||document.querySelector(''button[aria-label="Stop generating"]'')||document.querySelector(''button[aria-label="Parar"]'')))()'
            })
        } while (-not $genStarted -and (Get-Date) -lt $startDeadline)

        if (-not $genStarted) {
            # Reenvio: acha o Send de novo e clica; fallback Enter.
            $sendBtn2 = Send-CDP "Runtime.evaluate" @{
                returnByValue = $true
                expression = @'
(() => {
  const b = document.querySelector('button[aria-label="Send"]') || document.querySelector('button[aria-label="Enviar"]');
  if (!b || b.disabled) return JSON.stringify({ok:false});
  const r = b.getBoundingClientRect();
  return JSON.stringify({ok:true, x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)});
})()
'@
            }
            $sb2 = $null
            try { $sb2 = $sendBtn2 | ConvertFrom-Json } catch {}
            if ($sb2 -and $sb2.ok) {
                Send-CDP "Input.dispatchMouseEvent" @{ type="mousePressed";  x=[int]$sb2.x; y=[int]$sb2.y; button="left"; clickCount=1 } | Out-Null
                Send-CDP "Input.dispatchMouseEvent" @{ type="mouseReleased"; x=[int]$sb2.x; y=[int]$sb2.y; button="left"; clickCount=1 } | Out-Null
            } else {
                Send-CDP "Input.dispatchKeyEvent" @{ type="keyDown"; key="Enter"; code="Enter"; windowsVirtualKeyCode=13; nativeVirtualKeyCode=13 } | Out-Null
                Send-CDP "Input.dispatchKeyEvent" @{ type="keyUp";   key="Enter"; code="Enter"; windowsVirtualKeyCode=13; nativeVirtualKeyCode=13 } | Out-Null
            }

            # Depois do reenvio, confere de novo se a geracao comecou. Se mesmo
            # assim o Stop nao aparecer em ~8s, o WebView travou (editor cheio,
            # nada gerado): sinaliza wedged para o wrapper reiniciar o app e
            # retentar, em vez de gastar o TimeoutSec inteiro no poll.
            $genStarted = $false
            $resendDeadline = (Get-Date).AddSeconds(8)
            do {
                Start-Sleep -Milliseconds 400
                $genStarted = [bool](Send-CDP "Runtime.evaluate" @{
                    returnByValue = $true
                    expression = '(()=>!!(document.querySelector(''button[aria-label="Stop"]'')||document.querySelector(''button[aria-label="Stop generating"]'')||document.querySelector(''button[aria-label="Parar"]'')))()'
                })
            } while (-not $genStarted -and (Get-Date) -lt $resendDeadline)

            if (-not $genStarted) {
                return @{ wedged = $true }
            }
        }

        # 7) Aguarda a RESPOSTA FINAL. Sinal robusto, independente de quantos steps
        # o reasoning faz: o botao STOP existe DURANTE a geracao e SOME quando
        # termina. (A contagem de toolbars Copy nao serve: o DOM virtualiza e
        # colapsa as respostas -> o count fica preso em 1 e nunca "cresce".)
        # Logica: (A) espera ver o Stop (geracao em curso); (B) espera o Stop
        # sumir com texto presente = resposta final. Fallback: se nunca vimos o
        # Stop (janela perdida), aceita quando surge uma toolbar Copy nova.
        $existingCopyCount = [int]$p.copyCount
        $timeoutMs = $TimeoutSec * 1000

        $poll = Send-CDP "Runtime.evaluate" @{
            awaitPromise = $true
            returnByValue = $true
            expression = @"
(async () => {
    const baseCopy = $existingCopyCount;
    const timeoutMs = $timeoutMs;

    // Anti-throttle: mantem a pagina "visivel/focada" p/ o app continuar
    // STREAMando a resposta mesmo com a janela em segundo plano (rodada agendada).
    // Complementa o Emulation.setFocusEmulationEnabled + setWebLifecycleState (CDP,
    // aplicados na abertura) que perdem efeito quando a pagina re-throttla durante
    // a geracao longa.
    try {
        document.hasFocus = () => true;
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        document.dispatchEvent(new Event("visibilitychange"));
    } catch (e) {}

    const stopVisible = () => !!(
        document.querySelector('button[aria-label="Stop"]') ||
        document.querySelector('button[aria-label="Stop generating"]') ||
        document.querySelector('button[aria-label="Parar"]')
    );
    // Antes de ler, ROLA ate o fim para a lista virtualizada renderizar a cauda
    // (senao o node da ultima resposta pode nao existir no DOM). Le o markdown
    // padrao e, se sumiu, cai em seletores de resposta mais amplos.
    const readLast = () => {
        try { window.scrollTo(0, document.body.scrollHeight); } catch (e) {}
        let replies = [...document.querySelectorAll('[data-testid="markdown-reply"]')];
        if (!replies.length) {
            replies = [...document.querySelectorAll('[data-testid*="markdown" i],[data-testid*="reply" i],[data-testid*="response" i]')];
        }
        if (!replies.length) return "";
        const last = replies[replies.length - 1];
        try { last.scrollIntoView({ block: "end" }); } catch (e) {}
        return (last.innerText || last.textContent || "").replace(/\s+/g, " ").trim();
    };
    const editorLen = () => {
        const e = document.querySelector('[contenteditable="true"][aria-label="Message Copilot"]') || document.querySelector('[contenteditable="true"]');
        return e ? (e.innerText || "").trim().length : -1;
    };

    return await new Promise(resolve => {
        const started = Date.now();
        let sawStop = false, lastText = "", doneText = "", stableSince = 0, recoverSince = null;

        const finish = value => { clearInterval(timer); resolve(value); };

        const timer = setInterval(() => {
            // reafirma "visivel" a cada tick: se a janela re-throttlar no meio da
            // geracao, o app continua pintando/streamando a resposta no DOM.
            try { document.dispatchEvent(new Event("visibilitychange")); } catch (e) {}
            const stop = stopVisible();
            const copy = document.querySelectorAll('[data-testid="CopyButtonTestId"]').length;
            const text = readLast();
            if (text) lastText = text;
            if (stop) sawStop = true;

            // A geracao TERMINOU quando: (A) vimos o Stop e ele sumiu; ou
            // (B) fallback -- nunca vimos o Stop (janela perdida) mas surgiu uma
            // toolbar Copy nova. NAO exige texto aqui: se a virtualizacao
            // colapsou a resposta, entramos em recuperacao e insistimos no
            // scroll/re-read ate o texto aparecer e estabilizar.
            const genEnded =
                (sawStop && !stop) ||
                (!sawStop && copy > baseCopy);

            if (genEnded) {
                if (recoverSince === null) recoverSince = Date.now();
                if (text && text === doneText) {
                    // texto estavel por 800ms = frame final -> conclui
                    if (Date.now() - stableSince >= 800) { finish({ ok:true, text }); return; }
                } else {
                    doneText = text; stableSince = Date.now();
                }
                // Recuperacao esgotou (~6s insistindo): devolve o melhor texto
                // que houver; so falha se NADA foi lido a rodada inteira.
                if (Date.now() - recoverSince >= 6000) {
                    if (lastText) finish({ ok:true, text:lastText, partial:true });
                    else finish({ ok:false, error:"Timeout esperando resposta do Copilot.", diag:{ sawStop, mdReply:document.querySelectorAll('[data-testid="markdown-reply"]').length, copy, editorLen:editorLen(), elapsed:Math.round((Date.now()-started)/1000) } });
                    return;
                }
            }

            if (Date.now() - started > timeoutMs) {
                if (lastText) { finish({ ok:true, text:lastText, partial:true }); }
                else { finish({ ok:false, error:"Timeout esperando resposta do Copilot.", diag:{ sawStop, mdReply:document.querySelectorAll('[data-testid="markdown-reply"]').length, copy, editorLen:editorLen(), elapsed:Math.round((Date.now()-started)/1000) } }); }
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
            $d = $poll.diag

            # Assinatura de WebView travado: prompt digitado (editorLen>0) mas a
            # geracao nunca comecou (sawStop=false, copy=0). Sinaliza wedged para
            # o wrapper reiniciar o app e retentar.
            if ($d -and (-not $d.sawStop) -and ([int]$d.copy -eq 0) -and ([int]$d.editorLen -gt 0)) {
                return @{ wedged = $true }
            }

            $msg = [string]$poll.error
            if ($d) {
                $msg += " [diag: sawStop=$($d.sawStop) mdReply=$($d.mdReply) copy=$($d.copy) editorLen=$($d.editorLen) elapsed=$($d.elapsed)s]"
            }
            throw $msg
        }

        return @{ wedged = $false; text = $poll.text }
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

# Permite carregar este arquivo como BIBLIOTECA (dot-source) sem executar nada:
# `$env:COPILOT_LIB=1; . .\copilot-terminal.ps1` expoe as funcoes (Open-CopilotSession,
# Send-CDP, Ask-Copilot, etc.) para outros scripts/diagnostico.
if ($env:COPILOT_LIB -eq '1') { return }

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

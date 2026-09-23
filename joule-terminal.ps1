param(
    [string]$Prompt,
    [string]$PromptFile,
    [switch]$NewThread,
    [int]$TimeoutSec = 120
)

# Saida em UTF-8. Quando o cockpit roda este script via Start-Process
# -RedirectStandardOutput, o stdout e capturado na codepage do console (NAO
# UTF-8) e o cockpit le o arquivo como UTF-8 -> acentos viram "�" (ex.:
# "situa�ao"). Forcar UTF-8 aqui conserta o roundtrip, tanto no modo -PromptFile
# do cockpit quanto no console interativo. Guardado: headless pode nao ter
# console pra setar (best-effort).
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
} catch {}

# Prompt vindo por arquivo (usado pelo cockpit): evita quebrar aspas/acentos/
# quebras de linha ao passar texto natural pela linha de comando.
if (-not [string]::IsNullOrWhiteSpace($PromptFile) -and (Test-Path $PromptFile)) {
    $Prompt = [System.IO.File]::ReadAllText($PromptFile, [Text.Encoding]::UTF8)
}

# ============================================================
# JOULE TERMINAL
# PowerShell -> CDP localhost -> Joule Desktop
# ============================================================

$global:JoulePort = 9222

if (-not (Get-Variable JouleThreadId -Scope Global -ErrorAction SilentlyContinue)) {
    $global:JouleThreadId = $null
}

$global:JouleExe = Join-Path `
    $env:LOCALAPPDATA `
    "Programs\Joule Desktop\Joule Desktop.exe"

$global:JouleStdOut = Join-Path $env:TEMP "joule-terminal-out.log"
$global:JouleStdErr = Join-Path $env:TEMP "joule-terminal-err.log"


# ============================================================
# ENCONTRA O RENDERER DO JOULE
# ============================================================

function Get-JouleTarget {

    try {

        $targets = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$global:JoulePort/json/list" `
            -TimeoutSec 2

        return $targets |
            Where-Object {
                $_.type -eq "page" -and
                (
                    $_.title -like "*Joule*" -or
                    $_.url -like "file:///*"
                )
            } |
            Select-Object -First 1

    }
    catch {
        return $null
    }
}


# ============================================================
# GARANTE QUE JOULE ESTA RODANDO COM CDP LOCAL
# ============================================================

function Start-JouleBridge {

    $target = Get-JouleTarget

    if ($target) {
        return $target
    }


    # Localiza executavel
    if (-not (Test-Path $global:JouleExe)) {

        $running = Get-Process `
            -Name "Joule Desktop" `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($running -and $running.Path) {
            $global:JouleExe = $running.Path
        }
        else {
            throw "Nao encontrei o Joule Desktop."
        }
    }


    # Verifica conflito na porta 9222
    $listener = Get-NetTCPConnection `
        -LocalPort $global:JoulePort `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($listener) {

        $listenerProcess = Get-Process `
            -Id $listener.OwningProcess `
            -ErrorAction SilentlyContinue

        if (
            $listenerProcess -and
            $listenerProcess.ProcessName -notlike "*Joule*"
        ) {
            throw "A porta $global:JoulePort esta sendo usada por outro processo."
        }
    }


    # Se Joule esta aberto mas sem CDP, reinicia
    $runningJoule = Get-Process `
        -Name "Joule Desktop" `
        -ErrorAction SilentlyContinue

    if ($runningJoule) {

        $runningJoule |
            Stop-Process `
                -Force `
                -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2
    }


    # Limpa logs antigos
    Remove-Item `
        $global:JouleStdOut `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        $global:JouleStdErr `
        -Force `
        -ErrorAction SilentlyContinue


    # Abre Joule com debugging somente localhost
    # stdout/stderr vao para arquivos, nao para o terminal
    Start-Process `
        -FilePath $global:JouleExe `
        -ArgumentList @(
            "--remote-debugging-address=127.0.0.1"
            "--remote-debugging-port=$global:JoulePort"
        ) `
        -RedirectStandardOutput $global:JouleStdOut `
        -RedirectStandardError $global:JouleStdErr |
        Out-Null


    # Espera o renderer aparecer
    $deadline = (Get-Date).AddSeconds(30)

    do {

        Start-Sleep -Milliseconds 400

        $target = Get-JouleTarget

        if ($target) {
            return $target
        }

    } while ((Get-Date) -lt $deadline)


    throw "O Joule abriu, mas o renderer nao apareceu."
}


# ============================================================
# EXECUTA JAVASCRIPT NO RENDERER VIA CDP
# ============================================================

function Invoke-JouleCDP {

    param(
        [Parameter(Mandatory)]
        [string]$Expression,

        [int]$TimeoutSec = 135
    )


    $target = Start-JouleBridge

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()

    $cts = [System.Threading.CancellationTokenSource]::new()

    $cts.CancelAfter(
        [TimeSpan]::FromSeconds($TimeoutSec)
    )

    $ct = $cts.Token


    try {

        $ws.ConnectAsync(
            [Uri]$target.webSocketDebuggerUrl,
            $ct
        ).GetAwaiter().GetResult() | Out-Null


        # Anti-throttle (rodada agendada / janela em segundo plano): forca o
        # renderer a "ativo" e com foco emulado ANTES de avaliar, senao o app do
        # Joule pausa o pipeline de chat e o onEvent nunca entrega a resposta.
        # Best-effort: ids fixos < 10000 (nao colidem com o $id aleatorio abaixo);
        # os acks sao ignorados pelo loop de recepcao (msg.id != $id -> continue).
        $prelude = @(
            @{ id = 1; method = "Page.enable"; params = @{} },
            @{ id = 2; method = "Page.setWebLifecycleState"; params = @{ state = "active" } },
            @{ id = 3; method = "Emulation.setFocusEmulationEnabled"; params = @{ enabled = $true } }
        )
        foreach ($cmd in $prelude) {
            try {
                $pbytes = [Text.Encoding]::UTF8.GetBytes(
                    ($cmd | ConvertTo-Json -Compress -Depth 10)
                )
                $ws.SendAsync(
                    [ArraySegment[byte]]::new($pbytes),
                    [System.Net.WebSockets.WebSocketMessageType]::Text,
                    $true,
                    $ct
                ).GetAwaiter().GetResult() | Out-Null
            }
            catch {}
        }


        $id = Get-Random `
            -Minimum 10000 `
            -Maximum 99999


        $request = @{

            id = $id

            method = "Runtime.evaluate"

            params = @{
                expression    = $Expression
                awaitPromise  = $true
                returnByValue = $true
            }

        } | ConvertTo-Json `
            -Compress `
            -Depth 30


        $bytes = [Text.Encoding]::UTF8.GetBytes($request)


        $ws.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $ct
        ).GetAwaiter().GetResult() | Out-Null


        while ($true) {

            $buffer = New-Object byte[] 1048576
            $stream = [IO.MemoryStream]::new()


            do {

                $received = $ws.ReceiveAsync(
                    [ArraySegment[byte]]::new($buffer),
                    $ct
                ).GetAwaiter().GetResult()


                if (
                    $received.MessageType -eq
                    [System.Net.WebSockets.WebSocketMessageType]::Close
                ) {
                    throw "Conexao com o Joule encerrada."
                }


                $stream.Write(
                    $buffer,
                    0,
                    $received.Count
                )

            } while (-not $received.EndOfMessage)


            $raw = [Text.Encoding]::UTF8.GetString(
                $stream.ToArray()
            )


            try {
                $msg = $raw | ConvertFrom-Json
            }
            catch {
                continue
            }


            if ($msg.id -ne $id) {
                continue
            }


            if ($msg.result.exceptionDetails) {

                $description =
                    $msg.result.exceptionDetails.exception.description

                if (-not $description) {
                    $description =
                        $msg.result.exceptionDetails.text
                }

                throw $description
            }


            return $msg.result.result.value
        }

    }
    catch [System.OperationCanceledException] {

        throw "Timeout esperando resposta do Joule."

    }
    finally {

        try {
            $ws.Dispose()
        }
        catch {}

        try {
            $cts.Dispose()
        }
        catch {}
    }
}


# ============================================================
# ENVIA PERGUNTA
# ============================================================

function Ask-Joule {

    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [string]$Model =
            "anthropic--claude-4.6-sonnet",

        [switch]$NewThread,

        [int]$TimeoutSec = 120
    )


    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        $Prompt = Read-Host "Voce"
    }


    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        return
    }


    if ($NewThread) {
        $global:JouleThreadId = $null
    }


    $promptJson =
        $Prompt |
        ConvertTo-Json -Compress


    $modelJson =
        $Model |
        ConvertTo-Json -Compress


    if ($global:JouleThreadId) {

        $threadJson =
            $global:JouleThreadId |
            ConvertTo-Json -Compress

    }
    else {

        $threadJson = "null"
    }


    $timeoutMs = $TimeoutSec * 1000


    $js = @"
(async () => {

    const prompt = $promptJson;
    const model = $modelJson;
    const existingThreadId = $threadJson;


    // Anti-throttle (JS puro, complementa o Emulation.setFocusEmulationEnabled via
    // CDP): finge foco + visivel para o app nao pausar o chat em segundo plano.
    try {
        document.hasFocus = () => true;
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        window.dispatchEvent(new Event("focus"));
        document.dispatchEvent(new Event("visibilitychange"));
    } catch (e) {}


    if (
        !window.api ||
        !window.api.chat ||
        !window.api.chat.send ||
        !window.api.chat.onEvent
    ) {
        return {
            ok: false,
            error: "API de chat do Joule indisponivel."
        };
    }


    return await new Promise(async (resolve) => {

        let finished = false;
        let threadId = existingThreadId || null;
        let unsubscribe = null;
        let keepAlive = null;


        const finish = (value) => {

            if (finished) return;

            finished = true;

            clearTimeout(timer);

            try { clearInterval(keepAlive); } catch {}

            try {
                unsubscribe?.();
            } catch {}

            resolve(value);
        };


        const timer = setTimeout(() => {

            finish({
                ok: false,
                error: "Timeout esperando resposta."
            });

        }, $timeoutMs);


        // Reafirma foco/visibilidade a cada 8s: se a janela re-throttlar durante a
        // geracao longa, mantem o pipeline do Joule entregando eventos.
        keepAlive = setInterval(() => {
            try {
                document.dispatchEvent(new Event("visibilitychange"));
                window.dispatchEvent(new Event("focus"));
            } catch (e) {}
        }, 8000);


        unsubscribe =
            window.api.chat.onEvent((event) => {

                try {

                    const eventThreadId =
                        event?.message?.threadId ||
                        event?.threadId ||
                        null;


                    if (
                        threadId &&
                        eventThreadId &&
                        eventThreadId !== threadId
                    ) {
                        return;
                    }


                    if (event?.type === "error") {

                        finish({

                            ok: false,

                            threadId:
                                eventThreadId ||
                                threadId,

                            error:
                                event?.error ||
                                event?.message ||
                                "Erro retornado pelo Joule."
                        });

                        return;
                    }


                    if (
                        event?.message &&
                        typeof event.message.content === "string" &&
                        event.message.content.trim().length > 0
                    ) {

                        finish({

                            ok: true,

                            threadId:
                                eventThreadId ||
                                threadId,

                            text:
                                event.message.content
                        });
                    }

                    // Nota: o Joule emite eventos "done" INTERMEDIARIOS com
                    // content:"" quando conclui um passo de tool-call (ex.: ler
                    // e-mail/calendario) ANTES da resposta final. Nao podemos
                    // fechar nesses; so fechamos quando chega um done com
                    // content nao-vazio (a resposta de verdade / o array JSON).

                }
                catch (e) {

                    finish({

                        ok: false,

                        threadId:
                            threadId,

                        error:
                            String(
                                e?.message || e
                            )
                    });
                }
            });


        try {

            const payload = {

                threadId:
                    existingThreadId ||
                    undefined,

                content:
                    prompt,

                model:
                    model,

                attachments:
                    []
            };


            const sent =
                await window.api.chat.send(
                    payload
                );


            threadId =
                sent?.threadId ||
                existingThreadId ||
                null;

        }
        catch (e) {

            finish({

                ok: false,

                threadId:
                    threadId,

                error:
                    String(
                        e?.message || e
                    )
            });
        }
    });
})()
"@


    $result = Invoke-JouleCDP `
        -Expression $js `
        -TimeoutSec ($TimeoutSec + 15)


    if (-not $result) {
        throw "Joule nao retornou resultado."
    }


    if (-not $result.ok) {
        throw $result.error
    }


    if ($result.threadId) {
        $global:JouleThreadId = $result.threadId
    }


    return $result.text
}


# ============================================================
# RESETA CONVERSA
# ============================================================

function Reset-JouleThread {

    $global:JouleThreadId = $null
}


# ============================================================
# TERMINAL INTERATIVO
# ============================================================

function Start-JouleTerminal {

    Start-JouleBridge | Out-Null


    Write-Host ""
    Write-Host "Joule"
    Write-Host "-----"
    Write-Host "new  = nova conversa"
    Write-Host "exit = sair"
    Write-Host ""


    while ($true) {

        $question = Read-Host "Voce"


        if ([string]::IsNullOrWhiteSpace($question)) {
            continue
        }


        switch ($question.ToLower()) {

            "exit" {
                return
            }

            "quit" {
                return
            }

            "sair" {
                return
            }

            "new" {

                Reset-JouleThread

                Write-Host ""
                Write-Host "Nova conversa."
                Write-Host ""

                continue
            }
        }


        try {

            $answer = Ask-Joule `
                -Prompt $question

            Write-Host ""
            Write-Host "Joule:"
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


# ============================================================
# EXECUCAO
# ============================================================

if ($NewThread) {
    $global:JouleThreadId = $null
}


if (-not [string]::IsNullOrWhiteSpace($Prompt)) {

    try {

        Start-JouleBridge | Out-Null

        $answer = Ask-Joule `
            -Prompt $Prompt `
            -TimeoutSec $TimeoutSec

        Write-Output $answer

    }
    catch {

        Write-Error $_.Exception.Message
    }

}
else {

    try {

        Start-JouleTerminal

    }
    catch {

        Write-Error $_.Exception.Message
    }
}
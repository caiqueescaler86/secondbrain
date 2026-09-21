# SecondBrain - Microsoft 365 Copilot Terminal Adapter

Este projeto cria uma ponte local entre o PowerShell e o Microsoft 365 Copilot Desktop usando o renderer WebView2 ja autenticado no aplicativo.

O objetivo e permitir chamadas como:

```powershell
copilot "quais sao minhas reunioes de amanha?"
```

sem precisar automatizar mouse ou teclado fisico.

## Arquitetura

```text
PowerShell
   |
   v
copilot-terminal.ps1
   |
   v
CDP em 127.0.0.1:9223
   |
   v
Microsoft 365 Copilot WebView2
   |
   v
Renderer autenticado do Copilot
```

O adapter usa o Chrome DevTools Protocol apenas no loopback local (`127.0.0.1`).

Ele:

1. Garante que o WebView2 do `M365Copilot.exe` seja iniciado com CDP local na porta `9223`.
2. Descobre dinamicamente os targets do Copilot e escolhe o renderer que realmente tem o editor.
3. Ignora targets antigos/stale.
4. Da foco no editor `Message Copilot` com um clique REAL de mouse via CDP (`Input.dispatchMouseEvent`).
5. Digita o prompt com `Input.insertText` (entrada confiavel) e envia com `Enter` (`Input.dispatchKeyEvent`).
6. Espera uma nova resposta em `data-testid="markdown-reply"`.
7. Retorna somente o texto da resposta ao PowerShell.

> **Por que clique/teclado via CDP e nao JavaScript?** O editor do Copilot (Fluent UI / React) ignora eventos sinteticos (`.focus()`, `execCommand`, `.click()`, `dispatchEvent`). O botao `Send` so aparece quando o editor tem conteudo de verdade. So input CONFIAVEL via CDP (`Input.dispatchMouseEvent` / `Input.insertText` / `Input.dispatchKeyEvent`) registra o texto e dispara o envio.

## Arquivos

```text
SecondBrain/
|-- copilot-terminal.ps1      # adapter Copilot (CDP :9223)
|-- whatsapp-collector.ps1    # coletor WhatsApp Web -> JSONL local (BiDi :9224)
|-- analyze-whatsapp.ps1      # analise das conversas via LLM local (llama.cpp)
|-- README.md
|-- joule-terminal.ps1        # adapter Joule existente
```

Sugestao de pasta:

```text
C:\Users\I827769\Documents\Joule\SecondBrain
```

## Instalacao

Salve `copilot-terminal.ps1` em:

```text
C:\Users\I827769\Documents\Joule\SecondBrain\copilot-terminal.ps1
```

O script configura automaticamente este registro para o usuario atual:

```text
HKCU\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments
```

com uma entrada especifica para:

```text
M365Copilot.exe
```

usando:

```text
--remote-debugging-address=127.0.0.1 --remote-debugging-port=9223
```

A porta permanece restrita ao computador local.

## Teste rapido

Execute:

```powershell
& "C:\Users\I827769\Documents\Joule\SecondBrain\copilot-terminal.ps1" `
    -Prompt "Responda apenas COPILOT POWERSHELL OK"
```

Resultado esperado:

```text
COPILOT POWERSHELL OK
```

## Criar o comando global `copilot`

Abra seu profile:

```powershell
notepad $PROFILE
```

Adicione:

```powershell
function copilot {

    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Prompt
    )

    $script =
        "C:\Users\I827769\Documents\Joule\SecondBrain\copilot-terminal.ps1"

    if ($Prompt.Count -gt 0) {

        & $script `
            -Prompt ($Prompt -join " ")
    }
    else {

        & $script
    }
}
```

Recarregue o profile:

```powershell
. $PROFILE
```

## Uso

Pergunta direta:

```powershell
copilot "quais sao minhas reunioes de amanha?"
```

Modo interativo:

```powershell
copilot
```

Para sair do modo interativo:

```text
exit
```

ou:

```text
sair
```

## Diagnostico

Verifique se o CDP esta ativo:

```powershell
curl.exe http://127.0.0.1:9223/json/version
```

Liste os targets:

```powershell
curl.exe http://127.0.0.1:9223/json/list
```

Verifique o listener:

```powershell
Get-NetTCPConnection -LocalPort 9223 -State Listen |
    Select-Object LocalAddress, LocalPort, OwningProcess
```

O endereco esperado e:

```text
127.0.0.1:9223
```

## Como a resposta e localizada

Durante os testes, o renderer do Copilot apresentou containers estaveis como:

```text
data-testid="markdown-reply"
```

com um identificador de mensagem em:

```text
data-message-id
```

O adapter registra os IDs existentes antes de enviar a pergunta e aguarda um novo `markdown-reply`.

Isso evita simplesmente devolver uma resposta antiga que ja estava visivel na conversa.

## Targets stale

O WebView2 pode manter mais de um target do Microsoft Copilot disponivel no endpoint CDP.

Por isso o adapter nao depende de IDs fixos como:

```text
F4E67F82...
```

Ele enumera os targets e tenta cada WebSocket ate encontrar um renderer ativo.

## Timeout

O timeout padrao para uma resposta e 120 segundos.

Exemplo usando a funcao diretamente:

```powershell
Ask-Copilot `
    -Prompt "analise meus compromissos" `
    -TimeoutSec 180
```

## Joule + Copilot

A estrutura planejada do SecondBrain fica assim:

```text
                 brain
                   |
          +--------+--------+
          |                 |
        Joule             Copilot
          |                 |
 joule-terminal.ps1   copilot-terminal.ps1
          |                 |
        CDP               CDP
       :9222             :9223
```

Uso esperado:

```powershell
joule "quem preciso responder por email?"

copilot "prepare minhas reunioes de amanha"
```

A proxima camada pode ser um `brain.ps1` que decide automaticamente qual adapter consultar e combina as respostas.

## Integracao WhatsApp (coletor local)

O `whatsapp-collector.ps1` captura o historico das suas conversas do WhatsApp Web para uma base **local** em JSONL. Serve de materia-prima para definir pendencias e responsaveis ("quem esta pendente comigo").

### Como funciona

```text
PowerShell
   |
   v
whatsapp-collector.ps1
   |
   v
WebDriver BiDi em ws://127.0.0.1:9224
   |
   v
Firefox (perfil autenticado) -> WhatsApp Web
   |
   v
whatsapp-messages.jsonl (append-only, local)
```

1. Reinicia o Firefox com o perfil autenticado e o WebDriver BiDi ligado em `127.0.0.1:9224`.
2. Percorre a lista de chats (sidebar) e abre cada conversa com um **clique confiavel** via `input.performActions` — o WhatsApp ignora `.click()` sintetico e so abre o chat com pointer real.
3. Sobe o historico ate a data de corte (padrao: ultimos 90 dias na primeira execucao).
4. Extrai por mensagem: texto, autor/responsavel (do `data-pre-plain-text`), timestamp e direcao (por alinhamento da bolha).
5. Deduplica por SHA256 e grava em `whatsapp-messages.jsonl`.

Nas execucoes seguintes usa `lastSuccessfulRun - OverlapHours` como janela incremental. **Nao envia nada para Joule/Copilot — tudo fica local.**

### Onde os dados ficam

```text
%USERPROFILE%\Documents\Joule\SecondBrain\WhatsApp\
|-- whatsapp-messages.jsonl   # base append-only (uma mensagem por linha)
|-- whatsapp-state.json       # estado do sincronismo incremental
|-- whatsapp-run-<data>.json  # resumo de cada execucao
```

Cada linha do JSONL:

```json
{"id":"<sha256>","chat":"Nome do chat","timestamp":"2026-09-12T14:03:00.000+00:00","author":"Fulano","meta":"[14:03, 12/09/2026] Fulano:","direction":"in","text":"...","capturedAt":"2026-09-20T09:00:00.000-03:00"}
```

`direction` = `in` (recebida) / `out` (enviada) / `""` (indefinida). `author`/`meta` ficam vazios em mensagens de servico/broadcast sem `data-pre-plain-text`.

### Uso

```powershell
# Carga historica completa (recomeca do zero, mantendo o JSONL)
& "C:\Users\I827769\Documents\Joule\SecondBrain\whatsapp-collector.ps1" -BootstrapDays 90 -ResetState

# Sincronizacao incremental (dia a dia)
& "C:\Users\I827769\Documents\Joule\SecondBrain\whatsapp-collector.ps1"
```

Parametros: `-Port 9224`, `-BootstrapDays 90`, `-OverlapHours 24`, `-MaxChats 500`, `-MaxScrollsPerChat 120`, `-ResetState` (faz backup do state e recomeca o historico; o `whatsapp-messages.jsonl` e preservado, dedup por SHA256).

> **Atencao:** rodar o coletor **encerra e reabre o seu Firefox** (para subir o perfil com o BiDi ligado). Feche trabalhos importantes antes.

## Analise das conversas com LLM local

O `analyze-whatsapp.ps1` le o JSONL (filtrado pelos ultimos N dias), monta o contexto e pergunta a uma LLM **local** (servidor `llama.cpp`, endpoint compativel com OpenAI) para gerar, por exemplo, sua lista de pendencias e quem esta pendente com voce.

```powershell
# Pendencias dos ultimos 8 dias
& "C:\Users\I827769\Documents\Joule\SecondBrain\analyze-whatsapp.ps1" -Days 8

# Pergunta personalizada
& "C:\Users\I827769\Documents\Joule\SecondBrain\analyze-whatsapp.ps1" -Days 8 `
    -Question "Liste as decisoes tomadas e prazos combinados por chat."
```

Parametros: `-Days 8`, `-Endpoint http://127.0.0.1:19001`, `-Model` (auto-detectado), `-MaxChars 60000`, `-Question`, `-OnlyChat "Nome"`, `-Save` (grava o resultado em `WhatsApp\analysis-<data>.md`).

> **Seguranca (LLM local):** seu servidor `llama.cpp` esta escutando em `0.0.0.0:19001` com CORS `*` e sem API key — ou seja, exposto a qualquer maquina da rede. O `analyze-whatsapp.ps1` fala apenas com `127.0.0.1:19001`. Recomendado: subir o `llama-server` com `--host 127.0.0.1` (loopback) para nao expor o modelo — as suas conversas do WhatsApp vao no prompt.

## Seguranca

Este adapter nao desativa autenticacao, politicas corporativas, telemetria ou protecoes do endpoint.

Ele reutiliza a sessao ja autenticada pelo Microsoft 365 Copilot e mantem o endpoint de debugging restrito a:

```text
127.0.0.1
```

Nao altere para:

```text
0.0.0.0
```

pois isso poderia expor o endpoint de debugging para outras maquinas da rede.

## Observacoes

O Copilot e uma aplicacao atualizada continuamente. Alteracoes futuras no DOM podem exigir atualizar seletores como:

```text
[aria-label="Message Copilot"]
[data-testid="markdown-reply"]
```

O adapter evita classes CSS geradas automaticamente sempre que possivel, pois essas classes tendem a mudar entre builds.

---

SecondBrain - adapter local para Microsoft 365 Copilot Desktop.

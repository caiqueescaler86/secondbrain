 Joule Terminal — Windows

Interface de terminal para usar o Joule Desktop diretamente pelo PowerShell.

O projeto reutiliza a sessão autenticada já existente no Joule Desktop e se conecta ao renderer do aplicativo via Chrome DevTools Protocol (CDP), sem automação de mouse, teclado ou interface gráfica.

---

## Objetivo

Permitir executar o Joule de qualquer diretório no PowerShell:

```powershell
joule

ou enviar uma pergunta diretamente:

joule "quais sao minhas reunioes de amanha?"
Arquitetura
PowerShell
   ↓
joule-terminal.ps1
   ↓
CDP
127.0.0.1:9222
   ↓
Joule Desktop Renderer
   ↓
window.api.chat.send()
   ↓
Electron IPC
   ↓
Joule Chat Service
   ↓
AI Core + Tools + MCPs
   ↓
Resposta
   ↓
PowerShell

O script não chama diretamente o backend do Joule.

Ele usa o próprio cliente Joule Desktop já autenticado.

Arquivo

O script principal está salvo em:

C:\Users\I827769\Documents\Joule\SecondBrain\joule-terminal.ps1
Requisitos
Windows
PowerShell
Joule Desktop instalado
Sessão válida no Joule Desktop
Acesso às ferramentas que o usuário normalmente possui no Joule
Porta local 9222 disponível
Uso
Modo interativo

Execute:

joule

Resultado:

Joule
-----
new  = nova conversa
exit = sair

Voce: quais sao minhas reunioes de amanha?

Joule:

Amanha voce tem...

Nesse modo, as perguntas são digitadas dentro do terminal do Joule e não como comandos separados do PowerShell.

Pergunta direta
joule "quem eu preciso responder por email?"

A resposta será impressa diretamente no terminal.

Nova conversa
joule -New

Também é possível iniciar uma nova conversa já com uma pergunta:

joule -New "analise meus emails de hoje"

No modo interativo:

new

reseta a thread atual.

Sair

No modo interativo:

exit

Também são aceitos:

quit
sair
Funcionamento
1. Descoberta do Joule

O script tenta acessar:

http://127.0.0.1:9222/json/list

e localizar dinamicamente o renderer do Joule.

Não existe dependência de:

PID fixo
WebSocket fixo
IP externo
endereço do gateway
ID fixo do renderer
2. Inicialização automática

Se o Joule já estiver rodando com CDP ativo, o script apenas reutiliza a instância.

Se o Joule estiver fechado, ele é iniciado automaticamente com:

--remote-debugging-address=127.0.0.1
--remote-debugging-port=9222

Se estiver aberto sem CDP, o script reinicia o Joule com os parâmetros necessários.

Segurança da porta

O debugging fica restrito a:

127.0.0.1:9222

Ou seja, a interface CDP fica acessível somente pela própria máquina.

Não deve ser alterada para:

0.0.0.0

nem exposta diretamente na rede.

Envio de mensagens

O script executa JavaScript dentro do renderer do Joule e utiliza:

window.api.chat.send()

O evento de resposta é recebido através de:

window.api.chat.onEvent()

Assim, a requisição segue pelo fluxo normal do Joule Desktop.

Contexto de conversa

Durante uma sessão, o script mantém o threadId retornado pelo Joule.

Isso permite:

Voce: quem tenho de reuniao amanha?

Joule:
Voce tem 4 reunioes...

Voce: qual delas devo preparar primeiro?

Joule:
...

A segunda pergunta continua usando o contexto da primeira.

Para resetar:

new

ou:

joule -New
Capacidades

O terminal utiliza as mesmas capacidades disponíveis para o usuário no Joule Desktop.

Dependendo da configuração da conta e da sessão, isso pode incluir:

Email
Calendário
AI Core
MCPs
Knowledge sources
Ferramentas internas
Guardrails
Skills disponíveis no Joule

O terminal não concede permissões adicionais.

Ele apenas utiliza as permissões já existentes no Joule Desktop.

Logs

Os logs técnicos do processo do Joule são retirados da tela do PowerShell.

Eles são redirecionados para:

%TEMP%\joule-terminal-out.log

e:

%TEMP%\joule-terminal-err.log

Isso mantém a interface do terminal limpa.

Observabilidade

O script não desativa nem contorna a observabilidade normal do Joule.

As chamadas continuam passando pelos mecanismos normais da aplicação, incluindo:

autenticação
AI Core
consumo
guardrails
tools
MCPs
telemetry
traces

O objetivo do CDP é somente fornecer uma interface local alternativa para o cliente Joule Desktop.

Comando global do PowerShell

O comando joule é registrado no $PROFILE do PowerShell.

Exemplo:

function joule {

    param(
        [switch]$New,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Prompt
    )

    $script = "C:\Users\I827769\Documents\Joule\SecondBrain\joule-terminal.ps1"

    if ($Prompt.Count -gt 0) {

        & $script `
            -Prompt ($Prompt -join " ") `
            -NewThread:$New

    }
    else {

        & $script `
            -NewThread:$New
    }
}

Isso permite executar:

joule

de qualquer diretório.

Exemplos
Reuniões
Voce: quais sao minhas reunioes de amanha?
Email
Voce: quem eu preciso responder por email?
Follow-ups
Voce: quem esta esperando uma resposta minha?
Preparação do dia
Voce: analise minhas reunioes e emails e me diga o que preciso priorizar hoje
Contexto
Voce: quais reunioes tenho amanha?

Joule:
...

Voce: me prepare para a segunda
Troubleshooting
Porta 9222 ocupada

Verifique:

Get-NetTCPConnection -LocalPort 9222
Joule não responde

Confirme que o Joule Desktop está autenticado normalmente.

Também é possível verificar os logs:

Get-Content "$env:TEMP\joule-terminal-out.log" -Tail 50

ou:

Get-Content "$env:TEMP\joule-terminal-err.log" -Tail 50
Verificar CDP

Abra:

http://127.0.0.1:9222/json/list

Se o Joule estiver corretamente iniciado, deve existir um renderer disponível.

Limitações

O funcionamento depende da implementação interna atual do Joule Desktop.

Uma atualização do aplicativo pode alterar:

window.api.chat.send

ou:

window.api.chat.onEvent

e exigir atualização do bridge.

O modelo padrão utilizado atualmente é:

anthropic--claude-4.6-sonnet

Esse identificador também pode mudar no futuro.

Resumo
joule

transforma o Joule Desktop em uma interface de terminal local:

PowerShell → Joule Desktop → AI Core / Tools → PowerShell

mantendo a autenticação, permissões e capacidades já existentes no cliente Joule.
# SecondBrain — Guia de Setup e Operação (do zero)

Guia completo para instalar, configurar e operar o **SecondBrain** numa máquina
Windows 11 Enterprise gerenciada por GPO, sem conhecimento prévio do projeto.

> As afirmações abaixo vêm da leitura dos scripts do repositório e foram
> **verificadas na máquina em uso** (funções do `$PROFILE`, tarefa agendada, atalhos
> de logon, perfil do Firefox — ver o Apêndice no fim). O único ponto que depende do
> ambiente e não é observável no código é a ACE Deny do `whisper-cli.exe` dentro do
> Claude, sinalizada onde aparece.

---

## 1. Visão geral

O SecondBrain é um sistema **local-first** de produtividade para um CSM (Customer
Success Manager) da SAP. Ele coleta pendências de vários canais, **consolida tudo
de forma determinística em PowerShell** (sem uma segunda LLM decidindo nada) num
"banco" local (`processed\tasks.json`) e exibe uma **lista única priorizada** num
**cockpit web local** (`http://127.0.0.1:8787`). Nada sai para a nuvem além das
chamadas naturais dos apps Joule e Microsoft 365 Copilot; a análise pesada roda
num **LLM local** (llama.cpp / modelo Qwen) e a transcrição de áudio roda num
**whisper.cpp local** — tudo em CPU, na própria máquina.

Diretório raiz do projeto:

```
C:\Users\I827769\Documents\Joule\SecondBrain
```

### Arquitetura (canais → cockpit)

```
  ┌────────────────────────────────────────────────────────────────┐
  │                         CANAIS (coleta)                          │
  ├──────────────┬──────────────┬───────────────┬───────────────────┤
  │  Joule       │  Copilot     │  WhatsApp      │  Meetings         │
  │  (e-mail +   │  (Teams +    │  (mensagens +  │  (reuniões        │
  │  calendário) │  transcr. +  │  notas de voz) │  gravadas/        │
  │              │  e-mail)     │                │  transcritas)     │
  │  CDP :9222   │  CDP :9223   │  BiDi :9224    │  arquivos locais  │
  │  Joule       │  M365        │  Firefox +     │  Meetings\*.json  │
  │  Desktop     │  Copilot     │  WhatsApp Web  │  (whisper)        │
  └──────┬───────┴──────┬───────┴───────┬────────┴─────────┬─────────┘
         │              │               │                  │
         │        LLM local (llama-server :19001, Qwen) usado por
         │        WhatsApp e Meetings para gerar itens em JSON
         │              │               │                  │
         └──────────────┴───────┬───────┴──────────────────┘
                                 ▼
                  secondbrain-run.ps1 (ORQUESTRADOR — entrada única)
                   • coleta cada canal isolado por try/catch
                   • consolida (normaliza, SB-ID, dedup, prioriza,
                     categoriza, define prazo)
                   • faz merge no store preservando o que você mexeu
                   • roll-over de vencidas → hoje
                                 ▼
                     processed\tasks.json  (o "banco" local)
                                 ▼
                   cockpit.ps1  →  http://127.0.0.1:8787  (SPA local)
```

---

## 2. Pré-requisitos

| Item | Para que serve | Observação |
|---|---|---|
| **Windows 11** (Enterprise, gerenciado por GPO) | Sistema operacional | Task Scheduler pode estar bloqueado por GPO; há fallbacks. |
| **PowerShell 5.1** (Windows PowerShell) | Roda todos os `.ps1` | Os scripts usam `.NET Framework`/COM/`Add-Type` compatíveis com 5.1. |
| **Joule Desktop** | Canal Joule (e-mail/calendário) | Esperado em `%LOCALAPPDATA%\Programs\Joule Desktop\Joule Desktop.exe`. Falado via **CDP em 127.0.0.1:9222**. |
| **Microsoft 365 Copilot (Desktop)** | Canal Copilot (Teams/transcrições/e-mail) | App `M365Copilot.exe` (via `Microsoft.MicrosoftOfficeHub`). Falado via **CDP em 127.0.0.1:9223**. Usa WebView2. |
| **WebView2 Runtime** | Renderer usado por Joule e Copilot | Já vem com os apps. As portas CDP são injetadas via argumentos/registro. |
| **Mozilla Firefox** | Canal WhatsApp | Esperado em `C:\Program Files\Mozilla Firefox\firefox.exe`, perfil `...\Firefox\Profiles\qyl4c5lr.default-release` (fixo no `whatsapp-collector.ps1`; confirmado nesta máquina). Usa **WebDriver BiDi em 127.0.0.1:9224** contra WhatsApp Web. |
| **llama.cpp (llama-server.exe)** | LLM local (WhatsApp local + Meetings) | Esperado em `C:\llama-cpu\` com um `launcher.bat`. Escuta em **0.0.0.0:19001** (ver §7). |
| **Modelo GGUF (Qwen3-Coder-30B-A3B-Instruct, Q4_K_M)** | Pesos do LLM local | Caminho padrão em `C:\Users\I827769\.cache\huggingface\hub\models--PaoloOrange--Qwen3-Coder-30B-A3B-Instruct-Q4_K_M-GGUF\...\qwen3-coder-30b-a3b-instruct-q4_k_m.gguf`. |
| **whisper.cpp (whisper-cli.exe) + modelo ggml-medium.bin** | Transcrição local (áudios do WhatsApp e reuniões) | Instalados em `C:\whisper\` e `C:\whisper\models\` pelo `setup-whisper.ps1`. |
| **ffmpeg** | Transcodifica/mixa áudio antes do whisper | `winget install Gyan.FFmpeg` (o setup também acha em WinGet Packages). |
| **NAudio.dll (1.10.0)** | Captura de áudio das reuniões (sistema + microfone) | Baixada pelo `setup-meeting.ps1` para `lib\NAudio.dll` (sem admin). Sem ela, gravação só-microfone. |
| **Outlook (COM)** | (Opcional) detectar reunião pelo calendário | Best-effort; se GPO bloquear o COM, o vigia de reuniões usa só o uso do microfone. |

> **Atenção — whisper bloqueado dentro do Claude:** o executável `whisper-cli.exe`
> tem uma ACE **Deny** no seu usuário quando invocado **de dentro do Claude**.
> Rode os passos que usam whisper (transcrição) a partir do **terminal do usuário**,
> não de dentro do Claude. (Origem: memória de operação; **confirmar** ACE na sua máquina.)

---

## 3. Instalação passo a passo

1. **Coloque o repositório** em `C:\Users\I827769\Documents\Joule\SecondBrain`
   (é o caminho que praticamente todos os scripts assumem).

2. **Instale os apps desktop** e faça login uma vez em cada um (deixe as sessões
   autenticadas): **Joule Desktop**, **Microsoft 365 Copilot**, **Firefox + WhatsApp Web**.

3. **Suba/instale o LLM local** (llama-server + modelo GGUF) em `C:\llama-cpu\`
   com um `launcher.bat`. Detalhes de execução em §7.

4. **Instale o whisper** (uma vez):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\setup-whisper.ps1"
   ```
   Baixa o binário Windows x64 do whisper.cpp para `C:\whisper\` e o modelo
   `ggml-medium.bin` (~1,5 GB) para `C:\whisper\models\`, e valida que roda.
   Se o download corporativo bloquear, o script imprime instruções manuais.

5. **Instale o ffmpeg**:
   ```powershell
   winget install Gyan.FFmpeg
   ```

6. **Setup de reuniões** (uma vez) — baixa a NAudio, valida dependências e cria o
   auto-start do vigia:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\setup-meeting.ps1"
   ```

7. **Setup de voz** (uma vez, opcional) — cria o ambiente Python isolado, instala as
   libs, resolve o whisper e cria o auto-start do listener:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\setup-voice.ps1"
   ```
   Depois, os gatilhos são **Ctrl+Shift+B** e a wake word **"hey secondbrain"** (modelo
   custom treinado em Kaggle, já em `voice\models\hey_secondbrain.onnx`). O listener
   roda **no seu processo** (por isso o whisper não esbarra na ACE Deny). Veja §9.1.

8. **Crie os comandos do dia a dia** no seu `$PROFILE` (§6) e **recarregue**:
   ```powershell
   . $PROFILE
   ```

9. **(Opcional) Agende a rodada diária** (§8).

---

## 4. O orquestrador `secondbrain-run.ps1` (entrada única)

É o coração do sistema. Roda a rodada inteira e é o que os comandos `sb` /
`secondbrain` chamam.

### Parâmetros

| Switch/parâmetro | Efeito |
|---|---|
| `-OpenCockpit` | Ao final, sobe o cockpit (se não estiver no ar) e abre o navegador. |
| `-InitialLoad` | Carga inicial com janelas largas: e-mail 14d, Teams 7d, WhatsApp 90d, reuniões 7 dias à frente. Sem ele: e-mail 3d, Teams 24h, WhatsApp 2d, reuniões 1 dia. |
| `-DryRun` | Roda tudo mas **não grava** no store (só gera o snapshot `consolidated-<ts>.json` e o log). |
| `-SkipJoule`, `-SkipCopilot`, `-SkipWhatsApp`, `-SkipMeetings`, `-SkipCockpit` | Pula o canal/etapa correspondente. |
| `-SkipAudio` | Roda o WhatsApp mas **sem** extrair/transcrever notas de voz (só texto). |
| `-WhatsAppEngine local`\|`joule` | Motor de análise do WhatsApp. **Padrão: `local`** (nada do zap sai da máquina). `joule` manda o conteúdo para o Joule (nuvem SAP). |
| `-Port 8787` | Porta do cockpit (troque se der "Access denied"). |
| `-Date 2026-09-20` | Força a data-base da rodada. |

### Fluxo de execução (ordem real)

1. **Preflight** — confere e, se preciso, **abre sozinho** os apps dos canais e loga
   o estado (nunca silencioso). Best-effort e não-fatal:
   - **Joule** (`:9222`): se fechado, abre `Joule Desktop.exe` com
     `--remote-debugging-address=127.0.0.1 --remote-debugging-port=9222` e espera a
     porta até 45s.
   - **Firefox/WhatsApp** (`:9224`): se fechado, abre o Firefox com o perfil
     autenticado, `--remote-debugging-port=9224` em `https://web.whatsapp.com/`.
   - **Copilot** (`:9223`): **não** é aberto aqui de propósito (o próprio adapter
     mata e relança o app para conseguir a porta de debug); só loga o estado.
2. **Canal Joule** — usa `prompts\joule.md` (substitui `{{JANELA}}`), chama
   `joule-terminal.ps1` (timeout 240s), com retry curto se o Joule der "soluço de
   governança". Salva a saída crua em `raw\joule-<ts>.txt`.
3. **Canal Copilot** — usa `prompts\copilot.md`, chama `copilot-terminal.ps1`
   (timeout 360s). Salva `raw\copilot-<ts>.txt`.
4. **Canal WhatsApp** — se `-WhatsAppEngine local`, primeiro **garante o
   llama-server no ar** (chama `start-llama.ps1`, espera a porta até 90s). Depois:
   `whatsapp-collector.ps1` (coleta) → `whatsapp-audio.ps1` (extrai notas de voz,
   a menos de `-SkipAudio`) → `whatsapp-transcribe.ps1` (whisper) →
   `analyze-whatsapp.ps1 -Json -Engine <engine>` (análise). Salva `raw\whatsapp-<ts>.json`.
5. **Canal Meetings** — `meeting-detector.ps1 -Ahead <n> -Json` lê as transcrições
   locais de reunião e gera cards. Salva `raw\meetings-<ts>.json`.
6. **Consolidação determinística** — normaliza texto, calcula o **SB-ID**
   (`sb-` + SHA256 de `pessoa|assunto`, **sem** status — para o card não virar
   órfão quando muda de situação), deduplica, mantém a maior prioridade e o menor
   prazo, categoriza e define o `dueDate`. Salva `processed\consolidated-<ts>.json`.
7. **Merge no store** (`processed\tasks.json`) — atualiza o conteúdo mas
   **preserva o que você mexeu no cockpit** (concluído/adiado/notas/prioridade
   ajustada à mão via `userTouched`). Funde duplicatas antigas por identidade nova.
8. **Roll-over** — vencidas e abertas → `dueDate = hoje`; recalcula o "board"
   (visibilidade) de todo o store.
9. **Grava o store** (a menos de `-DryRun`) e imprime um **sumário** por canal +
   contadores (novas/atualizadas/roladas/revisão).
10. **Cockpit** — com `-OpenCockpit`, sobe (se preciso) e abre o navegador.

### O que gera / onde fica

```
SecondBrain\
├─ processed\tasks.json              ← o "banco" (store vivo)
├─ processed\consolidated-<ts>.json  ← delta incremental (novos/alterados desde o último run)
├─ processed\consolidated-<ts>.full.json ← cópia completa de auditoria
├─ processed\last-run.json           ← timestamp do último run bem-sucedido
├─ processed\initial-review.json     ← itens baixa/referência da carga inicial
├─ raw\<canal>-<ts>.txt|.json        ← saída crua de cada canal
└─ logs\run-<ts>.log                 ← log da rodada
```

> **Snapshots incrementais:** a partir do segundo run, `consolidated-<ts>.json` traz
> **só o delta** — itens novos ou cujo conteúdo semântico mudou desde a última rodada.
> O `last-run.json` também controla a **janela de busca dinâmica**: se o sistema ficou
> parado (máquina desligada, férias), a próxima rodada detecta o gap e expande
> automaticamente a janela enviada ao Joule/Copilot (ex.: 5 dias parado → busca 5 dias,
> não só 24h). Tetos: Joule 14 dias, Copilot 72h, WhatsApp 14 dias.

---

## 5. O cockpit (`cockpit.ps1` + pasta `cockpit\`)

Servidor **HttpListener** em `http://127.0.0.1:<Port>/` (padrão `8787`), 100%
loopback, servindo a SPA (`cockpit\index.html`, `app.js`, `style.css`) e uma
mini-API sobre `processed\tasks.json`. Leitura/escrita com lock e escrita atômica
(grava em `.tmp` e move por cima). **UTF-8 sem BOM** para não quebrar parsers.

Subir na mão:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\cockpit.ps1" -Port 8787
# -Open abre o navegador automaticamente
```

Parar: **Ctrl+C** na janela onde ele roda (usa `GetContextAsync` + `WaitOne(300ms)`
justamente para o Ctrl+C funcionar).

### Endpoints da API

| Método + rota | O que faz |
|---|---|
| `GET /api/tasks` | Lê o store, aplica roll-over de vencidas → hoje, devolve o array. |
| `POST /api/task` | Cria tarefa manual (botão "＋ Nova"). Body JSON: `assunto` (obrigatório), `pessoa`, `status`, `prioridade`, `proxima_acao`, `notas`, `resumo`, `dueDate`. Gera o mesmo SB-ID (pessoa+assunto), então sobrevive ao merge do orquestrador. Retorna 409 se já existir. |
| `POST /api/task/{sbid}` | Atualiza uma tarefa. Campos permitidos: `done`, `snoozedUntil`, `prioridade`, `notas`, `status`, `dueDate`. Marca `userTouched` (o orquestrador preserva). |
| `POST /api/joule` | Dispara o Joule de forma **assíncrona** (processo separado; devolve `{id}` na hora). Injeta o caminho de `tasks.json` como referência. |
| `GET /api/joule/{id}` | Faz poll do job do Joule (`pending`/`done`/`error`). Guarda-chuva de ~210s. |
| `GET /<arquivo>` | Serve estáticos de `cockpit\` (com proteção contra path traversal). |

> **Reinício para pegar tarefa manual:** ao criar uma tarefa nova, reinicie o
> cockpit para ela aparecer de forma consistente (origem: memória de operação;
> comportamento observado).

### Dentro do cockpit (uso)
- Lista única priorizada ("O que importa agora" no topo). **Status é só etiqueta**
  colorida (Responder / Fazer / Cobrar / Preparar / Risco), não decide visibilidade.
- "Aguardando os outros" e "Referência / baixa" ficam em seções recolhíveis.
- Clique no card → expande resumo/risco/notas/botões. **Feito**, **Adiar**,
  **↑↓ Prio**, **Notas** (salva ao sair do campo).
- Recarrega sozinho a cada 1 min; `⟳` recarrega na hora. Suas ações são preservadas
  na próxima rodada. Cards **criados na última rodada e ainda não abertos** aparecem com
  um badge **"novo"** e realce verde — abrir o card quita o destaque. Há uma **caixinha "Agente"**
  cujo alvo padrão é o **Joule** (assíncrono, lê `tasks.json`).

**Demo visual** (`cockpit-demo.ps1`): `cockpitdemo` semeia 9 tarefas de exemplo e
abre o cockpit; `cockpitdemo -Reset` limpa o store (volta a `[]`).

---

## 6. Comandos do dia a dia (funções no `$PROFILE`)

Estes comandos ficam no **`$PROFILE`** do PowerShell do usuário (funcionam de
qualquer pasta). Os corpos abaixo são os que estão **de fato no `$PROFILE` desta
máquina** (`C:\Users\I827769\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`),
verificados. Todas as funções resolvem os scripts a partir de
`$global:SecondBrainDir = "C:\Users\I827769\Documents\Joule\SecondBrain"`.

Abra o profile e edite:
```powershell
notepad $PROFILE
# depois de salvar:
. $PROFILE
```

| Comando | O que faz | Como está definido |
|---|---|---|
| `secondbrain` / `sb` | Roda a rodada inteira (orquestrador). Ex.: `sb -OpenCockpit`. | `function secondbrain { & (Join-Path $SecondBrainDir "secondbrain-run.ps1") @args }` + `Set-Alias sb secondbrain`. |
| `cockpit` | Só abre o cockpit com o que já foi coletado (não roda os canais). | `function cockpit { & (Join-Path $SecondBrainDir "cockpit.ps1") -Open @args }` (sempre com `-Open`). |
| `cockpitdemo` | Semeia dados de exemplo e abre o cockpit. | `function cockpitdemo { & (Join-Path $SecondBrainDir "cockpit-demo.ps1") @args }`. |
| `joule` | Fala com o Joule Desktop via CDP :9222. Ex.: `joule "quem preciso responder por email?"` / `joule -New ...`. | Função com `-New` (switch → `-NewThread`) e `$Prompt` restante → `joule-terminal.ps1`. |
| `copilot` | Fala com o M365 Copilot via CDP :9223. Ex.: `copilot "minhas reuniões de amanhã"`. | Função com `$Prompt` restante → `copilot-terminal.ps1`. |
| `teams` | Roda **só o canal Copilot** (Teams + transcrições + e-mail): `secondbrain-run.ps1 -SkipJoule -SkipWhatsApp -SkipMeetings`. Precisa do Copilot Desktop aberto. Ex.: `teams -OpenCockpit`. | `function teams { & (Join-Path $SecondBrainDir "secondbrain-run.ps1") -SkipJoule -SkipWhatsApp -SkipMeetings @args }`. |
| `whisper-setup` | Instala o whisper (uma vez). | `function whisper-setup { & (Join-Path $SecondBrainDir "setup-whisper.ps1") @args }`. |
| `whatsapp-transcreve` | Transcreve os áudios em `WhatsApp\audio-inbox\`. | `function whatsapp-transcreve { & (Join-Path $SecondBrainDir "whatsapp-transcribe.ps1") @args }`. |

Corpo real do `copilot` (do `$PROFILE`):
```powershell
function copilot {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Prompt)
    $script = Join-Path $global:SecondBrainDir "copilot-terminal.ps1"
    if ($Prompt.Count -gt 0) { & $script -Prompt ($Prompt -join " ") } else { & $script }
}
```

Corpo real do `joule` (do `$PROFILE`):
```powershell
function joule {
    param([switch]$New, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Prompt)
    $script = "C:\Users\I827769\Documents\Joule\SecondBrain\joule-terminal.ps1"
    if ($Prompt.Count -gt 0) { & $script -Prompt ($Prompt -join " ") -NewThread:$New }
    else { & $script -NewThread:$New }
}
```

---

## 7. LLM local — `start-llama.ps1` (auto-start no logon)

Sobe o `llama-server` usando **o mesmo `launcher.bat` do atalho do Desktop**
(`C:\llama-cpu\launcher.bat`); se o launcher sumir, cai no `llama-server.exe`
direto com os mesmos argumentos. É **idempotente**: se já houver algo escutando na
porta, sai sem fazer nada — seguro rodar a cada logon e na mão. Janela escondida.

- **Modelo:** `qwen3-coder-30b-a3b-instruct-q4_k_m.gguf`
  (Qwen3-Coder-30B-A3B-Instruct, Q4_K_M) no cache do HuggingFace.
- **Host/porta:** `--host 0.0.0.0 --port 19001`, alias `qwen-coder-local`,
  `-t 8` threads, `-c 32768` de contexto.

Subir na mão:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\start-llama.ps1"
```

### Auto-start no logon (atalho na pasta Inicializar)
Na máquina gerenciada por GPO, a **criação de gatilhos `ONLOGON` via `schtasks.exe`
é bloqueada** ("Access denied"), então o llama e o vigia de reuniões sobem por um
**atalho na pasta Inicializar do Windows** apontando para os scripts (idempotentes).
Curiosidade útil: tarefas **`-Daily` criadas com o cmdlet `Register-ScheduledTask`
funcionam** nesta máquina (é assim que a rodada diária de §8 está registrada) — o
que trava é o `schtasks.exe ONLOGON`. Se um dia o atalho também for bloqueado, rode
o comando acima após cada logon.

### Por que `0.0.0.0` sem API key é INTENCIONAL
O `BindHost = 0.0.0.0` é **proposital** (uso do modelo pela **LAN**; o NAT/roteador
protege). **NÃO troque para `127.0.0.1`** e não recomende isso — é decisão de
projeto. Os scripts do SecondBrain sempre falam com `127.0.0.1:19001`. Não há API
key nesse endpoint (também intencional para o uso interno na LAN).

---

## 8. Agendamento diário (Tarefa Agendada)

O `setup-schedule.ps1` registra uma **Tarefa Agendada do Windows** ("SecondBrain -
Rodada diaria") que roda o `secondbrain-run.ps1` em horários fixos, **nível usuário,
sem admin** (`New-ScheduledTaskTrigger -Daily`, principal Interactive/Limited,
janela oculta, sem profile). A rodada agendada é best-effort: se Joule/Copilot/llama
não estiverem abertos, esses canais falham (não-fatal) e WhatsApp/Meetings seguem.

```powershell
# registra 2x/dia (padrão do script: 07:55 e 13:25)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\setup-schedule.ps1"

# horários customizados (ex.: as 3 cargas diárias — manhã/tarde/noite)
... setup-schedule.ps1 -Times 07:55,13:25,19:00

# abrir o cockpit na rodada agendada
... setup-schedule.ps1 -OpenCockpit

# remover o agendamento
... setup-schedule.ps1 -Remove
```

> **Registrado nesta máquina (verificado):** a tarefa `SecondBrain - Rodada diaria`
> **está registrada com 3 gatilhos diários — 07:55, 13:25 e 19:00** (fuso local /
> Brasília), rodando `secondbrain-run.ps1` com janela oculta. O **padrão do script
> é só 2 horários** (`07:55` e `13:25`); as **19:00** entraram porque foi criada com
> `-Times 07:55,13:25,19:00`. Se recriar do zero, passe o `-Times` para manter as 3.

> **Auto-start do vigia de reuniões** é registrado à parte pelo `setup-meeting.ps1`.
> Nesta máquina ele **não** virou Tarefa Agendada (o `schtasks ONLOGON` foi bloqueado
> por GPO) — caiu no **fallback de atalho na pasta Inicializar** (`SecondBrain-MeetingWatch.lnk`,
> junto com `SecondBrain-Llama.lnk`), que sobe no logon.

---

## 9. Reuniões (gravar / observar / transcrever — tudo local)

**Por quê:** o Teams deste tenant **não inicia transcrição sozinho**, então
gravamos **todas** as reuniões localmente (áudio do sistema + microfone, funciona
até de fone) e o whisper transcreve. A transcrição vira card no cockpit via
`meeting-detector.ps1`. **Nada sobe para a nuvem.**

- **`setup-meeting.ps1`** (uma vez): baixa a NAudio 1.10.0 do nuget → `lib\NAudio.dll`,
  valida NAudio/whisper/ffmpeg/Outlook COM e cria o auto-start de logon do vigia
  (`schtasks ONLOGON` → fallback atalho Inicializar → fallback manual). Sem a NAudio
  a gravação degrada para **só-microfone**.
- **`meeting-watch.ps1`** (vigia de fundo): a cada poll (padrão 20s) decide se há
  reunião AO VIVO combinando (1) **microfone em uso agora** por app de chamada
  conhecido (Teams/Chrome/Edge/Slack/Zoom/Webex/...) lido do ConsentStore do Windows
  e (2) **calendário** via Outlook COM (best-effort). Ao detectar, dispara o
  `record-meeting.ps1`; quando o mic é liberado, cria o StopFlag e a gravação encerra,
  mixa e transcreve sozinha. Nunca grava em dobro.
- **`record-meeting.ps1`**: grava sistema (**WASAPI loopback no device de Communications**,
  capturando os outros participantes mesmo quando você está no **fone/headset**) +
  microfone (WaveInEvent), mixa/normaliza com ffmpeg (16 kHz mono) e transcreve com
  whisper (`-mc 0` para evitar loop de alucinação) → `Meetings\<data>-<label>.txt` + `.json`.
  **Sempre** mostra uma janelinha **"● Gravando (local)"** com botão **Parar**
  (salvaguarda legal — nunca é silencioso).
- **`meeting-detector.ps1 -Ahead <n> -Json`**: lê os sidecars `Meetings\*.json` ainda
  não vistos, processa com o LLM local (:19001) e devolve o array JSON no schema do
  cockpit (`canal="meetings"`). Dedup por `meeting-state.json`.

Ligar o vigia agora (sem deslogar):
```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\Users\I827769\Documents\Joule\SecondBrain\meeting-watch.ps1'
```
Teste manual de gravação:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\record-meeting.ps1" -Label teste
# adicione -KeepAudio para guardar o WAV mixado em Meetings\<base>.wav
```

> **Consentimento é sua responsabilidade:** avise os participantes e respeite a
> política da empresa. A janela "Gravando" existe para nunca ser silencioso.

### 9.1 Captura por voz ("hey secondbrain" — `voice\voice_listen.py`)

Captura um pedido falado e cria um card, **sem parar o que você está fazendo**. Roda
como um listener sempre ativo **no seu processo** (atalho de logon) — é por isso que o
whisper funciona aqui, ao contrário de dentro do Claude (ACE Deny).

- **Gatilhos** (os dois valem): **Ctrl+Shift+B** (hotkey global via `pynput`) e a
  **wake word "hey secondbrain"** (modelo custom treinado em Kaggle com openWakeWord,
  disponível em `voice\models\hey_secondbrain.onnx`).
- **Fluxo:** gatilho → janela **"● Ouvindo (local)"** (consentimento, always-on-top) →
  grava mic 16 kHz mono → **VAD por energia** encerra após **~2s de silêncio** (teto
  ~20s) → `whisper-cli.exe` local transcreve (pt) → extrai `{assunto, pessoa, prazo,
  status, prioridade, notas}` via **llama local** (mesmo template `prompts/criar-tarefa.md`
  do agente digitado) → `POST /api/task` com `origem="voz"`.
- **Nada vaza:** captura local, whisper local, cockpit local; o microfone é **sempre
  liberado ao fim** (teardown garantido). Se o llama estiver fora do ar, o card é criado
  com o **texto cru** como assunto — a captura nunca se perde.
- **Whisper local do projeto:** o `setup-voice.ps1` prefere
  `SecondBrain\whisper\Release\whisper-cli.exe` (evita o Deny do `C:\`); cai para
  `C:\whisper` se não achar. Os caminhos resolvidos ficam em `voice\config.json`.
- **Degradação:** se o modelo de wake word não carregar, o listener segue
  **só com Ctrl+Shift+B**. Diagnóstico em `voice\voice.log`.

Ligar o listener agora (sem deslogar):
```powershell
Start-Process "C:\Users\I827769\Documents\Joule\SecondBrain\voice\.venv\Scripts\pythonw.exe" -ArgumentList '"C:\Users\I827769\Documents\Joule\SecondBrain\voice\voice_listen.py"'
```

> **Instância única:** o listener usa um mutex nomeado — abrir uma segunda instância
> apenas sai (não disputa o microfone com a primeira).

---

## 10. WhatsApp (coleta + análise + áudio silencioso)

Fluxo automático dentro da rodada; os comandos abaixo são para setup/teste.

- **`whatsapp-collector.ps1`** — coletor do histórico do WhatsApp Web → base local
  `WhatsApp\whatsapp-messages.jsonl` (append-only, dedup por SHA256), via WebDriver
  BiDi em `ws://127.0.0.1:9224` (Firefox com perfil autenticado). Abre cada chat com
  **clique confiável** (`input.performActions` — o WhatsApp ignora `.click()`
  sintético). **Este script é INTOCÁVEL: NÃO o edite.** Só escreva *companion scripts*
  (áudio, análise) ao redor dele.
- **`whatsapp-audio.ps1`** — extrai as **notas de voz** para `WhatsApp\audio-inbox\`.
  **Extração silenciosa e obrigatória:** faz hook em `HTMLAudioElement.prototype.play`
  para **silenciar antes** de tocar; o WhatsApp ainda baixa/descriptografa o áudio
  (E2E, a rede não serve os bytes), captura-se o blob e pegam-se os bytes. **Nenhum
  som sai pelas caixas/fone.** Reinicia o Firefox ao final para liberar a sessão BiDi
  órfã (áudio é o último passo; nada depois usa o Firefox).
- **`whatsapp-transcribe.ps1`** — transcreve `audio-inbox\` com whisper (ffmpeg →
  WAV 16 kHz → whisper-cli), faz append no `.jsonl` no mesmo schema do collector.
  Idempotente (SHA256). Funciona também com `.ogg`/`.opus` arrastados na mão.
- **`analyze-whatsapp.ps1`** — lê o `.jsonl` (últimos N dias), monta o contexto **em
  lotes (`ChunkChars` ~7000)** e pede a análise de pendências. **Padrão `-Engine local`**
  (LLM local em `127.0.0.1:19001`; nada sai da máquina). `-Engine joule` mandaria o
  conteúdo para o Joule (nuvem SAP).

Setup/teste do áudio:
```powershell
# uma vez: instala whisper + modelo medium
powershell ... -File "...\setup-whisper.ps1"
# transcreve o que está na audio-inbox
powershell ... -File "...\whatsapp-transcribe.ps1"
```

> **Filosofia do canal:** o WhatsApp é urgência/conveniência. Deixe como está —
> não sobre-invista nele.

---

## 11. Ajustando o comportamento dos canais (prompts editáveis)

Os três canais de coleta usam arquivos de texto como templates de prompt — você edita
o arquivo e a mudança entra na próxima rodada, sem mexer em nenhum script.

| Arquivo | Canal | Placeholders substituídos pelo script |
|---|---|---|
| `prompts\joule.md` | Joule (e-mail + calendário) | `{{JANELA}}` — janela de tempo calculada automaticamente |
| `prompts\copilot.md` | Copilot (Teams + transcrições) | `{{JANELA}}` |
| `prompts\whatsapp.md` | WhatsApp (LLM local) | `{{HOJE}}` (dd/MM/yyyy), `{{HORA}}` (HH:mm), `{{DIAS}}` (nº de dias da janela) |

> O `{{HOJE}}` e `{{HORA}}` no WhatsApp existem porque a LLM local (llama) não tem
> relógio — sem eles, datas relativas ("sexta", "amanhã") virariam prazo chutado.

**Regras que valem nos 3 prompts e que foram cuidadosamente calibradas:**
- *"De quem é a bola = ÚLTIMA mensagem do thread"* — evita classificar como "aguardando"
  algo que já está esperando resposta sua.
- Escopo: *"Inclua somente itens que envolvam Caíque diretamente ou sejam referentes a
  Emarsys"* — descarta ruído de outras pessoas/projetos.

> ⚠️ Os prompts usam **comando imperativo** (sem cabeçalho `# Prompt`) de propósito —
> o M365 Copilot "otimiza" prompts com cabeçalho e perde o contrato JSON. Não adicione
> cabeçalhos de seção antes das instruções do `copilot.md`.

---

## 12. Restrições de segurança/operação (LEIA antes de operar)

- **Tudo local.** CDP do Joule (`127.0.0.1:9222`), CDP do Copilot (`127.0.0.1:9223`),
  BiDi do WhatsApp (`127.0.0.1:9224`) e o cockpit (`127.0.0.1:8787`) são **loopback**.
  Não exponha essas portas. O adapter do Copilot mantém `--remote-debugging-address=127.0.0.1`
  — **não troque para `0.0.0.0`**.
- **llama `0.0.0.0:19001` sem API key é INTENCIONAL** (uso na LAN). **NÃO** recomende
  `--host 127.0.0.1` nem adicione key — os scripts falam com `127.0.0.1:19001` de
  qualquer forma. (Ver §7.)
- **Áudio NUNCA pode vazar.** A extração de notas de voz do WhatsApp silencia por-aba
  (hook no `play`) e faz **teardown obrigatório** (reinício do Firefox). Não altere
  esse comportamento; qualquer mudança aqui arrisca vazar som.
- **whisper bloqueado dentro do Claude:** ACE Deny no usuário barra `whisper-cli.exe`
  quando chamado de dentro do Claude. Rode transcrições do **terminal do usuário**.
- **NÃO edite `whatsapp-collector.ps1`.** É intocável — só companion scripts ao redor.
- **NÃO repare `tasks.json` com one-liner PowerShell.** Um one-liner PS tende a
  embrulhar o conteúdo em `{value, Count}` e corromper o arquivo. Se precisar reparar,
  **use Python** (ou deixe o próprio orquestrador/cockpit regravar com escrita atômica).
- **Consentimento de gravação de reunião** é responsabilidade do operador (a janela
  "Gravando" existe para nunca ser silencioso).
- **Sem segredos versionados:** `.gitignore` já exclui `WhatsApp/`, `Meetings/`,
  `raw/`, `processed/`, `logs/`, `lib/`, `*.jsonl/*.wav/*.ogg/*.mp3` e
  `ET-Joule_commandline.txt`. Não commite dados pessoais.

---

## 13. Solução de problemas (troubleshooting)

| Sintoma | Causa provável / correção (do código) |
|---|---|
| Cockpit não sobe — "Access denied" ao abrir a porta | Rode uma vez como admin: `netsh http add urlacl url=http://127.0.0.1:8787/ user=$env:USERNAME`. Ou use outra porta: `-Port 8791`. |
| Cockpit não parava com Ctrl+C | Já corrigido: usa `GetContextAsync` + `WaitOne(300ms)` em vez de `GetContext()` bloqueante. Se travar mesmo assim, ache o dono da porta com `netsh http show servicestate view=requestq` e mate o PID. |
| Acentos viram "�" na saída de um script chamado via `-RedirectStandardOutput` | O stdout é capturado na code page do console. Os scripts setam `[Console]::OutputEncoding = UTF8`; se você escrever um novo, faça o mesmo. |
| Copilot: "Timeout esperando resposta" | Normalmente é a **janela em background sendo estrangulada/virtualizada** pelo WebView2 (não seletor morto). O adapter faz `ShowWindow(SW_RESTORE)` via Win32 para restaurar a janela antes de enviar o prompt — se a janela estiver minimizada/oculta, ela é restaurada automaticamente. Se persistir, verifique se o processo `M365Copilot.exe` está rodando. |
| Copilot ignora o clique/tecla / botão Send não aparece | O editor (Fluent UI/React) **ignora eventos sintéticos**. O envio exige input CONFIÁVEL via CDP (`Input.dispatchMouseEvent`/`insertText`/`Enter`). Não tente automatizar via JS `.click()`. |
| Copilot "otimiza"/reescreve o prompt | Use **comando imperativo direto**, sem cabeçalho tipo "# Prompt" (o M365 Copilot otimiza prompts-template). Os `prompts\copilot.md` já pedem "não reescreva, execute". |
| Copilot: "chave de policy bloqueada" ao habilitar debug | Em máquina GPO a policy do WebView2 é read-only. Se a chave já tem a porta certa, basta relançar o app. Senão, rode uma vez como admin ou inicie o Copilot com o debug já ligado. |
| WhatsApp: abrir chat não funciona / 0 chats | O WhatsApp ignora `.click()` sintético — o collector usa `input.performActions` (clique real). Confirme Firefox/WhatsApp Web logado e a porta 9224. |
| WhatsApp: "Maximum active sessions" (BiDi travado) | O Firefox não libera a sessão BiDi órfã. O `whatsapp-audio.ps1` **reinicia o Firefox** para zerar as sessões (por isso o áudio é o último passo). |
| WhatsApp: 0 áudios extraídos | Precisa do Firefox/WhatsApp Web aberto. Fallback: arraste os `.ogg`/`.opus` para `WhatsApp\audio-inbox\` e rode `whatsapp-transcribe.ps1`. |
| Análise local muito lenta / não responde | O modelo 30B demora a carregar; o orquestrador espera a porta 19001 até 90s. Confirme o llama no ar (`start-llama.ps1`). A LLM local é lenta para chat — para chat prefira o Joule. |
| Reunião gravada — outros participantes com áudio silencioso | O `WasapiLoopbackCapture` por padrão captura o device **Multimedia**. Se você estiver no **fone/headset**, o Teams usa o device **Communications** — o `record-meeting.ps1` já está configurado para usar o device de Communications, então funciona corretamente com headset. |
| Whisper em loop / frases repetidas na transcrição | Sem `--condition-on-previous-text false` (indisponível nesta versão), use `-mc 0` (`--max-context 0`). O `record-meeting.ps1` já passa `-mc 0` automaticamente. Se rodar whisper manual, inclua a flag. |
| Reunião não grava sozinha | Confirme o `meeting-watch.ps1` rodando (auto-start de logon) e a NAudio instalada (senão, só-microfone). Se COM do Outlook estiver bloqueado, ele usa só o sinal do microfone. |
| whisper não roda dentro do Claude | ACE Deny — rode do terminal do usuário. |
| `tasks.json` corrompido | **NÃO** conserte com one-liner PowerShell (embrulha em `{value,Count}`). Use Python ou deixe o orquestrador regravar. |
| Canal falhou mas a rodada continuou | É por design: cada canal é isolado por try/catch; veja o **sumário** no fim do log `logs\run-<ts>.log`. |

---

## 14. Fluxo mínimo do dia a dia

```powershell
# 1) deixe abertos: Joule Desktop, M365 Copilot, Firefox/WhatsApp; llama sobe no logon
# 2) rodada completa + abrir o cockpit:
sb -OpenCockpit
# 3) primeira carga (uma vez, janelas largas):
secondbrain -InitialLoad -OpenCockpit
# 4) só ver o cockpit com o que já foi coletado:
cockpit
```

---

### Apêndice — itens confirmados nesta máquina

Resolvidos durante a escrita deste guia (verificados na máquina em uso):

- ✅ **Funções do `$PROFILE`** — corpos reais capturados de
  `...\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` (§6). O `teams` roda o
  orquestrador só no canal Copilot (`-SkipJoule -SkipWhatsApp -SkipMeetings`).
- ✅ **Rodada agendada** — `SecondBrain - Rodada diaria` registrada **3x/dia**
  (07:55, 13:25, 19:00) via `Register-ScheduledTask` (§8).
- ✅ **Vigia de reuniões** — sem Tarefa Agendada; roda pelo atalho de logon
  `SecondBrain-MeetingWatch.lnk` na pasta Inicializar (§8).
- ✅ **Perfil do Firefox** — `qyl4c5lr.default-release` existe e está fixo no
  `whatsapp-collector.ps1` (§2, §10).

Único ponto que **não** é observável nos `.ps1` (comportamento de ambiente):

- **ACE Deny** do `whisper-cli.exe` quando invocado **de dentro do Claude** — rode
  transcrições a partir do terminal do usuário (§2, §11). Documentado pela memória
  de operação, não pelo código.
</content>
</invoke>

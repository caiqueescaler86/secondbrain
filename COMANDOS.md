# 🧠 SecondBrain — Comandos

Guia rápido dos comandos. Todos funcionam **de qualquer pasta** do PowerShell
(estão no seu profile). Se acabou de abrir o PowerShell, já valem; se editou o
profile, recarregue com `. $PROFILE` ou abra uma janela nova.

---

## 🚀 Uso no dia a dia

| Comando | O que faz |
|---|---|
| `secondbrain -OpenCockpit` | **O principal.** Roda a rodada inteira (Joule + Copilot + WhatsApp), consolida as pendências e abre o cockpit no navegador. |
| `sb -OpenCockpit` | Atalho curto do mesmo comando. |
| `cockpit` | Só abre o cockpit com o que já foi coletado (não roda os canais). |

> Para a rodada completa, deixe **Joule Desktop**, **Copilot** e o **llama-server**
> abertos. O **WhatsApp agora é analisado pela LLM local por padrão** (nada do zap
> sai da máquina) — então o llama-server é necessário pra esse canal. O WhatsApp
> reinicia o Firefox sozinho.
>
> Quer mandar o WhatsApp pro Joule (nuvem SAP) em vez da LLM local? Use
> `secondbrain -WhatsAppEngine joule`. **Padrão = `local`.**
>
> 🦙 **O llama-server sobe sozinho no logon** (atalho na pasta Inicializar →
> `start-llama.ps1`, idempotente: se já estiver no ar não sobe outro). Se precisar
> subir na mão: `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\start-llama.ps1"`.
> Ele escuta em `0.0.0.0:19001` **de propósito** (acesso pela LAN).

---

## 👀 Ver a aparência (dados de exemplo)

| Comando | O que faz |
|---|---|
| `cockpitdemo` | Semeia 9 tarefas de exemplo (uma por categoria) e abre o cockpit. Só pra ver o visual. |
| `cockpitdemo -Reset` | Limpa os exemplos e volta o store a vazio. |

---

## 🗓️ Primeira carga / casos especiais

| Comando | O que faz |
|---|---|
| `secondbrain -InitialLoad` | Primeira carga com janelas largas (e-mail 14d, Teams 7d, WhatsApp 90d). **Alta e média** entram no board; só **baixa/referência** ficam de fora (visíveis com o filtro "referência"). |
| `secondbrain -DryRun` | Simula a rodada **sem gravar** no store (gera só o snapshot e o log). |
| `secondbrain -InitialLoad -DryRun` | Testa a carga inicial sem alterar nada. |
| `secondbrain -SkipWhatsApp` | Roda pulando um canal (existe `-SkipJoule`, `-SkipCopilot`, `-SkipWhatsApp`). |
| `secondbrain -SkipAudio` | Roda o WhatsApp mas **sem** extrair/transcrever notas de voz (só texto). |

---

## 🎤 Áudios do WhatsApp (notas de voz → texto, local)

Transcreve as notas de voz do zap com **whisper.cpp** local (CPU) e as joga no mesmo
fluxo — viram pendência no cockpit igual mensagem de texto. Roda sozinho dentro da
rodada (`secondbrain`); os comandos abaixo são só para setup/teste.

| Comando | O que faz |
|---|---|
| `whisper-setup` | **Uma vez.** Baixa o whisper.cpp + o modelo `medium` (~1,5 GB) para `C:\whisper\`. |
| `whatsapp-transcreve` | Transcreve os áudios que estão em `WhatsApp\audio-inbox\` e adiciona à base. |

> **Como os áudios chegam:** na rodada, o `whatsapp-audio.ps1` puxa as notas de voz
> do WhatsApp Web pra `audio-inbox\` (best-effort). Se algum áudio não vier automático,
> dá pra **arrastar o `.ogg`/`.opus` na mão** pra `WhatsApp\audio-inbox\` e rodar
> `whatsapp-transcreve` — funciona igual.
>
> Precisa do **Firefox/WhatsApp Web aberto** (o mesmo do coletor) pra extração automática.

---

## ⚙️ Opções úteis

| Opção | Para quê |
|---|---|
| `-Port 8791` | Usar outra porta se a 8787 der "Access denied". Ex: `cockpitdemo -Port 8791`. |
| `-Date 2026-09-20` | Forçar a data-base da rodada. |

---

## 🖱️ Dentro do cockpit (navegador)

O cockpit é uma **lista única priorizada** — "O que importa agora" no topo, tudo
ordenado por prioridade + prazo. O **status é só uma etiqueta colorida**
(Responder / Fazer / Cobrar / Preparar / Risco), não decide mais se você vê ou não.
Nada seu e aberto fica escondido num canto.

- **"Aguardando os outros"** e **"Referência / baixa"** ficam em seções recolhíveis
  embaixo (clique no título pra abrir/fechar).
- **Clicar no card** → expande resumo, risco, notas e os botões.
- **✓ (canto sup. esq. do card)** → conclui em 1 clique sem expandir · confete 🎉 e elogio no toast.
- **Feito** → mesmo efeito de dentro do card · **Adiar** → joga pra amanhã · **↑↓ Prio** → cicla prioridade.
- **Notas** → digita direto no card (salva ao sair do campo, **sem piscar a tela**).
- **Prazo** → campo de data no canto superior direito do card (editável sem expandir).
- Topo: **relógio**, contadores (hoje / atrasadas / aguardando), **busca** e os toggles:
  - **"referência / baixa"** → mostra a seção de baixa prioridade/referência.
  - **"concluídas"** → mostra o que já foi feito.
  - **prioridade / data** → alterna a ordenação do board.
  - **⤢** → expande todos os cards visíveis de uma vez.
- O cockpit **recarrega sozinho a cada 1 min**; `⟳` recarrega na hora.
- Suas ações (feito, notas, prioridade) **são preservadas** na próxima rodada.

### 🧠 Agente (filtro e perguntas)

Botão **🧠 Agente** (canto superior direito) abre o painel de IA. Dois modos:

| Alvo | Motor | Velocidade | Acesso à internet |
|---|---|---|---|
| **Joule** (padrão) | Claude via Joule Desktop | 30–120 s | Sim (e-mail/calendário do M365) |
| **IA local** | llama-server :19001 | 1–3 s | Não (só o que está nos cards) |

**Filtrar a tela por linguagem natural** — fala no painel e o board muda:
- `"me traga as pendências da Cantu"` → mostra só cards da Cantu.
- `"mostra os riscos atrasados"` → filtra status=risco + prazo vencido.
- `"possíveis duplicados"` → detecta localmente (sem LLM), marca grupos ≈ no board.
- `"limpar filtro"` (ou o **✕** no chip) → volta tudo.

**Perguntas livres** também funcionam — ex.: `"o que é mais urgente hoje?"`, `"resume o que o cliente X pediu"`.

> Verbos que ativam o filtro (detectados no browser, instantâneo): *traga, mostra, filtra, deixa só, apenas, esconde, oculta…*
> Qualquer outra frase → pergunta normal pro modelo selecionado.

---

## 🎙️ Reuniões (gravação + transcrição local)

> **Por que gravar por fora?** O Teams deste tenant **não inicia transcrição
> sozinho**. Então gravamos **todas** as reuniões localmente (microfone + áudio do
> sistema, funciona até de fone) e o **whisper** transcreve tudo. A transcrição vira
> card no cockpit. **Tudo fica na máquina** — nada sobe pra nuvem.
>
> ⚠️ **Consentimento:** enquanto grava, aparece uma janela **"● Gravando (local)"**
> com botão **Parar** — nunca é silencioso. Avisar os participantes / respeitar a
> política da empresa é responsabilidade sua.

| Comando | O que faz |
|---|---|
| `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\setup-meeting.ps1"` | **Uma vez.** Baixa a NAudio (captura de áudio, sem admin), valida whisper/ffmpeg/Outlook e cria o **atalho de logon** que sobe o vigia sozinho. |
| `Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\Users\I827769\Documents\Joule\SecondBrain\meeting-watch.ps1'` | **Liga o vigia agora** (sem deslogar). Ele detecta quando uma reunião começa (uso do microfone) e grava sozinho; para quando o mic é liberado. |
| `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\I827769\Documents\Joule\SecondBrain\record-meeting.ps1" -Label teste` | **Teste manual.** Grava agora até você clicar **Parar**, mixa e transcreve. Bom pra validar áudio+whisper antes de uma reunião de verdade. |
| `... record-meeting.ps1 -Label reuniao -KeepAudio` | Igual, mas **guarda o WAV** em `Meetings\<base>.wav` pra você reouvir trechos. Sem `-KeepAudio` o áudio é temporário (só fica a transcrição). |

> **Auto-start nesta máquina:** o Agendador de Tarefas está bloqueado por GPO
> (`schtasks` dá *Access denied`), então o setup usa a **pasta Inicializar do Windows**
> — o vigia sobe sozinho a cada logon, sem admin. Se um dia isso também for bloqueado,
> rode o comando "Liga o vigia agora" acima depois de cada logon.

> As transcrições caem em `Meetings\<data>-<label>.txt` (+ `.json`). Na próxima rodada
> do `secondbrain`, o `meeting-detector.ps1` ingere esses arquivos e vira ação no cockpit.
>
> **Config do Teams (opcional):** se um dia liberarem, dá pra ligar
> *Opções da reunião → Gravar e transcrever automaticamente* — aí a transcrição cai
> no chat/OneDrive e o canal Copilot colhe sozinho. Hoje isso está indisponível, por
> isso gravamos por fora.
>
> **Se algo estiver bloqueado por GPO** (download, Task Scheduler, Outlook COM): o
> `setup-meeting.ps1` mostra o fallback manual de cada passo. Sem a NAudio a gravação
> ainda funciona, só com o microfone (sem o áudio dos outros).

---

## 🛑 Parar o cockpit

Na janela do PowerShell onde ele está rodando: **`Ctrl + C`**.

---

## 📁 Onde ficam as coisas

```
C:\Users\I827769\Documents\Joule\SecondBrain\
├─ secondbrain-run.ps1     ← orquestrador (entrada única)
├─ cockpit.ps1             ← servidor web local
├─ cockpit-demo.ps1        ← dados de exemplo
├─ cockpit\                ← visual (index.html / style.css / app.js / favicon)
├─ prompts\                ← templates de prompt editáveis pelo usuário
│   ├─ joule.md            ← e-mail + calendário  ({{JANELA}})
│   ├─ copilot.md          ← Teams + transcrições ({{JANELA}})
│   └─ whatsapp.md         ← WhatsApp             ({{HOJE}} {{HORA}} {{DIAS}})
├─ analyze-whatsapp.ps1    ← análise do WhatsApp pela LLM local (em lotes)
├─ start-llama.ps1         ← sobe o llama-server local (auto-start no logon, idempotente)
├─ meeting-detector.ps1    ← canal: ingere transcrições de reunião → cards
├─ meeting-watch.ps1       ← vigia: detecta reunião ao vivo e dispara a gravação
├─ record-meeting.ps1      ← grava (mic + sistema) + mixa + transcreve (whisper)
├─ setup-meeting.ps1       ← setup único da gravação (NAudio + tarefa de logon)
├─ lib\NAudio.dll          ← captura de áudio (baixada pelo setup, sem admin)
├─ Meetings\               ← transcrições das reuniões (.txt/.json)
├─ processed\
│   ├─ tasks.json          ← suas tarefas (o "banco" local)
│   └─ last-run.json       ← timestamp do último run bem-sucedido (controla janela de busca)
├─ raw\                    ← saída crua de cada canal por rodada
└─ logs\                   ← run-<data>.log de cada rodada
```

Tudo **100% local** (127.0.0.1). Nada sai para a nuvem além das chamadas
naturais do Joule/Copilot.

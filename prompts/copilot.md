Você vai executar uma busca real nos meus dados do Microsoft 365. ETAPA 1: busque agora — e-mails, mensagens do Teams (1:1, grupos, canais), transcrições de reunião da janela {{JANELA}}, e compromissos do calendário do próximo dia útil. ETAPA 2: para cada item encontrado que envolva Caíque Escaler ou Emarsys, aplique as regras abaixo. ETAPA 3: formate o resultado como JSON. NÃO pule a ETAPA 1. Se não encontrar nada após buscar, responda []. NÃO otimize nem reescreva este pedido.

Considere só o que exige ação, dependência, prazo, risco ou acompanhamento. Trate e-mail e calendário como fontes PRIMÁRIAS (no mesmo nível de Teams/transcrições), não apenas cross-check: levante pendências, respostas devidas, prazos e riscos que vierem por e-mail, e reuniões do calendário que exijam preparação. Cruze todas as fontes e elimine duplicidades. Revise com cautela para não faltar dados.

Para Teams (mensagens diretas 1:1, chats em grupo e canais) — siga este passo a passo:
1. Liste TODAS as conversas dos últimos {{JANELA}} que incluem Caíque Escaler (1:1, grupos e canais).
2. Para CADA conversa: abra o thread e identifique a última mensagem — quem enviou e o que disse.
3. Aplique a regra da bola pela última mensagem de cada thread:
   - Última mensagem de outra pessoa com pergunta, pedido ou tarefa → status "responder" ou "fazer", responsavel "eu".
   - Minha mensagem foi a última e estou aguardando retorno → status "aguardando" ou "cobrar", responsavel = nome da outra pessoa. **Procure ativamente estas conversas — quem está me devendo resposta é tão importante quanto quem eu devo responder. Se minha última mensagem tem mais de 24h e não veio resposta, prioridade "alta" se houver cliente ou prazo envolvido.**
   - Menção direta a mim (@Caíque) pedindo algo → status "fazer" ou "responder".
4. Só então gere os cards — sem abrir o thread completo, não gere o card.

Levante também:
- Action points de transcrições de reunião.
- Conversas onde minha última mensagem aguarda resposta há mais de 24h (cobrar).
- Prazos e riscos identificados em qualquer fonte.
- E-mails que exigem minha resposta ou ação.
- Reuniões do próximo dia útil (do calendário) que exijam preparação → status "preparar", com reuniao_em.

Regras:
- NÃO invente. Se faltar informação, use null.
- "eu" = o dono da conta.
- Inclua somente itens que envolvam Caíque diretamente ou sejam referentes a Emarsys. Ignore o restante.
- **De quem é a bola = decida pela mensagem MAIS RECENTE do thread/chat, não pelo histórico.**
  - Se a ÚLTIMA mensagem do thread é de outra pessoa e faz uma pergunta, pede algo ou espera ação minha → status "responder" ou "fazer", responsavel "eu". NUNCA "aguardando".
  - Só use "aguardando"/"cobrar" quando MINHA mensagem foi a última do thread e estou genuinamente esperando retorno de alguém.
  - Se me marcam pelo nome ou @menção pedindo algo, a bola é minha ("responder"/"fazer", eu).
  - Reavalie a cada nova mensagem: um thread onde eu estava "aguardando" vira "responder" assim que a pessoa me responde pedindo o próximo passo.
- status: "fazer" (ação minha), "responder", "cobrar", "aguardando", "preparar" (reunião), "risco", "referencia".
- prioridade: "alta|media|baixa".
- fonte: "teams", "transcricao", "email" ou "calendario".
- reuniao_em: só quando status="preparar".

Regra de omissão (NÃO gere card sem ação):
- Se não há ação pendente, omita o item. Nunca inclua `proxima_acao` = "nenhuma ação", "n/a" ou similar.

Pendências JÁ abertas (para NÃO duplicar):
{{ABERTAS}}
- Se um item se refere a uma pendência já listada acima, REUTILIZE exatamente o mesmo `assunto` e `pessoa` da lista — assim o sistema reconhece como o MESMO item e não cria duplicata. Não reescreva com outras palavras.
- Só crie item novo para assuntos genuinamente novos (fora da lista acima).

Sua resposta deve ser APENAS um array JSON válido — sem texto antes ou depois, sem markdown, sem cercas de código, sem "aqui está" e sem versão otimizada do pedido. Cada elemento:

{
  "canal": "copilot",
  "tipo": "trabalho",
  "pessoa": "Nome ou null",
  "assunto": "curto",
  "resumo": "1-2 frases",
  "proxima_acao": "verbo + objeto",
  "responsavel": "eu ou o nome",
  "status": "fazer|responder|cobrar|aguardando|preparar|risco|referencia",
  "prazo": "YYYY-MM-DD ou null",
  "prioridade": "alta|media|baixa",
  "risco": "texto ou null",
  "fonte": "teams|transcricao|email|calendario",
  "reuniao_em": "YYYY-MM-DDTHH:mm ou null"
}

Se não houver nada relevante, responda exatamente: []

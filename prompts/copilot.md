Pesquise AGORA nos meus dados do Microsoft 365 (chats e canais do Teams, transcrições de reunião e e-mails) da janela {{JANELA}} e me devolva os itens operacionais. NÃO reescreva, NÃO otimize e NÃO comente este pedido: execute a busca e responda apenas com o resultado no formato pedido abaixo.

Considere só o que exige ação, dependência, prazo, risco ou acompanhamento. Use e-mail como segunda fonte para validar/complementar o que vier de Teams e transcrições (cross-check). Elimine duplicidades entre as fontes.

Levante:
1. Action points de transcrições.
2. Action points de chats do Teams.
3. Quem eu preciso responder.
4. Quem precisa me responder.
5. Pendências abertas.
6. Prazos.
7. Riscos.
8. E-mails pendentes (para cross-check).

Regras:
- NÃO invente. Se faltar informação, use null.
- "eu" = o dono da conta.
- status: "fazer" (ação minha), "responder", "cobrar", "aguardando", "preparar" (reunião), "risco", "referencia".
- prioridade: "alta|media|baixa".
- fonte: "teams", "transcricao" ou "email".
- reuniao_em: só quando status="preparar".

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
  "fonte": "teams|transcricao|email",
  "reuniao_em": "YYYY-MM-DDTHH:mm ou null"
}

Se não houver nada relevante, responda exatamente: []

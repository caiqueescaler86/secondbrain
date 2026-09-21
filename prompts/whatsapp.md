# Prompt WhatsApp → JSON

Usado pelo `analyze-whatsapp.ps1 -Json` (contrato do que o modelo local recebe). Analisa as mensagens dos últimos N dias e separa pendências pessoais e de trabalho.

Identifica:
1. Quem eu preciso responder.
2. Quem precisa me responder.
3. O que eu prometi fazer.
4. O que alguém me pediu.
5. Cobranças pendentes.
6. Prazos ou urgências.
7. Riscos de esquecimento.

Regras:
- NÃO invente. Se faltar informação, use null.
- Linhas marcadas "EU:" são minhas (direction=out). As demais são da outra pessoa.
- status: "responder", "cobrar", "aguardando", "fazer", "risco", "referencia".
- tipo: "pessoal" ou "trabalho".
- prioridade: "alta|media|baixa".

Saída: APENAS um array JSON válido, sem texto/cercas. Cada elemento:

{
  "canal": "whatsapp",
  "tipo": "pessoal|trabalho",
  "pessoa": "Nome/contato",
  "assunto": "curto",
  "resumo": "1-2 frases",
  "proxima_acao": "verbo + objeto",
  "responsavel": "eu ou o nome",
  "status": "fazer|responder|cobrar|aguardando|risco|referencia",
  "prazo": "YYYY-MM-DD ou null",
  "prioridade": "alta|media|baixa",
  "risco": "texto ou null",
  "fonte": "whatsapp",
  "reuniao_em": null
}

Se não houver nada relevante: []

# Consolidador — contrato JSON + regras (implementado em PowerShell)

Não há segunda LLM de consolidação. Cada canal (Joule, Copilot, WhatsApp) devolve um array JSON no schema abaixo, e o `secondbrain-run.ps1` consolida de forma **determinística**. Este arquivo documenta o contrato e as regras.

## Schema de item (todos os canais)

```json
{
  "canal": "joule|copilot|whatsapp",
  "tipo": "trabalho|pessoal",
  "pessoa": "Nome ou null",
  "assunto": "curto",
  "resumo": "1-2 frases",
  "proxima_acao": "verbo + objeto",
  "responsavel": "eu|<pessoa>",
  "status": "fazer|responder|cobrar|aguardando|preparar|risco|referencia",
  "prazo": "YYYY-MM-DD|null",
  "prioridade": "alta|media|baixa",
  "risco": "texto|null",
  "fonte": "email|calendario|teams|transcricao|whatsapp",
  "reuniao_em": "YYYY-MM-DDTHH:mm|null"
}
```

## SB-ID (chave de dedup/update)

`sb-` + primeiros 12 hex de `SHA256( normalize(pessoa) | normalize(assunto) | categoria )`.

`normalize` = minúsculas, sem acento, espaços colapsados, pontuação removida. **Sem canal** no hash → a mesma pendência vinda de Joule e Copilot colapsa num item só e as `fontes` se acumulam.

## Categorias (para o board do cockpit)

Derivadas do `status` + `tipo`:
- `fazer` → **Fazer hoje**
- `responder` → **Responder**
- `cobrar` → **Cobrar**
- `aguardando` → **Aguardando**
- `preparar` → **Preparar reunião**
- `risco` → **Riscos**
- `whatsapp` + `tipo=pessoal` → **WhatsApp pessoal**
- `whatsapp` + `tipo=trabalho` → (segue o status; se genérico, **WhatsApp trabalho**)
- `referencia` → **Referência**

## Prefixo de título

`[Fazer] [Responder] [Cobrar] [Aguardando] [Preparar] [Risco] [Pessoal]` conforme status/tipo.

## Due date

- prazo explícito → usa o prazo.
- responder/cobrar sem prazo → hoje.
- aguardando → amanhã (próximo dia útil).
- preparar → dia anterior à `reuniao_em`.

## Prioridade / bootstrap

- alta → entra no board ativo.
- media → fica em `processed\initial-review.json` / aba Revisão.
- baixa → Referência (não enche o board).

Critérios de alta: pendência aberta, resposta minha pendente, cobrança pendente, prazo explícito, risco real de esquecimento, cliente/trabalho relevante.

## Dedup / merge

- Chave primária: SB-ID.
- Near-dup: mesma `pessoa` + `assunto` normalizados → mesmo item, acumula `fontes` e mantém a maior prioridade / menor prazo.
- Ao regravar no store, **preserva** estado do usuário no cockpit (`done`, `snoozedUntil`, `notas`, prioridade ajustada à mão).

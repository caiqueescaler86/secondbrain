# Modelos de wake word (openWakeWord)

Largue aqui os modelos **customizados** que você treinar — os arquivos `.onnx`
(ex.: `hey_secondbrain.onnx`, `hey_sb.onnx`). O `setup-voice.ps1` escaneia esta
pasta e registra o que encontrar no `voice\config.json` (campo `wakeword_models`);
o `voice_listen.py` carrega **todos** de uma vez e dispara em qualquer um deles.

Enquanto não houver nenhum `.onnx` aqui, a wake word cai no pré-treinado
**"hey jarvis"** (e o **Ctrl+Shift+B** funciona sempre, independente disso).

---

## Como treinar "hey SecondBrain" e "hey SB" (Google Colab, ~1h cada, grátis)

Nada é instalado na sua máquina; o treino roda no Colab e você só baixa o `.onnx`.
O reconhecimento depois é **100% local**.

1. Abra o notebook oficial de treino automático do openWakeWord:
   https://github.com/dscripka/openWakeWord  → seção **"Training New Models"** →
   link do **"automatic model training" (Google Colab)**.
   (Link direto costuma ser:
   https://colab.research.google.com/github/dscripka/openWakeWord/blob/main/notebooks/automatic_model_training.ipynb )

2. No topo do Colab: **Runtime → Change runtime type → GPU** (T4 grátis serve).

3. Rode as células em ordem. Quando pedir o **`target_word`/`wake_word`**, digite a
   frase exatamente como vai falar:
   - primeiro modelo: **`hey secondbrain`**
   - depois repita o notebook do zero para: **`hey sb`**
     (dica: fale/treine como **"hey esse-bê"** se você pronuncia as letras em
     português; frases curtas assim são mais difíceis — capriche no nº de amostras).

4. O notebook gera voz sintética da frase (TTS), treina e **exporta um `.onnx`**.
   Baixe o arquivo ao final de cada rodada.

5. Renomeie e coloque nesta pasta, por exemplo:
   - `voice\models\hey_secondbrain.onnx`
   - `voice\models\hey_sb.onnx`

6. Rode de novo o setup pra registrar os modelos no config:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "..\..\setup-voice.ps1" -NoAutoStart
   ```
   (o `-NoAutoStart` evita recriar o atalho de logon; pode omitir se quiser recriá-lo)

7. Reinicie o listener e teste falando a frase. Ajuste a sensibilidade em
   `config.json` → `wakeword_threshold` (padrão 0.5; **subir** = menos disparo à toa,
   **descer** = dispara mais fácil).

> Exporte em **ONNX** (padrão do notebook). Se por algum motivo exportar `.tflite`,
> mude `wakeword_framework` para `"tflite"` no `config.json`.

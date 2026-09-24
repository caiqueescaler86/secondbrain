#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =====================================================================
# SecondBrain - listener de voz ("Jarvis")
#
# RODA NO PROCESSO DO USUARIO (atalho de logon / terminal dele).
# NUNCA lancado pelo Claude: o whisper-cli.exe tem ACE Deny quando o
# Claude o executa -> so funciona no processo do usuario.
#
# Gatilhos (os dois valem):
#   - Ctrl+Shift+B  (hotkey global, sem admin, via pynput)
#   - wake word "hey jarvis" (openWakeWord ouvindo o mic)
#
# Fluxo: gatilho -> janela "Ouvindo (local)" -> grava mic 16k mono ->
#        ~2s de silencio encerra -> whisper local (pt) -> extrai a
#        tarefa (llama local) -> POST /api/task (origem=voz).
#
# Tudo LOCAL. Nenhum audio sai da maquina. O microfone e sempre
# liberado ao fim (teardown garantido).
# =====================================================================

import os
import sys
import json
import time
import wave
import queue
import tempfile
import threading
import subprocess
import datetime
import ctypes
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # ...\SecondBrain
LOG_FILE = os.path.join(HERE, "voice.log")


def log(msg):
    line = "[%s] %s" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    try:
        print(line, flush=True)
    except Exception:
        pass


# ---------------------------------------------------------------------
# Config: defaults + override por voice\config.json (gerado pelo setup).
# ---------------------------------------------------------------------
def load_config():
    cfg = {
        "cockpit_url": "http://127.0.0.1:8787",
        "llama_url": "http://127.0.0.1:19001",
        "prompt_file": os.path.join(ROOT, "prompts", "criar-tarefa.md"),
        "whisper_exe": "",           # resolvido pelo setup-voice.ps1
        "whisper_model": "",         # idem
        "whisper_lang": "pt",
        "whisper_threads": 8,
        "wakeword": "hey_jarvis",    # fallback pre-treinado se nao houver modelos custom
        "wakeword_models": [],       # lista: caminhos .onnx/.tflite custom (ex.: "models/hey_sb.onnx")
                                     #        OU nomes pre-treinados; vazio => usa 'wakeword' acima
        "wakeword_framework": "onnx",  # "onnx" ou "tflite" (formato exportado pelo Colab)
        "wakeword_threshold": 0.5,
        "enable_wakeword": True,
        "hotkey": "<ctrl>+<shift>+b",
        "sample_rate": 16000,
        "silence_ms": 2000,          # 2s de silencio encerra a fala
        "max_record_ms": 20000,      # teto de gravacao
        "start_timeout_ms": 6000,    # aborta se nada for dito
        "llama_timeout_s": 120,      # extracao local e lenta (~52s)
    }
    p = os.path.join(HERE, "config.json")
    if os.path.exists(p):
        try:
            with open(p, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
            log("config.json carregado")
        except Exception as e:
            log("config.json invalido, usando defaults: %s" % e)
    return cfg


# ---------------------------------------------------------------------
# Instancia unica (evita dois listeners disputando o mic).
# ---------------------------------------------------------------------
def acquire_single_instance():
    try:
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.CreateMutexW(None, False, "Global\\SecondBrainVoiceListener")
        ERROR_ALREADY_EXISTS = 183
        if kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
            return None
        return handle  # manter referencia viva pelo processo todo
    except Exception as e:
        log("nao consegui criar mutex (seguindo assim mesmo): %s" % e)
        return True


# ---------------------------------------------------------------------
# Indicador visual: silencioso em background, aparece so quando acionado.
# Arrastavel durante a gravacao (drag por qualquer parte do widget).
# Sem console em producao (usar pythonw.exe).
# ---------------------------------------------------------------------
class Indicator:
    def __init__(self):
        import tkinter as tk
        self._tk   = tk
        self.q     = queue.Queue()
        self._hide_after = None
        self._drag_x = 0
        self._drag_y = 0

        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg="#0e1117")
        self.root.attributes("-alpha", 0.95)
        self.root.withdraw()   # silencioso ate ser acionado

        # Carrega o logo PNG via tkinter nativo (Python 3 suporta PNG sem PIL).
        self._logo_img = None
        try:
            import tkinter as _tk2
            HERE_ = os.path.dirname(os.path.abspath(__file__))
            png   = os.path.join(os.path.dirname(HERE_), "cockpit", "favicon-256.png")
            if os.path.exists(png):
                raw = _tk2.PhotoImage(file=png)
                # subsample(7) -> 256/7 ≈ 36px
                self._logo_img = raw.subsample(7, 7)
        except Exception:
            pass

        frame = tk.Frame(self.root, bg="#0e1117", padx=10, pady=8)
        frame.pack()

        if self._logo_img:
            self._logo_lbl = tk.Label(frame, image=self._logo_img,
                                      bg="#0e1117", bd=0)
        else:
            self._logo_lbl = tk.Label(frame, text="\U0001f9e0",
                                      font=("Segoe UI Emoji", 22),
                                      bg="#0e1117", fg="#ffffff")
        self._logo_lbl.grid(row=0, column=0, rowspan=2, padx=(0, 10))

        self._main_lbl = tk.Label(frame, text="SecondBrain",
                                  font=("Segoe UI", 10, "bold"),
                                  bg="#0e1117", fg="#6060a0", anchor="w")
        self._main_lbl.grid(row=0, column=1, sticky="w")

        self._sub_lbl = tk.Label(frame, text="",
                                 font=("Segoe UI", 7),
                                 bg="#0e1117", fg="#404060", anchor="w")
        self._sub_lbl.grid(row=1, column=1, sticky="w")

        # Posicao padrao: canto inferior direito
        self.root.update_idletasks()
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        ww = self.root.winfo_width()
        wh = self.root.winfo_height()
        self.root.geometry("+%d+%d" % (sw - ww - 20, sh - wh - 60))

        # Drag: arrasta qualquer widget do frame
        for w in (frame, self._logo_lbl, self._main_lbl, self._sub_lbl):
            w.bind("<Button-1>",   self._drag_start)
            w.bind("<B1-Motion>",  self._drag_move)

        self.root.after(80, self._pump)

    # ------------------------------------------------------------------
    # Drag
    # ------------------------------------------------------------------
    def _drag_start(self, event):
        self._drag_x = event.x_root - self.root.winfo_x()
        self._drag_y = event.y_root - self.root.winfo_y()

    def _drag_move(self, event):
        x = event.x_root - self._drag_x
        y = event.y_root - self._drag_y
        self.root.geometry("+%d+%d" % (x, y))

    # ------------------------------------------------------------------
    # Fila de mensagens (thread-safe)
    # ------------------------------------------------------------------
    def post(self, kind, text=""):
        self.q.put((kind, text))

    def _pump(self):
        try:
            while True:
                kind, text = self.q.get_nowait()
                self._handle(kind, text)
        except queue.Empty:
            pass
        except Exception as e:
            log("erro no pump da UI: %s" % e)
        self.root.after(80, self._pump)

    def _show(self):
        if self._hide_after is not None:
            try:
                self.root.after_cancel(self._hide_after)
            except Exception:
                pass
            self._hide_after = None
        try:
            self.root.deiconify()
            self.root.lift()
            self.root.attributes("-topmost", True)
        except Exception:
            pass

    def _schedule_hide(self, ms):
        self._hide_after = self.root.after(ms, self._do_hide)

    def _do_hide(self):
        self._hide_after = None
        try:
            self.root.withdraw()
        except Exception:
            pass

    def _handle(self, kind, text):
        if kind == "listening":
            self._show()
            self._main_lbl.config(text="●  Ouvindo (local)", fg="#ff5050")
            self._sub_lbl.config(text="fale seu pedido…", fg="#9a4040")
        elif kind == "processing":
            self._show()
            self._main_lbl.config(text="⧗  transcrevendo…", fg="#e0a000")
            self._sub_lbl.config(text="processando local", fg="#806020")
        elif kind == "done":
            self._show()
            self._main_lbl.config(text="\U0001f3af  anotei", fg="#38c172")
            self._sub_lbl.config(text=(text or "")[:52], fg="#206040")
            self._schedule_hide(3000)
        elif kind == "dup":
            self._show()
            self._main_lbl.config(text="↺  ja existia", fg="#7aa2ff")
            self._sub_lbl.config(text=(text or "")[:52], fg="#405080")
            self._schedule_hide(3000)
        elif kind == "error":
            self._show()
            self._main_lbl.config(text="⚠  " + (text or "erro"), fg="#e0a000")
            self._sub_lbl.config(text="veja voice.log", fg="#806020")
            self._schedule_hide(3500)
        elif kind == "hide":
            self._do_hide()

    def run(self):
        self.root.mainloop()


# ---------------------------------------------------------------------
# VAD por energia (RMS) - sem dependencia nativa (evita compilador C).
# ---------------------------------------------------------------------
def _rms(frame):
    import numpy as np
    if frame.size == 0:
        return 0.0
    x = frame.astype(np.float32)
    return float(np.sqrt(np.mean(x * x)))


def record_until_silence(cfg, ui):
    """Grava do mic ate ~2s de silencio (apos comecar a fala). Retorna
    ndarray int16 mono ou None (nada dito / erro)."""
    import numpy as np
    import sounddevice as sd

    sr = int(cfg["sample_rate"])
    frame_len = int(sr * 0.03)  # 30ms
    silence_frames_needed = max(1, int(cfg["silence_ms"] / 30))
    max_frames = max(1, int(cfg["max_record_ms"] / 30))
    start_timeout_frames = max(1, int(cfg["start_timeout_ms"] / 30))

    collected = []
    speech_started = False
    silence_run = 0
    frames_seen = 0

    ui.post("listening")
    try:
        with sd.InputStream(samplerate=sr, channels=1, dtype="int16",
                            blocksize=frame_len) as stream:
            # Calibra o ruido ambiente nos primeiros ~400ms.
            ambient = []
            for _ in range(max(1, int(0.4 * sr / frame_len))):
                data, _ = stream.read(frame_len)
                ambient.append(_rms(data[:, 0]))
            noise = (sum(ambient) / len(ambient)) if ambient else 60.0
            threshold = max(noise * 3.0, 300.0)
            log("VAD: ruido=%.0f limiar=%.0f" % (noise, threshold))

            while True:
                data, _ = stream.read(frame_len)
                frame = data[:, 0]
                collected.append(frame.copy())
                frames_seen += 1
                level = _rms(frame)

                if level > threshold:
                    speech_started = True
                    silence_run = 0
                elif speech_started:
                    silence_run += 1

                if speech_started and silence_run >= silence_frames_needed:
                    break
                if not speech_started and frames_seen >= start_timeout_frames:
                    log("nenhuma fala detectada; abortando captura")
                    return None
                if frames_seen >= max_frames:
                    log("teto de gravacao atingido")
                    break
    except Exception as e:
        log("erro na captura de audio: %s" % e)
        return None

    if not collected:
        return None
    audio = np.concatenate(collected)
    if audio.size < int(0.3 * sr):  # < 300ms de audio util
        return None
    return audio


# ---------------------------------------------------------------------
# Transcricao: whisper-cli.exe local (processo do usuario -> sem Deny).
# ---------------------------------------------------------------------
def _safe_rm(p):
    try:
        if p and os.path.exists(p):
            os.remove(p)
    except Exception:
        pass


def transcribe(cfg, audio):
    import numpy as np  # noqa: F401  (audio ja e ndarray)
    sr = int(cfg["sample_rate"])
    exe = cfg.get("whisper_exe", "")
    model = cfg.get("whisper_model", "")
    if not exe or not os.path.exists(exe):
        log("whisper_exe ausente/invalido: %r" % exe)
        return None
    if not model or not os.path.exists(model):
        log("whisper_model ausente/invalido: %r" % model)
        return None

    tmpd = tempfile.gettempdir()
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    base = os.path.join(tmpd, "sbvoice-" + stamp)
    wav = base + ".wav"
    txt = base + ".txt"
    try:
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes(audio.tobytes())
    except Exception as e:
        log("erro gravando wav temporario: %s" % e)
        _safe_rm(wav)
        return None

    args = [exe, "-m", model, "-f", wav,
            "-t", str(cfg.get("whisper_threads", 8)),
            "-otxt", "-of", base, "-nt"]
    lang = cfg.get("whisper_lang")
    if lang and lang != "auto":
        args += ["-l", lang]

    try:
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=180)
    except Exception as e:
        log("whisper falhou: %s" % e)
        _safe_rm(wav)
        _safe_rm(txt)
        return None

    text = ""
    if os.path.exists(txt):
        try:
            with open(txt, "r", encoding="utf-8") as f:
                text = " ".join(f.read().split()).strip()
        except Exception as e:
            log("erro lendo saida do whisper: %s" % e)
    _safe_rm(wav)
    _safe_rm(txt)
    return text or None


# ---------------------------------------------------------------------
# Extracao de campos via llama local (mesmo template do agente digitado).
# ---------------------------------------------------------------------
def _parse_json_obj(s):
    """Extrai o primeiro objeto {..} balanceado de um texto."""
    if not s:
        return None
    start = s.find("{")
    if start < 0:
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(s)):
        c = s[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(s[start:i + 1])
                    except Exception:
                        return None
    return None


def _clean(v):
    s = ("" if v is None else str(v)).strip()
    return "" if s.lower() == "null" else s


def extract_fields(cfg, text):
    """texto -> campos estruturados. Fallback: assunto = texto cru."""
    pf = cfg.get("prompt_file", "")
    if not pf or not os.path.exists(pf):
        log("prompt de criacao ausente; usando texto cru")
        return {"assunto": text}
    try:
        with open(pf, "r", encoding="utf-8") as f:
            system = f.read()
    except Exception as e:
        log("erro lendo prompt: %s" % e)
        return {"assunto": text}

    now = datetime.datetime.now()
    system = system.replace("{{HOJE}}", now.strftime("%d/%m/%Y"))
    system = system.replace("{{HORA}}", now.strftime("%H:%M"))

    body = json.dumps({
        "model": "local-model",
        "temperature": 0,
        "max_tokens": 400,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": text},
        ],
    }).encode("utf-8")

    try:
        req = urllib.request.Request(
            cfg["llama_url"].rstrip("/") + "/v1/chat/completions",
            data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=int(cfg.get("llama_timeout_s", 120))) as r:
            resp = json.loads(r.read().decode("utf-8"))
        content = resp["choices"][0]["message"]["content"]
    except Exception as e:
        log("extracao (llama) falhou, usando texto cru: %s" % e)
        return {"assunto": text}

    j = _parse_json_obj(content)
    if not j:
        log("JSON da extracao invalido, usando texto cru")
        return {"assunto": text}

    return {
        "assunto": _clean(j.get("assunto")) or text,
        "pessoa": _clean(j.get("pessoa")),
        "proxima_acao": _clean(j.get("proxima_acao")),
        "dueDate": _clean(j.get("prazo")),
        "status": _clean(j.get("status")) or "fazer",
        "prioridade": _clean(j.get("prioridade")) or "media",
        "notas": _clean(j.get("notas")),
    }


# ---------------------------------------------------------------------
# Cria o card no cockpit (POST /api/task, origem=voz).
# ---------------------------------------------------------------------
def create_task(cfg, fields):
    payload = dict(fields)
    payload["origem"] = "voz"
    body = json.dumps(payload).encode("utf-8")
    try:
        req = urllib.request.Request(
            cfg["cockpit_url"].rstrip("/") + "/api/task",
            data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
            return r.getcode(), data
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read().decode("utf-8"))
        except Exception:
            data = {}
        return e.code, data
    except Exception as e:
        log("POST /api/task falhou: %s" % e)
        return 0, {}


# ---------------------------------------------------------------------
# Pipeline completo de uma captura (gatilho -> card).
# ---------------------------------------------------------------------
def handle_capture(cfg, ui):
    audio = record_until_silence(cfg, ui)
    if audio is None:
        ui.post("hide")
        return

    ui.post("processing")
    text = transcribe(cfg, audio)
    if not text:
        log("transcricao vazia")
        ui.post("error", "não entendi o áudio")
        return
    log("transcricao: %s" % text)

    fields = extract_fields(cfg, text)
    code, data = create_task(cfg, fields)
    assunto = fields.get("assunto", "")
    if code == 201:
        titulo = (data.get("titulo") or data.get("assunto") or assunto)
        log("criado: %s" % titulo)
        ui.post("done", titulo)
    elif code == 409:
        log("duplicado: %s" % assunto)
        ui.post("dup", assunto)
    else:
        log("falha ao criar card (code=%s)" % code)
        ui.post("error", "não consegui criar o card")


# ---------------------------------------------------------------------
# Wake word (openWakeWord). Opcional: se falhar, segue so com a hotkey.
# ---------------------------------------------------------------------
def try_load_wakeword(cfg):
    if not cfg.get("enable_wakeword", True):
        return None
    try:
        from openwakeword.model import Model
    except Exception as e:
        log("openWakeWord indisponivel; wake word desligada: %s" % e)
        return None

    # Resolve a lista de modelos: caminhos de arquivo (.onnx/.tflite) sao
    # validados e tornados absolutos; nomes pre-treinados passam direto.
    # (ConvertTo-Json do PS pode emitir 1 item como string, nao lista.)
    requested = cfg.get("wakeword_models") or []
    if isinstance(requested, str):
        requested = [requested]
    requested = list(requested)
    resolved = []
    for m in requested:
        ml = str(m).strip()
        if not ml:
            continue
        if ml.lower().endswith((".onnx", ".tflite")):
            p = ml if os.path.isabs(ml) else os.path.join(HERE, ml)
            if os.path.exists(p):
                resolved.append(p)
            else:
                log("modelo de wake word ausente, ignorando: %r" % p)
        else:
            resolved.append(ml)  # nome pre-treinado (ex.: 'hey_jarvis')

    if not resolved:
        # Sem modelos custom ainda: cai no pre-treinado pra wake word nao ficar morta.
        resolved = [cfg.get("wakeword", "hey_jarvis")]
        log("sem modelos custom; usando pre-treinado '%s' (Ctrl+Shift+B funciona normal)"
            % resolved[0])

    framework = cfg.get("wakeword_framework", "onnx")
    try:
        oww = Model(wakeword_models=resolved, inference_framework=framework)
        names = ", ".join(os.path.basename(str(x)) for x in resolved)
        log("wake word ativa: %s (limiar %.2f)" % (names, float(cfg["wakeword_threshold"])))
        return oww
    except Exception as e:
        log("falha carregando modelo(s) de wake word %s; wake word desligada: %s"
            % (resolved, e))
        return None


# ---------------------------------------------------------------------
# Worker principal: aguarda gatilho (wake word + hotkey) e captura.
# Roda em thread separado; o mic so e aberto durante a espera/captura.
# ---------------------------------------------------------------------
def main_worker(cfg, ui, trigger_event):
    oww = try_load_wakeword(cfg)
    sr = int(cfg["sample_rate"])
    chunk = 1280  # 80ms @ 16k, tamanho recomendado pelo openWakeWord
    thr = float(cfg["wakeword_threshold"])

    while True:
        triggered_by = None

        if oww is None:
            # So hotkey: bloqueia ate o evento, sem segurar o mic.
            trigger_event.wait()
            trigger_event.clear()
            triggered_by = "hotkey"
        else:
            # Wake word ligada: ouve o mic em frames e tambem checa a hotkey.
            try:
                import sounddevice as sd
                with sd.InputStream(samplerate=sr, channels=1, dtype="int16",
                                    blocksize=chunk) as stream:
                    while True:
                        if trigger_event.is_set():
                            trigger_event.clear()
                            triggered_by = "hotkey"
                            break
                        data, _ = stream.read(chunk)
                        pred = oww.predict(data[:, 0])
                        score = max(pred.values()) if pred else 0.0
                        if score >= thr:
                            triggered_by = "wake"
                            log("wake word detectada (score=%.2f)" % score)
                            try:
                                oww.reset()  # zera o buffer p/ nao redisparar
                            except Exception:
                                pass
                            break
            except Exception as e:
                log("erro na fase de espera (wake): %s" % e)
                time.sleep(1.0)
                continue

        log("gatilho: %s" % triggered_by)
        try:
            handle_capture(cfg, ui)
        except Exception as e:
            log("erro no handle_capture: %s" % e)
            ui.post("error", "erro interno")
        # Descarta qualquer gatilho acumulado durante a captura.
        trigger_event.clear()


# ---------------------------------------------------------------------
# Icone de bandeja do sistema (pystray). Confirma ao usuario que o
# listener esta vivo sem abrir janela alguma. Roda em background thread.
# ---------------------------------------------------------------------
def start_tray():
    try:
        import pystray
        from PIL import Image as PILImage
    except ImportError:
        log("pystray/Pillow ausentes; icone de bandeja desativado (instale: pip install pystray Pillow)")
        return None

    png = os.path.join(os.path.dirname(HERE), "cockpit", "favicon-256.png")
    try:
        img = PILImage.open(png).resize((64, 64), PILImage.LANCZOS)
    except Exception:
        img = PILImage.new("RGBA", (64, 64), (14, 17, 23, 255))

    def on_quit(icon, _item):
        icon.stop()
        os._exit(0)

    menu = pystray.Menu(
        pystray.MenuItem("SecondBrain Voice", None, enabled=False),
        pystray.MenuItem("Ctrl+Shift+B → capturar", None, enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Sair", on_quit),
    )

    icon = pystray.Icon("secondbrain_voice", img, "SecondBrain Voice", menu)
    try:
        icon.run_detached()
        log("icone de bandeja ativo (clique direito -> Sair para encerrar)")
    except Exception as e:
        log("bandeja falhou: %s" % e)
        return None
    return icon


# ---------------------------------------------------------------------
# Hotkey global via pynput (sem admin).
# ---------------------------------------------------------------------
def start_hotkey(cfg, trigger_event):
    try:
        from pynput import keyboard
    except Exception as e:
        log("pynput indisponivel; hotkey desligada: %s" % e)
        return None
    hk = cfg.get("hotkey", "<ctrl>+<shift>+b")

    def on_activate():
        log("hotkey acionada")
        trigger_event.set()

    try:
        listener = keyboard.GlobalHotKeys({hk: on_activate})
        listener.daemon = True
        listener.start()
        log("hotkey global registrada: %s" % hk)
        return listener
    except Exception as e:
        log("falha registrando hotkey %s: %s" % (hk, e))
        return None


def main():
    cfg = load_config()
    guard = acquire_single_instance()
    if guard is None:
        log("outra instancia ja esta rodando; saindo.")
        return

    log("=== SecondBrain voice listener iniciado ===")
    ui = Indicator()

    start_tray()

    trigger_event = threading.Event()
    start_hotkey(cfg, trigger_event)

    worker = threading.Thread(target=main_worker, args=(cfg, ui, trigger_event),
                              daemon=True)
    worker.start()

    # tkinter precisa do thread principal.
    ui.run()


if __name__ == "__main__":
    main()

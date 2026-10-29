"""Local models for Referee's claim checks, so nothing leaves the computer and nothing costs money.

Chosen in Settings (~/.referee/config.json, "ai_provider"):
    ollama:  a model run by Ollama (ollama.com) on this computer; the model is "ollama_model".
             The default when Ollama is installed.
    claude:  Anthropic's API, with the person's own key: the most accurate, and the only one
             used for comparing theorems with papers.

Measured on 100 SciFact pairs at Referee's threshold of 0.7 (eval_scifact.py): Claude precision
0.96, recall 0.70; Qwen 3 14B 0.91 and 0.74 (~12 s a check on an M1, answering with sentence
numbers); Qwen 2.5 7B 0.90 and 0.66 (~5 s).
Apple's on-device model (0.64) and a DeBERTa entailment model (~0.5) were tried and left out.
"""

import json
import os
import statistics
import time
from pathlib import Path
from typing import Dict, Optional

import requests

import paths

CONFIG = Path.home() / ".referee" / "config.json"
OLLAMA = "http://127.0.0.1:11434"   # this computer only
RECOMMENDED = ["qwen2.5:7b", "qwen3:14b"]  # 7B: precision 0.90 at ~5 s and ~4.6 GB; 14B: 0.91 at ~12 s and ~9.3 GB
TIMEOUT = 120  # seconds: ~17 s a check for Qwen 3 14B on an M1, longer the first time it loads


def _config() -> Dict:

    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def ollama_models() -> Optional[list]:

    """
    The models Ollama has downloaded, or None if Ollama isn't running.
    """

    try:
        return [m["name"] for m in requests.get(f"{OLLAMA}/api/tags", timeout=2).json().get("models", [])]
    except (requests.RequestException, ValueError):
        return None


def settings() -> Dict:

    config = _config()
    chosen = os.environ.get("REFEREE_AI_PROVIDER") or config.get("ai_provider")
    model = os.environ.get("REFEREE_OLLAMA_MODEL") or config.get("ollama_model")
    if not chosen or (chosen == "ollama" and not model):
        # Not chosen yet: Claude. A model Ollama has is kept as the offline backup, never switched to
        # automatically (local models on most Macs were much less accurate; decided 24 Oct 2026).
        models = ollama_models() or []
        best = next((m for m in RECOMMENDED if m in models), models[0] if models else None)
        if not chosen:
            chosen = "claude"
        model = model or best or RECOMMENDED[0]
    return {"provider": chosen, "ollama_model": model}


def provider() -> str:

    return settings()["provider"]


TIMINGS = paths.data("check-times.json")


def record_time(model: str, seconds: float) -> None:

    """
    How long a check took on this computer, keeping the last 20 per model, so Settings can say
    how long checks take here rather than on the Mac they were measured on.
    """

    try:
        times = json.loads(TIMINGS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        times = {}
    times[model] = (times.get(model, []) + [round(seconds, 2)])[-20:]
    try:
        TIMINGS.write_text(json.dumps(times), encoding="utf-8")
    except OSError:
        pass


def measured(model: str) -> Optional[Dict]:

    """
    The typical time for a check with this model on this computer, once there are a few.
    The first check after loading is left out: it includes loading the model.
    """

    try:
        times = json.loads(TIMINGS.read_text(encoding="utf-8")).get(model, [])
    except (OSError, ValueError):
        return None
    if len(times) < 4:
        return None
    return {"seconds": round(statistics.median(times[1:]), 1), "checks": len(times)}


# Offline fallback: with Claude or ChatGPT chosen and no internet, the model on this Mac checks
# instead (if Ollama has one), until the connection is back. Checked at most every 30 seconds.
_offline_until = 0.0
_last_check = (0.0, True)


def online() -> bool:

    global _last_check
    now = time.monotonic()
    if now < _offline_until:
        return False
    if now - _last_check[0] < 30:
        return _last_check[1]
    import socket
    try:
        socket.create_connection(("api.anthropic.com", 443), timeout=1.5).close()
        up = True
    except OSError:
        up = False
    _last_check = (now, up)
    return up


def went_offline() -> None:

    """A request just failed to connect: treat the internet as gone for the next 30 seconds."""
    global _offline_until
    _offline_until = time.monotonic() + 30


def fallback_model() -> Optional[str]:

    """The model on this Mac to fall back to: the one chosen before, else a recommended one Ollama has."""
    models = ollama_models() or []
    chosen = settings().get("ollama_model")
    if chosen in models:
        return chosen
    return next((m for m in RECOMMENDED if m in models), None)


def ask_ollama(system: str, user: str, schema: Dict, model: Optional[str] = None) -> Optional[Dict]:

    model = model or settings()["ollama_model"]
    started = time.monotonic()
    try:
        response = requests.post(f"{OLLAMA}/api/chat", timeout=TIMEOUT, json={
            "model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "format": schema,          # Ollama keeps the reply to this JSON schema
            "stream": False,
            "think": False,            # thinking models (Qwen 3) took ~3 minutes a check on an M1
            "keep_alive": "10m",       # loaded through a writing session (reloading Qwen 3 14B took ~11 s), then its memory is freed
            "options": {"temperature": 0},
        })
        response.raise_for_status()
        reply = json.loads(response.json()["message"]["content"])
        record_time(model, time.monotonic() - started)
        return reply
    except (requests.RequestException, KeyError, ValueError):
        return None


def status() -> Dict:

    """
    What's chosen, and what Ollama has on this computer, for Settings.
    """

    models = ollama_models()
    chosen = settings()
    return {**chosen, "ollama": models is not None, "ollama_models": models or [], "recommended": RECOMMENDED,
            "measured": measured(chosen["ollama_model"])}

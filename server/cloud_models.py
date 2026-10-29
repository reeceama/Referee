"""Another AI provider for Referee's checks, with the person's own API key: OpenAI (the models
behind ChatGPT). Claude stays in verify.py, as the benchmark.

The key is kept in the system's password store, like the Anthropic key. A ChatGPT subscription
doesn't include API access: OpenAI's API is paid separately (platform.openai.com). OpenAI doesn't
train on API data by default. Gemini was left out: on its free tier Google may use what's sent to
improve its models, and Referee can't tell a free key from a paid one.

Each call sends the same instructions and prompt as Claude gets and asks for a reply in the
same JSON shape, so verify.py and statements.py treat every provider alike.
"""

import copy
import json
import os
from typing import Dict, Optional

import keyring
import requests

SERVICE = "Referee"
# The cheapest model of each provider's newest generation (October 2026). Names taken from
# pricing pages, not yet confirmed against each API's own model list.
PROVIDERS = {
    "openai": {"name": "OpenAI", "account": "openai-api-key", "env": "OPENAI_API_KEY", "model": "gpt-5.5-nano",
               # For comparing theorems with papers: the larger model, as careful as Claude Sonnet needs to be.
               "theorem_model": "gpt-5.5"},
}
TIMEOUT = 60


def key(provider: str) -> Optional[str]:

    info = PROVIDERS[provider]
    try:
        saved = keyring.get_password(SERVICE, info["account"])
    except keyring.errors.KeyringError:
        saved = None
    return saved or os.environ.get(info["env"]) or None


def model(provider: str) -> str:

    # REFEREE_OPENAI_MODEL, for trying another model without a release.
    return os.environ.get(f"REFEREE_{provider.upper()}_MODEL") or PROVIDERS[provider]["model"]


def _inline(schema: Dict) -> Dict:

    """
    A JSON schema with its $defs written in place, so it needs no $ref.
    """

    schema = copy.deepcopy(schema)
    defs = schema.pop("$defs", {})

    def walk(node):
        if isinstance(node, dict):
            if "$ref" in node:
                return walk(copy.deepcopy(defs[node["$ref"].split("/")[-1]]))
            return {k: walk(v) for k, v in node.items() if k not in ("title", "default")}
        if isinstance(node, list):
            return [walk(v) for v in node]
        return node

    return walk(schema)


def ask(provider: str, system: str, user: str, schema: Dict, use_model: Optional[str] = None) -> Optional[Dict]:

    """
    The provider's reply as a dict in the schema's shape, or None (no key, no answer, or a
    reply that isn't JSON).
    """

    secret = key(provider)
    if not secret:
        return None
    try:
        if provider == "openai":
            response = requests.post("https://api.openai.com/v1/chat/completions", timeout=TIMEOUT,
                                     headers={"Authorization": f"Bearer {secret}"}, json={
                "model": use_model or model(provider),
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "response_format": {"type": "json_schema",
                                    "json_schema": {"name": "reply", "schema": _inline(schema), "strict": False}},
            })
            response.raise_for_status()
            return json.loads(response.json()["choices"][0]["message"]["content"])
    except (requests.RequestException, KeyError, IndexError, ValueError):
        return None
    return None


def connect(provider: str, secret: str) -> Dict:

    """
    Checks a key with the provider (listing its models costs nothing), then stores it.
    """

    secret = secret.strip()
    name = PROVIDERS[provider]["name"]
    try:
        response = requests.get("https://api.openai.com/v1/models", timeout=15, headers={"Authorization": f"Bearer {secret}"})
    except requests.RequestException:
        return {"ok": False, "reason": f"Couldn't reach {name}. Check your connection."}
    if response.status_code in (400, 401, 403):
        return {"ok": False, "reason": f"{name} didn't accept this key."}
    if not response.ok:
        return {"ok": False, "reason": f"{name} answered {response.status_code}."}
    keyring.set_password(SERVICE, PROVIDERS[provider]["account"], secret)
    return {"ok": True}


def disconnect(provider: str) -> None:

    try:
        keyring.delete_password(SERVICE, PROVIDERS[provider]["account"])
    except keyring.errors.KeyringError:
        pass


def status() -> Dict:

    return {p: {"connected": bool(key(p)), "model": model(p)} for p in PROVIDERS}

"""The person's Anthropic API key, kept in the system's password store.

macOS Keychain or Windows Credential Manager, through the keyring library, so the key is
never in a plain text file. A key in server/.env (or the ANTHROPIC_API_KEY environment
variable) still works, for anyone who prefers that; a key saved from the app takes priority.
"""

import os
from pathlib import Path
from typing import Dict, Optional

import importlib


class _Lazy:
    # Anthropic's library is loaded on first use: importing it took about a second of the server's start.
    def __getattr__(self, name):
        return getattr(importlib.import_module("anthropic"), name)


anthropic = _Lazy()
import keyring
from dotenv import load_dotenv

import paths

SERVICE, ACCOUNT = "Referee", "anthropic-api-key"

load_dotenv()                     # server/.env, when running from the code folder
load_dotenv(paths.data(".env"))   # or a .env in Referee's data folder


def get() -> Optional[str]:

    try:
        saved = keyring.get_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        saved = None
    return saved or os.environ.get("ANTHROPIC_API_KEY") or None


def signed_in() -> bool:

    """
    Whether the person has signed in with Anthropic's ant command-line tool on this Mac. Anthropic's
    library then finds that sign-in itself (and renews it), so no key is needed.
    """

    folder = Path.home() / ".config" / "anthropic" / "credentials"
    return folder.is_dir() and any(folder.glob("*.json"))


def status() -> Dict:

    """
    Whether there's a key and where it's from, showing only its last four characters.
    """

    try:
        saved = keyring.get_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        saved = None
    key = get()
    if not key:
        # No key: an ant sign-in serves instead.
        return {"has_key": True, "source": "ant", "ends": ""} if signed_in() else {"has_key": False}
    return {"has_key": True, "source": "password store" if saved else "env", "ends": key[-4:]}


def save(key: str) -> Dict:

    """
    Checks the key with Anthropic, then stores it. Returns {"ok": True} or {"ok": False, "reason"}.
    """

    key = key.strip()
    if not key.startswith("sk-ant-"):
        return {"ok": False, "reason": "That doesn't look like an Anthropic API key. They start with sk-ant-."}
    try:
        anthropic.Anthropic(api_key=key, timeout=10.0).models.list(limit=1)
    except anthropic.AuthenticationError:
        return {"ok": False, "reason": "Anthropic didn't accept this key. Check it was copied in full."}
    except anthropic.APIError as error:
        return {"ok": False, "reason": f"Couldn't check the key with Anthropic ({type(error).__name__}). Try again in a moment."}
    try:
        keyring.set_password(SERVICE, ACCOUNT, key)
    except keyring.errors.KeyringError as error:
        return {"ok": False, "reason": f"Couldn't save the key in the system's password store ({error})."}
    return {"ok": True, **status()}


def remove() -> Dict:

    try:
        keyring.delete_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        pass
    return status()

"""The pairing code for the Google Docs add-on: a random code kept in the system's password
store, shown in Referee's Settings and pasted into the add-on once. Requests from Google's
script pages are only answered with it, so another Apps Script page can't read your Referee.
"""

import hmac
import secrets

import keyring

SERVICE, ACCOUNT = "Referee", "google-docs-pairing"


def code() -> str:

    try:
        saved = keyring.get_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        saved = None
    return saved or renew()


def renew() -> str:

    fresh = secrets.token_urlsafe(18)
    try:
        keyring.set_password(SERVICE, ACCOUNT, fresh)
    except keyring.errors.KeyringError:
        pass
    return fresh


def matches(given: str) -> bool:

    return bool(given) and hmac.compare_digest(given, code())

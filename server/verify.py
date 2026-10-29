import difflib
import hashlib
import json
import re
import sys
import threading
from collections import Counter, OrderedDict
from pathlib import Path
from typing import Literal, Optional

import importlib


class _Lazy:
    # Anthropic's library is loaded on first use: importing it took about a second of the server's start.
    def __getattr__(self, name):
        return getattr(importlib.import_module("anthropic"), name)


anthropic = _Lazy()
from pydantic import BaseModel

import api_key
import cloud_models
import local_models
import paths


class Client:

    """
    The Anthropic client, rebuilt whenever the person's saved API key changes.
    """

    def __init__(self):

        self.key = None
        self.client = None
        self.lock = threading.Lock()  # checks run in parallel: build the client once, not half-built

    def get(self):

        key = api_key.get()
        with self.lock:
            if key != self.key:
                self.client = anthropic.Anthropic(api_key=key, timeout=10.0) if key else None  # never leave the writer waiting
                self.key = key
            return self.client


anthropic_client = Client()

MODEL = "claude-haiku-5-5"
THINKING = True  # ~200 extra output tokens a check, but SciFact precision at 0.7 falls from 0.96 to 0.81 without it
THRESHOLD = 0.7  # SciFact, current prompt: precision 0.96 (95% CI 0.87-0.99), recall 0.70; 0.6 gave 0.93 and 0.76
# Calibrated in eval_wording.py (margin 0.32 between copying and own words on 21 sentences):
NGRAM = 3  # length of the word runs compared when checking for copying
STOCK_MIN = 4  # a run in at least this many different sentences of the research is stock phrasing
TOO_CLOSE = 0.3  # share of the sentence's distinctive runs found in the passage
MISQUOTE_MIN = 0.3  # a non-matching quotation is only a misquote if this much of it matches the reading
MIN_QUOTE_WORDS = 4  # shortest supporting quote accepted from the verifier

SYSTEM_PROMPT = """You check whether a sentence someone has written is backed by sources they have read.

You will be given one sentence and one or more numbered passages. Decide whether any passage supports or contradicts the specific claim in the sentence.

Labels:
- "supports": the passage directly backs this exact claim, including its strength and scope (e.g. "strongly", "always", "most").
- "contradicts": the passage directly states something that goes against the claim, including evidence that the effect is much weaker or absent.
- "neutral": anything else. Being about the same topic is NOT support. Partial or indirect relevance is neutral.

Rules:
- Pick the single best passage, or none if all are neutral.
- If passages disagree, judge by the one that addresses the claim most directly. A claim about the
  general case is not contradicted by an exception or a qualification (e.g. "not in every country").
- "quote" must be copied word for word from the chosen passage: the shortest span that justifies your label.
- "passage" is the chosen passage's number, or null if none.
- "confidence" is how sure you are of the label, from 0 to 1.
- "together_with" is the number of a second passage, from a different source, when the claim only
  holds by combining the two (each backs part of it), or null. Use it only when no single passage
  supports the whole claim.
- "disagrees" is the number of another passage that points the opposite way to your chosen one
  (supports where it contradicts, or the reverse), or null if none does."""


class Verdict(BaseModel):
    passage: Optional[int]
    label: Literal["supports", "contradicts", "neutral"]
    confidence: float
    quote: str
    disagrees: Optional[int] = None
    together_with: Optional[int] = None


# Local models write slowly (about 6 tokens a second for Qwen 3 14B on an M1), and copying the
# quote out was most of each reply. So for them each passage's sentences are numbered, the model
# answers with a number, and the quote is taken from the passage: shorter, and always exact.
LOCAL_PROMPT = SYSTEM_PROMPT.replace(
    '''- "quote" must be copied word for word from the chosen passage: the shortest span that justifies your label.''',
    '''- Each passage's sentences are numbered like [2.3] (passage 2, sentence 3). "evidence" is the number of
  the sentence in the chosen passage that best justifies your label, such as "2.3", or "" if neutral.''')


class LocalVerdict(BaseModel):
    passage: Optional[int]
    label: Literal["supports", "contradicts", "neutral"]
    confidence: float
    evidence: str
    disagrees: Optional[int] = None
    together_with: Optional[int] = None


def numbered(candidates):
    """Each passage split into sentences labelled [passage.sentence], and the sentences by label."""
    blocks, sentences = [], {}
    for i, candidate in enumerate(candidates, start=1):
        parts = [p.strip() for p in SENTENCE_END_LOCAL.split(candidate["text"]) if p.strip()]
        for j, part in enumerate(parts, start=1):
            sentences[f"{i}.{j}"] = part
        blocks.append(f"Passage {i}:\n" + " ".join(f"[{i}.{j}] {part}" for j, part in enumerate(parts, start=1)))
    return "\n\n".join(blocks), sentences


SENTENCE_END_LOCAL = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\"“\[])")


def ask_local(sentence, candidates, use_cache=True, model=None):
    """A verdict from the local model, in Claude's shape, with the quote taken from the passage."""
    passages, sentences = numbered(candidates)
    user = f"Sentence:\n{sentence}\n\n{passages}"
    model = model or local_models.settings()["ollama_model"]
    key = cache.key(LOCAL_PROMPT, user) + f":ollama:{model}"
    cached = cache.get(key) if use_cache else None
    if cached is not None:
        return cached
    reply = local_models.ask_ollama(LOCAL_PROMPT, user, LocalVerdict.model_json_schema(), model=model)
    try:
        local = LocalVerdict(**reply) if reply else None
    except (TypeError, ValueError):
        return None
    if local is None:
        return None
    label = local.evidence.strip().strip("[]")
    quote = sentences.get(label, "")
    number, _, line = label.partition(".")
    if quote and len(quote.split()) < MIN_QUOTE_WORDS and line.isdigit():
        # A very short sentence: quote it with the one after, so the quote shows enough.
        quote = f"{quote} {sentences.get(f'{number}.{int(line) + 1}', '')}".strip()
    passage = local.passage if local.passage else (int(number) if quote and number.isdigit() else None)
    verdict = Verdict(passage=passage, label=local.label, confidence=local.confidence, quote=quote,
                      disagrees=local.disagrees, together_with=local.together_with)
    cache.put(key, verdict)
    return verdict


def ask_cloud(provider, user, use_cache=True):
    """A verdict from OpenAI, with the same prompt and reply shape as Claude's."""
    key = cache.key(SYSTEM_PROMPT, user) + f":{provider}:{cloud_models.model(provider)}"
    cached = cache.get(key) if use_cache else None
    if cached is not None:
        return cached
    reply = cloud_models.ask(provider, SYSTEM_PROMPT, user, Verdict.model_json_schema())
    try:
        verdict = Verdict(**reply) if reply else None
    except (TypeError, ValueError):
        return None
    if verdict is not None:
        cache.put(key, verdict)
    return verdict


class VerdictCache:

    """
    Verdicts already paid for. Re-checking the same sentence against the same passages
    (a reload, a re-check, the same sentence in two documents) reuses the earlier answer.
    Saved to disk, so a restart doesn't pay for them again.
    """

    def __init__(self, size=2000, path=None):

        self.size = size
        self.path = path
        self.verdicts = OrderedDict()
        if path is not None:
            try:
                for key, verdict in json.loads(Path(path).read_text(encoding="utf-8")):
                    self.verdicts[key] = Verdict(**verdict)
            except (OSError, ValueError, TypeError):
                pass

    def key(self, system, user):

        return hashlib.sha256(f"{MODEL}\n{system}\n{user}".encode()).hexdigest()

    def get(self, key):

        if key in self.verdicts:
            self.verdicts.move_to_end(key)
        return self.verdicts.get(key)

    def put(self, key, verdict):

        self.verdicts[key] = verdict
        self.verdicts.move_to_end(key)
        while len(self.verdicts) > self.size:
            self.verdicts.popitem(last=False)
        if self.path is not None:
            items = [[k, v.model_dump()] for k, v in self.verdicts.items()]
            Path(self.path).write_text(json.dumps(items), encoding="utf-8")


cache = VerdictCache(path=paths.data("verdicts.json"))


def call_llm(system, user, use_cache=True):
    """Ask Claude for a verdict. Structured outputs guarantee the reply matches Verdict.

    use_cache=False always asks the model, e.g. when measuring run-to-run variation.
    """
    key = cache.key(system, user)
    cached = cache.get(key) if use_cache else None
    if cached is not None:
        return cached
    client = anthropic_client.get()
    if client is None:
        print("[verify] No Anthropic API key: add one in Referee's settings.")
        return None
    response = client.messages.parse(
        model=MODEL,
        max_tokens=1500,  # with thinking on, replies used up to ~700 tokens in testing
        # The instructions and reply format (~1,000 tokens) are the same on every check, so
        # Anthropic caches them: later checks read them at a tenth of the price.
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": user}],
        output_format=Verdict,
        **({} if THINKING else {"thinking": {"type": "disabled"}}),
    )
    if response.parsed_output is not None:
        cache.put(key, response.parsed_output)
    return response.parsed_output


SENTENCE_END = re.compile(r"(?<=[.!?])\s+")
QUOTED = re.compile(r'"([^"]+)"|“([^”]+)”')
GAPS = re.compile(r"\.\.\.|…|\[[^\]]*\]")  # ellipses and [editorial insertions]


def normalise(text):
    """Lower case, straight quotes and apostrophes, single spaces, no edge punctuation."""
    text = text.lower().translate(str.maketrans("‘’“”", "''\"\""))
    return " ".join(text.split()).strip(" .,;:!?")


def split_quotes(sentence):
    """Return (quoted strings, the sentence with them removed)."""
    quotes = [a or b for a, b in QUOTED.findall(sentence)]
    return quotes, QUOTED.sub(" ", sentence)


def quote_in_source(quote, source):
    """True if a quotation appears word for word in the source.

    Ellipses and [square-bracketed] insertions mark gaps: each piece between
    them must appear in the source, in order.
    """
    source = normalise(source)
    position = 0
    for piece in GAPS.split(quote):
        piece = normalise(piece)
        if not piece:
            continue
        found = source.find(piece, position)
        if found == -1:
            return False
        position = found + len(piece)
    return True


def ngrams(text, n=None):
    """The set of n-word runs in the text."""
    n = n or NGRAM
    words = re.findall(r"[a-z0-9']+", normalise(text))
    return {tuple(words[i:i + n]) for i in range(len(words) - n + 1)}


def stock_phrases(texts, n=None, min_count=None):
    """Word runs that recur across different sentences of the research.

    A run like "the mediterranean diet is associated" that appears all over the
    reading is the topic's standard wording, not copying from one passage.
    Counted over distinct sentences because stored passages overlap.
    """
    min_count = min_count or STOCK_MIN
    sentences = {normalise(s) for text in texts for s in SENTENCE_END.split(text)}
    counts = Counter(run for s in sentences for run in ngrams(s, n))
    return {run for run, count in counts.items() if count >= min_count}


def research_passages():
    """Every passage captured so far, if the server has loaded the store (empty in tests)."""
    store = sys.modules.get("store")
    return [p["text"] for p in getattr(store, "_passages", [])]


def copied_share(text, source, n=None, stock=frozenset()):
    """Share of the text's distinctive n-word runs that also appear in the source (0 to 1)."""
    own = ngrams(text, n) - stock
    if not own:
        return 0.0
    return len(own & ngrams(source, n)) / len(own)


def is_misquote(quote, source):
    """The quotation isn't in the source word for word, yet clearly comes from it.

    A quotation that resembles nothing in the source probably comes from reading that
    wasn't captured, so it isn't flagged.
    """
    return not quote_in_source(quote, source) and copied_share(quote, source) >= MISQUOTE_MIN


def check_wording(sentence, passage, all_text=None, stock=frozenset()):
    """Quotes must match the source exactly; everything else must not copy the passage too closely.

    Quotations are checked against all_text (every candidate passage) when given,
    since a quotation may come from a neighbouring passage. Stock phrases are
    ignored when measuring copying.
    """
    quotes, unquoted = split_quotes(sentence)
    return {
        "misquote": any(is_misquote(q, all_text or passage) for q in quotes),
        "too_close": copied_share(unquoted, passage, stock=stock) >= TOO_CLOSE,
    }


NUMBER = re.compile(r"\d[\d,]*(?:\.\d+)?")


def wrong_numbers(sentence, passage):
    """Figures and years in the sentence that the supporting passage doesn't contain.

    Only checked when the passage gives figures of its own, so a sentence adding a date
    from elsewhere isn't flagged against a passage with no numbers at all.
    """
    found = {n.replace(",", "") for n in NUMBER.findall(passage)}
    if not found:
        return []
    # Numbers that point somewhere rather than state a figure aren't checked: "Definition 4.42",
    # "Thm. 2.12(c)", "F1", "(4.2)", "p. 17", "Section 4", "Question 2", and indices like v_1 or c_n.
    # Nor maths ($n-1$, $\\dim V = 2$): a formula isn't a figure the source should print as it stands.
    sentence = REFERENCES.sub(" ", re.sub(r"\$[^$]*\$|\\\(.*?\\\)", " ", sentence))
    return [n.rstrip(",") for n in NUMBER.findall(sentence) if n.replace(",", "") not in found]


REFERENCES = re.compile(
    r"\b(?:Def(?:inition)?|Defn|Thm|Theorem|Lem(?:ma)?|Prop(?:osition)?|Cor(?:ollary)?|Fact|Ex(?:ample)?|Exercise|Rem(?:ark)?"
    r"|Eq(?:uation)?|Fig(?:ure)?|Sec(?:tion)?|Ch(?:apter)?|Question|Q|Part|Step|Case|Lecture|Week|Problem|Appendix"
    r"|pp?|page)s?\.?\s*~?\s*\d+(?:\.\d+)*(?:\s*\([a-z]+\))?"
    r"|\b[A-Z]\d+\b"                      # F1, Q2, A3: labels
    r"|\(\d+(?:\.\d+)+\)"                 # (4.2): an equation number
    r"|[_^]\{?\d+\}?"                       # v_1, x^2 in LaTeX
    r"|(?<=[A-Za-z])\d+",                    # v1, x2 as plain text
    re.I)


def quote_changes(quote, source_text):
    """Where a quotation differs from the closest source wording, word by word."""
    wrote, said = quote.split(), source_text.split()
    clean = lambda w: normalise(w)
    matcher = difflib.SequenceMatcher(a=[clean(w) for w in wrote], b=[clean(w) for w in said], autojunk=False)
    blocks = [b for b in matcher.get_matching_blocks() if b.size]
    if not blocks:
        return []
    # Only compare against the stretch of source the quotation lines up with.
    start, end = blocks[0].b, blocks[-1].b + blocks[-1].size
    matcher.set_seq2([clean(w) for w in said[start:end]])
    said = said[start:end]
    return [{"wrote": " ".join(wrote[i1:i2]), "source": " ".join(said[j1:j2])}
            for tag, i1, i2, j1, j2 in matcher.get_opcodes() if tag != "equal"]


def misquote_marker(sentence, candidates):
    """A marker for a misquotation, even when the claim itself wasn't verified.

    The quote field holds the source sentence closest to what the person quoted,
    so the frontend can show what the source actually says.
    """
    all_text = " ".join(c["text"] for c in candidates)
    for quote in split_quotes(sentence)[0]:
        if not is_misquote(quote, all_text):
            continue
        best = max(candidates, key=lambda c: copied_share(quote, c["text"]))
        closest = max(SENTENCE_END.split(best["text"]), key=lambda s: copied_share(quote, s))
        changes = quote_changes(quote, closest)
        return {
            "source": best["source"],
            "passage": best["text"],
            "quote": closest,
            "confidence": 1.0,
            "label": "misquote",
            "changes": changes,
            "score": best.get("score"),
            "page": best.get("page"),
            "time": best.get("time"),
            "misquote": True,
            "too_close": False,
        }
    return None


def verify(sentence, candidates, threshold=THRESHOLD, use_cache=True):
    """Check a sentence against candidate passages.

    candidates: the top matches from store.search - [{"text", "source", "score"}, ...].
    Returns {"source", "passage", "quote", "confidence", "label", "score", "misquote", "too_close"}
    or None. label is "supports", "contradicts", or "misquote" (a quotation that doesn't match
    the source, on a claim that couldn't be verified).
    """
    if not candidates:
        return None
    return _verified(sentence, candidates, threshold, use_cache) or misquote_marker(sentence, candidates)


def _verified(sentence, candidates, threshold, use_cache=True):
    """Claude's verdict, if it confidently supports or contradicts the sentence."""
    passages = "\n\n".join(f"Passage {i}:\n{c['text']}" for i, c in enumerate(candidates, start=1))
    user = f"Sentence:\n{sentence}\n\n{passages}"

    try:
        chosen = local_models.provider()
        if chosen == "ollama":
            result = ask_local(sentence, candidates, use_cache)
        elif not local_models.online() and local_models.fallback_model():
            # Offline: the model on this Mac checks instead, until the connection is back.
            result = ask_local(sentence, candidates, use_cache, model=local_models.fallback_model())
        elif chosen in cloud_models.PROVIDERS:
            result = ask_cloud(chosen, user, use_cache)
        else:
            result = call_llm(SYSTEM_PROMPT, user, use_cache)
    except anthropic.APIConnectionError as e:
        print(f"[verify] couldn't reach Anthropic: {e}")
        local_models.went_offline()
        model = local_models.fallback_model()
        result = ask_local(sentence, candidates, use_cache, model=model) if model else None
    except anthropic.APIError as e:
        print(f"[verify] API error: {e}")  # shows in the uvicorn terminal
        return None
    if result is None:
        return None

    label = result.label
    confidence = result.confidence
    index = result.passage
    if label not in ("supports", "contradicts") or confidence < threshold:
        return None
    if not isinstance(index, int) or not 1 <= index <= len(candidates):
        return None

    chosen = candidates[index - 1]
    quote = result.quote
    # The quote must be real text from the source. An empty or tiny quote would pass a plain
    # "in" check ("" is in every string), so require a few words, and compare normalised text
    # so curly quotes or spacing differences don't reject a genuine quote.
    if len(quote.split()) < MIN_QUOTE_WORDS or normalise(quote) not in normalise(chosen["text"]):
        return None  # never show a quote that isn't really in the source

    # Mixed evidence: another passage in the reading points the other way.
    other = result.disagrees
    mixed = candidates[other - 1]["source"] if isinstance(other, int) and 1 <= other <= len(candidates) and other != index else None

    pair = result.together_with
    together = (candidates[pair - 1] if label == "supports" and isinstance(pair, int)
                and 1 <= pair <= len(candidates) and pair != index else None)

    all_text = " ".join(c["text"] for c in candidates)
    misquoted = [q for q in split_quotes(sentence)[0] if is_misquote(q, all_text)]
    closest = max(SENTENCE_END.split(all_text), key=lambda s: copied_share(misquoted[0], s)) if misquoted else ""

    return {
        "source": chosen["source"],
        "mixed": mixed,
        "changes": quote_changes(misquoted[0], closest) if misquoted else [],
        "together_with": {"source": together["source"], "page": together.get("page"), "time": together.get("time")} if together else None,
        "wrong_numbers": wrong_numbers(sentence, chosen["text"] + (" " + together["text"] if together else "")) if label == "supports" else [],
        "passage": chosen["text"],
        "quote": quote,
        "confidence": confidence,
        "label": label,
        "score": chosen.get("score"),
        "page": chosen.get("page"),  # PDFs only: the page the passage starts on
        "time": chosen.get("time"),  # videos only: the second the passage starts at
        **check_wording(
            sentence,
            chosen["text"],
            all_text=" ".join(c["text"] for c in candidates),
            stock=stock_phrases(research_passages()),
        ),
    }


if __name__ == "__main__":
    source = (
        "A 10-year cohort study found that adults who exercised three times a week "
        "had a 30% lower incidence of cardiovascular disease than those who did not."
    )
    wording_tests = [
        # (sentence, expected misquote, expected too_close)
        ('One study found "a 30% lower incidence of cardiovascular disease" among regular exercisers.', False, False),
        ("One study found “a 30% lower incidence of cardiovascular disease” among regular exercisers.", False, False),
        ('Adults who exercised "three times a week had a 40% lower incidence" of heart disease.', True, False),
        ('Regular exercisers "had a 30% lower incidence of [heart] disease than those who did not."', False, False),
        ('The study "found that adults ... had a 30% lower incidence" of disease.', False, False),
        ("Adults who exercised three times a week had a 30% lower incidence of cardiovascular disease.", False, True),
        ("People who work out regularly are noticeably less likely to develop heart problems.", False, False),
        ('As one author put it, "the evidence base is still developing" in this area.', False, False),
    ]
    print("Wording checks:")
    for sentence, misquote, too_close in wording_tests:
        got = check_wording(sentence, source)
        ok = got == {"misquote": misquote, "too_close": too_close}
        print(f"{'✓' if ok else '✗'} {got} | {sentence}")

    print("\nVerifier:")
    tests = [
        # (sentence, passage, expected label)
        (
            "Regular exercise lowers the risk of heart disease.",
            "A 10-year cohort study found that adults who exercised three times a week had a 30% lower incidence of cardiovascular disease.",
            "supports",
        ),
        (
            "Remote workers report higher job satisfaction than office workers.",
            "In a 2023 survey of 12,000 employees, fully remote staff rated their job satisfaction 7.8 out of 10 on average, compared with 6.9 for those working in the office full time.",
            "supports",
        ),
        (
            "Social media use is strongly linked to depression in teenagers.",
            "A large longitudinal analysis of 17,000 adolescents found only a very small association between social media use and depressive symptoms, comparable in size to the effect of eating potatoes.",
            "contradicts",
        ),
        (
            "Drinking coffee improves long-term memory.",
            "Caffeine is the world's most widely consumed stimulant, and a typical cup of coffee contains around 95mg of it. It increases alertness by blocking adenosine receptors in the brain.",
            "neutral",
        ),
        (
            "The Treaty of Versailles was signed in 1919.",
            "Photosynthesis converts light energy into chemical energy, producing glucose and oxygen from carbon dioxide and water.",
            "neutral",
        ),
    ]

    correct = 0
    for sentence, passage, expected in tests:
        match = verify(sentence, [{"text": passage, "source": {"url": "test", "title": "test"}}])
        actual = match["label"] if match else "neutral"
        correct += actual == expected
        mark = "✓" if actual == expected else "✗"
        confidence = f"{match['confidence']:.2f}" if match else "-"
        print(f"{mark} expected={expected:<11} actual={actual:<11} conf={confidence} | {sentence}")
    print(f"\n{correct}/{len(tests)} correct")

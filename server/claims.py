"""Does a sentence make a factual claim that ought to have a source?

A rule-based check, used only for sentences nothing in the reading supports, so the person
can see where their writing needs more research. Deliberately cheap and transparent rather
than another model call: it looks for figures, research language and cause-and-effect
wording, and ignores opinion and signposting. It will miss some claims and occasionally
flag a sentence that doesn't need a source.
"""

import re

FIGURES = re.compile(r"\d+(\.\d+)?\s?%|\b(19|20)\d{2}\b|\b\d{2,}\b|\b(half|twice|double|triple|majority|minority)\b", re.IGNORECASE)
RESEARCH = re.compile(
    r"\b(study|studies|research|review|trial|survey|evidence|data|analysis|meta-analysis|"
    r"found|shows?|showed|suggests?|reported|according to|experts?|scientists?)\b", re.IGNORECASE)
CAUSAL = re.compile(
    r"\b(causes?|caused|leads? to|led to|results? in|linked|associated|increases?|increased|"
    r"reduces?|reduced|lowers?|lowered|raises?|improves?|improved|prevents?|risk|effect|impact|"
    r"more likely|less likely|most|least|majority|always|never)\b", re.IGNORECASE)
OPINION = re.compile(
    r"^\s*(i|we)\b|\b(i think|i believe|i argue|in my (view|opinion)|this (essay|report|chapter|"
    r"section|dissertation) (will|aims|argues|discusses)|in (this|the following) (essay|section))\b",
    re.IGNORECASE)


# Not prose at all: pieces of links or LaTeX, left when a sentence is split at a link's full stop
# ("com/blog/184}{Mendeley}"), and instructions for using software ("click the Review menu"), as in
# a template's sample text.
RESIDUE = re.compile(r"\}\{|\\verb|https?://|www\.|^\W*[a-z0-9-]+\.?[a-z]*/\S|^\W*(com|org|net|edu|io|ac|uk|gov)/", re.IGNORECASE)
INTERFACE = re.compile(r"\b(click|clicking|menu|toolbar|button)\b", re.IGNORECASE)
LINK = re.compile(r"\S*(?:/|\\url|\\href)\S*")


def needs_source(sentence: str) -> bool:

    """
    True if the sentence reads like a factual claim rather than opinion, signposting, pieces of
    links or LaTeX, or instructions for using software.
    """

    if OPINION.search(sentence) or sentence.rstrip().endswith("?"):
        return False
    if RESIDUE.search(sentence) or INTERFACE.search(sentence):
        return False
    sentence = LINK.sub(" ", sentence)   # numbers inside links aren't figures
    signals = sum(bool(pattern.search(sentence)) for pattern in (FIGURES, RESEARCH, CAUSAL))
    return signals >= 1

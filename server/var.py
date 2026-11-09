"""VAR: learning what the person has written, and the material around it, and a mock viva.

When a write-up is added, Claude reads it once and builds a study set, saved until the person asks for
new questions: the opening account of the work, each concept it defines, each main argument, and
related topics beyond it. Each has the tasks a viva asks for (state it, examples, non-examples,
explain, a perturbation, check an argument), with what a full-mastery answer includes and the key idea,
shown only after the person has tried, and the passages in the project's reading that cover it. Answers given aloud are transcribed on the device, corrected by the
person, and judged on content only, in four tiers from not yet to mastery. What's weak comes back
sooner (spaced repetition).

The mock viva runs questions from the set in a viva's order, with no hints and no feedback until the
end, then places it in a band and adds the weak points to everyday practice.
"""

import base64
import hashlib
import json
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from pathlib import Path
from typing import Callable, Dict, List, Literal, Optional

from pydantic import BaseModel

from verify import anthropic_client

MODEL = "claude-sonnet-5-5"   # careful with mathematics, as for comparing theorems: writing the questions
QUICK = "claude-haiku-5-5"    # checking an answer against its full-mastery points, and reading a question's picture

# The calls that build a set all start with the same material (the question pictures, the write-up,
# how it's assessed), cached by the first so the rest read it at a tenth of the price. The
# instructions for each call come after it, so they don't break the shared start.
SHARED = "You help a person learn their own written mathematical work, and prepare to be examined on it."

# The tasks for each kind of topic, in the order a viva tends to ask them.
TASKS = {
    "opening": ["account"],
    "concept": ["state", "perturb", "examples"],
    "argument": ["explain", "perturb", "error"],
    "related": ["state"],
}
TIERS = ["Not yet", "Developing", "Secure", "Mastery"]   # grades 0 to 3
OPENING = "To begin, give a brief account of your work: how you structured your arguments, and where you found the main difficulty."

OUTLINE = """You read a person's own mathematical write-up and set out what they need to master, both to
account for it in a viva and to understand the material properly. If you're given the questions the
project answers, keep to what they ask and what answering them needs. List:

Be concise: only what matters most.

- concepts: the terms the write-up defines or relies on centrally, at most 7; one definition or fact each,
  or two only when one is meaningless without the other (never a whole list of definitions in one).
- arguments: each main argument or proof, as a whole (not each step); 1 or 2 per question, at most 4.
- related: at most 3 nearby topics not in the write-up that an examiner could move to: the next case, a
  generalisation, a result the arguments rely on, a common confusion.

For each give a short title, where it is in the write-up (as it's labelled there, such as "Definition (2)"
or "Question 1, proof"; empty for related topics), its text (for concepts and arguments, the write-up's
own LaTeX, trimmed to the relevant part; for related topics, one sentence on what it is) and the titles
of up to three other listed topics it connects to.

Also list what a strong 2 to 3 minute opening account of the work covers, as short phrases: the
structure, the key idea of each argument, where the main difficulty lies. Never write the account."""

QUESTIONS = """You are an examiner writing questions for a person to practise on, about topics from
their own write-up (or related to it). For each topic, write one question for each task asked for, as an examiner
would say it aloud:


Each question asks one thing, as an examiner would in one breath: at most two definitions or facts,
never a list to work through.
- state: state it precisely from memory (name it; don't quote it). For a related topic, also how it
  connects to the write-up.
- examples: give an example and a non-example (saying which condition fails), preferably new ones not
  in the write-up.
- explain: why a particular step holds, which definition or result justifies it, and why it's needed;
  ask for the reason, not for the step to be repeated.
- perturb: what happens if a hypothesis is dropped, a parameter changes, or the next case is considered;
  these may go beyond the write-up, to test reasoning rather than memory. For a concept: whether the
  definition holds in a particular case they haven't seen, with a twist (a different domain or a changed
  condition), and why.
- error: a short argument or computation (3 to 6 lines) on this material with exactly one error, to check
  and find the error. Put the argument in the question.

For each question also give what an answer showing full mastery includes (short phrases, a precise and
complete answer) and the key idea to learn from it (one or two sentences). Questions never include the
answer or a hint. Use LaTeX in $...$ for maths.

The write-up is what matters: every question is about it or follows from it. You may also get passages
from the person's own reading for this project (lecture notes, papers): these only add to it. Use them so the questions and key ideas match how the material is taught there. And you may get how the
person will be assessed: let it shape what you ask, how you ask it (match the kinds of question it
says examiners ask) and what full mastery includes, so practice is as close as possible to the real
assessment of their own work."""

ASSESS = """You are an examiner assessing one spoken or typed answer while a person practises on their
own written work. You get their submitted write-up, passages from their reading for the project where
there are any, the topic, the question, what full mastery includes, and their answer. Verify the answer
against the write-up first (it must agree with what they submitted, or say clearly why it differs), then
the reading where it applies, then the mathematics itself. When the question sets up its own example (its own program, vectors,
numbers), judge the answer against that example only, never values from the write-up. If the
answer was spoken, it was transcribed: ignore wording, filler and garbled notation, and judge the
mathematics they meant. Judge content only, never fluency or confidence. Reasoning aloud towards an
answer earns credit, and so does saying clearly that they don't know: neither counts against them. An
explanation that only restates the write-up hasn't explained why; examples copied from the write-up
count for less than new ones.

List what was right and what was missing or wrong, each as a short phrase. Give a grade: 0 nothing
useful, 1 partly right with real gaps, 2 right with a small gap, 3 complete and precise
(full mastery). Then one follow-up question an examiner might ask next, without giving away any answer: if
there was a slip, a prompt that lets them correct it themselves. Write every mathematical expression in LaTeX in $...$, in every field including the follow-up
question: $c_1v_1+\\dots+c_nv_n=0$, never c_1v_1+...+c_nv_n=0 as plain text."""

REPORT = """You are the examiner at the end of a short viva on a person's own written work. You get each
question and their answer (spoken answers were transcribed, so judge the mathematics meant, not the
wording). Judge content only.

Reasoning aloud towards an answer, and saying clearly that they don't know, both earn credit.
Place the viva in a band out of 10, best fit. If you're given how the person will be assessed, use that;
otherwise these expectations:
9-10: definitions stated accurately from memory; examples and non-examples readily produced, including
new ones; every step explained; arguments adapted under perturbation; errors found; sound reasoning on
unprepared questions.
7-8: a clear, correct account; definitions accurate, small slips corrected when prompted; confident on
their own work; simple perturbations handled, harder ones partly.
5-6: an accurate description of what was done, but explanations of why only restate the text; examples
mainly from the write-up; difficulty with perturbations. Towards 5: imprecise definitions, uncertain
beyond routine points.
0-4: no coherent account of the work; definitions or main claims not stated or explained.
Give the band as "a-b", what was strong and what was weak (short phrases), and for each weak point the
index of the question it came from. Be fair and specific; don't pad."""


class Part(BaseModel):
    title: str
    document: int
    page: int
    label: str
    text: str


class Brief(BaseModel):
    parts: List[Part]
    scheme: str


class Transcribed(BaseModel):
    text: str


BRIEF = """You read the documents a person was given for a written project (project sheets, guidelines,
screenshots; their text was read automatically, so spacing and maths may be garbled, and "[Page n]"
marks each PDF page), and their note on which parts are theirs. Find:

- parts: each question or task they answered: a short title; the number of the document it's in (as
  numbered below); the page it starts on (1 for a screenshot); its label exactly as printed, short and
  unique, to find it on the page (such as "MTH5112–3", or "Question 4"); and its text in full as set,
  tidied, with maths in LaTeX in $...$. Only the ones their note says are theirs; if the note is empty, all.
- scheme: how the work will be assessed: the mark scheme, its bands, what an oral examination (viva)
  will ask, word or page limits that matter. As set out in the documents, condensed but not reworded
  in substance. Empty if the documents don't say.

Never invent anything not in the documents."""

TRANSCRIBE = """Write out the question in this picture exactly as set, in Markdown with maths in LaTeX
($...$ inline, $$...$$ displayed). Keep its numbering and parts. Nothing else."""


def find_brief(files: List[Dict], guide: str) -> Optional[Dict]:

    """
    The questions a person answered and how they're assessed, from the documents they were given.
    Referee then shows each question as its page prints it, and reads it from that picture.
    """

    documents = "\n\n".join(f"=== Document {n}: {f.get('name', 'Document')} ===\n{f.get('text', '')}" for n, f in enumerate(files, 1))
    found = _ask(BRIEF, f"Their note: {guide or '(none)'}\n\n{documents[:60000]}", Brief, 8000, 180)
    return found.model_dump() if found else None


def read_picture(picture: str) -> Optional[str]:

    """A question read from its picture, so maths and layout come out as set, not as extracted text garbles them."""

    client = anthropic_client.get()
    if client is None or not Path(picture).is_file():
        return None
    data = base64.b64encode(Path(picture).read_bytes()).decode()
    response = client.with_options(timeout=90).messages.parse(
        model=QUICK, max_tokens=3000, system=TRANSCRIBE, output_format=Transcribed,
        messages=[{"role": "user", "content": [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": data}}]}])
    return response.parsed_output.text


class Topic(BaseModel):
    section: Literal["concept", "argument", "related"]
    title: str
    where: str
    text: str
    connects: List[str]


class Outline(BaseModel):
    opening: List[str]
    topics: List[Topic]


class Written(BaseModel):
    topic: str
    task: str
    question: str
    model: List[str]
    idea: str


class Questions(BaseModel):
    questions: List[Written]


class Assessment(BaseModel):
    right: List[str]
    missing: List[str]
    grade: Literal[0, 1, 2, 3]
    follow_up: str


class FollowCheck(BaseModel):
    right: List[str]
    missing: List[str]


FOLLOW_CHECK = """The person answered a follow-up question on their own work, after feedback on a first
answer. List what's right and what's missing or wrong in this answer, each as a short phrase, judged
against what the follow-up asks and what a precise, complete answer needs. When the question sets up its own example (its own program, vectors, numbers), use only that: never
bring in values from their write-up unless the question points to it. Never give the full answer. Use LaTeX in
$...$ for maths."""


class Reply(BaseModel):
    reply: str


FOLLOW_UP = """The person has answered a question on their own work and had feedback. Now they ask about it.
Answer what they ask, briefly and precisely, as a supervisor would in office hours: explain the idea,
point to where their write-up or reading covers it, and when they could work something out themselves,
give them the step that gets them there before giving the whole answer. Never invent what their
write-up says. When the question sets up its own example (its own program, vectors, numbers), use only that: never
bring in values from their write-up unless the question points to it. Use LaTeX in $...$ for maths."""


class Speakable(BaseModel):
    questions: List[str]


SPEAKABLE = """You get numbered questions for a mock viva that the person answers fully spoken, without
paper. Rewrite each as one short thing an examiner would ask in one breath, answerable aloud in two or
three sentences: "Define linear independence.", "Give me two vectors in $\\mathbb{R}^2$ that aren't
independent.", "In your Q1(a), why can't $S$ be zero?", "In (a)(ii), where do you use $p \\ge 0$?",
"What happens in (a)(ii) if $x$ isn't optimal?". No multi-part prompts, no "and also", nothing to hold in
their head while talking, and no calculation beyond something like $2+3$. Where a question has several
parts, keep only the most important one. Keep the same topic and what it tests, and refer to their own
work by its question or part where it helps. Keep any maths in LaTeX in $...$. Never include the answer
or a hint. Return the questions in the same order, one for each."""


class Weak(BaseModel):
    point: str
    question: int


class Report(BaseModel):
    band: str
    strong: List[str]
    weak: List[Weak]


SPOKEN = """A person answered a maths question aloud and it was transcribed word for word. Rewrite the
spoken mathematics as LaTeX in $...$, each whole expression or equation in one pair of dollars, using
standard notation: "x squared plus one" becomes $x^2+1$; "c one v one plus and so on up to c n v n
equals zero" becomes $c_1v_1+\\dots+c_nv_n=0$; "v one to v n" becomes $v_1,\\dots,v_n$. Keep the
letters' case as a mathematician would write them (vectors and scalars lower case unless the question
uses capitals). Vectors and points given by
their coordinates become bracketed tuples, one pair of dollars each: "one, one, zero" or "1,1,0"
becomes $(1,1,0)$; "minus one" or "negative one" is $-1$; "one comma one; one comma minus one" becomes
$(1,1)$ and $(1,-1)$. Keep exactly the numbers they said, in their order: never add, drop or change an
entry, even if the count doesn't match the space. Fix misheard maths terms using the question. Drop transcription tags such as
[BLANK_AUDIO] and repeated false starts ("which can cause, which can lead to" becomes "which can lead
to"). Otherwise keep their words; never add, correct or complete the reasoning."""


def spoken_maths(text: str, question: str = "") -> Optional[str]:
    """A spoken answer's maths written as LaTeX, for the person to check before it's assessed."""
    result = _ask(SPOKEN, f"Question: {question}\n\nTranscript:\n{text}", Transcribed, 2000, model=QUICK)
    return result.text if result else None


def _ask(system: str, user: str, schema, max_tokens: int = 1200, timeout: float = 90, model: str = MODEL,
         shared: Optional[Dict] = None, pictures: List[str] = ()):
    client = anthropic_client.get()
    if client is None:
        return None
    content = [{"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                            "data": base64.b64encode(Path(p).read_bytes()).decode()}}
               for p in pictures if Path(p).is_file()]
    if shared:
        # The shared start, cached: pictures of the questions (read as the questions themselves), then
        # the write-up and how it's assessed. This call's own instructions follow it.
        content = [{"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                                "data": base64.b64encode(Path(p).read_bytes()).decode()}}
                   for p in shared["pictures"] if Path(p).is_file()] + content
        content.append({"type": "text", "text": shared["text"], "cache_control": {"type": "ephemeral"}})
        user = f"{system}\n\n{user}"
        system = shared.get("system") or SHARED
    content.append({"type": "text", "text": user})
    response = client.with_options(timeout=timeout).messages.parse(
        model=model, max_tokens=max_tokens,
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": content}], output_format=schema)
    return response.parsed_output


def _id(*parts: str) -> str:
    return hashlib.sha1("\n".join(parts).encode()).hexdigest()[:12]


# The same tasks and sections serve every purpose, each read differently: for an interview, concepts are
# the methods and tools used, arguments the decisions and results, related topics what lies beyond the
# project; for a presentation, the key figures and claims, the reasoning and recommendations, and the
# challenges an audience is likely to raise.
INTERVIEW_OUTLINE = """You read a person's own project (its README, code, notebooks and results) and set out what
they need to be able to explain and defend in a job interview about it. List:

Be concise: only what matters most.

- concepts: the main methods, models, tools and techniques the project uses, at most 6, one each.
- arguments: the key decisions and results (why this approach, how a result was reached and checked), at
  most 4.
- related: at most 3 things an interviewer could move to beyond the project: scaling it, putting it into
  production, what you'd do next, a well-known alternative.

For each give a short title, where it is in the project (a file or section; empty for related topics),
its text (the relevant code or passage, trimmed; for related topics one sentence) and the titles of up to
three other listed topics it connects to.

Also list what a strong 2 minute walkthrough of the project covers, as short phrases: the problem and
why it matters, what was built, the main result, a limitation. Never write the walkthrough."""

INTERVIEW_QUESTIONS = """You are an interviewer for a data or technical role, writing questions a person practises on
about their own project. For each topic, write one question for each task asked for, as an interviewer
would say it aloud; each asks one thing:

- state: for a method or tool, what it is and why they chose it here over an alternative; for a topic
  beyond the project, how they would approach it.
- examples: when this method would give misleading results or fail, and what they'd use instead.
- explain: why they made this decision, or how they know this result holds (validation, checks).
- perturb: what changes if the data, an assumption or the requirement changes (twice the data, a biased
  sample, a stakeholder wanting a different metric).
- error: a short claim about the project or a few lines of code with exactly one flaw (a misread result, a
  leak, a bug), to spot and explain. Put it in the question.

For each question also give what a strong answer includes (short phrases: clear, specific to their
project, honest about limits and trade-offs) and the key idea (one or two sentences). Questions never
include the answer or a hint. If you're given the job description, lean the questions towards what that
role needs."""

INTERVIEW_ASSESS = """You are an interviewer assessing one spoken or typed answer while a person practises on their
own project. Check it against the project first: it must agree with what they built. Judge content
only: clarity of explanation, accuracy, reasons given for decisions, and honesty about limitations and
trade-offs, never fluency or confidence. If spoken, it was transcribed: ignore filler and wording.
Saying clearly what they don't know, and how they'd find out, earns credit.

List what was right and what was missing or wrong, as short phrases. Grade 0 nothing useful, 1 partly
right with real gaps, 2 right with a small gap, 3 a strong interview answer. Then one follow-up question
an interviewer might ask next, without giving away the answer. Write every mathematical expression in LaTeX in $...$, in every field including the follow-up
question: $c_1v_1+\\dots+c_nv_n=0$, never c_1v_1+...+c_nv_n=0 as plain text."""

INTERVIEW_REPORT = """You are the interviewer at the end of a short mock interview on a person's own project. You get
each question and answer (spoken answers were transcribed: judge content, not wording). Give a band out
of 10, best fit: 9-10 explains every decision with reasons and trade-offs, handles what-ifs, spots the
flaw, honest about limits; 7-8 clear and correct, some trade-offs or what-ifs thin; 5-6 describes what
was done but not why; 0-4 no coherent account. If you're given the job description, judge for that
role. Give the band as "a-b", what was strong and weak (short phrases), and for each weak point the index
of the question it came from."""

BRIEFING_OUTLINE = """You read a person's own report or presentation and set out what they need to be able to explain
and defend when presenting it and taking questions. List:

Be concise: only what matters most.

- concepts: the key figures and claims the audience will rely on, at most 6, one each.
- arguments: the main lines of reasoning and the recommendations, at most 4.
- related: at most 3 challenges the audience is likely to raise: risks, costs, alternatives, objections.

For each give a short title, where it is (a section or slide; empty for challenges), its text (the
relevant passage, trimmed; for challenges one sentence) and the titles of up to three other listed topics
it connects to.

Also list what a strong 2 minute opening summary covers, as short phrases: the question, what was found,
the recommendation, the main caveat. Never write the summary."""

BRIEFING_QUESTIONS = """You are a member of the person's audience (as described, if given) writing questions they
practise on about their own report. For each topic, write one question for each task asked for, as it
would be asked in the room; each asks one thing:

- state: for a figure or claim, what it is and where it comes from; for a challenge, the challenge
  itself, put to them.
- examples: what this figure or claim does and doesn't show.
- explain: why this reasoning holds, or why this recommendation follows from the evidence.
- perturb: what happens to the conclusion if an assumption or a number changes.
- error: a short objection or reading of the figures with exactly one flaw, to spot and answer. Put it in
  the question.

For each question also give what a strong answer includes (short phrases: accurate, sourced, direct,
honest about uncertainty) and the key idea (one or two sentences). Questions never include the answer or
a hint."""

BRIEFING_ASSESS = """You are assessing one spoken or typed answer while a person rehearses questions on their own
report. Check it against the report first: figures and claims must match it. Judge content only:
accuracy, sources given, a direct answer to what was asked, and honesty about uncertainty, never fluency.
If spoken, it was transcribed: ignore filler and wording. Saying clearly what they don't know, and how
they'd find out, earns credit.

List what was right and what was missing or wrong, as short phrases. Grade 0 nothing useful, 1 partly
right with real gaps, 2 right with a small gap, 3 a strong answer. Then one follow-up question the
audience might ask next, without giving away the answer. Write every mathematical expression in LaTeX in $...$, in every field including the follow-up
question: $c_1v_1+\\dots+c_nv_n=0$, never c_1v_1+...+c_nv_n=0 as plain text."""

BRIEFING_REPORT = """You are the audience at the end of a short mock question session on a person's own report. You get
each question and answer (spoken answers were transcribed: judge content, not wording). Give a band out
of 10, best fit: 9-10 every figure sourced, reasoning defended, challenges answered directly, honest
about uncertainty; 7-8 clear and correct, some challenges answered thinly; 5-6 repeats the report
without defending it; 0-4 can't account for the main findings. Give the band as "a-b", what was strong
and weak (short phrases), and for each weak point the index of the question it came from."""

# What each purpose uses: the instructions for each step, its opening question, and what the extra
# context it's given is called.
PURPOSES = {
    "viva": {"shared": SHARED, "outline": OUTLINE, "questions": QUESTIONS, "assess": ASSESS, "report": REPORT,
             "opening": OPENING, "title": "Your account of the work", "context": "How they will be assessed"},
    "interview": {"shared": "You help a person prepare to explain and defend their own project in a job interview.",
                  "outline": INTERVIEW_OUTLINE, "questions": INTERVIEW_QUESTIONS, "assess": INTERVIEW_ASSESS,
                  "report": INTERVIEW_REPORT, "title": "Walk me through it",
                  "opening": "Walk me through this project: the problem, what you built, and what came of it.",
                  "context": "The job description"},
    "briefing": {"shared": "You help a person prepare to present their own report and answer questions on it.",
                 "outline": BRIEFING_OUTLINE, "questions": BRIEFING_QUESTIONS, "assess": BRIEFING_ASSESS,
                 "report": BRIEFING_REPORT, "title": "Your opening summary",
                 "opening": "Give us a two-minute summary: the question, what you found, and what you recommend.",
                 "context": "The audience"},
}


def build_set(latex: str, reading: Callable[[str], List[Dict]] = lambda q: [], scheme: str = "",
              questions: str = "", pictures: List[str] = (), purpose: str = "viva", context: str = "") -> Optional[Dict]:

    """
    The study set for a write-up: Claude outlines it once, then writes each topic's questions in
    parallel, with the passages in the project's reading that cover each topic, and how the person is
    assessed: the mark scheme they gave, or failing that, their reading's. The questions the project
    answers, if given, keep it all on what was asked. None without a key.
    """

    # The questions as pictures of their pages when there are some (safer than any transcript), else as text.
    pictures = [p for p in pictures if Path(p).is_file()]
    use = PURPOSES.get(purpose, PURPOSES["viva"])
    if purpose != "viva":
        # A project or report, with the job description or the audience if given.
        shared = {"pictures": [], "system": use["shared"], "text": (f"{use['context']}:\n{context}\n\n" if context.strip() else "")
                  + ("The project:\n" if purpose == "interview" else "The report:\n") + latex[:60000]}
        assessed = context
    else:
      assessed = scheme or assessment(reading)
      shared = {"pictures": pictures, "text": (
        ("The questions the project answers are the pictures above, as set.\n\n" if pictures
         else f"The questions the project answers:\n{questions}\n\n" if questions else "")
        + (f"How they will be assessed:\n{assessed}\n\n" if assessed else "")
        + "The write-up:\n" + latex[:30000])}
    # The outline first: it writes the cache that the question calls then read.
    outline = _ask(use["outline"], "Set out the outline.", Outline, 8000, 300, shared=shared)
    if outline is None:
        return None
    opening = {"id": _id("opening"), "section": "opening", "title": use["title"], "where": "",
               "text": "", "connects": [],
               "questions": {"account": {"question": use["opening"], "model": outline.opening,
                                         "idea": "A clear opening shows you know the shape of the whole work before any detail."}}}
    topics = [{"id": _id(t.section, t.title), **t.model_dump()} for t in outline.topics]
    for topic in topics:
        topic["reading"] = reading(f"{topic['title']} {topic['text'][:300]}")

    def write(group: List[Dict]) -> Dict[str, Dict]:
        # Several topics in one call, each with its tasks and the passages from their reading on it.
        asked = "\n\n".join(
            f"Topic ({t['section']}): {t['title']}\nTasks: {', '.join(TASKS[t['section']])}\n{t['text']}"
            + "".join(f"\n\nFrom their reading ({p['source']}{', p. ' + str(p['page']) if p.get('page') else ''}):\n{p['text']}"
                      for p in t["reading"])
            for t in group)
        try:
            written = _ask(use["questions"], "Write the questions for each of these topics, naming the topic exactly as "
                                      "given for each question.\n\n" + asked, Questions, 16000, 300, shared=shared)
        except Exception:
            written = None
        found: Dict[str, Dict] = {}
        for w in written.questions if written else []:
            found.setdefault(w.topic, {})[w.task] = {"question": w.question, "model": w.model, "idea": w.idea}
        return found

    # A few calls, not one per topic: the concepts together, the arguments in twos, the related topics
    # together. A topic a group call missed is tried again on its own.
    groups = [[t for t in topics if t["section"] == "concept"], [t for t in topics if t["section"] == "related"]]
    arguments = [t for t in topics if t["section"] == "argument"]
    groups += [arguments[n:n + 2] for n in range(0, len(arguments), 2)]
    groups = [g for g in groups if g]
    # The first on its own, so it writes the cache the rest then read (the outline's differs, as its
    # answer takes another form).
    found: Dict[str, Dict] = write(groups[0]) if groups else {}
    with ThreadPoolExecutor(max_workers=6) as pool:
        for one in pool.map(write, groups[1:]):
            found.update(one)
    missed = [t for t in topics if not all(k in found.get(t["title"], {}) for k in TASKS[t["section"]])]
    with ThreadPoolExecutor(max_workers=6) as pool:
        for one in pool.map(lambda t: write([t]), missed):
            for title, tasks in one.items():
                found.setdefault(title, {}).update(tasks)
    for topic in topics:
        written = found.get(topic["title"], {})
        topic["questions"] = {k: written[k] for k in TASKS[topic["section"]] if k in written}
    return {"built": time.time(), "assessed": assessed, "topics": [opening] + [t for t in topics if t["questions"]]}


def assessment(reading: Callable[[str], List[Dict]]) -> str:
    # How the person will be assessed, if their reading for the project includes it (a mark scheme,
    # a viva's guidelines): it shapes the questions and the mock viva's band.
    found = reading("viva mark scheme assessment criteria bands examiners will ask")
    return "\n\n".join(p["text"] for p in found[:2])


class Var:

    """
    The write-ups, their study sets, progress and mock vivas, kept in var.json: {"documents": {name:
    {"project", "latex", "updated", "set", "built_from", "state"}}, "progress": {"topic id/task":
    {"due", "interval", "ease", "history"}}, "vivas": [...]}.
    """

    def __init__(self, path: Path, reading: Callable[[str, str], List[Dict]] = lambda q, project: []):

        self.path = path
        self.reading = reading      # (query, project) -> the closest passages in that project's reading
        self.lock = threading.Lock()
        try:
            self.data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.data = {}
        for key, empty in (("documents", {}), ("progress", {}), ("vivas", []), ("briefs", {})):
            self.data.setdefault(key, empty)
        for document in self.data["documents"].values():
            if document.get("state") == "building":      # interrupted by a restart
                document["state"] = "failed"

    def _save(self) -> None:

        with self.lock:
            self.path.write_text(json.dumps(self.data, indent=1), encoding="utf-8")

    def set_document(self, name: str, latex: str, project: str = "") -> Dict:

        """
        A write-up to practise on, sent by the Overleaf panel or chosen as a file. The first time, its
        study set is built; after that, a changed write-up keeps its set until new questions are asked for.
        """

        document = self.data["documents"].setdefault(name, {})
        document.update(project=project, latex=latex, updated=time.time())
        document.setdefault("files", [])
        if not document.get("set") and document.get("state") != "building":
            self.rebuild(name)
        self._save()
        return {"name": name}

    def set_context(self, name: str, purpose: Optional[str] = None, context: Optional[str] = None) -> Dict:

        """
        What a set is for (a viva or exam, a job interview, a presentation), and for the last two, the job
        description or the audience. Used for new questions.
        """

        document = self.data["documents"].get(name)
        if document is None:
            return {"ok": False, "reason": "not_found"}
        if purpose in PURPOSES:
            document["purpose"] = purpose
        if context is not None:
            document["context"] = context.strip()
        self._save()
        return {"ok": True}

    def set_files(self, name: str, files: List[Dict], project: str = "", purpose: Optional[str] = None) -> Dict:

        """
        A write-up made of files ({"name", "latex"}), one per question say: added to it (a file of the
        same name replacing the old) and learnt and examined together. No files left takes it out.
        """

        if not files and name in self.data["documents"]:
            return self.delete(name)
        joined = "\n\n".join(f["latex"] for f in files)
        if purpose in PURPOSES:
            # Known before its set is built, so the first build is for the right purpose.
            self.data["documents"].setdefault(name, {})["purpose"] = purpose
        self.set_document(name, joined, project or (self.data["documents"].get(name) or {}).get("project", ""))
        self.data["documents"][name]["files"] = [{"name": f["name"], "latex": f["latex"]} for f in files]
        self._save()
        return {"ok": True, "name": name}

    def files(self, name: str) -> List[Dict]:
        document = self.data["documents"].get(name) or {}
        return document.get("files") or ([{"name": name, "latex": document["latex"]}] if document.get("latex") else [])

    def rebuild(self, name: str) -> Dict:

        """Builds the study set again from the write-up as it is now, in the background."""

        document = self.data["documents"].get(name)
        if not document:
            return {"ok": False, "reason": "not_found"}
        if document.get("state") == "building":
            return {"ok": True}
        document["state"] = "building"
        latex, project = document["latex"], document.get("project", "")
        brief = self.brief(project)
        purpose, context = document.get("purpose") or "viva", document.get("context") or ""

        def run():
            try:
                built = build_set(latex, lambda q: self.reading(q, project), brief["scheme"], brief["questions"],
                                  [p["picture"] for p in brief.get("parts") or [] if p.get("picture")], purpose, context)
            except Exception:
                built = False
            document["state"] = "no_api_key" if built is None else "ready" if built else "failed"
            if built:
                document.update(set=built, built_from=_id(latex))
            self._save()

        threading.Thread(target=run, daemon=True).start()
        self._save()
        return {"ok": True}

    def brief(self, project: str) -> Dict:
        return {"questions": "", "scheme": "", "guide": "", "files": [], "parts": []} | self.data["briefs"].get(project or "", {})

    def scheme(self, project: str) -> str:
        return self.brief(project)["scheme"]

    def set_brief(self, project: str, questions: str, scheme: str, guide: str = "", files: Optional[List[Dict]] = None,
                  parts: Optional[List[Dict]] = None) -> None:

        """
        What a project was set: the questions it answers, and its mark scheme (or how it's assessed).
        Both are used for new questions; the mark scheme also for the mock viva's band.
        """

        self.data["briefs"][project or ""] = {"questions": questions.strip(), "scheme": scheme.strip(),
                                              "guide": guide.strip(), "files": files or [], "parts": parts or []}
        self._save()

    def delete(self, name: str) -> Dict:

        """Takes a write-up out of VAR, with its questions, progress and mock vivas."""

        document = self.data["documents"].pop(name, None)
        if document is None:
            return {"ok": False, "reason": "not_found"}
        ids = {t["id"] for t in (document.get("set") or {}).get("topics", [])}
        self.data["progress"] = {k: v for k, v in self.data["progress"].items() if k.split("/")[0] not in ids}
        self.data["vivas"] = [v for v in self.data["vivas"] if v["document"] != name]
        self._save()
        return {"ok": True}

    def documents(self, project: Optional[str] = None) -> List[Dict]:

        return [{"name": n, "project": d["project"], "updated": d["updated"], "purpose": d.get("purpose") or "viva"}
                for n, d in sorted(self.data["documents"].items(), key=lambda kv: -kv[1]["updated"])
                if project is None or d["project"] == project]

    def _progress(self, topic_id: str, task: str) -> Dict:
        return self.data["progress"].get(f"{topic_id}/{task}", {})

    def _grade(self, topic_id: str, task: str) -> Optional[int]:
        history = self._progress(topic_id, task).get("history", [])
        return history[-1]["grade"] if history else None

    def items(self, name: str) -> Dict:

        """
        The study set as the sidebar shows it: each topic with its tasks' latest grades and when it's
        next due, and how many tasks are at mastery.
        """

        document = self.data["documents"].get(name)
        if not document:
            return {"state": "none", "topics": []}
        today = date.today().isoformat()
        topics, strong, total = [], 0, 0
        for topic in (document.get("set") or {}).get("topics", []):
            tasks = [{"task": t, "grade": self._grade(topic["id"], t)} for t in topic["questions"]]
            strong += sum(t["grade"] == 3 for t in tasks)
            total += len(tasks)
            dues = [self._progress(topic["id"], t["task"]).get("due", today) for t in tasks]
            topics.append({k: topic.get(k) or [] if k in ("connects", "reading") else topic[k]
                           for k in ("id", "section", "title", "where", "text", "connects", "reading")} |
                          {"tasks": tasks, "due": min(dues, default=today)})
        return {"state": document.get("state", "ready"), "topics": topics, "strong": strong, "total": total,
                "purpose": document.get("purpose") or "viva", "context": document.get("context") or "",
                "changed": bool(document.get("set")) and document.get("built_from") != _id(document["latex"])}

    def _topic(self, name: str, topic_id: str) -> Optional[Dict]:
        document = self.data["documents"].get(name) or {}
        return next((t for t in (document.get("set") or {}).get("topics", []) if t["id"] == topic_id), None)

    def question(self, name: str, topic_id: str, task: str = "") -> Dict:

        """
        A saved question on a topic: the task asked for, or the one most in need of practice (not yet
        tried, then the weakest, then the one due soonest).
        """

        topic = self._topic(name, topic_id)
        if not topic:
            return {"ok": False, "reason": "not_found"}
        if task not in topic["questions"]:
            def need(t):
                grade = self._grade(topic_id, t)
                return (grade is not None, grade or 0, self._progress(topic_id, t).get("due", ""))
            task = min(topic["questions"], key=need)
        return {"ok": True, "task": task, "question": topic["questions"][task]["question"]}

    def assess(self, name: str, topic_id: str, task: str, answer: str, spoken: bool = False,
               pictures: List[str] = (), recordings: List[str] = ()) -> Dict:

        """Assesses an answer, records it, and schedules the task: sooner if weak, later if solid."""

        topic = self._topic(name, topic_id)
        if not topic or task not in topic["questions"]:
            return {"ok": False, "reason": "not_found"}
        asked = topic["questions"][task]
        # Checked against what they submitted and, where it helps, their reading for the project.
        latex = self.data["documents"][name]["latex"]
        purpose = self.data["documents"][name].get("purpose") or "viva"
        use = PURPOSES.get(purpose, PURPOSES["viva"])
        reading = "".join(f"\n\nFrom their reading ({p['source']}{', p. ' + str(p['page']) if p.get('page') else ''}):\n{p['text']}"
                          for p in topic.get("reading") or [])
        context = self.data["documents"][name].get("context") or ""
        result = _ask(use["assess"], (f"{use['context']}:\n{context}\n\n" if purpose != "viva" and context else "")
                              + f"Their {'submitted write-up' if purpose == 'viva' else 'project' if purpose == 'interview' else 'report'}:\n{latex[:30000]}{reading}\n\n"
                              f"Topic: {topic['title']}\n{topic['text']}\n\nQuestion: {asked['question']}\n\n"
                              f"Full mastery includes: {', '.join(asked['model'])}\n\n"
                              f"Answer ({'spoken, transcribed' if spoken else 'typed'}):\n{answer or '(none typed)'}"
                              + ("\n\nTheir answer also includes the pictures above (handwritten or photographed working): "
                                 "read them as part of it." if pictures else ""),
                              Assessment, 3000, model=QUICK, pictures=pictures)
        if result is None:
            return {"ok": False, "reason": "no_api_key"}
        self.schedule(f"{topic_id}/{task}", result.grade)
        # The answer kept with its grade: its words, and its recording and pictures on this Mac.
        self.data["progress"][f"{topic_id}/{task}"]["history"][-1].update(
            answer=answer, recordings=list(recordings), pictures=list(pictures))
        self._save()
        return {"ok": True, **result.model_dump(), "model": asked["model"], "idea": asked["idea"]}

    def schedule(self, key: str, grade: int) -> None:

        """
        Spaced repetition in the manner of SM-2: a weak answer (0 or 1) comes back tomorrow; a good one
        waits longer each time, by a factor that grows with good answers and shrinks with weak ones.
        """

        progress = self.data["progress"].setdefault(key, {"interval": 0, "ease": 2.5, "history": []})
        if grade <= 1:
            progress["interval"] = 1
            progress["ease"] = max(1.3, progress["ease"] - 0.2)
        else:
            previous = progress["interval"]
            progress["interval"] = 3 if previous < 3 else round(previous * progress["ease"])
            progress["ease"] = min(3.0, progress["ease"] + (0.1 if grade == 3 else 0))
        progress["due"] = (date.today() + timedelta(days=progress["interval"])).isoformat()
        progress["history"].append({"date": date.today().isoformat(), "grade": grade})
        self._save()

    def follow_up(self, name: str, topic_id: str, task: str, feedback: Dict, conversation: List[Dict]) -> Dict:

        """A question about the feedback on an answer, with the conversation so far."""

        topic = self._topic(name, topic_id)
        if not topic or task not in topic["questions"] or not conversation:
            return {"ok": False, "reason": "not_found"}
        asked = topic["questions"][task]
        history = self._progress(topic_id, task).get("history", [])
        answer = history[-1].get("answer", "") if history else ""
        latex = self.data["documents"][name]["latex"]
        reading = "".join(f"\n\nFrom their reading ({p['source']}{', p. ' + str(p['page']) if p.get('page') else ''}):\n{p['text']}"
                          for p in topic.get("reading") or [])
        talk = "\n\n".join(f"{'They' if c.get('role') == 'user' else 'You'}: {c.get('text', '')}"
                           + (" (with the pictures above)" if c is conversation[-1] and c.get("pictures") else "")
                           for c in conversation[-12:])
        pictures = [p for p in (conversation[-1].get("pictures") or "").split("\n") if p]
        result = _ask(FOLLOW_UP, f"Their work:\n{latex[:30000]}{reading}\n\nTopic: {topic['title']}\n{topic['text']}\n\n"
                                 f"Question: {asked['question']}\n\nFull mastery includes: {', '.join(asked['model'])}\n\n"
                                 f"Their answer:\n{answer or '(not kept)'}\n\n"
                                 f"Feedback given: right: {'; '.join(feedback.get('right') or [])}. "
                                 f"Missing: {'; '.join(feedback.get('missing') or [])}.\n\n{talk}\n\nReply to their last message.",
                      Reply, 3000, model=QUICK, pictures=pictures)
        if result is None:
            return {"ok": False, "reason": "no_api_key"}
        return {"ok": True, "reply": result.reply}

    def follow_check(self, name: str, topic_id: str, task: str, follow: str, answer: str,
                     pictures: List[str] = ()) -> Dict:

        """Checks an answer to the follow-up question in an answer's feedback (it doesn't change the grade)."""

        topic = self._topic(name, topic_id)
        if not topic or task not in topic["questions"]:
            return {"ok": False, "reason": "not_found"}
        latex = self.data["documents"][name]["latex"]
        result = _ask(FOLLOW_CHECK, f"Their work:\n{latex[:30000]}\n\nTopic: {topic['title']}\n{topic['text']}\n\n"
                                    f"Original question: {topic['questions'][task]['question']}\n\n"
                                    f"Follow-up question (it follows on from the original question): {follow}\n\nAnswer:\n{answer or '(none typed)'}"
                                    + ("\n\nTheir answer also includes the pictures above." if pictures else ""),
                      FollowCheck, 3000, model=QUICK, pictures=pictures)
        if result is None:
            return {"ok": False, "reason": "no_api_key"}
        return {"ok": True, **result.model_dump()}

    def reset(self, topic_id: str, task: str) -> Dict:
        """Forgets a task's grades, kept answers and review schedule, as if never attempted."""
        self.data["progress"].pop(f"{topic_id}/{task}", None)
        self._save()
        return {"ok": True}

    def mock_viva(self, name: str) -> Dict:

        """
        A mock viva from the saved set, in a viva's order: the opening account, then a definition and a
        case to decide with it, explaining an argument, and a perturbation of it, each reworded to answer aloud.
        """

        document = self.data["documents"].get(name)
        if not document or not document.get("set"):
            return {"ok": False, "reason": "not_found"}
        # An unfinished one carries on where it was left: a new one only once it's done.
        # One not yet answered, or from before the shorter format, is replaced by a new one.
        self.data["vivas"] = [v for v in self.data["vivas"] if v.get("report") or v["document"] != name
                              or (v.get("answers") and len(v["questions"]) <= 5)]
        unfinished = next((v for v in reversed(self.data["vivas"]) if v["document"] == name and not v.get("report")), None)
        if unfinished:
            return {"ok": True, **unfinished}
        topics = document["set"]["topics"]
        # How often each question has come up in earlier mock vivas: the least asked come first, so
        # the whole set is worked through before any repeats.
        times: Dict[str, int] = {}
        for earlier in self.data["vivas"]:
            if earlier["document"] == name:
                for q in earlier["questions"]:
                    key = f"{q['item']['id']}/{q['kind']}"
                    times[key] = times.get(key, 0) + 1
        asked = []
        # A definition is followed by a case to decide on the same concept, as examiners tend to.
        # The reflection, then four questions, all answerable aloud.
        for section, task in (("opening", "account"), ("concept", "state"), ("concept", "perturb"),
                              ("argument", "explain"), ("argument", "perturb")):
            used = [a["item"]["id"] for a in asked]
            fits = [t for t in topics if t["section"] == section and task in t["questions"]]
            if (section, task) == ("concept", "perturb"):
                fits = [t for t in fits if asked and t["id"] == asked[-1]["item"]["id"]]
            fits = [t for t in fits if t["id"] not in used] or fits
            if fits:
                least = min(times.get(f"{t['id']}/{task}", 0) for t in fits)
                topic = random.choice([t for t in fits if times.get(f"{t['id']}/{task}", 0) == least])
                asked.append({"kind": task, "item": {"id": topic["id"], "title": topic["title"]},
                              "question": topic["questions"][task]["question"]})
        # Reworded so each can be answered fully spoken, in a minute or two.
        # The opening reflection stays in full; the rest are shortened.
        short = [q for q in asked if q["kind"] != "account"]
        if short:
            spoken = _ask(SPEAKABLE, "\n\n".join(f"{n}. {q['question']}" for n, q in enumerate(short)),
                          Speakable, 2000, model=QUICK)
            if spoken and len(spoken.questions) == len(short):
                for q, text in zip(short, spoken.questions):
                    q["question"] = text
        viva = {"id": _id(name, str(time.time()))[:10], "document": name, "started": time.time(),
                "questions": asked, "answers": [], "report": None}
        self.data["vivas"].append(viva)
        self._save()
        return {"ok": True, **viva}

    def save_answer(self, viva_id: str, index: int, answer: Dict, seconds: int) -> Dict:

        """One answer in a mock viva, kept as it's given, so leaving part-way carries on later."""

        viva = next((v for v in self.data["vivas"] if v["id"] == viva_id), None)
        if not viva or viva.get("report"):
            return {"ok": False, "reason": "not_found"}
        answers = viva["answers"]
        answers.extend({} for _ in range(index + 1 - len(answers)))
        answers[index] = answer
        viva["seconds"] = seconds
        self._save()
        return {"ok": True}

    def finish_viva(self, viva_id: str, answers: List[Dict], seconds: int) -> Dict:

        """
        Assesses a whole mock viva at the end ({"answer", "spoken"} for each question), and brings the
        weak points' items back for practice today.
        """

        viva = next((v for v in self.data["vivas"] if v["id"] == viva_id), None)
        if not viva:
            return {"ok": False, "reason": "not_found"}
        lines, pictures = [], []
        for n, (q, a) in enumerate(zip(viva["questions"], answers)):
            shown = [p for p in a.get("pictures") or [] if Path(p).is_file()]
            first = len(pictures) + 1
            pictures += shown
            lines.append(f"[{n}] Question ({q['kind']}): {q['question']}\nAnswer ({'spoken' if a.get('spoken') else 'typed'}): "
                         f"{a.get('answer') or ('(in pictures)' if shown else '(no answer)')}"
                         + (f" (also pictures {first} to {len(pictures)} above, their written working)" if shown else ""))
        latex = self.data["documents"][viva["document"]]["latex"]
        document = self.data["documents"][viva["document"]]
        purpose = document.get("purpose") or "viva"
        use = PURPOSES.get(purpose, PURPOSES["viva"])
        assessed = (self.scheme(document.get("project", "")) if purpose == "viva" else document.get("context")) or (document.get("set") or {}).get("assessed")
        result = _ask(use["report"], (f"{use['context']}:\n{assessed}\n\n" if assessed else "") + "The work:\n" + latex[:12000] + "\n\nThe viva:\n" + "\n\n".join(lines), Report, 2000, 120,
                      pictures=pictures)
        if result is None:
            return {"ok": False, "reason": "no_api_key"}
        today = date.today().isoformat()
        practise = []
        for weak in result.weak:
            if 0 <= weak.question < len(viva["questions"]):
                asked = viva["questions"][weak.question]
                item = asked["item"]
                self.data["progress"].setdefault(f"{item['id']}/{asked['kind']}", {"interval": 0, "ease": 2.5, "history": []})["due"] = today
                if item not in practise:
                    practise.append(item)
        viva.update(answers=answers, seconds=seconds, report=result.model_dump())
        self._save()
        return {"ok": True, **result.model_dump(), "seconds": seconds, "practise": practise}

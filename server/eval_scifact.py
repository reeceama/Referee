"""Evaluate verify() on SciFact, a published fact-checking benchmark.

Three stages, run separately so the API is only called once:
    python eval_scifact.py build    # SciFact -> eval_pairs.csv          (no API calls)
    python eval_scifact.py run      # verify() each pair -> eval_results.csv  (~100 API calls)
    python eval_scifact.py analyse  # precision/recall per threshold, Wilson CIs, PR plot (free)
"""

import json
import math
import random
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pandas as pd

DATA = Path.home() / "scifact" / "data"
PAIRS_CSV = "eval_pairs.csv"
RESULTS_CSV = "eval_results.csv"
PLOT_PNG = "eval_pr.png"

N_SUPPORTS = 40
N_CONTRADICTS = 30
N_NEUTRAL_UNRELATED = 15  # claim + abstract it cites but that doesn't address it
N_NEUTRAL_SAME_DOC = 15   # claim + non-evidence sentences from its own evidence abstract (hard)
TARGET_PRECISION = 0.9
SEED = 0


def load_jsonl(path):

    return [json.loads(line) for line in open(path)]


def build():

    """
    Turn SciFact claims into (sentence, passage, label) pairs.
    """

    rng = random.Random(SEED)
    claims = load_jsonl(DATA / "claims_dev.jsonl")
    corpus = {doc["doc_id"]: doc["abstract"] for doc in load_jsonl(DATA / "corpus.jsonl")}

    supports, contradicts, same_doc, unrelated = [], [], [], []
    for claim in claims:
        if not claim["evidence"]:
            # No evidence: pair with a window of the abstract it cites.
            abstract = corpus[claim["cited_doc_ids"][0]]
            start = rng.randrange(max(1, len(abstract) - 2))
            unrelated.append((claim["claim"], " ".join(abstract[start:start + 3]), "neutral"))
            continue

        doc_id, evidence_sets = next(iter(claim["evidence"].items()))
        abstract = corpus[int(doc_id)]
        rationale = sorted({i for s in evidence_sets for i in s["sentences"]})
        passage = " ".join(abstract[i] for i in rationale)
        label = "supports" if evidence_sets[0]["label"] == "SUPPORT" else "contradicts"
        (supports if label == "supports" else contradicts).append((claim["claim"], passage, label))

        # Same topic, but none of the sentences that actually carry the evidence.
        other = [i for i in range(len(abstract)) if i not in rationale]
        if len(other) >= 2:
            picked = sorted(rng.sample(other, min(3, len(other))))
            same_doc.append((claim["claim"], " ".join(abstract[i] for i in picked), "neutral"))

    pairs = (
        [(*p, "supports") for p in rng.sample(supports, N_SUPPORTS)]
        + [(*p, "contradicts") for p in rng.sample(contradicts, N_CONTRADICTS)]
        + [(*p, "neutral_unrelated") for p in rng.sample(unrelated, N_NEUTRAL_UNRELATED)]
        + [(*p, "neutral_same_doc") for p in rng.sample(same_doc, N_NEUTRAL_SAME_DOC)]
    )
    df = pd.DataFrame(pairs, columns=["sentence", "passage", "label", "kind"])
    df.to_csv(PAIRS_CSV, index=False)
    print(f"Wrote {len(df)} pairs to {PAIRS_CSV}")
    print(df["kind"].value_counts().to_string())


def run():

    """
    Run verify() on every pair with the threshold disabled, recording raw labels and confidences.
    """

    from verify import verify

    df = pd.read_csv(PAIRS_CSV)

    def check(row):
        # threshold=0 records every verdict; thresholds are applied in analyse()
        match = verify(row.sentence, [{"text": row.passage, "source": {}}], threshold=0, use_cache=False)
        return (match["label"], match["confidence"]) if match else ("neutral", 0.0)

    import local_models
    chosen = local_models.provider()
    # Local models run one check at a time on this computer; the API takes several at once.
    with ThreadPoolExecutor(max_workers=8 if chosen == "claude" else 1) as pool:
        verdicts = list(pool.map(check, df.itertuples()))
    df["pred"] = [label for label, _ in verdicts]
    df["confidence"] = [conf for _, conf in verdicts]
    out = results_csv()
    df.to_csv(out, index=False)
    print(f"Wrote {len(df)} results to {out}")
    print(f"Raw accuracy (no threshold): {(df['pred'] == df['label']).mean():.2f}")


def results_csv():

    """
    eval_results.csv for Claude (the published benchmark); eval_results_<provider>.csv otherwise,
    chosen with REFEREE_AI_PROVIDER=ollama (and REFEREE_OLLAMA_MODEL).
    """

    import local_models
    chosen = local_models.provider()
    if chosen == "claude":
        return RESULTS_CSV
    name = chosen if chosen != "ollama" else f"ollama_{local_models.settings()['ollama_model'].replace(':', '_')}"
    return f"eval_results_{name}.csv"


def wilson(successes, n, z=1.96):

    """
    95% Wilson score interval for a proportion.
    """

    if n == 0:
        return (float("nan"), float("nan"))
    p = successes / n
    centre = (p + z**2 / (2 * n)) / (1 + z**2 / n)
    half = z * math.sqrt(p * (1 - p) / n + z**2 / (4 * n**2)) / (1 + z**2 / n)
    return (centre - half, centre + half)


def metrics_at(df, threshold):

    """
    A marker is shown when the verdict is supports/contradicts with confidence >= threshold.

    precision: of the markers shown, the share with the right label.
    recall:    of the pairs that deserve a marker, the share that got the right one.
    """

    shown = df[(df["pred"] != "neutral") & (df["confidence"] >= threshold)]
    correct = int((shown["pred"] == shown["label"]).sum())
    deserving = int((df["label"] != "neutral").sum())
    low, high = wilson(correct, len(shown))
    return {
        "threshold": threshold,
        "shown": len(shown),
        "correct": correct,
        "precision": correct / len(shown) if len(shown) else float("nan"),
        "ci_low": low,
        "ci_high": high,
        "recall": correct / deserving,
    }


def analyse():

    df = pd.read_csv(results_csv())
    thresholds = sorted(set(df["confidence"]) | {0.5, 0.6, 0.7, 0.8, 0.9})
    table = pd.DataFrame([metrics_at(df, t) for t in thresholds if t > 0])
    print(table.round(3).to_string(index=False))

    good = table[table["precision"] >= TARGET_PRECISION]
    if good.empty:
        print(f"\nNo threshold reaches precision {TARGET_PRECISION}.")
    else:
        best = good.iloc[0]  # lowest qualifying threshold = highest recall
        print(
            f"\nChosen threshold: {best.threshold:.2f}  "
            f"precision {best.precision:.2f} (95% CI {best.ci_low:.2f}-{best.ci_high:.2f}), "
            f"recall {best.recall:.2f}, {int(best.shown)} markers shown"
        )

    print("\nConfusion matrix (rows = true label, columns = prediction, no threshold):")
    print(pd.crosstab(df["label"], df["pred"]).to_string())
    print("\nHard negatives (same abstract, non-evidence sentences) wrongly marked:")
    hard = df[df["kind"] == "neutral_same_doc"]
    print(f"{int((hard['pred'] != 'neutral').sum())} of {len(hard)}")

    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(5, 4))
    ax.plot(table["recall"], table["precision"], marker="o")
    ax.fill_between(table["recall"], table["ci_low"], table["ci_high"], alpha=0.2)
    ax.axhline(TARGET_PRECISION, linestyle="--", linewidth=1)
    ax.set_xlabel("Recall")
    ax.set_ylabel("Precision")
    ax.set_title("Verifier on SciFact (95% Wilson CI)")
    fig.tight_layout()
    plot = PLOT_PNG if results_csv() == RESULTS_CSV else results_csv().replace("eval_results", "eval_pr").replace(".csv", ".png")
    fig.savefig(plot, dpi=150)
    print(f"\nSaved plot to {plot}")


if __name__ == "__main__":
    
    stages = {"build": build, "run": run, "analyse": analyse}
    if len(sys.argv) != 2 or sys.argv[1] not in stages:
        sys.exit("usage: python eval_scifact.py build|run|analyse")
    stages[sys.argv[1]]()

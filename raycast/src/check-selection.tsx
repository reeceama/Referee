import { Action, ActionPanel, Alert, confirmAlert, getSelectedText, Icon, List, LocalStorage } from "@raycast/api";
import { useEffect, useState } from "react";
import { referee } from "./referee";

// Check Selected Text: the sentence selected in any app (Pages, Notes, an email), checked against
// the current project's reading, as Referee checks writing in Word: the source that backs it, the
// page and passage, and the citation to copy. Each check is kept here, newest first, until removed.

type Verdict = {
  match: boolean; label?: string; source?: { title?: string; url?: string }; page?: number;
  passage?: string; quote?: string; cite?: string; needs_source?: boolean;
  closest?: { title?: string; url: string; page?: number }[];
};
type Check = { id: string; sentence: string; verdict: Verdict; at: number };

const KEY = "checks";

async function saved(): Promise<Check[]> {
  try {
    return JSON.parse((await LocalStorage.getItem<string>(KEY)) ?? "[]");
  } catch {
    return [];
  }
}

function result(v: Verdict): string {
  if (!v.match) return v.needs_source ? "Nothing in your reading backs this yet" : "Not backed, but may not need a source";
  return v.label === "supports" ? "Backed by your reading" : v.label === "contradicts" ? "Your reading says otherwise" : "Check the wording";
}

function markdown(c: Check): string {
  const v = c.verdict;
  const quoted = `> ${c.sentence}`;
  if (!v.match) {
    const places = (v.closest ?? []).map((s) => `- ${s.title || s.url}${s.page ? `, p. ${s.page}` : ""}`).join("\n");
    return `${quoted}\n\n## ${result(v)}${places ? `\n\nClosest in your reading:\n\n${places}` : ""}`;
  }
  const title = v.source?.title || v.source?.url || "Source";
  return `${quoted}\n\n## ${result(v)}\n\n> ${v.quote || v.passage || ""}\n\n**${title}**${v.page ? ` · page ${v.page}` : ""}`;
}

export default function Command() {
  const [checks, setChecks] = useState<Check[]>();
  const [working, setWorking] = useState(true);
  const [problem, setProblem] = useState<string>();

  async function keep(list: Check[]) {
    setChecks(list);
    await LocalStorage.setItem(KEY, JSON.stringify(list.slice(0, 200)));
  }

  useEffect(() => {
    (async () => {
      const earlier = await saved();
      setChecks(earlier);
      try {
        const sentence = (await getSelectedText()).trim();
        if (sentence.split(/\s+/).length < 5) throw new Error("Select a whole sentence in another app, then run this again.");
        const verdict = await referee<Verdict>("check", { sentence, document: "Selected text (Raycast)" });
        await keep([{ id: String(Date.now()), sentence, verdict, at: Date.now() }, ...earlier.filter((c) => c.sentence !== sentence)]);
      } catch (e) {
        const message = (e as Error).message;
        setProblem(message.includes("Referee") || message.includes("Select") ? message : "Select some text in another app to check it.");
      } finally {
        setWorking(false);
      }
    })();
  }, []);

  async function remove(id: string) {
    await keep((checks ?? []).filter((c) => c.id !== id));
  }

  async function clearAll() {
    if (await confirmAlert({ title: "Clear all checks?", message: "They're only kept here: checks already in Referee's Evidence stay.",
                             primaryAction: { title: "Clear", style: Alert.ActionStyle.Destructive } })) {
      await keep([]);
    }
  }

  const list = checks ?? [];
  return (
    <List isLoading={working} isShowingDetail={list.length > 0} searchBarPlaceholder="Search your checks">
      {problem && list.length === 0 && <List.EmptyView icon={Icon.TextSelection} title={problem} />}
      {list.map((c, i) => {
        const v = c.verdict;
        const link = v.source?.url ? `referee://source?url=${encodeURIComponent(v.source.url)}${v.page ? `&page=${v.page}` : ""}` : undefined;
        return (
          <List.Section key={c.id} title={i === 0 && !problem ? "Just checked" : i === (problem ? 0 : 1) ? "Earlier" : undefined}>
            <List.Item
              icon={{ source: v.match && v.label === "supports" ? Icon.CheckCircle : Icon.Circle }}
              title={c.sentence}
              accessories={[{ date: new Date(c.at) }]}
              detail={<List.Item.Detail markdown={markdown(c)} />}
              actions={
                <ActionPanel>
                  {v.cite && <Action.CopyToClipboard title="Copy Citation" content={v.cite} />}
                  {link && <Action.Open title="Open at This Page" target={link} icon={Icon.Book} />}
                  {v.passage && <Action.CopyToClipboard title="Copy Passage" content={v.passage} />}
                  <Action title="Remove This Check" icon={Icon.Trash} style={Action.Style.Destructive}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }} onAction={() => remove(c.id)} />
                  <Action title="Clear All Checks" icon={Icon.XMarkCircle} style={Action.Style.Destructive}
                    shortcut={{ modifiers: ["ctrl", "shift"], key: "x" }} onAction={clearAll} />
                </ActionPanel>
              }
            />
          </List.Section>
        );
      })}
    </List>
  );
}

import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { openInReferee, SectionList, useProjectList } from "./browse";
import { plainMaths } from "./referee";

// Meetings: the current project's meetings, newest first, with notes, decisions and action points.

type Meeting = { id: string; title: string; date: string; attendees: string; notes: string; decisions: string;
                 actions?: { text: string; who?: string; due?: string; done?: boolean }[] };

export default function Command() {
  const { items, project, error } = useProjectList<Meeting>((p) => `meetings?project=${encodeURIComponent(p)}`);
  const sorted = [...(items ?? [])].sort((a, b) => (b.date || "").localeCompare(a.date || ""));
  return (
    <SectionList items={items} project={project} error={error} empty="No meetings yet" placeholder="Search meetings">
      {sorted.map((m) => {
        const actions = (m.actions ?? []).filter((a) => a.text).map((a) => `- [${a.done ? "x" : " "}] ${a.text}${a.who ? ` (${a.who})` : ""}${a.due ? `, by ${a.due}` : ""}`).join("\n");
        const md = [`## ${m.title || "Meeting"}`, [m.date, m.attendees].filter(Boolean).join(" · "),
          m.notes && `### Notes\n\n${m.notes}`, m.decisions && `### Decisions\n\n${m.decisions}`,
          actions && `### Action points\n\n${actions}`].filter(Boolean).join("\n\n");
        return (
          <List.Item key={m.id} icon={Icon.TwoPeople} title={m.title || "Meeting"} accessories={[{ text: m.date }]}
            keywords={[m.notes, m.attendees]} detail={<List.Item.Detail markdown={plainMaths(md)} />}
            actions={<ActionPanel>{openInReferee(`referee://meeting/${m.id}`)}<Action.CopyToClipboard title="Copy Notes" content={md} /></ActionPanel>} />
        );
      })}
    </SectionList>
  );
}

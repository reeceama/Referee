import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { openInReferee, SectionList, useProjectList } from "./browse";
import { plainMaths } from "./referee";

// AI Use: the current project's log of AI use, newest first.

type Entry = { id: string; purpose: string; tool: string; version: string; date: string; prompt: string; response: string; checked: string };

export default function Command() {
  const { items, project, error } = useProjectList<Entry>((p) => `ai-log?project=${encodeURIComponent(p)}`);
  const sorted = [...(items ?? [])].sort((a, b) => (b.date || "").localeCompare(a.date || ""));
  return (
    <SectionList items={items} project={project} error={error} empty="No AI use logged" placeholder="Search AI use">
      {sorted.map((e) => {
        const md = [`## ${e.purpose || "AI use"}`, [e.tool, e.version, e.date].filter(Boolean).join(" · "),
          e.prompt && `### What you asked\n\n${e.prompt}`, e.response && `### What it gave you\n\n${e.response}`,
          e.checked && `### How you checked it\n\n${e.checked}`].filter(Boolean).join("\n\n");
        return (
          <List.Item key={e.id} icon={Icon.Stars} title={e.purpose || "AI use"} subtitle={e.tool} accessories={[{ text: e.date }]}
            detail={<List.Item.Detail markdown={plainMaths(md)} />}
            actions={<ActionPanel>{openInReferee()}<Action.CopyToClipboard title="Copy Entry" content={md} /></ActionPanel>} />
        );
      })}
    </SectionList>
  );
}

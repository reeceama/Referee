import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { openInReferee, SectionList, useProjectList } from "./browse";
import { plainMaths } from "./referee";

// Notes: the current project's notes, each shown in full.

type Note = { id: string; title: string; body: string; created?: number };

export default function Command() {
  const { items, project, error } = useProjectList<Note>((p) => `notes?project=${encodeURIComponent(p)}`);
  return (
    <SectionList items={items} project={project} error={error} empty="No notes yet" placeholder="Search notes">
      {[...(items ?? [])].reverse().map((n) => (
        <List.Item key={n.id} icon={Icon.Document} title={plainMaths(n.title || "Untitled")} keywords={[n.body]}
          detail={<List.Item.Detail markdown={`## ${plainMaths(n.title || "Untitled")}\n\n${plainMaths(n.body)}`} />}
          actions={<ActionPanel>{openInReferee(`referee://note/${n.id}`)}<Action.CopyToClipboard title="Copy Note" content={n.body} /></ActionPanel>} />
      ))}
    </SectionList>
  );
}

import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { ReactNode, useEffect, useState } from "react";
import { currentProject, referee } from "./referee";

// The pieces the section commands (Library, Evidence, Notes, Meetings, AI Use) share: the current
// project's items, loaded once, in a list with each one's detail beside it.

export function useProjectList<T>(path: (project: string) => string) {
  const [items, setItems] = useState<T[]>();
  const [project, setProject] = useState("");
  const [error, setError] = useState<string>();
  useEffect(() => {
    (async () => {
      try {
        const name = await currentProject();
        setProject(name);
        setItems(await referee<T[]>(path(name)));
      } catch (e) {
        setError((e as Error).message);
        setItems([]);
      }
    })();
  }, []);
  return { items, project, error };
}

export function SectionList(props: { items?: unknown[]; project: string; error?: string; empty: string; children: ReactNode; placeholder: string }) {
  return (
    <List isLoading={props.items === undefined} isShowingDetail={(props.items?.length ?? 0) > 0}
      searchBarPlaceholder={props.placeholder} navigationTitle={props.project || undefined}>
      <List.EmptyView icon={props.error ? Icon.ExclamationMark : Icon.Tray} title={props.error ?? props.empty}
        description={props.error ? undefined : props.project ? `In ${props.project}` : undefined} />
      {props.children}
    </List>
  );
}

export const openInReferee = (link = "referee://") => <Action.Open title="Open in Referee" target={link} icon={Icon.AppWindow} />;
export { ActionPanel, Color, List };

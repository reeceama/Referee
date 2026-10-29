import { Action, ActionPanel, Icon, List, popToRoot, showToast } from "@raycast/api";
import { useEffect, useState } from "react";
import { referee } from "./referee";

// Switch Project: what you read is saved to the current project, and your writing is checked
// against it.

export default function Command() {
  const [projects, setProjects] = useState<string[]>([]);
  const [current, setCurrent] = useState("");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    referee<{ project?: string; projects?: string[] }>("settings")
      .then((s) => { setProjects(s.projects ?? []); setCurrent(s.project ?? ""); })
      .catch((e) => showToast({ title: (e as Error).message }))
      .finally(() => setLoading(false));
  }, []);

  async function choose(name: string) {
    await referee("settings", { project: name });
    await showToast({ title: `Now in ${name}` });
    await popToRoot();
  }

  return (
    <List isLoading={loading}>
      {projects.map((name) => (
        <List.Item key={name} title={name} icon={name === current ? Icon.CheckCircle : Icon.Circle}
          accessories={name === current ? [{ text: "Current" }] : []}
          actions={<ActionPanel><Action title="Switch to This Project" onAction={() => choose(name)} /></ActionPanel>} />
      ))}
    </List>
  );
}

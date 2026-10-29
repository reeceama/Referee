import { Action, ActionPanel, Form, popToRoot, showToast, Toast } from "@raycast/api";
import { currentProject, referee } from "./referee";

// New Note: a titled note, with an optional Markdown body, in Referee's current project.

export default function Command() {
  async function save(values: { title: string; body: string }) {
    if (!values.title.trim()) {
      await showToast({ style: Toast.Style.Failure, title: "Give the note a title" });
      return;
    }
    try {
      const project = await currentProject();
      await referee("notes", { title: values.title.trim(), body: values.body, project, attachments: [] });
      await showToast({ title: "Note saved", message: project || undefined });
      await popToRoot();
    } catch (e) {
      await showToast({ style: Toast.Style.Failure, title: (e as Error).message });
    }
  }
  return (
    <Form actions={<ActionPanel><Action.SubmitForm title="Save Note" onSubmit={save} /></ActionPanel>}>
      <Form.TextField id="title" title="Title" />
      <Form.TextArea id="body" title="Note" enableMarkdown />
    </Form>
  );
}

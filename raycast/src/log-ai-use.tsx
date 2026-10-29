import { Action, ActionPanel, Form, popToRoot, showToast, Toast } from "@raycast/api";
import { currentProject, referee, today } from "./referee";

// Log AI Use: what you used it for, the tool, and how you checked it, for the project's disclosure.

export default function Command() {
  async function save(values: { purpose: string; tool: string; version: string; checked: string }) {
    if (!values.purpose.trim()) {
      await showToast({ style: Toast.Style.Failure, title: "Say what you used it for" });
      return;
    }
    try {
      const project = await currentProject();
      await referee("ai-log", { ...values, project, date: today(), prompt: "", response: "" });
      await showToast({ title: "AI use logged", message: project || undefined });
      await popToRoot();
    } catch (e) {
      await showToast({ style: Toast.Style.Failure, title: (e as Error).message });
    }
  }
  return (
    <Form actions={<ActionPanel><Action.SubmitForm title="Log AI Use" onSubmit={save} /></ActionPanel>}>
      <Form.TextField id="purpose" title="Used for" />
      <Form.TextField id="tool" title="Tool" />
      <Form.TextField id="version" title="Version" />
      <Form.TextArea id="checked" title="How you checked it" />
    </Form>
  );
}

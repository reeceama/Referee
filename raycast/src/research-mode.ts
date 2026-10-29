import { showHUD } from "@raycast/api";
import { referee } from "./referee";

// Toggle Research Mode: the same switch as the browser extension's popup and Referee's menu bar.
// While it's on, pages you read are saved to the current project.

export default async function Command() {
  try {
    const state = await referee<{ focus?: boolean }>("writing");
    const on = !state.focus;
    await referee("focus", { on });
    const project = (await referee<{ project?: string }>("settings")).project;
    await showHUD(on ? `Research mode on${project ? `: ${project}` : ""}` : "Research mode off");
  } catch (e) {
    await showHUD((e as Error).message);
  }
}

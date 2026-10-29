import { BrowserExtension, environment, LaunchProps, showHUD } from "@raycast/api";
import { referee } from "./referee";

// Save Link: a page saved as a source in the current project, with no form. With nothing typed, the
// page open in your browser (through Raycast's browser extension).

export default async function Command(props: LaunchProps<{ arguments: { url?: string } }>) {
  let url = (props.arguments.url ?? "").trim();
  if (!url && environment.canAccess(BrowserExtension)) {
    const tabs = await BrowserExtension.getTabs().catch(() => []);
    url = tabs.find((t) => t.active)?.url ?? "";
  }
  if (!url.startsWith("http")) {
    await showHUD("Type or paste a link, or open the page in your browser");
    return;
  }
  try {
    const result = await referee<{ ok: boolean; reason?: string }>("sources/add-url", { url });
    await showHUD(result.ok ? "Saved to Referee" : result.reason ?? "Couldn't save that link");
  } catch (e) {
    await showHUD((e as Error).message);
  }
}

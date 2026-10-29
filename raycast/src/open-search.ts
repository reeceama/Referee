import { LaunchProps } from "@raycast/api";
import { execFile } from "child_process";

// Search Referee: opens Referee's own search window (⌘K in the app), bigger than Raycast's and with
// pages shown as they print, with what you typed (or, as a fallback command, what you'd typed in Raycast).

export default async function Command(props: LaunchProps<{ arguments: { q?: string } }>) {
  const q = (props.arguments.q || props.fallbackText || "").trim();
  // In the background (-g), so Referee shows only its search panel, not its main window too.
  await new Promise((done) => execFile("/usr/bin/open", ["-g", `referee://find?q=${encodeURIComponent(q)}`], () => done(null)));
}

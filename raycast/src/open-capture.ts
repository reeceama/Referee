import { execFile } from "child_process";

// Quick Capture: opens Referee's own quick capture window, as its shortcut in the app does.

export default async function Command() {
  // In the background (-g), so Referee shows only its capture panel, not its main window too.
  await new Promise((done) => execFile("/usr/bin/open", ["-g", "referee://capture"], () => done(null)));
}

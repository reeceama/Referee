import { execFile } from "child_process";

// VAR: opens Referee at VAR, to practise a viva on your write-up or an interview on your project.

export default async function Command() {
  await new Promise((done) => execFile("/usr/bin/open", ["referee://open/var"], () => done(null)));
}

import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { openInReferee, SectionList, useProjectList } from "./browse";
import { sourceLink } from "./referee";

// Evidence: each checked claim in the current project's writing, by document, with what backs it.

type Claim = { sentence: string; label: string; document?: string; page?: number; confidence?: number; too_close?: boolean;
               source?: { url?: string; title?: string } };

const RESULTS: Record<string, [string, Color]> = {
  supports: ["Backed", Color.Green], contradicts: ["Contradicted", Color.Red],
  misquote: ["Misquoted", Color.Orange], needs_source: ["Needs a source", Color.Orange],
};

export default function Command() {
  const { items, project, error } = useProjectList<Claim>((p) => `claims?project=${encodeURIComponent(p)}`);
  const documents = Array.from(new Set((items ?? []).map((c) => c.document || "Unnamed document"))).sort();
  return (
    <SectionList items={items} project={project} error={error} empty="No checked writing yet" placeholder="Search claims">
      {documents.map((doc) => (
        <List.Section key={doc} title={doc}>
          {(items ?? []).filter((c) => (c.document || "Unnamed document") === doc).map((c, i) => {
            const [text, colour] = c.too_close && c.label === "supports" ? ["Backed, too close", Color.Orange] : RESULTS[c.label] ?? RESULTS.needs_source;
            const source = c.source?.title || c.source?.url;
            return (
              <List.Item key={`${doc}-${i}`} icon={{ source: Icon.CircleFilled, tintColor: colour }} title={c.sentence}
                detail={<List.Item.Detail markdown={`> ${c.sentence}\n\n**${text}**${source ? `\n\n${source}${c.page ? ` · page ${c.page}` : ""}` : ""}`} />}
                actions={<ActionPanel>
                  {c.source?.url && <Action.OpenInBrowser title="Open Source at This Page" url={sourceLink(c.source.url, c.page)} />}
                  {openInReferee()}
                </ActionPanel>} />
            );
          })}
        </List.Section>
      ))}
    </SectionList>
  );
}

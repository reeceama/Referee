import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { openInReferee, SectionList, useProjectList } from "./browse";
import { sourceLink } from "./referee";

// Library: the current project's saved sources.

type Source = { url: string; title?: string; name?: string; project?: string; site?: string; date?: string; type?: string; authors?: string[] | string };

export default function Command() {
  const { items, project, error } = useProjectList<Source>(() => "sources");
  const mine = (items ?? []).filter((s) => (s.project ?? "") === project);
  return (
    <SectionList items={items && mine} project={project} error={error} empty="No sources saved yet" placeholder="Search sources">
      {mine.map((s) => {
        const title = s.name || s.title || s.url;
        const authors = Array.isArray(s.authors) ? s.authors.join(", ") : s.authors;
        const pdf = s.type === "pdf" || s.url.toLowerCase().endsWith(".pdf");
        return (
          <List.Item key={s.url} icon={pdf ? Icon.Document : Icon.Globe} title={title} keywords={[s.site ?? "", authors ?? ""]}
            detail={<List.Item.Detail markdown={`## ${title}\n\n${[authors, s.site, (s.date ?? "").slice(0, 4)].filter(Boolean).join(" · ")}`} />}
            actions={<ActionPanel><Action.OpenInBrowser title="Open Source" url={sourceLink(s.url)} />{openInReferee()}
              <Action.CopyToClipboard title="Copy Link" content={s.url} /></ActionPanel>} />
        );
      })}
    </SectionList>
  );
}

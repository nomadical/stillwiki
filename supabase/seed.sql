-- ============================================================================
-- stillwiki : sample content
-- Run AFTER schema.sql. Idempotent — re-running won't duplicate rows.
--   Supabase SQL editor, or: supabase db execute < supabase/seed.sql
-- ============================================================================

insert into public.articles (slug, title, folder, tags, published, content) values

-- ---------------------------------------------------------------------------
('welcome', 'Welcome To Stillwiki', '', '{getting-started}', true, $md$
# Welcome to stillwiki 👋

This is a tiny, self-hostable **markdown knowledge base**. Anyone can read
published articles; signed-in editors write them in a split editor with live
preview.

## Start here

- [[markdown-cheatsheet|Markdown cheat sheet]] — everything you can write
- [[using-wikilinks|Linking pages]] — connect articles like in Obsidian
- [[writing-workflow|The writing workflow]] — how editing & publishing works

## How content is organised

- **Folders** are a `/`-separated path (this page lives at the root).
- **Tags** make articles findable from the sidebar search.
- **Drafts** stay hidden from the public until you flip *Published*.

> Tip: hit **+ New article** in the editor, set a folder like `guides/`, and
> start typing.
$md$),

-- ---------------------------------------------------------------------------
('markdown-cheatsheet', 'Markdown Cheat Sheet', 'guides', '{markdown,reference}', true, $md$
# Markdown Cheat Sheet

GitHub-Flavored Markdown (GFM) is fully supported.

## Text

**bold**, _italic_, ~~strikethrough~~, `inline code`, and [links](https://example.com).

## Lists

- Bullet
  - Nested bullet
1. Numbered
2. Numbered

Task list:

- [x] Write the article
- [ ] Publish it

## Quote

> Knowledge shared is knowledge multiplied.

## Table

| Feature      | Supported |
| ------------ | :-------: |
| Tables       | ✅        |
| Code blocks  | ✅        |
| Wikilinks    | ✅        |

## Code

```ts
export function greet(name: string): string {
  return `Hello, ${name}!`;
}
```

## Divider

---

That's the lot. See [[using-wikilinks]] for internal links.
$md$),

-- ---------------------------------------------------------------------------
('using-wikilinks', 'Linking Pages With Wikilinks', 'guides', '{wikilinks,reference}', true, $md$
# Linking Pages With Wikilinks

Connect articles the way you would in Obsidian — with double brackets.

## Syntax

| You write              | You get                          |
| ---------------------- | -------------------------------- |
| `[[welcome]]`          | a link to the **welcome** page   |
| `[[welcome\|Home]]`     | the same link, labelled *Home*   |

The target is matched by **slug** (the URL-safe id of a page). The slug for
*Markdown Cheat Sheet* is `markdown-cheatsheet`, so [[markdown-cheatsheet]]
points straight at it.

## Why use them

- Build a web of related notes instead of dead-end pages.
- Links survive renames as long as the slug is stable.

Next: [[writing-workflow]].
$md$),

-- ---------------------------------------------------------------------------
('writing-workflow', 'The Writing Workflow', 'guides', '{getting-started}', true, $md$
# The Writing Workflow

1. **Sign in** at `/login` with a magic link.
2. **+ New article** — a draft is created and opened in the editor.
3. Fill in **Title**; the **Slug** auto-fills (you can override it).
4. Optionally set a **Folder** (e.g. `guides/setup`) and **Tags**.
5. Write in the left pane — the right pane previews live.
6. Save with the **Save** button or `⌘ / Ctrl + S`.
7. Toggle **Published** when it's ready for the public.

Unpublished articles show a `draft` badge and are visible only in the editor —
see [[internal-roadmap]] for an example (editors only).
$md$),

-- ---------------------------------------------------------------------------
-- A DRAFT: invisible to the public, visible in the editor sidebar.
('internal-roadmap', 'Internal Roadmap', 'internal', '{planning}', false, $md$
# Internal Roadmap (draft)

This page is **unpublished**, so the public KB never shows it — only signed-in
editors see it.

- [ ] Backlinks panel
- [ ] Postgres full-text search
- [ ] Image uploads
$md$)

on conflict (slug) do nothing;

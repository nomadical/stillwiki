import { Router, type Request } from "express";
import multer from "multer";
import JSZip from "jszip";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Role } from "../../src/lib/types";
import {
  articleToMarkdownFile,
  parseMarkdownImport,
  type ExportArticle,
} from "../importExport";
import {
  LANGUAGE_CODES,
  SOURCE_LANGUAGE,
  isSourceLanguage,
} from "../../src/lib/types";
import { slugify } from "../../src/lib/markdown";
import { applyTemplate } from "../../src/lib/templates";
import { HttpError, requireRole, type Actor } from "../auth";
import { logAudit, type AuditAction } from "../audit";

// Port of src/app/admin/actions.ts. Each write runs under the actor's RLS
// (actor.supabase) and records audit_log via the service role — the integrity
// guarantee a direct client→Supabase write can't provide.

const r = Router();
type Result =
  | { ok: true }
  | { ok: false; error: string }
  | { id: string }
  | { ok: true; draft: unknown };

function route(name: string, fn: (req: Request) => Promise<Result>) {
  r.post(`/${name}`, async (req, res) => {
    try {
      res.json(await fn(req));
    } catch (e) {
      if (e instanceof HttpError) res.status(e.status).json({ error: e.message });
      else res.status(500).json({ error: (e as Error)?.message ?? String(e) });
    }
  });
}

const normalizeFolder = (folder: string): string =>
  folder
    .split("/")
    .map((s) => s.trim())
    .filter(Boolean)
    .join("/");

async function titleOf(db: SupabaseClient, id: string): Promise<string | null> {
  const { data } = await db
    .from("articles")
    .select("title")
    .eq("id", id)
    .maybeSingle();
  return (data?.title as string) ?? null;
}

// ---- content + metadata (source language: the caller's PRIVATE draft) ----
// Saving never touches the published `articles` row — it upserts the caller's
// own draft. The published content only changes when the draft is published.
// Private WIP saves are not audited (audit captures the lifecycle events).
route("saveArticle", async (req) => {
  const actor = await requireRole(req, "admin", "editor", "reviewer");
  const i = req.body as {
    id: string;
    title: string;
    slug: string;
    folder: string;
    content: string;
    tags: string[];
    access_roles: string[];
    context_keys: string[];
  };
  const slug = slugify(i.slug || i.title) || i.id;
  const title = i.title.trim() || "Untitled";
  const { error } = await actor.supabase
    .from("article_drafts")
    .upsert(
      {
        article_id: i.id,
        author_id: actor.userId,
        language: SOURCE_LANGUAGE,
        title,
        slug,
        folder: normalizeFolder(i.folder),
        content: i.content,
        tags: i.tags.map((t) => t.trim()).filter(Boolean),
        access_roles: i.access_roles.map((x) => x.trim().toUpperCase()).filter(Boolean),
        context_keys: i.context_keys.map((k) => k.trim()).filter(Boolean),
      },
      { onConflict: "article_id,author_id,language" },
    );
  if (error) return { ok: false, error: error.message };
  return { ok: true };
});

// ---- load/create the caller's private draft for an article (fork-on-edit) ----
route("getDraft", async (req) => {
  const actor = await requireRole(req, "admin", "editor", "reviewer");
  const { data, error } = await actor.supabase.rpc("fork_draft", {
    p_article_id: req.body.id as string,
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true, draft: data };
});

// ---- lifecycle (article + per-language translation) ----
// `language` in the body picks the target: the source language updates the
// `articles` row (unchanged behaviour); any other language updates that
// article's row in `article_translations`. Translations carry their own status,
// so they submit/publish independently of the source.
const langOf = (req: Request): string =>
  (req.body?.language as string) || SOURCE_LANGUAGE;

async function statusUpdate(
  actor: Actor,
  req: Request,
  patch: Record<string, unknown>,
): Promise<{ ok: true } | { ok: false; error: string }> {
  const id = req.body.id as string;
  const language = langOf(req);
  const { error } = isSourceLanguage(language)
    ? await actor.supabase.from("articles").update(patch).eq("id", id)
    : await actor.supabase
        .from("article_translations")
        .update(patch)
        .eq("article_id", id)
        .eq("language", language);
  return error ? { ok: false, error: error.message } : { ok: true };
}

// Choose the article- vs translation-flavoured audit action for the target.
const act = (
  req: Request,
  article: AuditAction,
  translation: AuditAction,
): AuditAction => (isSourceLanguage(langOf(req)) ? article : translation);

// Audit metadata: tag the language for translation lifecycle events.
const langMeta = (
  req: Request,
  extra?: Record<string, unknown>,
): Record<string, unknown> | undefined => {
  const language = langOf(req);
  if (isSourceLanguage(language)) return extra;
  return { language, ...extra };
};

// Source-language lifecycle acts on a specific PRIVATE draft (draftId); the
// translation lifecycle keeps acting on the article_translations row (id+lang).
route("submitForReview", async (req) => {
  const actor = await requireRole(req, "admin", "editor", "reviewer");
  const draftId = req.body.draftId as string | undefined;
  if (draftId) {
    const { data, error } = await actor.supabase
      .from("article_drafts")
      .update({ status: "in_review", submitted_at: new Date().toISOString() })
      .eq("id", draftId)
      .eq("author_id", actor.userId)
      .select("article_id,title")
      .maybeSingle();
    if (error) return { ok: false, error: error.message };
    if (!data) return { ok: false, error: "Draft not found." };
    await logAudit({ actor, action: "article.submit", targetType: "article", targetId: data.article_id as string, summary: data.title as string });
    return { ok: true };
  }
  const id = req.body.id as string;
  const res = await statusUpdate(actor, req, {
    status: "in_review",
    submitted_by: actor.userId,
    submitted_at: new Date().toISOString(),
    review_note: null,
  });
  if (res.ok)
    await logAudit({ actor, action: act(req, "article.submit", "translation.submit"), targetType: "article", targetId: id, summary: await titleOf(actor.supabase, id), metadata: langMeta(req) });
  return res;
});

route("approveArticle", async (req) => {
  const draftId = req.body.draftId as string | undefined;
  if (draftId) {
    // Editors are allowed through here too; publish_draft enforces the real
    // policy from app_settings (requireReview / allowAdminSelfReview).
    const actor = await requireRole(req, "admin", "editor", "reviewer");
    const { data, error } = await actor.supabase.rpc("publish_draft", { p_draft_id: draftId });
    if (error) return { ok: false, error: error.message };
    const a = data as { id: string; title: string };
    await logAudit({ actor, action: "article.approve", targetType: "article", targetId: a.id, summary: a.title });
    return { ok: true };
  }
  const actor = await requireRole(req, "admin", "reviewer");
  const id = req.body.id as string;
  const res = await statusUpdate(actor, req, { status: "published", review_note: null });
  if (res.ok)
    await logAudit({ actor, action: act(req, "article.approve", "translation.approve"), targetType: "article", targetId: id, summary: await titleOf(actor.supabase, id), metadata: langMeta(req) });
  return res;
});

route("requestChanges", async (req) => {
  const actor = await requireRole(req, "admin", "reviewer");
  const { id, note, draftId } = req.body as { id?: string; note: string; draftId?: string };
  if (draftId) {
    const { data, error } = await actor.supabase.rpc("request_changes_draft", { p_draft_id: draftId, p_note: note });
    if (error) return { ok: false, error: error.message };
    const d = data as { article_id: string; title: string };
    await logAudit({ actor, action: "article.request_changes", targetType: "article", targetId: d.article_id, summary: d.title, metadata: { note: note.trim() || null } });
    return { ok: true };
  }
  const res = await statusUpdate(actor, req, { status: "draft", review_note: note.trim() || null });
  if (res.ok)
    await logAudit({ actor, action: act(req, "article.request_changes", "translation.request_changes"), targetType: "article", targetId: id as string, summary: await titleOf(actor.supabase, id as string), metadata: langMeta(req, { note: note.trim() || null }) });
  return res;
});

route("unpublishArticle", async (req) => {
  const actor = await requireRole(req, "admin", "reviewer");
  const id = req.body.id as string;
  const res = await statusUpdate(actor, req, { status: "draft" });
  if (res.ok)
    await logAudit({ actor, action: act(req, "article.unpublish", "translation.unpublish"), targetType: "article", targetId: id, summary: await titleOf(actor.supabase, id), metadata: langMeta(req) });
  return res;
});

route("withdrawReview", async (req) => {
  const actor = await requireRole(req, "admin", "editor", "reviewer");
  const draftId = req.body.draftId as string | undefined;
  if (draftId) {
    const { data, error } = await actor.supabase
      .from("article_drafts")
      .update({ status: "draft" })
      .eq("id", draftId)
      .eq("author_id", actor.userId)
      .select("article_id,title")
      .maybeSingle();
    if (error) return { ok: false, error: error.message };
    if (!data) return { ok: false, error: "Draft not found." };
    await logAudit({ actor, action: "article.withdraw", targetType: "article", targetId: data.article_id as string, summary: data.title as string });
    return { ok: true };
  }
  const id = req.body.id as string;
  const res = await statusUpdate(actor, req, { status: "draft" });
  if (res.ok)
    await logAudit({ actor, action: act(req, "article.withdraw", "translation.withdraw"), targetType: "article", targetId: id, summary: await titleOf(actor.supabase, id), metadata: langMeta(req) });
  return res;
});

// ---- translation content (per-language title + body) ----
// Upsert the (article_id, language) row. Created lazily on first save of a
// language; never touches `status` (so saving an in_review translation keeps it
// in review, matching saveArticle). RLS + the parent's can_write_article gate
// who may write. Article-level fields (slug/folder/tags/access_roles/context)
// stay on the source article and are not duplicated here.
route("saveTranslation", async (req) => {
  const actor = await requireRole(req, "admin", "editor");
  const i = req.body as {
    articleId: string;
    language: string;
    title: string;
    content: string;
  };
  if (!LANGUAGE_CODES.includes(i.language) || isSourceLanguage(i.language))
    return { ok: false, error: `Unsupported translation language "${i.language}".` };
  const title = i.title.trim() || "Untitled";
  const { data, error } = await actor.supabase
    .from("article_translations")
    .upsert(
      { article_id: i.articleId, language: i.language, title, content: i.content },
      { onConflict: "article_id,language" },
    )
    .select("id");
  if (error)
    return {
      ok: false,
      error:
        error.code === "42501"
          ? "You don't have the entitlement to edit this article."
          : error.message,
    };
  if (!data || data.length === 0)
    return { ok: false, error: "You don't have the entitlement to edit this article." };
  await logAudit({ actor, action: "translation.update", targetType: "article", targetId: i.articleId, summary: title, metadata: { language: i.language } });
  return { ok: true };
});

route("restoreTranslationRevision", async (req) => {
  const actor = await requireRole(req, "admin", "editor");
  const { revisionId } = req.body as { revisionId: string };
  const { data: rev, error: re } = await actor.supabase
    .from("article_translation_revisions")
    .select("translation_id,article_id,language,revision,title,content")
    .eq("id", revisionId)
    .maybeSingle();
  if (re) return { ok: false, error: re.message };
  if (!rev) return { ok: false, error: "Revision not found." };
  const { error } = await actor.supabase
    .from("article_translations")
    .update({ title: rev.title, content: rev.content })
    .eq("id", rev.translation_id);
  if (error) return { ok: false, error: error.message };
  await logAudit({ actor, action: "translation.restore_version", targetType: "article", targetId: rev.article_id as string, summary: rev.title as string, metadata: { language: rev.language, revision: rev.revision } });
  return { ok: true };
});

// ---- create (returns the new id; the SPA navigates) ----
// New articles are created with the author's private draft atomically (RLS-safe
// via the create_article RPC). They are invisible to others until published.
route("createArticle", async (req) => {
  const actor = await requireRole(req, "admin", "editor");
  const { data, error } = await actor.supabase.rpc("create_article");
  if (error) throw new HttpError(500, error.message);
  const id = data as string;
  await logAudit({ actor, action: "article.create", targetType: "article", targetId: id, summary: "Untitled" });
  return { id };
});

route("createArticleFromTemplate", async (req) => {
  const actor = await requireRole(req, "admin", "editor");
  const templateId = req.body.templateId as string;
  const { data: tpl, error: te } = await actor.supabase
    .from("article_templates")
    .select("name,content,folder,tags")
    .eq("id", templateId)
    .maybeSingle();
  if (te) throw new HttpError(500, te.message);
  if (!tpl) throw new HttpError(404, "Template not found.");
  const { data, error } = await actor.supabase.rpc("create_article");
  if (error) throw new HttpError(500, error.message);
  const id = data as string;
  const content = applyTemplate(tpl.content as string, { title: "Untitled", author: actor.email ?? undefined });
  // Seed the freshly-created private draft with the template content.
  await actor.supabase
    .from("article_drafts")
    .update({ content, folder: tpl.folder, tags: tpl.tags })
    .eq("article_id", id)
    .eq("author_id", actor.userId)
    .eq("language", SOURCE_LANGUAGE);
  await logAudit({ actor, action: "article.create", targetType: "article", targetId: id, summary: `From template “${tpl.name}”` });
  return { id };
});

// ---- templates ----
route("saveTemplate", async (req) => {
  const actor = await requireRole(req, "admin", "editor");
  const i = req.body as {
    id?: string;
    name: string;
    description: string;
    content: string;
    folder: string;
    tags: string[];
  };
  const row = {
    name: i.name.trim(),
    description: i.description.trim() || null,
    content: i.content,
    folder: normalizeFolder(i.folder),
    tags: i.tags.map((t) => t.trim()).filter(Boolean),
  };
  if (!row.name) return { ok: false, error: "Template needs a name." };
  const { data, error } = i.id
    ? await actor.supabase.from("article_templates").update(row).eq("id", i.id).select("id").single()
    : await actor.supabase.from("article_templates").insert({ ...row, created_by: actor.userId }).select("id").single();
  if (error)
    return { ok: false, error: error.code === "23505" ? `A template named “${row.name}” already exists.` : error.message };
  await logAudit({ actor, action: i.id ? "template.update" : "template.create", targetType: "template", targetId: data.id, summary: row.name });
  return { ok: true };
});

route("deleteTemplate", async (req) => {
  const actor = await requireRole(req, "admin");
  const id = req.body.id as string;
  const { data: tpl } = await actor.supabase.from("article_templates").select("name").eq("id", id).maybeSingle();
  const { error } = await actor.supabase.from("article_templates").delete().eq("id", id);
  if (error) return { ok: false, error: error.message };
  await logAudit({ actor, action: "template.delete", targetType: "template", targetId: id, summary: (tpl?.name as string) ?? id });
  return { ok: true };
});

// ---- trash / revisions ----
route("deleteArticle", async (req) => {
  const actor = await requireRole(req, "admin");
  const id = req.body.id as string;
  const title = await titleOf(actor.supabase, id);
  const { error } = await actor.supabase
    .from("articles")
    .update({ deleted_at: new Date().toISOString(), deleted_by: actor.userId, status: "draft" })
    .eq("id", id);
  if (error) return { ok: false, error: error.message };
  await logAudit({ actor, action: "article.trash", targetType: "article", targetId: id, summary: title });
  return { ok: true };
});

route("restoreArticle", async (req) => {
  const actor = await requireRole(req, "admin");
  const id = req.body.id as string;
  const title = await titleOf(actor.supabase, id);
  const { error } = await actor.supabase.from("articles").update({ deleted_at: null, deleted_by: null }).eq("id", id);
  if (error)
    return { ok: false, error: error.code === "23505" ? "Another live article already uses this slug — rename it first." : error.message };
  await logAudit({ actor, action: "article.restore", targetType: "article", targetId: id, summary: title });
  return { ok: true };
});

route("purgeArticle", async (req) => {
  const actor = await requireRole(req, "admin");
  const id = req.body.id as string;
  const { data: row } = await actor.supabase.from("articles").select("title,deleted_at").eq("id", id).maybeSingle();
  if (!row) return { ok: false, error: "Article not found." };
  if (!row.deleted_at) return { ok: false, error: "Only trashed articles can be permanently deleted." };
  await logAudit({ actor, action: "article.purge", targetType: "article", targetId: id, summary: row.title as string });
  const { error } = await actor.supabase.from("articles").delete().eq("id", id);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
});

// Restoring a published version writes it into the caller's private draft (to
// be re-published), rather than mutating the live article directly.
route("restoreRevision", async (req) => {
  const actor = await requireRole(req, "admin", "editor", "reviewer");
  const { articleId, revisionId } = req.body as { articleId: string; revisionId: string };
  const { data: rev, error: re } = await actor.supabase
    .from("article_revisions")
    .select("revision,title,slug,folder,content,tags,access_roles")
    .eq("id", revisionId)
    .eq("article_id", articleId)
    .maybeSingle();
  if (re) return { ok: false, error: re.message };
  if (!rev) return { ok: false, error: "Revision not found." };
  const { error: fe } = await actor.supabase.rpc("fork_draft", { p_article_id: articleId });
  if (fe) return { ok: false, error: fe.message };
  const { error } = await actor.supabase
    .from("article_drafts")
    .update({ title: rev.title, slug: rev.slug, folder: rev.folder, content: rev.content, tags: rev.tags, access_roles: rev.access_roles })
    .eq("article_id", articleId)
    .eq("author_id", actor.userId)
    .eq("language", SOURCE_LANGUAGE);
  if (error) return { ok: false, error: error.message };
  await logAudit({ actor, action: "article.restore_version", targetType: "article", targetId: articleId, summary: rev.title as string, metadata: { revision: rev.revision } });
  return { ok: true };
});

// ---- users ----
route("setUserRole", async (req) => {
  const actor = await requireRole(req, "admin");
  const { userId, role } = req.body as { userId: string; role: Role };
  if (userId === actor.userId) return { ok: false, error: "You can't change your own role." };
  const { data: before } = await actor.supabase.from("profiles").select("email,role").eq("id", userId).maybeSingle();
  const { error } = await actor.supabase.from("profiles").update({ role, role_source: "manual" }).eq("id", userId);
  if (error) return { ok: false, error: error.message };
  await logAudit({ actor, action: "user.role_change", targetType: "user", targetId: userId, summary: `${before?.email ?? userId}: ${before?.role ?? "?"} → ${role}`, metadata: { from: before?.role ?? null, to: role } });
  return { ok: true };
});

route("setUserAccessRoles", async (req) => {
  const actor = await requireRole(req, "admin");
  const { userId, roles } = req.body as { userId: string; roles: string[] };
  const clean = [...new Set(roles.map((x) => x.trim().toUpperCase()).filter(Boolean))];
  const { data: before } = await actor.supabase.from("profiles").select("email").eq("id", userId).maybeSingle();
  const { error } = await actor.supabase.from("profiles").update({ manual_access_roles: clean }).eq("id", userId);
  if (error) return { ok: false, error: error.message };
  await logAudit({ actor, action: "user.access_roles_change", targetType: "user", targetId: userId, summary: `${before?.email ?? userId}: granted [${clean.join(", ") || "none"}]`, metadata: { roles: clean } });
  return { ok: true };
});

// ---- app settings ----
route("updateSettings", async (req) => {
  const actor = await requireRole(req, "admin");
  const settings = (req.body as { settings: Record<string, unknown> }).settings;
  const { error } = await actor.supabase
    .from("app_settings")
    .update({ value: settings, updated_at: new Date().toISOString(), updated_by: actor.userId })
    .eq("id", 1);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
});

// ---- bulk export / import (admin) ----
// Export: every live article as a frontmatter .md file, bundled into a zip
// (organized by folder). Runs under the admin's RLS. Import: accepts .md files
// and/or .zip archives; each doc becomes a NEW article seeded into the
// importer's private draft (invisible until published), consistent with the
// per-user-draft model.

r.get("/export", async (req, res) => {
  try {
    const actor = await requireRole(req, "admin");
    const { data, error } = await actor.supabase
      .from("articles")
      .select("slug,title,folder,tags,access_roles,context_keys,content,status")
      .is("deleted_at", null)
      .order("folder")
      .order("slug");
    if (error) throw new HttpError(500, error.message);

    const zip = new JSZip();
    for (const a of (data ?? []) as ExportArticle[]) {
      const { path, contents } = articleToMarkdownFile(a);
      zip.file(path, contents);
    }
    const buf = await zip.generateAsync({ type: "nodebuffer" });
    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Disposition", 'attachment; filename="stillwiki-export.zip"');
    res.send(buf);
  } catch (e) {
    if (e instanceof HttpError) res.status(e.status).json({ error: e.message });
    else res.status(500).json({ error: (e as Error).message });
  }
});

const uploadImport = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 25 * 1024 * 1024, files: 500 },
});

r.post("/import", uploadImport.array("files"), async (req, res) => {
  try {
    const actor = await requireRole(req, "admin");
    const files = (req.files as Express.Multer.File[]) ?? [];

    // Expand: .zip → its .md entries; .md → itself.
    const docs: { path: string; raw: string }[] = [];
    for (const f of files) {
      if (/\.zip$/i.test(f.originalname)) {
        const zip = await JSZip.loadAsync(f.buffer);
        for (const entry of Object.values(zip.files)) {
          if (entry.dir || !/\.md$/i.test(entry.name)) continue;
          docs.push({ path: entry.name, raw: await entry.async("string") });
        }
      } else if (/\.md$/i.test(f.originalname)) {
        docs.push({ path: f.originalname, raw: f.buffer.toString("utf8") });
      }
    }
    if (docs.length === 0)
      throw new HttpError(400, "No .md files found in the upload.");

    let imported = 0;
    const errors: { path: string; error: string }[] = [];
    for (const doc of docs) {
      try {
        const parsed = parseMarkdownImport(doc.path, doc.raw);
        if (!parsed.content.trim()) {
          errors.push({ path: doc.path, error: "Empty content." });
          continue;
        }
        const { data: id, error: ce } = await actor.supabase.rpc("create_article");
        if (ce) throw new Error(ce.message);
        const { error: ue } = await actor.supabase
          .from("article_drafts")
          .update({
            title: parsed.title,
            slug: parsed.slug,
            folder: parsed.folder,
            content: parsed.content,
            tags: parsed.tags,
            access_roles: parsed.access_roles,
            context_keys: parsed.context_keys,
          })
          .eq("article_id", id as string)
          .eq("author_id", actor.userId)
          .eq("language", SOURCE_LANGUAGE);
        if (ue) throw new Error(ue.message);
        await logAudit({
          actor,
          action: "article.create",
          targetType: "article",
          targetId: id as string,
          summary: parsed.title,
          metadata: { import: true, source: doc.path },
        });
        imported++;
      } catch (e) {
        errors.push({ path: doc.path, error: (e as Error).message });
      }
    }
    res.json({ imported, total: docs.length, errors });
  } catch (e) {
    if (e instanceof HttpError) res.status(e.status).json({ error: e.message });
    else res.status(500).json({ error: (e as Error).message });
  }
});

export default r;

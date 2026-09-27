import { Router, type Request, type Response } from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { adminClient } from "../supabase";
import { slugify } from "../../src/lib/markdown";
import { MCP_API_TOKEN, SITE_URL } from "../env";

// Remote MCP server for the knowledge base (read-only article tools over MCP).
// route, which used the Next-only `mcp-handler`). Lets a Claude.ai connector
// search the KB and create *draft* articles (never published — a human reviews).
// Streamable-HTTP endpoint at <site>/knowledge-base/api/mcp.
//
// Auth: static bearer (MCP_API_TOKEN). Writes use the service-role client and
// are constrained to status='draft', so the connector can never publish.

const textResult = (text: string) => ({
  content: [{ type: "text" as const, text }],
});

/** Collapse/trim a folder path: " A // B " -> "A/B". */
const normFolder = (folder: string): string =>
  folder
    .split("/")
    .map((s) => s.trim())
    .filter(Boolean)
    .join("/");

function buildServer(): McpServer {
  const server = new McpServer({ name: "stillwiki", version: "1.0.0" });

  server.tool(
    "search_kb_articles",
    "Search existing Knowledge Base articles (incl. drafts) by text. Use this before creating an article to avoid duplicates and find related content.",
    {
      query: z.string().describe("Free-text query (title + body)."),
      limit: z.number().int().min(1).max(25).optional(),
    },
    async ({ query, limit }) => {
      const db = adminClient();
      if (!db) return textResult("Knowledge Base is not configured.");
      const q = query.trim();
      if (q.length < 2) return textResult("Query too short.");
      const { data, error } = await db
        .from("articles")
        .select("slug,title,folder,status")
        .is("deleted_at", null)
        .textSearch("search_tsv", q, { type: "websearch", config: "english" })
        .limit(limit ?? 10);
      if (error) return textResult(`Search failed: ${error.message}`);
      if (!data || data.length === 0) return textResult(`No articles match "${q}".`);
      return textResult(
        data
          .map(
            (a) =>
              `- ${a.title} [${a.status}] (slug: ${a.slug}${a.folder ? `, folder: ${a.folder}` : ""})`,
          )
          .join("\n"),
      );
    },
  );

  server.tool(
    "list_kb_folders",
    "List existing KB folder paths so a new article can be placed consistently.",
    {},
    async () => {
      const db = adminClient();
      if (!db) return textResult("Knowledge Base is not configured.");
      const { data, error } = await db
        .from("articles")
        .select("folder")
        .is("deleted_at", null);
      if (error) return textResult(`Failed: ${error.message}`);
      const folders = [
        ...new Set((data ?? []).map((r) => r.folder).filter(Boolean)),
      ].sort();
      return textResult(folders.length ? folders.join("\n") : "(no folders yet)");
    },
  );

  server.tool(
    "create_draft_article",
    "Create a DRAFT Knowledge Base article. Drafts are never public — a human editor reviews and publishes them. Returns the draft's admin edit URL. Search first to avoid duplicates.",
    {
      title: z.string().min(1).max(200),
      content: z.string().min(1).describe("Markdown body."),
      folder: z.string().optional().describe('e.g. "Asset Management/Onboarding".'),
      tags: z.array(z.string()).optional(),
      context_keys: z
        .array(z.string())
        .optional()
        .describe('Stable host-screen keys, e.g. "intervention.shipment-detail".'),
    },
    async ({ title, content, folder, tags, context_keys }) => {
      const db = adminClient();
      if (!db) return textResult("Knowledge Base is not configured.");
      const base = slugify(title) || "draft";
      const row = {
        title: title.trim() || "Untitled",
        content,
        folder: normFolder(folder ?? ""),
        tags: (tags ?? []).map((t) => t.trim()).filter(Boolean),
        context_keys: (context_keys ?? []).map((k) => k.trim()).filter(Boolean),
        status: "draft" as const,
        slug: base,
      };
      let res = await db.from("articles").insert(row).select("id,slug").maybeSingle();
      // Partial unique index on active slugs -> retry once with a suffix.
      if (res.error && res.error.code === "23505") {
        row.slug = `${base}-${Date.now().toString(36)}`;
        res = await db.from("articles").insert(row).select("id,slug").maybeSingle();
      }
      if (res.error) return textResult(`Could not create draft: ${res.error.message}`);
      const url = SITE_URL
        ? `${SITE_URL}/admin/${res.data?.id}`
        : `/admin/${res.data?.id}`;
      return textResult(
        `Created draft "${row.title}" (slug: ${row.slug}). Review & publish at: ${url}`,
      );
    },
  );

  return server;
}

function authorized(req: Request): boolean {
  if (!MCP_API_TOKEN) return false;
  const token = (req.header("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  return token.length > 0 && token === MCP_API_TOKEN;
}

const r = Router();

// Stateless Streamable-HTTP: a fresh server + transport per request (no session).
r.post("/", async (req: Request, res: Response) => {
  if (!authorized(req)) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  try {
    const server = buildServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
    });
    res.on("close", () => {
      void transport.close();
      void server.close();
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (e) {
    if (!res.headersSent) res.status(500).json({ error: (e as Error).message });
  }
});

// Stateless server: no SSE stream / session teardown.
const methodNotAllowed = (_req: Request, res: Response) =>
  res.status(405).json({ error: "Method Not Allowed" });
r.get("/", methodNotAllowed);
r.delete("/", methodNotAllowed);

export default r;

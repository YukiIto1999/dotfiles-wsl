import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const { default: plugin } = await import(process.env.MEMORY_PLUGIN!);
const workspace = mkdtempSync(join(tmpdir(), "project-memory-client-"));
const gates = new Map<string, ReturnType<typeof gate>>();
type RetainItem = { document_id: string; content: string; metadata: Record<string, string> };
type FixtureDocument = {
  id: string; bank_id: string; original_text: string;
  document_metadata: Record<string, string>; memory_unit_count: number;
};
const documents = new Map<string, FixtureDocument>();
let bank: string;
let server: ReturnType<typeof Bun.serve>;

function gate() {
  return { seen: Promise.withResolvers<void>(), release: Promise.withResolvers<void>() };
}

const claims: Record<string, string> = {
  "slow-one": "プロジェクト一の訂正を優先する。",
  "fast-two": "プロジェクト二の仕様を参照する。",
  "slow-old": "以前の指示は取り消された。",
  "fast-current": "現在の指示だけを採用する。",
};

async function command(args: string[]): Promise<string> {
  const child = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  if (code !== 0) throw new Error(stderr);
  return stdout;
}

beforeAll(async () => {
  await command(["git", "init", workspace]);
  bank = JSON.parse(await command([process.env.MEMORY_BINARY!, "project", workspace])).bank_id;
  server = Bun.serve({
    hostname: "127.0.0.1",
    port: 18082,
    idleTimeout: 0,
    async fetch(request: Request) {
      const path = new URL(request.url).pathname;
      if (path === "/stall") return Promise.withResolvers<Response>().promise;
      if (path === "/v1/default/banks") return Response.json({ banks: [{ bank_id: bank }] });
      if (request.method === "PATCH" && path.endsWith("/config")) {
        const body = await request.json() as { updates: unknown };
        return Response.json({ bank_id: bank, overrides: body.updates });
      }
      if (request.method === "POST" && path.endsWith("/memories")) {
        const body = await request.json() as { items: RetainItem[]; operation_id: string };
        const item = body.items[0];
        documents.set(item.document_id, {
          id: item.document_id, bank_id: bank, original_text: item.content,
          document_metadata: item.metadata, memory_unit_count: 1,
        });
        return Response.json({ success: true, bank_id: bank, async: true, items_count: 1, operation_id: body.operation_id });
      }
      if (path.includes("/operations/")) {
        return Response.json({ operation_id: path.split("/operations/")[1], status: "completed" });
      }
      if (path.includes("/documents/")) {
        return Response.json(documents.get(decodeURIComponent(path.split("/documents/")[1])));
      }
      if (path.endsWith("/memories/recall")) {
        const { query } = await request.json() as { query: string };
        const pending = gates.get(query);
        if (pending) {
          pending.seen.resolve();
          await pending.release.promise;
        }
        return Response.json({ results: [{ id: "fixture-memory", text: claims[query] }] });
      }
      return Response.json({ error: "unexpected endpoint" }, { status: 404 });
    },
  });
});

afterAll(() => {
  server?.stop(true);
  rmSync(workspace, { recursive: true, force: true });
});

async function hooks() {
  return plugin({
    worktree: workspace,
    client: {
      session: { messages: async () => ({ data: [] }) },
      tui: { showToast: async () => ({ data: true }) },
    },
  });
}

test("concurrent sessions receive only their own recalled context", async () => {
  const callbacks = await hooks();
  const pending = gate();
  gates.set("slow-one", pending);
  const first = callbacks["chat.message"]({ sessionID: "one" }, { parts: [{ type: "text", text: "slow-one" }] });
  await pending.seen.promise;
  try {
    await callbacks["chat.message"]({ sessionID: "two" }, { parts: [{ type: "text", text: "fast-two" }] });
  } finally {
    pending.release.resolve();
  }
  await first;
  const one = { system: [] as string[] };
  const two = { system: [] as string[] };
  await callbacks["experimental.chat.system.transform"]({ sessionID: "one" }, one);
  await callbacks["experimental.chat.system.transform"]({ sessionID: "two" }, two);
  expect(one.system.join("\n")).toContain(claims["slow-one"]);
  expect(one.system.join("\n")).not.toContain(claims["fast-two"]);
  expect(two.system.join("\n")).toContain(claims["fast-two"]);
  expect(two.system.join("\n")).not.toContain(claims["slow-one"]);
}, 15000);

test("late old recall cannot replace the newest prompt context", async () => {
  const callbacks = await hooks();
  const pending = gate();
  gates.set("slow-old", pending);
  const old = callbacks["chat.message"]({ sessionID: "one" }, { parts: [{ type: "text", text: "slow-old" }] });
  await pending.seen.promise;
  try {
    await callbacks["chat.message"]({ sessionID: "one" }, { parts: [{ type: "text", text: "fast-current" }] });
  } finally {
    pending.release.resolve();
  }
  await old;
  const current = { system: [] as string[] };
  await callbacks["experimental.chat.system.transform"]({ sessionID: "one" }, current);
  expect(current.system.join("\n")).toContain(claims["fast-current"]);
  expect(current.system.join("\n")).not.toContain(claims["slow-old"]);
}, 15000);

test("auxiliary model requests do not consume the active turn recall", async () => {
  const callbacks = await hooks();
  await callbacks["chat.message"]({ sessionID: "new-session" }, { parts: [{ type: "text", text: "fast-current" }] });
  const title = { system: [] as string[] };
  const response = { system: [] as string[] };
  await callbacks["experimental.chat.system.transform"]({ sessionID: "new-session" }, title);
  await callbacks["experimental.chat.system.transform"]({ sessionID: "new-session" }, response);
  expect(response.system.join("\n")).toContain(claims["fast-current"]);
  await callbacks.event({ event: { type: "session.idle", properties: { sessionID: "new-session" } } });
  const afterTurn = { system: [] as string[] };
  await callbacks["experimental.chat.system.transform"]({ sessionID: "new-session" }, afterTurn);
  expect(afterTurn.system).toEqual([]);
});

test("capture aborts stalled history and warning requests", async () => {
  const nativeTimeout = AbortSignal.timeout.bind(AbortSignal);
  const timeout = spyOn(AbortSignal, "timeout").mockImplementation(() => nativeTimeout(1));
  let warningVisible = false;
  const callbacks = await plugin({
    worktree: workspace,
    client: {
      session: {
        messages: async ({ signal }: { signal: AbortSignal }) => ({
          data: await (await fetch(new URL("/stall", server.url), { signal })).json(),
        }),
      },
      tui: {
        showToast: async ({ body, signal }: { body: { variant: string }; signal: AbortSignal }) => {
          warningVisible = body.variant === "warning";
          await fetch(new URL("/stall", server.url), { signal });
        },
      },
    },
  });
  try {
    await callbacks.event({ event: { type: "session.idle", properties: { sessionID: "stalled" } } });
    expect(warningVisible).toBe(true);
  } finally {
    timeout.mockRestore();
  }
});

test("dispose waits for unawaited capture and its failure warning", async () => {
  const history = gate();
  const notification = gate();
  let warning = "";
  const callbacks = await plugin({
    worktree: workspace,
    client: {
      session: {
        messages: async () => {
          history.seen.resolve();
          await history.release.promise;
          throw new Error("history unavailable");
        },
      },
      tui: {
        showToast: async ({ body }: { body: { message: string } }) => {
          warning = body.message;
          notification.seen.resolve();
          await notification.release.promise;
        },
      },
    },
  });
  const capture = callbacks.event({ event: { type: "session.idle", properties: { sessionID: "closing" } } });
  await history.seen.promise;
  let disposed = false;
  const disposal = Promise.resolve(callbacks.dispose?.()).then(() => { disposed = true; });
  try {
    await Promise.resolve();
    expect(disposed).toBe(false);
    history.release.resolve();
    await notification.seen.promise;
    expect(disposed).toBe(false);
    notification.release.resolve();
    await disposal;
    expect(warning).toContain("history unavailable");
  } finally {
    history.release.resolve();
    notification.release.resolve();
    await capture;
    await disposal;
  }
});

test("failed assistant turns are not retained while completed turns are", async () => {
  let failed = true;
  const callbacks = await plugin({
    worktree: workspace,
    client: {
      session: {
        messages: async () => ({ data: [
          { info: { role: "user" }, parts: [{ type: "text", text: "検証済みの訂正だけを保存する。" }] },
          {
            info: {
              role: "assistant", time: { completed: 1 }, finish: "stop",
              ...(failed ? { error: { name: "APIError" } } : {}),
            },
            parts: [{ type: "text", text: failed ? "unfinished-claim" : "verified-final-answer" }],
          },
        ] }),
      },
      tui: { showToast: async () => ({ data: true }) },
    },
  });
  await callbacks.event({ event: { type: "session.idle", properties: { sessionID: "incomplete" } } });
  expect([...documents.values()].filter((doc) => doc.document_metadata.source === "session:opencode:incomplete")).toEqual([]);
  failed = false;
  await callbacks.event({ event: { type: "session.idle", properties: { sessionID: "complete" } } });
  const saved = [...documents.values()].find((doc) => doc.document_metadata.source === "session:opencode:complete");
  expect(saved?.original_text).toContain("verified-final-answer");
});

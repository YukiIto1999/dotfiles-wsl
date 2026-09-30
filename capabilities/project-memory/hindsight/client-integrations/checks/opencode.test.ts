import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const { default: plugin } = await import(process.env.MEMORY_PLUGIN!);
const workspace = mkdtempSync(join(tmpdir(), "project-memory-client-"));
const gates = new Map<string, ReturnType<typeof gate>>();
// hook が backend へ送った要求。turn の終わりに会話を送らないことを確かめる
const requests: string[] = [];
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
      requests.push(`${request.method} ${path}`);
      if (path === "/v1/default/banks") return Response.json({ banks: [{ bank_id: bank }] });
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
});

test("session idle discards the recall and sends nothing to memory", async () => {
  // 完結した turn を履歴に置く。会話を保存する実装ならここで送る
  const callbacks = await plugin({
    worktree: workspace,
    client: {
      session: {
        messages: async () => ({ data: [
          { info: { role: "user" }, parts: [{ type: "text", text: "検証済みの訂正だけを保存する。" }] },
          { info: { role: "assistant", time: { completed: 1 }, finish: "stop" }, parts: [{ type: "text", text: "完了した応答" }] },
        ] }),
      },
      tui: { showToast: async () => ({ data: true }) },
    },
  });
  await callbacks["chat.message"]({ sessionID: "idle-session" }, { parts: [{ type: "text", text: "fast-current" }] });
  const before = requests.length;
  await callbacks.event({ event: { type: "session.idle", properties: { sessionID: "idle-session" } } });
  expect(requests.slice(before)).toEqual([]);
  const afterTurn = { system: [] as string[] };
  await callbacks["experimental.chat.system.transform"]({ sessionID: "idle-session" }, afterTurn);
  expect(afterTurn.system).toEqual([]);
});

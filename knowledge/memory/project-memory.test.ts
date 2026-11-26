import { afterAll, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// 実 runtime の代わりに、呼ばれた回数を記録して固定の文脈を返す。fail の印があれば失敗する
const workspace = mkdtempSync(join(tmpdir(), "project-memory-hook-"));
afterAll(() => rmSync(workspace, { recursive: true, force: true }));
const calls = join(workspace, "calls");
const failing = join(workspace, "fail");
const memory = join(workspace, "dotfiles-memory");
writeFileSync(
  memory,
  `#!${Bun.which("bash")}
echo "$*" >> "${calls}"
if [ -e "${failing}" ]; then echo "fixture failure" >&2; exit 1; fi
echo "<project_memory>recalled</project_memory>"
`,
);
chmodSync(memory, 0o755);
const hook = join(workspace, "project-memory.ts");
writeFileSync(hook, readFileSync(join(import.meta.dir, "project-memory.ts"), "utf8").replace("@memoryBinary@", memory));
// hook は配備時に binary の path を埋める template のため、置換後の写しを実行時に読む
const { default: projectMemory } = await import(hook);

type Handler = (event: unknown, ctx: unknown) => unknown;

function client() {
  const handlers = new Map<string, Handler[]>();
  const warnings: string[] = [];
  projectMemory({
    on: (name: string, handler: Handler) => handlers.set(name, [...(handlers.get(name) ?? []), handler]),
    logger: { warn: (message: string) => warnings.push(message) },
  } as never);
  async function start(session: string, prompt: string, reason = "prompt") {
    const ctx = { cwd: workspace, sessionManager: { getSessionId: () => session }, ui: { notify: () => {} } };
    for (const handler of handlers.get("before_agent_start") ?? []) {
      const result = await handler({ reason, prompt }, ctx);
      if (result) return result;
    }
    return undefined;
  }
  return { start, warnings };
}

const recalls = () => (existsSync(calls) ? readFileSync(calls, "utf8").split("\n").filter(Boolean).length : 0);

beforeEach(() => {
  rmSync(calls, { force: true });
  rmSync(failing, { force: true });
});

test("only the first prompt of a session recalls and injects the context", async () => {
  const { start } = client();
  expect(await start("first", "最初の依頼")).toEqual({
    message: {
      customType: "project-memory-context",
      content: "<project_memory>recalled</project_memory>",
      display: false,
      attribution: "agent",
    },
  });
  expect(recalls()).toBe(1);
  expect(await start("first", "次の依頼")).toBeUndefined();
  expect(await start("first", "停止 hook の再投入")).toBeUndefined();
  expect(await start("first", "継続", "continue")).toBeUndefined();
  expect(recalls()).toBe(1);
  expect(await start("second", "別 session の最初の依頼")).toBeDefined();
  expect(recalls()).toBe(2);
});

test("an empty prompt does not use up the recall of its session", async () => {
  const { start } = client();
  expect(await start("empty", "   ")).toBeUndefined();
  expect(recalls()).toBe(0);
  expect(await start("empty", "依頼")).toBeDefined();
  expect(recalls()).toBe(1);
});

test("a failed recall warns without blocking the prompt and is not retried", async () => {
  writeFileSync(failing, "");
  const { start, warnings } = client();
  expect(await start("failing", "最初の依頼")).toBeUndefined();
  expect(warnings).toEqual(["Project memory recall failed: fixture failure"]);
  expect(await start("failing", "次の依頼")).toBeUndefined();
  expect(recalls()).toBe(1);
  expect(warnings).toHaveLength(1);
});

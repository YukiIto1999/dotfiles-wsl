import { beforeAll, expect, test } from "bun:test";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Handler = (event: Record<string, unknown>, ctx: unknown) => Promise<unknown>;
type Handlers = Map<string, Handler>;

const TEST_TIMEOUT_MS = 60_000;
const home = process.env.HOME as string;
const workDir = join(home, "work");
const skillBody = join(home, ".omp/agent/skills/ui-design/SKILL.md");
const GUARDED_PATH = "/r/surfaces/viewer/x.tsx";
const FREE_PATH = "/r/docs/note.md";
const LARGE_WRITE = 3 * 1024 * 1024;
const COMPLETE = `# ui-design\n${Array.from(
  { length: 6000 },
  (_, index) => `Discipline line ${index + 1} stays in the body so the read exceeds one argument.`,
).join("\n")}\n`;

let real: Handlers;
let hanging: Handlers;

async function load(hookPath: string): Promise<Handlers> {
  const { default: verificationGate } = await import(hookPath);
  const handlers: Handlers = new Map();
  verificationGate({
    on: (name: string, handler: Handler) => handlers.set(name, handler),
    logger: { warn: () => undefined },
  });
  return handlers;
}

function handlerOf(handlers: Handlers, name: string): Handler {
  const handler = handlers.get(name);
  if (!handler) throw new Error(`the hook registered no ${name} handler`);
  return handler;
}

const context = (session: string, cwd = workDir) => ({
  cwd,
  sessionManager: { getSessionId: () => session },
});

const write = (handlers: Handlers, session: string, input: Record<string, unknown>, cwd = workDir) =>
  handlerOf(handlers, "tool_call")({ toolName: "write", toolCallId: `${session}-write`, input }, context(session, cwd));

function readEvent(session: string, shown: string) {
  const lines = shown.split("\n");
  return {
    toolName: "read",
    toolCallId: `${session}-read`,
    input: { path: skillBody },
    isError: false,
    content: [{ type: "text", text: shown }],
    details: {
      resolvedPath: skillBody,
      totalLines: lines.length,
      displayContent: { text: shown, startLine: 1, lineNumbers: lines.map((_, index) => index + 1) },
    },
  };
}

const learn = (session: string, event: Record<string, unknown>) =>
  handlerOf(real, "tool_result")(event, context(session));

async function expectBlockedForSkill(session: string, content = "x") {
  const outcome = (await write(real, session, { path: GUARDED_PATH, content })) as { block: true; reason: string };
  expect(outcome.block).toBe(true);
  expect(outcome.reason).toContain("skill://ui-design");
}

function isRunning(pid: number): boolean {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const state = stat[stat.lastIndexOf(")") + 2];
    return state !== "Z" && state !== "X";
  } catch {
    return false;
  }
}

async function until(condition: () => boolean, what: string): Promise<void> {
  const deadline = performance.now() + 10_000;
  while (!condition()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(20);
  }
}

async function descendantOf(cwd: string): Promise<number> {
  const file = join(cwd, "descendant.pid");
  await until(() => existsSync(file) && /^\d+$/.test(readFileSync(file, "utf8").trim()), "the gate's descendant");
  return Number(readFileSync(file, "utf8").trim());
}

beforeAll(async () => {
  mkdirSync(dirname(skillBody), { recursive: true });
  mkdirSync(workDir, { recursive: true });
  real = await load(process.env.GATE_HOOK as string);
  hanging = await load(process.env.HANGING_GATE_HOOK as string);
});

test("small events keep refusing unread disciplines and accept read ones", async () => {
  writeFileSync(skillBody, "# ui-design\nShort discipline.\n");
  expect(await write(real, "small-free", { path: FREE_PATH, content: "note" })).toBeUndefined();
  await expectBlockedForSkill("small");
  await learn("small", readEvent("small", "# ui-design\nShort discipline."));
  expect(await write(real, "small", { path: GUARDED_PATH, content: "x" })).toBeUndefined();
}, TEST_TIMEOUT_MS);

test("a write larger than the argv limits reaches the gate", async () => {
  writeFileSync(skillBody, "# ui-design\nShort discipline.\n");
  const content = "x".repeat(LARGE_WRITE);
  expect(await write(real, "large-write-free", { path: FREE_PATH, content })).toBeUndefined();
  await expectBlockedForSkill("large-write-unread", content);
}, TEST_TIMEOUT_MS);

test("only a complete read beyond the argv limit counts as reading the discipline", async () => {
  writeFileSync(skillBody, COMPLETE);
  const shown = COMPLETE.slice(0, -1);
  const content = "x".repeat(LARGE_WRITE);
  const altered = `${shown.slice(0, 100_000)}§${shown.slice(100_001)}`;
  const refused: Record<string, Record<string, unknown>> = {
    truncated: readEvent("large-truncated", shown.slice(0, -2000)),
    altered: readEvent("large-altered", altered),
    "altered-rendered": {
      ...readEvent("large-altered-rendered", shown),
      content: [{ type: "text", text: altered }],
    },
    "no-display": {
      ...readEvent("large-no-display", shown),
      details: { resolvedPath: skillBody, totalLines: 6001 },
    },
    "no-result": { ...readEvent("large-no-result", shown), content: [], details: undefined },
  };
  for (const [name, event] of Object.entries(refused)) {
    const session = `large-${name}`;
    await learn(session, event);
    await expectBlockedForSkill(session, content);
  }

  await expectBlockedForSkill("large-complete", content);
  await learn("large-complete", readEvent("large-complete", shown));
  expect(await write(real, "large-complete", { path: GUARDED_PATH, content })).toBeUndefined();

  appendFileSync(skillBody, "Changed after the read.\n");
  await expectBlockedForSkill("large-complete", content);
  await learn("large-replayed", readEvent("large-replayed", shown));
  await expectBlockedForSkill("large-replayed", content);
}, TEST_TIMEOUT_MS);

test("an aborted stop hook takes the gate's descendants down with it", async () => {
  const cwd = join(home, "abort");
  mkdirSync(cwd, { recursive: true });
  const controller = new AbortController();
  const pending = handlerOf(hanging, "session_stop")(
    { signal: controller.signal, stop_hook_active: false },
    context("abort", cwd),
  );
  const descendant = await descendantOf(cwd);
  expect(isRunning(descendant)).toBe(true);
  controller.abort();
  expect(await pending).toMatchObject({ decision: "block", reason: expect.stringContaining("aborted") });
  await until(() => !isRunning(descendant), "the descendant to stop");
}, TEST_TIMEOUT_MS);

test("a gate that outlives its deadline blocks the edit and its descendants stop", async () => {
  const cwd = join(home, "deadline");
  mkdirSync(cwd, { recursive: true });
  const started = performance.now();
  const outcome = await write(hanging, "deadline", { path: FREE_PATH, content: "x" }, cwd);
  expect(performance.now() - started).toBeGreaterThanOrEqual(19_000);
  expect(outcome).toMatchObject({ block: true, reason: expect.stringContaining("timed out") });
  const descendant = await descendantOf(cwd);
  await until(() => !isRunning(descendant), "the descendant to stop");
}, TEST_TIMEOUT_MS);

test("a hook loaded for one generation keeps its own gate after the next generation's hook loads", async () => {
  writeFileSync(skillBody, "# ui-design\nShort discipline.\n");
  const calls = join(home, "next-generation-gate.calls");
  const next = await load(process.env.NEXT_GENERATION_GATE_HOOK as string);
  expect(await write(next, "next-session", { path: GUARDED_PATH, content: "x" })).toBeUndefined();
  const recorded = readFileSync(calls, "utf8");
  expect(recorded).toContain("hook edit");
  await expectBlockedForSkill("older-session");
  expect(readFileSync(calls, "utf8")).toBe(recorded);
}, TEST_TIMEOUT_MS);

import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type Handler = (event: Record<string, unknown>, ctx: unknown) => unknown;

interface Host {
  handlers: Map<string, Handler>;
  notices: string[];
}

interface Call {
  pid: number;
  session: string;
  cwd: string;
  prompt: string;
}

const TEST_TIMEOUT_MS = 60_000;
const RECALL_TIMEOUT_MS = 30_000;
const BACKEND_PORT = 18082;
const scratch = process.env.FAKE_MEMORY_DIR as string;
const callsFile = join(scratch, "calls.log");
const releaseFile = join(scratch, "release");
const descendantFile = join(scratch, "descendant.pid");
const project = join(scratch, "project");
const otherProject = join(scratch, "other-project");

/** backend が受けた recall 要求 */
const recallRequests: { bank: string; query: string }[] = [];
const banks: string[] = [];
let backendDown = false;
let backend: { stop(closeActiveConnections?: boolean): unknown } | undefined;
let repositoryX: string;
let repositoryY: string;
let bankX: string;
let bankY: string;

async function command(args: string[]): Promise<string> {
  const child = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0) throw new Error(stderr);
  return stdout;
}

async function repository(name: string): Promise<{ path: string; bank: string }> {
  const path = join(scratch, name);
  await command(["git", "init", path]);
  const bank = JSON.parse(await command([process.env.MEMORY_BINARY as string, "project", path])).bank_id;
  banks.push(bank);
  return { path, bank };
}

beforeAll(async () => {
  mkdirSync(scratch);
  mkdirSync(project);
  mkdirSync(otherProject);
  ({ path: repositoryX, bank: bankX } = await repository("repository-x"));
  ({ path: repositoryY, bank: bankY } = await repository("repository-y"));
  backend = Bun.serve({
    hostname: "127.0.0.1",
    port: BACKEND_PORT,
    idleTimeout: 0,
    async fetch(request: Request) {
      const url = new URL(request.url);
      if (url.pathname === "/v1/default/banks") return Response.json({ banks: banks.map((bank_id) => ({ bank_id })) });
      const recall = url.pathname.match(/^\/v1\/default\/banks\/([^/]+)\/memories\/recall$/);
      if (!recall) return Response.json({ error: "unexpected endpoint" }, { status: 404 });
      const bank = decodeURIComponent(recall[1]);
      const { query } = (await request.json()) as { query: string };
      recallRequests.push({ bank, query });
      if (backendDown) return Response.json({ error: "backend down" }, { status: 500 });
      return Response.json({
        results: [{ id: `memory-${recallRequests.length}`, text: `recall ${recallRequests.length} bank=${bank}` }],
      });
    },
  });
}, TEST_TIMEOUT_MS);

afterAll(() => {
  backend?.stop(true);
  rmSync(scratch, { recursive: true, force: true });
});

function reset(): void {
  writeFileSync(callsFile, "");
  rmSync(releaseFile, { force: true });
  rmSync(descendantFile, { force: true });
}

function calls(): Call[] {
  if (!existsSync(callsFile)) return [];
  return readFileSync(callsFile, "utf8")
    .split("\n")
    .filter((line) => line !== "")
    .map((line) => {
      const [pid, session, cwd, prompt] = line.split("\t");
      return { pid: Number(pid), session, cwd, prompt };
    });
}

function statOf(pid: number): { state: string; started: string } | undefined {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return { state: fields[0], started: fields[19] };
  } catch {
    return undefined;
  }
}

function isRunning(pid: number): boolean {
  const stat = statOf(pid);
  return stat !== undefined && stat.state !== "Z" && stat.state !== "X";
}

// pid だけの照合は再利用された別 process を同じ子と誤認するため不可
function isReaped(identity: { pid: number; started: string }): boolean {
  const stat = statOf(identity.pid);
  return stat === undefined || stat.started !== identity.started;
}

async function until(condition: () => boolean, what: string): Promise<void> {
  const deadline = performance.now() + 10_000;
  while (!condition()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(20);
  }
}

afterEach(() => {
  expect(calls().filter((call) => statOf(call.pid) !== undefined)).toEqual([]);
});

async function load(hookPath: string): Promise<Host> {
  // 配備済み hook の path は実行時の環境変数で決まるため静的 import は不可
  const { default: projectMemory } = await import(hookPath);
  const host: Host = { handlers: new Map(), notices: [] };
  projectMemory({
    on: (name: string, handler: Handler) => host.handlers.set(name, handler),
    logger: { warn: () => undefined },
  });
  return host;
}

function emit(host: Host, name: string, event: Record<string, unknown>, session: string, cwd: string): unknown {
  const handler = host.handlers.get(name);
  if (!handler) {
    if (name === "before_agent_start") throw new Error("the hook registered no before_agent_start handler");
    return undefined;
  }
  return handler(
    { type: name, ...event },
    {
      cwd,
      sessionManager: { getSessionId: () => session },
      ui: { notify: (message: string) => host.notices.push(message) },
    },
  );
}

/** 利用者の入力 */
const submit = (host: Host, session: string, cwd: string, text: string) =>
  emit(host, "input", { text, source: "interactive" }, session, cwd);

/** main session の停止判定 */
const stop = (host: Host, session: string, cwd: string) =>
  emit(host, "session_stop", { messages: [], stop_hook_active: false }, session, cwd);

/** 一回の agent loop の settle */
const settle = (host: Host, session: string, cwd: string, willContinue?: boolean) =>
  emit(host, "agent_end", { messages: [], ...(willContinue === undefined ? {} : { willContinue }) }, session, cwd);

/** 会話へ注入する記憶の本文で、注入しないときは undefined */
async function begin(
  host: Host,
  session: string,
  cwd: string,
  prompt: string,
  reason: "prompt" | "revive" = "prompt",
): Promise<string | undefined> {
  const result = (await emit(host, "before_agent_start", { reason, prompt, systemPrompt: [] }, session, cwd)) as
    | { message?: { customType: string; content: string; display: boolean; attribution: string } }
    | undefined;
  if (!result?.message) return undefined;
  expect(result.message).toMatchObject({ customType: "project-memory-context", display: false, attribution: "agent" });
  return result.message.content;
}

test("a user request recalls once and a re-entry of the same submission reuses that recall", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "reentry", project, "request one");
  const first = await begin(host, "reentry", project, "request one");
  const again = await begin(host, "reentry", project, "request one");
  expect(first).toContain("call 1 session=reentry");
  expect(again).toBe(first);
  expect(calls()).toHaveLength(1);
}, TEST_TIMEOUT_MS);

test("internal continuations after a stop neither spawn memory nor inject again, whatever their text", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "continuation", project, "request one");
  expect(await begin(host, "continuation", project, "request one")).toContain("call 1");
  for (const text of ["gate says continue", "gate says continue", "another gate reason"]) {
    await stop(host, "continuation", project);
    await settle(host, "continuation", project, true);
    expect(await begin(host, "continuation", project, text)).toBeUndefined();
  }
  expect(calls().map((call) => call.prompt)).toEqual(["request one"]);
}, TEST_TIMEOUT_MS);

test("a new user request recalls again and never reuses the previous result", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "turns", project, "request one");
  const first = await begin(host, "turns", project, "request one");
  await stop(host, "turns", project);
  await settle(host, "turns", project);
  await submit(host, "turns", project, "request one");
  const repeated = await begin(host, "turns", project, "request one");
  await submit(host, "turns", project, "request two");
  const changed = await begin(host, "turns", project, "request two");
  expect(first).toContain("call 1 ");
  expect(repeated).toContain("call 2 ");
  expect(repeated).not.toBe(first);
  expect(changed).toContain("call 3 session=turns");
  expect(changed).toContain("prompt=request two");
  expect(calls()).toHaveLength(3);
}, TEST_TIMEOUT_MS);

test("without input events a terminal settle ends the turn and a stop marks only the resumption", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  const first = await begin(host, "headless", project, "request one");
  await stop(host, "headless", project);
  await settle(host, "headless", project, true);
  expect(await begin(host, "headless", project, "gate says continue")).toBeUndefined();
  await stop(host, "headless", project);
  await settle(host, "headless", project);
  const second = await begin(host, "headless", project, "request one");
  expect(first).toContain("call 1 ");
  expect(second).toContain("call 2 ");
  expect(calls()).toHaveLength(2);
}, TEST_TIMEOUT_MS);

test("a user input outstanding at the stop is never mistaken for a resumption", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "queued", project, "queued follow-up");
  await stop(host, "queued", project);
  const whichever = await begin(host, "queued", project, "gate says continue");
  const queued = await begin(host, "queued", project, "queued follow-up");
  expect(whichever).toContain("call 1 ");
  expect(queued).toContain("call 2 ");
  expect(queued).toContain("prompt=queued follow-up");
}, TEST_TIMEOUT_MS);

test("sessions and projects never receive each other's recall", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "session-a", project, "same words");
  const a = await begin(host, "session-a", project, "same words");
  await submit(host, "session-b", project, "same words");
  const b = await begin(host, "session-b", project, "same words");
  const aAgain = await begin(host, "session-a", project, "same words");
  const elsewhere = await begin(host, "session-a", otherProject, "same words");
  await stop(host, "session-c", project);
  const unrelated = await begin(host, "session-d", project, "same words");
  expect(a).toContain("session=session-a");
  expect(b).toContain("session=session-b");
  expect(b).not.toContain("session=session-a");
  expect(aAgain).toBe(a);
  expect(elsewhere).toContain(`cwd=${otherProject}`);
  expect(elsewhere).not.toContain(`cwd=${project}`);
  expect(unrelated).toContain("session=session-d");
  expect(calls().map((call) => [call.session, call.cwd])).toEqual([
    ["session-a", project],
    ["session-b", project],
    ["session-a", otherProject],
    ["session-d", project],
  ]);
}, TEST_TIMEOUT_MS);

test("concurrent starts of the same submission share one recall", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "shared", project, "hold: shared request");
  const one = begin(host, "shared", project, "hold: shared request");
  const two = begin(host, "shared", project, "hold: shared request");
  await until(() => calls().length === 1, "the recall to start");
  expect(calls()).toHaveLength(1);
  writeFileSync(releaseFile, "");
  const [first, second] = await Promise.all([one, two]);
  expect(first).toContain("call 1 session=shared");
  expect(second).toBe(first);
  expect(calls()).toHaveLength(1);
}, TEST_TIMEOUT_MS);

test("a revived subagent and a blank prompt spawn no memory process", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  expect(await begin(host, "revive", project, "", "revive")).toBeUndefined();
  expect(await begin(host, "revive", project, "   ")).toBeUndefined();
  expect(calls()).toEqual([]);
}, TEST_TIMEOUT_MS);

test("a failed recall warns once, is not retried by a resumption, and is retried by the next user request", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "failure", project, "fail: request one");
  expect(await begin(host, "failure", project, "fail: request one")).toBeUndefined();
  expect(await begin(host, "failure", project, "fail: request one")).toBeUndefined();
  await stop(host, "failure", project);
  await settle(host, "failure", project, true);
  expect(await begin(host, "failure", project, "gate says continue")).toBeUndefined();
  expect(calls()).toHaveLength(1);
  expect(host.notices).toEqual([expect.stringContaining("Project memory recall failed: backend unavailable")]);
  await settle(host, "failure", project);
  await submit(host, "failure", project, "fail: request one");
  expect(await begin(host, "failure", project, "fail: request one")).toBeUndefined();
  expect(calls()).toHaveLength(2);
  expect(host.notices).toHaveLength(2);
  await submit(host, "failure", project, "request two");
  expect(await begin(host, "failure", project, "request two")).toContain("call 3 ");
}, TEST_TIMEOUT_MS);

// 実 process の 30 秒の期限を確かめるため fake timer は不可
test("a recall that outlives its deadline is reaped with its descendants and is not retried by a resumption", async () => {
  reset();
  const host = await load(process.env.FAKE_MEMORY_HOOK as string);
  await submit(host, "deadline", project, "hang: request one");
  const started = performance.now();
  const pending = begin(host, "deadline", project, "hang: request one");
  await until(() => existsSync(descendantFile) && /^\d+$/.test(readFileSync(descendantFile, "utf8").trim()), "the recall's descendant");
  const descendant = Number(readFileSync(descendantFile, "utf8").trim());
  const [spawned] = calls();
  const child = { pid: spawned.pid, started: statOf(spawned.pid)?.started as string };
  expect(isRunning(child.pid)).toBe(true);
  expect(isRunning(descendant)).toBe(true);
  const outcome = await pending;
  // 返却後の待ち直しは返却時点の寿命を検証できないため不可
  const returned = { childReaped: isReaped(child), descendantRunning: isRunning(descendant) };
  expect(outcome).toBeUndefined();
  expect(returned).toEqual({ childReaped: true, descendantRunning: false });
  expect(performance.now() - started).toBeGreaterThanOrEqual(RECALL_TIMEOUT_MS - 1000);
  expect(host.notices).toEqual([expect.stringContaining(`timed out after ${RECALL_TIMEOUT_MS / 1000}s`)]);
  expect(await begin(host, "deadline", project, "hang: request one")).toBeUndefined();
  expect(calls()).toHaveLength(1);
  expect(host.notices).toHaveLength(1);
}, TEST_TIMEOUT_MS);

test("the backend receives one recall per user request, none for resumptions, and per-project banks", async () => {
  reset();
  const host = await load(process.env.BACKEND_MEMORY_HOOK as string);
  const before = recallRequests.length;
  await submit(host, "backend", repositoryX, "request about the build");
  const first = await begin(host, "backend", repositoryX, "request about the build");
  const again = await begin(host, "backend", repositoryX, "request about the build");
  await stop(host, "backend", repositoryX);
  await settle(host, "backend", repositoryX, true);
  const resumed = await begin(host, "backend", repositoryX, "internal continuation text");
  expect(again).toBe(first);
  expect(resumed).toBeUndefined();
  expect(recallRequests.slice(before)).toEqual([{ bank: bankX, query: "request about the build" }]);
  expect(first).toContain(`bank=${bankX}`);

  await stop(host, "backend", repositoryX);
  await settle(host, "backend", repositoryX);
  await submit(host, "backend", repositoryX, "request about the build");
  const second = await begin(host, "backend", repositoryX, "request about the build");
  expect(recallRequests.slice(before)).toHaveLength(2);
  expect(second).not.toBe(first);

  await submit(host, "backend-other", repositoryY, "request about the build");
  const other = await begin(host, "backend-other", repositoryY, "request about the build");
  expect(recallRequests.at(-1)).toEqual({ bank: bankY, query: "request about the build" });
  expect(other).toContain(`bank=${bankY}`);
  expect(other).not.toContain(`bank=${bankX}`);
}, TEST_TIMEOUT_MS);

test("a backend failure is reported once and a recovered backend serves the next user request", async () => {
  reset();
  const host = await load(process.env.BACKEND_MEMORY_HOOK as string);
  const before = recallRequests.length;
  backendDown = true;
  try {
    await submit(host, "outage", repositoryX, "request during the outage");
    expect(await begin(host, "outage", repositoryX, "request during the outage")).toBeUndefined();
    expect(await begin(host, "outage", repositoryX, "request during the outage")).toBeUndefined();
    await stop(host, "outage", repositoryX);
    await settle(host, "outage", repositoryX, true);
    expect(await begin(host, "outage", repositoryX, "internal continuation text")).toBeUndefined();
  } finally {
    backendDown = false;
  }
  expect(recallRequests.slice(before)).toHaveLength(1);
  expect(host.notices).toEqual([expect.stringContaining("Project memory recall failed")]);
  await settle(host, "outage", repositoryX);
  await submit(host, "outage", repositoryX, "request after the outage");
  expect(await begin(host, "outage", repositoryX, "request after the outage")).toContain(`bank=${bankX}`);
  expect(recallRequests.slice(before)).toHaveLength(2);
}, TEST_TIMEOUT_MS);

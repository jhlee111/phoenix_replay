// Tests for panel async lifecycle: cleanup Promise, canStart hooks,
// inline-error API. Run with: node test/js/canstart_hook_test.js
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_replay.js"),
  "utf8"
);

function makeSandbox() {
  const sandbox = {
    window: {},
    document: undefined,
    console,
    setTimeout,
    clearTimeout,
    Promise,
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  return sandbox;
}

function assert(cond, msg) {
  if (!cond) { console.error("FAIL:", msg); process.exit(1); }
}

(async () => {
  const sb = makeSandbox();
  const { collectCleanupResults } = sb.window.PhoenixReplay._testInternals;

  // sync cleanups: returns resolved Promise
  {
    const cleanups = new Map();
    let counter = 0;
    cleanups.set("a", () => { counter += 1; });
    cleanups.set("b", () => { counter += 10; });
    const result = collectCleanupResults(cleanups);
    assert(result && typeof result.then === "function", "returns a thenable");
    await result;
    assert(counter === 11, "all sync cleanups ran");
  }

  // mixed sync + async
  {
    const cleanups = new Map();
    let asyncDone = false;
    cleanups.set("sync", () => {});
    cleanups.set("async", () => new Promise(r => setTimeout(() => { asyncDone = true; r(); }, 10)));
    await collectCleanupResults(cleanups);
    assert(asyncDone, "async cleanup completed before promise resolved");
  }

  // thrown sync cleanup is logged but does not abort other cleanups
  {
    const cleanups = new Map();
    let bRan = false;
    cleanups.set("a", () => { throw new Error("boom"); });
    cleanups.set("b", () => { bRan = true; });
    await collectCleanupResults(cleanups);
    assert(bRan, "sibling cleanup ran despite earlier throw");
  }

  // canStart registry: empty → ok
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([]);
    assert(result.ok === true, "empty hook list returns ok:true");
  }

  // single hook ok
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["audio", async () => ({ ok: true })],
    ]);
    assert(result.ok === true, "single ok hook returns ok:true");
  }

  // single hook fails → error threaded through with failingId
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["audio", async () => ({ ok: false, error: "Mic blocked." })],
    ]);
    assert(result.ok === false, "failing hook returns ok:false");
    assert(result.error === "Mic blocked.", "error message threaded through");
    assert(result.failingId === "audio", "failingId identifies the hook");
  }

  // ok + fail → fail wins (first failure short-circuits)
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["zzz", async () => ({ ok: true })],
      ["audio", async () => ({ ok: false, error: "Nope." })],
    ]);
    assert(result.ok === false, "any failure makes overall fail");
    assert(result.failingId === "audio", "fail propagates");
  }

  // throwing hook is caught and treated as ok:false
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["audio", async () => { throw new Error("getUserMedia failed"); }],
    ]);
    assert(result.ok === false, "throw becomes ok:false");
    assert(typeof result.error === "string" && result.error.length > 0, "error message present");
  }

  console.log("canstart_hook_test: ok");
})();

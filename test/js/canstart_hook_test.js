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

  console.log("canstart_hook_test: ok");
})();

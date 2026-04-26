// Pure-function test for createRingBuffer time-window eviction.
// Run with: node test/js/ring_buffer_test.js
// No test framework — exits 1 on first failure.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_replay.js"),
  "utf8"
);

// Build a fake browser global so the IIFE wires onto it.
const sandbox = { window: {}, document: undefined, console };
vm.createContext(sandbox);
vm.runInContext(src, sandbox);

// Reach the internal factory via the test hook we add in Task 2 step 3.
const { createRingBuffer } = sandbox.window.PhoenixReplay._testInternals;

function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
}

// --- count-based cap (existing behavior preserved) ---
{
  let now = 0;
  const buf = createRingBuffer({ maxEvents: 3, windowMs: null, nowFn: () => now });
  buf.push({ k: "a" });
  buf.push({ k: "b" });
  buf.push({ k: "c" });
  buf.push({ k: "d" }); // evicts "a" by count cap
  const drained = buf.drain();
  assert(drained.length === 3, "count cap keeps 3");
  assert(drained[0].k === "b", "head 'a' evicted by count cap");
}

// --- time-window eviction ---
{
  let now = 1000;
  const buf = createRingBuffer({ maxEvents: 100, windowMs: 60000, nowFn: () => now });
  buf.push({ k: "old" });          // t=1000
  now = 30000;
  buf.push({ k: "mid" });          // t=30000
  now = 90000;                     // 90s elapsed; "old" is 89s old → evicted on next push
  buf.push({ k: "fresh" });        // t=90000
  const drained = buf.drain();
  assert(drained.length === 2, `time-window keeps 2, got ${drained.length}`);
  assert(drained[0].k === "mid", "head 'old' evicted by time window");
  assert(drained[1].k === "fresh", "fresh retained");
}

// --- drain returns events without their wrapper timestamps ---
{
  let now = 0;
  const buf = createRingBuffer({ maxEvents: 10, windowMs: null, nowFn: () => now });
  buf.push({ type: 2, data: { x: 1 } });
  const out = buf.drain();
  assert(out.length === 1, "drain count");
  assert(out[0].type === 2, "drain returns the original event shape");
  assert(out[0].data.x === 1, "drain preserves nested fields");
}

// --- size() reflects current contents ---
{
  let now = 0;
  const buf = createRingBuffer({ maxEvents: 10, windowMs: null, nowFn: () => now });
  buf.push({ k: 1 });
  buf.push({ k: 2 });
  assert(buf.size() === 2, "size after pushes");
  buf.drain();
  assert(buf.size() === 0, "size after drain");
}

console.log("OK ring_buffer_test (4 cases)");

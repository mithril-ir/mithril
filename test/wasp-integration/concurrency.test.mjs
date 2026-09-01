// Hermetic regression for the concurrency helpers
// (test/wasp-integration/concurrency.mjs): it needs no PostgreSQL and
// no Wasp server.  It pins that
//
//   * the barrier deadline stays strictly and substantially below
//     Prisma's interactive-transaction timeout;
//   * two concurrent independentRequest calls GENUINELY OVERLAP at a
//     local barrier server (two live sockets before any response is
//     released, zero fallback-deadline releases) — and a deliberately
//     serialized dispatch, which uses two distinct successive sockets
//     but never overlaps, is REJECTED by the same oracle;
//   * a partial, aborted response makes independentRequest reject
//     within a bounded time (rather than hang) while its companion
//     still settles;
//   * settlement and transport-error description are TOTAL for
//     arbitrary rejection values (synchronous throws, null-prototype
//     objects, hostile getters/coercion, cyclic and excessively deep
//     cause chains, non-Error primitives), so a malformed rejection
//     never escapes as an uninformative top-level throw and never
//     hides a companion outcome, another failure, or later evidence.
//
// Run by test/wasp-integration/test-harness.sh (scenario 9).
// Test-only tooling, outside the confinement claim.

import http from "node:http";

import {
  BARRIER_DEADLINE_MS,
  BARRIER_SAFETY_MARGIN_MS,
  PRISMA_TRANSACTION_TIMEOUT_MS,
  barrierDeadlineInterval,
  describeTransportError,
  evaluateTwoAdminBarrierEvidence,
  independentRequest,
  renderTransportFailure,
  settleConcurrent,
} from "./concurrency.mjs";

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`ok: ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL: ${name}${detail === undefined ? "" : ` — ${detail}`}`);
  }
}

// Reject if `promise` has not settled within `ms`, and never leave a
// pending timer: used to assert bounded (non-hanging) settlement.
function withDeadline(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} did not settle within ${ms} ms`)), ms);
    if (typeof timer.unref === "function") {
      timer.unref();
    }
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

// --- 1. barrier deadline strictly and substantially below Prisma's timeout ---

check(
  "the barrier deadline is strictly below Prisma's interactive-transaction timeout",
  BARRIER_DEADLINE_MS < PRISMA_TRANSACTION_TIMEOUT_MS,
  `${BARRIER_DEADLINE_MS} vs ${PRISMA_TRANSACTION_TIMEOUT_MS}`,
);
check(
  "the safety margin below the transaction timeout is at least 2000 ms",
  BARRIER_SAFETY_MARGIN_MS === PRISMA_TRANSACTION_TIMEOUT_MS - BARRIER_DEADLINE_MS && BARRIER_SAFETY_MARGIN_MS >= 2000,
  `${BARRIER_SAFETY_MARGIN_MS} ms`,
);
check(
  "Prisma's documented default transaction timeout is pinned at 5000 ms",
  PRISMA_TRANSACTION_TIMEOUT_MS === 5000,
  `${PRISMA_TRANSACTION_TIMEOUT_MS}`,
);
check(
  "the barrier interval literal is expressed in milliseconds and is no longer '5 seconds'",
  barrierDeadlineInterval() === `${BARRIER_DEADLINE_MS} milliseconds` && !barrierDeadlineInterval().includes("5 seconds"),
  barrierDeadlineInterval(),
);

// --- 2. a transport rejection is a pinned failure, not a top-level throw ---

// A synthetic fetch/undici-style transport rejection (cause.code) and
// a synthetic node:http-style one (code on the error itself).
const fetchStyle = Object.assign(new TypeError("fetch failed"), {
  cause: Object.assign(new Error("other side closed"), { code: "UND_ERR_SOCKET" }),
});
const httpStyle = Object.assign(new Error("socket hang up"), { code: "ECONNRESET" });

{
  const described = describeTransportError(fetchStyle);
  check(
    "a fetch-style transport error surfaces its nested Undici code and cause",
    described.code === "UND_ERR_SOCKET" && described.cause === "other side closed" && described.message === "fetch failed",
    JSON.stringify(described),
  );
}
{
  const described = describeTransportError(httpStyle);
  check(
    "a node:http-style transport error surfaces its own code",
    described.code === "ECONNRESET" && described.message === "socket hang up",
    JSON.stringify(described),
  );
}

{
  // settleConcurrent must not throw when a task rejects: it collects
  // the rejection, names the request, and still returns the other
  // task's observation.
  let threw = false;
  let result;
  try {
    result = await settleConcurrent(
      [
        () => Promise.resolve({ status: 200, text: "ok" }),
        () => Promise.reject(fetchStyle),
      ],
      ["first request", "second request"],
    );
  } catch {
    threw = true;
  }
  check("settleConcurrent does not throw when a request rejects", !threw);
  check(
    "settleConcurrent keeps the fulfilled observation and nulls the rejected one",
    result && result.observations.length === 2 && result.observations[0] && result.observations[0].status === 200 && result.observations[1] === null,
    result && JSON.stringify(result.observations),
  );
  check(
    "settleConcurrent identifies which request failed, with its code and cause",
    result &&
      result.transportFailures.length === 1 &&
      result.transportFailures[0].label === "second request" &&
      result.transportFailures[0].index === 1 &&
      result.transportFailures[0].code === "UND_ERR_SOCKET" &&
      result.transportFailures[0].cause === "other side closed",
    result && JSON.stringify(result.transportFailures),
  );
  const rendered = result && renderTransportFailure(result.transportFailures[0]);
  check(
    "the rendered transport failure names the request, the message, the code, and the cause",
    rendered === "second request: fetch failed [UND_ERR_SOCKET] (other side closed)",
    rendered,
  );
  check(
    "both concurrent settlements are represented (a rejection does not hide the other)",
    result && result.observations.filter((o) => o !== null).length === 1 && result.transportFailures.length === 1,
    result && JSON.stringify(result),
  );
}

// --- 3. settlement and diagnostic rendering are TOTAL (finding 3) -----------

{
  // A synchronous task throw must become a recorded rejection, not
  // escape before Promise.allSettled — with a fulfilled companion.
  let threw = false;
  let result;
  try {
    result = await settleConcurrent(
      [
        () => {
          throw new Error("synchronous boom");
        },
        () => Promise.resolve({ status: 200, text: "ok" }),
      ],
      ["throwing task", "ok task"],
    );
  } catch {
    threw = true;
  }
  check(
    "a synchronous task throw is recorded as a rejection, not an escape (fulfilled companion retained)",
    !threw &&
      result &&
      result.observations[0] === null &&
      result.observations[1] &&
      result.observations[1].status === 200 &&
      result.transportFailures.length === 1 &&
      result.transportFailures[0].label === "throwing task" &&
      result.transportFailures[0].message === "synchronous boom",
    result && JSON.stringify(result),
  );
}

{
  // A synchronous task throw plus a rejected companion: both recorded,
  // each aligned to its task.
  let threw = false;
  let result;
  try {
    result = await settleConcurrent(
      [
        () => {
          throw new Error("synchronous boom");
        },
        () => Promise.reject(Object.assign(new Error("network is down"), { code: "ENETDOWN" })),
      ],
      ["throwing task", "rejecting task"],
    );
  } catch {
    threw = true;
  }
  check(
    "a synchronous throw and a rejected companion are both recorded and aligned",
    !threw &&
      result &&
      result.observations.every((o) => o === null) &&
      result.transportFailures.length === 2 &&
      result.transportFailures[0].label === "throwing task" &&
      result.transportFailures[0].message === "synchronous boom" &&
      result.transportFailures[1].label === "rejecting task" &&
      result.transportFailures[1].code === "ENETDOWN",
    result && JSON.stringify(result.transportFailures),
  );
}

{
  // An Object.create(null) rejection (no prototype, so String() throws
  // during coercion) must not make settlement or reporting throw, and
  // must not hide the companion.
  let threw = false;
  let result;
  try {
    result = await settleConcurrent(
      [
        () => Promise.reject(Object.create(null)),
        () => Promise.resolve({ status: 200, text: "ok" }),
      ],
      ["null-proto task", "ok task"],
    );
  } catch {
    threw = true;
  }
  check("a null-prototype rejection does not make settleConcurrent throw", !threw && !!result);
  check(
    "a null-prototype rejection yields a stable diagnostic and preserves the companion",
    result &&
      result.observations[1] &&
      result.observations[1].status === 200 &&
      result.transportFailures.length === 1 &&
      result.transportFailures[0].index === 0 &&
      typeof result.transportFailures[0].message === "string" &&
      result.transportFailures[0].message.length > 0,
    result && JSON.stringify(result.transportFailures),
  );
  // Rendering a stable diagnostic for it must also not throw.
  let renderThrew = false;
  try {
    renderTransportFailure(result.transportFailures[0]);
  } catch {
    renderThrew = true;
  }
  check("rendering a null-prototype rejection's diagnostic does not throw", !renderThrew);
}

{
  // A throwing `cause` getter must not escape.
  const hostile = new Error("outer");
  Object.defineProperty(hostile, "cause", {
    configurable: true,
    get() {
      throw new Error("cause getter boom");
    },
  });
  let threw = false;
  let described;
  try {
    described = describeTransportError(hostile);
  } catch {
    threw = true;
  }
  check(
    "describeTransportError survives a throwing cause getter",
    !threw && described && described.message === "outer" && described.cause === undefined && described.code === undefined,
    threw ? "threw" : JSON.stringify(described),
  );
}

{
  // A throwing `code` getter must not escape.
  const hostile = new Error("outer");
  Object.defineProperty(hostile, "code", {
    configurable: true,
    get() {
      throw new Error("code getter boom");
    },
  });
  let threw = false;
  let described;
  try {
    described = describeTransportError(hostile);
  } catch {
    threw = true;
  }
  check(
    "describeTransportError survives a throwing code getter",
    !threw && described && described.message === "outer" && described.code === undefined,
    threw ? "threw" : JSON.stringify(described),
  );
}

{
  // A throwing `message` getter must not escape; the description falls
  // back to a stable string.
  const hostile = Object.create(Error.prototype);
  Object.defineProperty(hostile, "message", {
    configurable: true,
    get() {
      throw new Error("message getter boom");
    },
  });
  let threw = false;
  let described;
  try {
    described = describeTransportError(hostile);
  } catch {
    threw = true;
  }
  check(
    "describeTransportError survives a throwing message getter and falls back to a stable string",
    !threw && described && typeof described.message === "string" && described.message.length > 0,
    threw ? "threw" : JSON.stringify(described),
  );
}

{
  // A rejection whose coercion hook throws (hostile Symbol.toPrimitive)
  // must be described without throwing, through settleConcurrent.
  const hostile = {
    [Symbol.toPrimitive]() {
      throw new Error("no primitive for you");
    },
  };
  let threw = false;
  let result;
  try {
    result = await settleConcurrent([() => Promise.reject(hostile)], ["hostile-coercion task"]);
  } catch {
    threw = true;
  }
  check(
    "a rejection whose value coercion throws is described without throwing",
    !threw &&
      result &&
      result.transportFailures.length === 1 &&
      typeof result.transportFailures[0].message === "string" &&
      result.transportFailures[0].message.length > 0,
    result && JSON.stringify(result.transportFailures),
  );
}

{
  // A cyclic cause chain must terminate and still surface a nested
  // code and the immediate cause message.
  const alpha = Object.assign(new Error("alpha"), { code: undefined });
  const beta = Object.assign(new Error("beta"), { code: "CYCLE_CODE" });
  alpha.cause = beta;
  beta.cause = alpha;
  let threw = false;
  let described;
  try {
    described = describeTransportError(alpha);
  } catch {
    threw = true;
  }
  check(
    "describeTransportError traverses a cyclic cause chain without looping or throwing",
    !threw && described && described.code === "CYCLE_CODE" && described.cause === "beta",
    threw ? "threw" : JSON.stringify(described),
  );
}

{
  // An excessively deep cause chain must be depth-bounded: it returns
  // a stable object without throwing or running unbounded.
  let deep = Object.assign(new Error("leaf"), { code: "LEAF_CODE" });
  for (let level = 0; level < 500; level += 1) {
    const outer = new Error(`level ${level}`);
    outer.cause = deep;
    deep = outer;
  }
  let threw = false;
  let described;
  try {
    described = describeTransportError(deep);
  } catch {
    threw = true;
  }
  check(
    "describeTransportError bounds an excessively deep cause chain and still returns a stable description",
    !threw && described && typeof described.message === "string" && described.message.length > 0,
    threw ? "threw" : JSON.stringify(described),
  );
}

{
  // Non-Error primitives and nullish values render totally.
  const asString = describeTransportError("just a string");
  const asNumber = describeTransportError(42);
  const asUndefined = describeTransportError(undefined);
  const asNull = describeTransportError(null);
  check(
    "describeTransportError renders non-Error primitives and nullish values totally",
    asString.message === "just a string" &&
      asNumber.message === "42" &&
      typeof asUndefined.message === "string" &&
      asUndefined.message.length > 0 &&
      typeof asNull.message === "string" &&
      asNull.message.length > 0,
    JSON.stringify([asString, asNumber, asUndefined, asNull]),
  );
}

{
  // Positive control: an ordinary nested Node-style error still
  // surfaces the nested code and the immediate cause message.
  const inner = Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:1"), { code: "ECONNREFUSED" });
  const outer = Object.assign(new TypeError("fetch failed"), { cause: inner });
  const described = describeTransportError(outer);
  check(
    "an ordinary nested Node-style error still surfaces the nested code and cause (positive control)",
    described.code === "ECONNREFUSED" && described.cause === "connect ECONNREFUSED 127.0.0.1:1" && described.message === "fetch failed",
    JSON.stringify(described),
  );
}

// --- 4. a partial, aborted response rejects within a bound (finding 2) ------

// A server that, for /partial, declares a longer body than it writes
// and then destroys the socket mid-message; for /ok it answers 200.
function createAbortServer() {
  const sockets = new Set();
  const server = http.createServer((request, response) => {
    request.resume();
    if ((request.url || "/") === "/ok") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ ok: true }));
      return;
    }
    // Promise 100 bytes, write only a few, flush them, then destroy the
    // underlying socket so the client sees a torn, incomplete message.
    response.writeHead(200, { "Content-Type": "text/plain", "Content-Length": "100" });
    response.write("partial", () => {
      request.socket.destroy();
    });
  });
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  return {
    sockets,
    listen: () =>
      new Promise((resolve) => {
        server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}`));
      }),
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) {
          socket.destroy();
        }
        sockets.clear();
        server.close(() => resolve());
      }),
  };
}

{
  const abort = createAbortServer();
  const base = await abort.listen();
  const started = process.hrtime.bigint();
  let settleThrew = false;
  let result;
  try {
    result = await withDeadline(
      settleConcurrent(
        [
          () => independentRequest(base, "/partial", { method: "GET" }),
          () => independentRequest(base, "/ok", { method: "GET" }),
        ],
        ["aborted request", "companion request"],
      ),
      5000,
      "settleConcurrent(partial-abort)",
    );
  } catch {
    settleThrew = true;
  }
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  check("a partial aborted response settles (does not hang) — settleConcurrent resolved within its bound", !settleThrew && !!result);
  check("the partial aborted response rejected within a bounded time, not after a long hang", elapsedMs < 4000, `${elapsedMs.toFixed(0)} ms`);
  check(
    "the aborted request is nulled and recorded as a transport failure with a useful code",
    result &&
      result.observations[0] === null &&
      result.transportFailures.length === 1 &&
      result.transportFailures[0].index === 0 &&
      typeof result.transportFailures[0].code === "string" &&
      result.transportFailures[0].code.length > 0,
    result && JSON.stringify(result.transportFailures),
  );
  check(
    "the companion request's successful outcome is retained despite the abort",
    result && result.observations[1] && result.observations[1].status === 200,
    result && JSON.stringify(result.observations),
  );
  const rendered = result && renderTransportFailure(result.transportFailures[0]);
  check(
    "the aborted request's diagnostic renders with its label and a bracketed code",
    typeof rendered === "string" && rendered.startsWith("aborted request:") && rendered.includes("["),
    rendered,
  );
  await abort.close();
  check("the partial-abort server closed cleanly with no live sockets left", abort.sockets.size === 0, `${abort.sockets.size}`);
}

// --- 5. genuine overlap vs. a serialized dispatch (finding 1) ---------------

// A local barrier server that HOLDS each response until two requests
// are genuinely present at once, and instruments enough to tell a
// genuine overlap from two distinct-but-serial sockets.  It records
// total arrivals, distinct client ports, the maximum number of
// simultaneously live client sockets, whether any response was
// released by the fallback deadline, and whether two connections were
// live before the first response was released.  When two are live at
// once it releases every pending response, clears every fallback
// timer, and lets no timer fire afterward.
function createBarrierServer({ deadlineMs }) {
  let arrivals = 0;
  let liveSockets = 0;
  let maxLiveSockets = 0;
  let deadlineReleases = 0;
  let firstReleased = false;
  let twoLiveBeforeFirstRelease = false;
  const distinctPorts = new Set();
  const sockets = new Set();
  const timers = new Set();
  const pending = [];
  const idleWaiters = [];
  let resolveFirstRelease;
  const firstRelease = new Promise((resolve) => {
    resolveFirstRelease = resolve;
  });

  const releaseEntry = (entry, viaDeadline) => {
    if (entry.released) {
      return;
    }
    entry.released = true;
    if (entry.timer !== null) {
      clearTimeout(entry.timer);
      timers.delete(entry.timer);
      entry.timer = null;
    }
    if (!firstReleased) {
      firstReleased = true;
      // Snapshot simultaneity at the instant of the first release:
      // genuine overlap has both sockets live here.
      twoLiveBeforeFirstRelease = liveSockets >= 2;
      resolveFirstRelease();
    }
    if (viaDeadline) {
      deadlineReleases += 1;
    }
    entry.response.writeHead(200, { "Content-Type": "application/json" });
    entry.response.end(JSON.stringify({ ok: true }));
  };

  const server = http.createServer((request, response) => {
    distinctPorts.add(request.socket.remotePort);
    request.resume();
    request.on("end", () => {
      arrivals += 1;
      const entry = { response, released: false, timer: null };
      pending.push(entry);
      if (liveSockets >= 2 && pending.length >= 2) {
        // Both genuinely present at once: release all, clear timers.
        for (const queued of pending.splice(0)) {
          releaseEntry(queued, false);
        }
      } else {
        entry.timer = setTimeout(() => {
          const index = pending.indexOf(entry);
          if (index >= 0) {
            pending.splice(index, 1);
          }
          releaseEntry(entry, true);
        }, deadlineMs);
        timers.add(entry.timer);
      }
    });
  });

  server.on("connection", (socket) => {
    liveSockets += 1;
    if (liveSockets > maxLiveSockets) {
      maxLiveSockets = liveSockets;
    }
    sockets.add(socket);
    socket.on("close", () => {
      liveSockets -= 1;
      sockets.delete(socket);
      if (liveSockets === 0) {
        for (const waiter of idleWaiters.splice(0)) {
          waiter();
        }
      }
    });
  });

  return {
    firstRelease,
    metrics: () => ({
      arrivals,
      distinctPorts: distinctPorts.size,
      maxLiveSockets,
      deadlineReleases,
      twoLiveBeforeFirstRelease,
    }),
    waitForIdle: () =>
      new Promise((resolve) => {
        if (liveSockets === 0) {
          resolve();
        } else {
          idleWaiters.push(resolve);
        }
      }),
    listen: () =>
      new Promise((resolve) => {
        server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}`));
      }),
    close: () =>
      new Promise((resolve) => {
        for (const timer of timers) {
          clearTimeout(timer);
        }
        timers.clear();
        for (const socket of sockets) {
          socket.destroy();
        }
        sockets.clear();
        server.close(() => resolve());
      }),
  };
}

// The strict overlap oracle: a genuine overlap requires ALL of both
// requests succeeding, exactly two arrivals over two distinct sockets,
// two simultaneously live sockets, two live before the first release,
// and zero fallback-deadline releases.
function overlapAccepted(metrics, observations, transportFailures) {
  const bothSucceeded =
    transportFailures.length === 0 && observations.length === 2 && observations.every((o) => o && o.status === 200);
  return (
    bothSucceeded &&
    metrics.arrivals === 2 &&
    metrics.distinctPorts === 2 &&
    metrics.maxLiveSockets >= 2 &&
    metrics.twoLiveBeforeFirstRelease === true &&
    metrics.deadlineReleases === 0
  );
}

{
  // Positive: two normal independentRequest calls reach the server
  // concurrently and satisfy the strict oracle.  A generous 2000 ms
  // fallback is never reached because a genuine overlap resolves in a
  // few ms.
  const barrier = createBarrierServer({ deadlineMs: 2000 });
  const base = await barrier.listen();
  const { observations, transportFailures } = await withDeadline(
    settleConcurrent(
      [
        () => independentRequest(base, "/", { body: { n: 1 } }),
        () => independentRequest(base, "/", { body: { n: 2 } }),
      ],
      ["request 1", "request 2"],
    ),
    5000,
    "settleConcurrent(overlap)",
  );
  const metrics = barrier.metrics();
  check(
    "two concurrent independentRequest calls satisfy the strict overlap oracle",
    overlapAccepted(metrics, observations, transportFailures),
    JSON.stringify({ metrics, transportFailures }),
  );
  check(
    "the overlap had two live sockets before the first response was released and reached maxLiveSockets >= 2",
    metrics.twoLiveBeforeFirstRelease === true && metrics.maxLiveSockets >= 2,
    JSON.stringify(metrics),
  );
  check("no response in the overlapping case was released by the fallback deadline", metrics.deadlineReleases === 0, `${metrics.deadlineReleases}`);
  check(
    "the two overlapping requests used two distinct client sockets and produced two arrivals",
    metrics.distinctPorts === 2 && metrics.arrivals === 2,
    JSON.stringify(metrics),
  );
  await barrier.close();
}

{
  // Negative (reviewer-style): a deliberately serialized dispatch — the
  // second request is issued only after the first has been released and
  // its socket has fully closed — uses two distinct SUCCESSIVE sockets
  // and both succeed, yet the strict oracle rejects it because the
  // sockets were never simultaneously live and a fallback-deadline
  // release was required.  Coordinated by server events (firstRelease,
  // waitForIdle), not a fixed sleep, so it terminates promptly.
  const barrier = createBarrierServer({ deadlineMs: 120 });
  const base = await barrier.listen();
  const first = independentRequest(base, "/", { body: { n: 1 } });
  await barrier.firstRelease; // released by its own fallback deadline (it is alone)
  const firstResult = await first;
  await barrier.waitForIdle(); // the first socket is fully closed on the server
  const secondResult = await independentRequest(base, "/", { body: { n: 2 } });
  const metrics = barrier.metrics();
  check(
    "the serialized dispatch uses two distinct successive sockets and both requests succeed",
    firstResult.status === 200 && secondResult.status === 200 && metrics.distinctPorts === 2,
    JSON.stringify({ firstResult, secondResult, metrics }),
  );
  check(
    "the strict overlap oracle rejects the serialized dispatch (no genuine overlap)",
    overlapAccepted(metrics, [firstResult, secondResult], []) === false,
    JSON.stringify(metrics),
  );
  check(
    "the serialized dispatch is rejected specifically: sockets never simultaneously live and a deadline release was required",
    metrics.maxLiveSockets === 1 && metrics.twoLiveBeforeFirstRelease === false && metrics.deadlineReleases >= 1,
    JSON.stringify(metrics),
  );
  await barrier.close();
}

{
  // The two-admin barrier-evidence predicate (evaluateTwoAdminBarrierEvidence)
  // is the SINGLE acceptance rule the real battery applies to a two-admin
  // round, so pinning it here pins the battery's own rule, not a weaker
  // copy.  A genuine round is exactly one-shot (arrival count 2, arrival 1
  // the waiter and arrival 2 the designated committer); a round whose count
  // reached 3 or more — a retry re-entered the barrier — is rejected even
  // when the statuses, bodies, final state, pids, and commit evidence are
  // otherwise valid.  The predicate is also strictly FAIL-CLOSED: it
  // validates the canonical shape of every record before any semantic
  // comparison, so malformed or partial evidence (missing/absent records,
  // null, arrays, primitives, wrong types, numeric strings, NaN/Infinity,
  // non-positive ids, an absent-not-negative timeout record) is rejected
  // with a deterministic, field-identifying reason and never throws.  The
  // real battery reads only correctly-typed evidence, so these malformed
  // cases pin the guard, not real-battery behavior.
  const seq = (lastValue) => ({ isCalled: true, lastValue });
  const unset = { isCalled: false, lastValue: 0 };
  const validEvidence = () => ({
    arrivals: seq(2),
    committerArrival: seq(2),
    committerTxid: seq(4242),
    committerPid: seq(1001),
    waiterPid: seq(1002),
    blockedSeen: seq(1),
    timeouts: { isCalled: false, lastValue: 1 },
    committerCommitted: true,
  });
  // The complete, correctly-typed round with exactly one field omitted.
  const omit = (key) => {
    const evidence = validEvidence();
    delete evidence[key];
    return evidence;
  };
  // A malformed/partial round must be REJECTED (ok:false) WITHOUT throwing,
  // and must name the offending field/invariant in a deterministic reason.
  const expectFail = (name, evidence, cite) => {
    let result;
    try {
      result = evaluateTwoAdminBarrierEvidence(evidence);
    } catch (error) {
      check(name, false, `threw instead of returning ok:false — ${error && error.message}`);
      return;
    }
    const cited =
      cite === undefined || (Array.isArray(result.reasons) && result.reasons.some((r) => r.includes(cite)));
    check(name, result.ok === false && cited, JSON.stringify(result));
  };

  // --- the valid, complete, correctly-typed round is accepted ---
  check(
    "the barrier-evidence predicate accepts a genuine one-shot round (arrival count exactly 2)",
    evaluateTwoAdminBarrierEvidence(validEvidence()).ok === true,
    JSON.stringify(evaluateTwoAdminBarrierEvidence(validEvidence())),
  );

  // --- arrival re-entry: arrivals -> 3/4 with committerArrival still 2 ---
  expectFail(
    "the predicate rejects an arrival-3 round even with otherwise-valid pids and commit evidence, citing the re-entry",
    { ...validEvidence(), arrivals: seq(3) },
    "arrival count",
  );
  {
    const arrivalThree = evaluateTwoAdminBarrierEvidence({ ...validEvidence(), arrivals: seq(3) });
    check(
      "the arrival-3 rejection cites 'not exactly 2' specifically",
      arrivalThree.ok === false &&
        arrivalThree.reasons.some((r) => r.includes("arrival count") && r.includes("not exactly 2")),
      JSON.stringify(arrivalThree),
    );
  }
  expectFail("the predicate rejects an arrival-4 round", { ...validEvidence(), arrivals: seq(4) }, "arrival count");

  // --- committer-arrival clause, proven INDEPENDENTLY: arrivals stays
  //     exactly 2 and only committerArrival changes to 3, so the failure is
  //     attributable to the committer-arrival clause alone ---
  {
    const onlyCommitterArrival = evaluateTwoAdminBarrierEvidence({ ...validEvidence(), committerArrival: seq(3) });
    check(
      "the predicate rejects a round whose committer evidence identifies arrival 3 while arrivals is still exactly 2",
      onlyCommitterArrival.ok === false &&
        onlyCommitterArrival.reasons.some((r) => r.includes("identifies arrival 3, not arrival 2")) &&
        !onlyCommitterArrival.reasons.some((r) => r.includes("arrival count")),
      JSON.stringify(onlyCommitterArrival),
    );
  }

  // --- structural: null / primitive / array / empty top-level evidence ---
  expectFail("the predicate rejects null evidence", null, "not an object");
  expectFail("the predicate rejects a numeric primitive as evidence", 42, "not an object");
  expectFail("the predicate rejects a string primitive as evidence", "nope", "not an object");
  expectFail("the predicate rejects a boolean primitive as evidence", true, "not an object");
  expectFail("the predicate rejects an array as evidence", [], "not an object");
  check(
    "the predicate is total for empty evidence (rejects, does not throw)",
    evaluateTwoAdminBarrierEvidence({}).ok === false,
    JSON.stringify(evaluateTwoAdminBarrierEvidence({})),
  );

  // --- missing required sequence records (absence, not just uninitialized) ---
  expectFail("the predicate rejects a missing arrivals record", omit("arrivals"), "arrivals:");
  expectFail("the predicate rejects a missing committerArrival record", omit("committerArrival"), "committerArrival:");
  expectFail("the predicate rejects a missing committerTxid record", omit("committerTxid"), "committerTxid:");
  expectFail("the predicate rejects a missing committerPid record", omit("committerPid"), "committerPid:");
  expectFail("the predicate rejects a missing waiterPid record", omit("waiterPid"), "waiterPid:");
  expectFail("the predicate rejects a missing blockedSeen record", omit("blockedSeen"), "blockedSeen:");
  // --- uninitialized (isCalled false) required records ---
  expectFail("the predicate rejects an uninitialized arrivals sequence", { ...validEvidence(), arrivals: unset }, "arrivals:");
  expectFail(
    "the predicate rejects a round whose committer evidence was never published",
    { ...validEvidence(), committerArrival: unset, committerTxid: unset, committerPid: unset },
    "committerArrival:",
  );

  // --- timeout evidence must be EXPLICIT and negative, never synthesized
  //     from an absent record ---
  expectFail("the predicate rejects missing timeouts (absence is not 'no timeout')", omit("timeouts"), "timeouts:");
  expectFail("the predicate rejects a null timeouts record", { ...validEvidence(), timeouts: null }, "timeouts:");
  expectFail("the predicate rejects timeouts missing isCalled", { ...validEvidence(), timeouts: { lastValue: 1 } }, "timeouts: isCalled");
  expectFail("the predicate rejects a string-valued timeouts.isCalled flag", { ...validEvidence(), timeouts: { isCalled: "false", lastValue: 1 } }, "timeouts: isCalled");
  expectFail("the predicate rejects a numeric-zero timeouts.isCalled flag", { ...validEvidence(), timeouts: { isCalled: 0, lastValue: 1 } }, "timeouts: isCalled");
  expectFail("the predicate rejects a malformed timeout lastValue (string)", { ...validEvidence(), timeouts: { isCalled: false, lastValue: "1" } }, "timeouts: lastValue");
  expectFail("the predicate rejects an actual barrier timeout (isCalled true)", { ...validEvidence(), timeouts: seq(1) }, "barrier deadline expired");

  // --- committer transaction id: null / zero / negative / fractional /
  //     NaN / Infinity / string ---
  expectFail("the predicate rejects committerTxid.lastValue = null", { ...validEvidence(), committerTxid: { isCalled: true, lastValue: null } }, "committerTxid: lastValue");
  expectFail("the predicate rejects a zero transaction id", { ...validEvidence(), committerTxid: seq(0) }, "committer transaction id");
  expectFail("the predicate rejects a negative transaction id", { ...validEvidence(), committerTxid: seq(-5) }, "committer transaction id");
  expectFail("the predicate rejects a fractional transaction id", { ...validEvidence(), committerTxid: { isCalled: true, lastValue: 1.5 } }, "committerTxid: lastValue");
  expectFail("the predicate rejects a NaN transaction id", { ...validEvidence(), committerTxid: { isCalled: true, lastValue: NaN } }, "committerTxid: lastValue");
  expectFail("the predicate rejects an Infinity transaction id", { ...validEvidence(), committerTxid: { isCalled: true, lastValue: Infinity } }, "committerTxid: lastValue");
  expectFail("the predicate rejects a string transaction id", { ...validEvidence(), committerTxid: { isCalled: true, lastValue: "4242" } }, "committerTxid: lastValue");

  // --- backend pids: negative / equal / string ---
  expectFail("the predicate rejects a negative committer pid", { ...validEvidence(), committerPid: seq(-1) }, "committer backend pid");
  expectFail("the predicate rejects a negative waiter pid", { ...validEvidence(), waiterPid: seq(-2) }, "waiter backend pid");
  expectFail("the predicate rejects equal positive waiter/committer pids", { ...validEvidence(), waiterPid: seq(1001) }, "two distinct backends");
  expectFail("the predicate rejects a string-valued committer pid", { ...validEvidence(), committerPid: { isCalled: true, lastValue: "1001" } }, "committerPid: lastValue");
  expectFail("the predicate rejects a string-valued waiter pid", { ...validEvidence(), waiterPid: { isCalled: true, lastValue: "1002" } }, "waiterPid: lastValue");

  // --- blocked-seen count: string / zero / negative / fractional ---
  expectFail("the predicate rejects a string-valued blocked count", { ...validEvidence(), blockedSeen: { isCalled: true, lastValue: "1" } }, "blockedSeen: lastValue");
  expectFail("the predicate rejects a zero blocked count", { ...validEvidence(), blockedSeen: seq(0) }, "no blocked-seen tick");
  expectFail("the predicate rejects a negative blocked count", { ...validEvidence(), blockedSeen: seq(-1) }, "no blocked-seen tick");
  expectFail("the predicate rejects a fractional blocked count", { ...validEvidence(), blockedSeen: { isCalled: true, lastValue: 0.5 } }, "blockedSeen: lastValue");

  // --- committed-status flag must be the boolean true, no truthy substitute ---
  expectFail("the predicate rejects committerCommitted = false", { ...validEvidence(), committerCommitted: false }, "did not reach the committed state");
  expectFail("the predicate rejects a string committerCommitted flag", { ...validEvidence(), committerCommitted: "true" }, "committerCommitted is not a boolean");
  expectFail("the predicate rejects a numeric committerCommitted flag", { ...validEvidence(), committerCommitted: 1 }, "committerCommitted is not a boolean");
  expectFail("the predicate rejects an object committerCommitted flag", { ...validEvidence(), committerCommitted: {} }, "committerCommitted is not a boolean");
  expectFail("the predicate rejects missing committerCommitted", omit("committerCommitted"), "committerCommitted is not a boolean");
}

if (failures > 0) {
  console.log(`${failures} concurrency-helper regression check(s) failed`);
  process.exit(1);
}
console.log("All concurrency-helper regression checks passed.");

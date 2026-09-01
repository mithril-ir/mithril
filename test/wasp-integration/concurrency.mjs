// Test-only concurrency helpers of the HTTP battery
// (test/wasp-integration/battery.mjs) shared by both Wasp Confinement
// Profiles — Profile v0 (the exact singleton rule-1 plan) and Profile
// v1 (the exact ordered rule-1, rule-2 pair; every other plan is
// refused before any generation).  Extracted so the timing constants,
// the barrier-deadline SQL fragment, and the concurrent-dispatch and
// transport-error logic can be exercised by a hermetic regression
// (test/wasp-integration/concurrency.test.mjs) without a running
// server or database.  Nothing here is part of the confinement claim,
// and nothing here is added to the generated application.
//
// == The barrier deadline vs. Prisma's transaction timeout ==
//
// The generated Action runs its authorization reads and the
// SetRelation update inside one Prisma interactive transaction opened
// with { isolationLevel: "Serializable" } and NO explicit timeout, so
// it inherits Prisma 5.19.1's default interactive-transaction timeout
// (the runtime's `timeout ?? 5e3`), five seconds.  The concurrency
// battery installs a BEFORE UPDATE barrier trigger that holds the
// first-arriving transaction open until it observes its companion (the
// same-row barrier: blocked on the row; the two-admin barrier: arrived
// and committed), proving the two real HTTP requests overlap at the
// database.  If the barrier's own
// give-up deadline were also five seconds, a round that failed to
// overlap would sit at the barrier for the whole transaction lifetime
// and race Prisma's timeout: the loser would return an unrelated
// transaction failure (HTTP 500) and its companion a client transport
// error, aborting the battery with no useful concurrency result
// (measured: ~5025 ms, one 500, one `fetch failed`).
//
// The barrier deadline is therefore held strictly and substantially
// below the transaction timeout.  Measured on this machine against
// the built server: a genuinely overlapping round completes in about
// 20-30 ms (the barrier wait is tens of ms), and a lone
// non-overlapping request under a 2000 ms barrier deadline returns a
// clean HTTP status and records a barrier timeout at about 2027 ms —
// roughly 2970 ms below Prisma's 5000 ms transaction timeout, so it
// can never reach that timeout and never degrades into a 500 or a
// torn connection.  2000 ms is about two orders of magnitude above
// the genuine-overlap latency (so a real overlap is never falsely
// timed out, even under CI scheduling jitter) while leaving that
// large margin below the transaction timeout.  A recorded barrier
// timeout remains a test failure — it is a diagnostic outcome, not an
// accepted one.

// Prisma 5.19.1's default interactive-transaction timeout (the
// runtime's `timeout ?? 5e3`); the generated Action passes only
// isolationLevel, so it inherits this.  Documented here, not imposed:
// the battery must not raise the production timeout to suit the test.
export const PRISMA_TRANSACTION_TIMEOUT_MS = 5000;

// The barrier's own give-up deadline, held strictly and substantially
// below PRISMA_TRANSACTION_TIMEOUT_MS (module header).
export const BARRIER_DEADLINE_MS = 2000;

// The margin the separation guarantees.
export const BARRIER_SAFETY_MARGIN_MS = PRISMA_TRANSACTION_TIMEOUT_MS - BARRIER_DEADLINE_MS;

// The PostgreSQL interval literal for the barrier deadline, in
// milliseconds (never the old '5 seconds').
export function barrierDeadlineInterval() {
  return `${BARRIER_DEADLINE_MS} milliseconds`;
}

// A single real HTTP request over its own dedicated, non-pooled
// connection: each call builds a one-shot agent with keepAlive false,
// so two concurrent calls use two independent sockets and cannot
// head-of-line block each other on a shared keep-alive connection
// (the observed CI failure mode).  Resolves { status, text } only for
// a genuinely complete response; rejects with the transport error
// (its code and any nested cause reachable through
// describeTransportError) for every premature termination.
//
// == One guarded, idempotent completion path ==
//
// A response can arrive complete (end with response.complete true), or
// tear mid-message: the server may send headers that promise a body,
// write only part of it, then destroy the socket.  In that case the
// response emits some subset of 'aborted', 'error', and 'close', and
// 'end' may or may not fire — with response.complete false.  A naive
// resolve-on-end/reject-on-request-error handler never settles that
// case: no complete 'end' arrives and the request need not emit
// 'error'.  So every terminal event routes through one `complete`
// guard that runs its finisher at most once, destroys the one-shot
// agent (and, on failure, the request socket), and can neither settle
// twice nor turn a completed response into a late rejection.  A
// premature end/abort/close is rejected with a useful code
// (ECONNRESET) so describeTransportError still names it.
export function independentRequest(serverUrl, path, { method = "POST", body, session } = {}) {
  const url = new URL(path, serverUrl);
  const transport = url.protocol === "https:" ? "node:https" : "node:http";
  const payload = body === undefined ? undefined : JSON.stringify(body);
  const headers = { "Content-Type": "application/json" };
  if (payload !== undefined) {
    headers["Content-Length"] = Buffer.byteLength(payload);
  }
  if (session !== undefined) {
    headers["Authorization"] = `Bearer ${session}`;
  }
  return import(transport).then(({ default: lib }) => {
    const agent = new lib.Agent({ keepAlive: false, maxSockets: 1 });
    return new Promise((resolve, reject) => {
      let settled = false;
      let request;
      // The single completion path: idempotent, always releases the
      // agent, and (on failure) the request socket.
      const complete = (finisher) => {
        if (settled) {
          return;
        }
        settled = true;
        agent.destroy();
        finisher();
      };
      const succeed = (value) => complete(() => resolve(value));
      const failWith = (error) =>
        complete(() => {
          if (request !== undefined) {
            request.destroy();
          }
          reject(error);
        });
      // A premature transport termination: synthesize a useful,
      // describeTransportError-legible error.  A real transport error
      // (request 'error', response 'error') is passed through as-is.
      const failPremature = (event) => {
        const error = new Error(`the response socket ${event} before the message completed`);
        error.code = "ECONNRESET";
        failWith(error);
      };
      request = lib.request(url, { method, headers, agent }, (response) => {
        let text = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          text += chunk;
        });
        response.on("end", () => {
          // Resolve only on a genuinely complete message; a premature
          // 'end' (response.complete false) is a transport failure.
          if (response.complete) {
            succeed({ status: response.statusCode, text });
          } else {
            failPremature("ended");
          }
        });
        response.on("aborted", () => failPremature("was aborted"));
        response.on("error", (error) => failWith(error));
        response.on("close", () => {
          if (!response.complete) {
            failPremature("closed");
          }
        });
      });
      request.on("error", (error) => failWith(error));
      if (payload !== undefined) {
        request.write(payload);
      }
      request.end();
    });
  });
}

// The bound on cause-chain traversal: deterministic, non-recursive,
// and small — a real transport error nests one or two levels.
const MAX_CAUSE_DEPTH = 16;

// Read obj[key] without ever throwing: a null/undefined base, a
// hostile getter, or a hostile proxy trap all yield undefined.
function safeProperty(value, key) {
  if (value === null || value === undefined) {
    return undefined;
  }
  try {
    return value[key];
  } catch {
    return undefined;
  }
}

// Coerce any value to a string without ever throwing: a null-prototype
// object, a throwing Symbol.toPrimitive / toString / valueOf, or a
// throwing property during coercion all yield undefined (the caller
// supplies a stable fallback).  Reaching an object's `name` and
// `message` through String() here is itself guarded by this try.
function safeToString(value) {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === "string") {
    return value;
  }
  try {
    const text = String(value);
    return typeof text === "string" ? text : undefined;
  } catch {
    return undefined;
  }
}

// The first Node/Undici error code found walking the cause chain (on
// the error itself for node:http, or under .cause.code for a fetch
// failure).  Cycle-safe (a `seen` set) and depth-bounded, so a cyclic
// or excessively deep chain terminates; every property read is
// fail-safe, so a hostile getter cannot throw while reporting.
function firstCodeInChain(error) {
  const seen = new Set();
  let current = error;
  for (let depth = 0; depth < MAX_CAUSE_DEPTH && current !== undefined && current !== null; depth += 1) {
    const kind = typeof current;
    if (kind === "object" || kind === "function") {
      if (seen.has(current)) {
        break;
      }
      seen.add(current);
    }
    const code = safeToString(safeProperty(current, "code"));
    if (code !== undefined && code !== "") {
      return code;
    }
    current = safeProperty(current, "cause");
  }
  return undefined;
}

// The immediate cause's message, if any, read fail-safely.
function immediateCauseMessage(error) {
  const cause = safeProperty(error, "cause");
  const message = safeToString(safeProperty(cause, "message"));
  return message !== undefined && message !== "" ? message : undefined;
}

// A stable, human-readable message for any rejection value: the
// error's own `message`, else the value coerced to a string, else a
// fixed fallback — never a throw.
function primaryMessage(error) {
  const own = safeToString(safeProperty(error, "message"));
  if (own !== undefined && own !== "") {
    return own;
  }
  const whole = safeToString(error);
  if (whole !== undefined && whole !== "") {
    return whole;
  }
  return "[unrepresentable error]";
}

// The transport error of a rejected request, reduced to the fields
// worth reporting: the Node/Undici error code (own or nested), the
// nested cause message when present, and a stable top-level message.
// Total for ARBITRARY JavaScript rejection values — a null-prototype
// object, a hostile proxy, a throwing code/message/cause getter, a
// throwing coercion hook, a cyclic or excessively deep cause chain, or
// a non-Error primitive all produce a stable description rather than
// throwing, so a malformed rejection can never hide a companion
// outcome, another failure, later evidence, or cleanup.
export function describeTransportError(error) {
  return {
    code: firstCodeInChain(error),
    cause: immediateCauseMessage(error),
    message: primaryMessage(error),
  };
}

// The label for task `index`, read fail-safely with a stable fallback.
function labelAt(labels, index) {
  const raw = safeToString(safeProperty(labels, index));
  return raw !== undefined && raw !== "" ? raw : `task ${index}`;
}

// Run labelled tasks (thunks returning promises) concurrently and
// collect every outcome with Promise.allSettled, so one rejected
// request never aborts the batch or hides the others' evidence.  Each
// task is invoked through an asynchronous promise boundary
// (Promise.resolve().then(task)), so even a SYNCHRONOUS throw inside a
// task becomes an ordinary rejected settlement rather than escaping
// before allSettled.  Returns { observations, transportFailures }:
// observations[i] is the fulfilled { status, text } or null when task
// i rejected; transportFailures lists the rejections, each identifying
// its task by label and carrying its code and nested cause.  Because
// describeTransportError is total, a malformed rejection value cannot
// make this throw.
export async function settleConcurrent(tasks, labels) {
  const settled = await Promise.allSettled(tasks.map((task) => Promise.resolve().then(task)));
  const observations = settled.map((outcome) => (outcome.status === "fulfilled" ? outcome.value : null));
  const transportFailures = [];
  settled.forEach((outcome, index) => {
    if (outcome.status === "rejected") {
      const described = describeTransportError(outcome.reason);
      transportFailures.push({ index, label: labelAt(labels, index), ...described });
    }
  });
  return { observations, transportFailures };
}

// A one-line, human-readable rendering of a transport failure for a
// pinned FAIL detail: the label, the message, the code, and the
// cause.  Every field is read fail-safely, so rendering a diagnostic
// can never itself throw.
export function renderTransportFailure(failure) {
  const label = safeToString(safeProperty(failure, "label")) ?? "unlabelled request";
  const message = safeToString(safeProperty(failure, "message")) ?? "[unrepresentable error]";
  const codeText = safeToString(safeProperty(failure, "code"));
  const causeText = safeToString(safeProperty(failure, "cause"));
  const code = codeText ? ` [${codeText}]` : "";
  const cause = causeText ? ` (${causeText})` : "";
  return `${label}: ${message}${code}${cause}`;
}

// The complete evidence a genuine, one-shot two-admin barrier round must
// exhibit, as a PURE predicate over the non-transactional sequence values
// the battery reads after the round — each an { isCalled, lastValue } pair
// (test/wasp-integration/battery.mjs's sequenceValue), including
// waiterCommittedTxid: the EXACT transaction id the held-open waiter itself
// observed COMMITTED inside the trigger and published on a non-transactional
// sequence, which must equal the designated committer's published id.  This
// is the single acceptance
// rule the real battery applies to a two-admin round, exported so the
// hermetic regression (test/wasp-integration/concurrency.test.mjs) pins
// exactly the predicate the battery calls, never a weaker copy.
//
// The two-admin barrier forces two DISTINCT-row transactions to overlap
// and exactly one to commit.  A genuine round has EXACTLY two arrivals at
// the trigger — arrival 1 the waiter, arrival 2 the designated committer.
// A retry that re-entered the barrier (arrival >= 3) is therefore NOT a
// genuine one-shot round and makes ok false, even when the statuses,
// bodies, final state, pids, and commit evidence are otherwise valid: the
// designated committer's published evidence must still identify arrival 2,
// so no later arrival can be accepted as a replacement companion.  Every
// clause below is required; reasons lists each violated clause so a
// failing round (or a failing unit case) is self-describing.
// This predicate is strictly FAIL-CLOSED: it validates the canonical shape
// of every record BEFORE any semantic comparison, and never coerces.  Each
// required sequence-state record must be a non-null object carrying a
// boolean isCalled and a finite, safe-integer lastValue (exactly the
// representation the reader produces); waiterCommittedTxid must be a called,
// positive id equal to committerTxid; and the timeout record must be present
// with isCalled ===
// false — an ABSENT timeout record is malformed, never silently read as
// "no timeout".  Malformed or partial evidence (null, arrays, primitives,
// wrong types, numeric strings, NaN/Infinity, non-positive ids) yields
// ok:false with a field-identifying reason, and never throws.
export function evaluateTwoAdminBarrierEvidence(evidence) {
  // The evidence itself must be a plain, non-null, non-array object.
  if (evidence === null || typeof evidence !== "object" || Array.isArray(evidence)) {
    return { ok: false, reasons: ["the barrier evidence is not an object (it is null, an array, or a primitive)"] };
  }
  const reasons = [];
  // A canonical sequence-state record: { isCalled: boolean, lastValue:
  // finite safe integer }, exactly as the integration reader produces
  // (test/wasp-integration/battery.mjs's sequenceValue, which normalizes
  // last_value through Number() and is_called through === "t" at the trusted
  // collection boundary).  Returns the validated record, or null while
  // recording a field-identifying reason for any missing/malformed value.
  // No truthiness, no coercive comparison.
  const canonicalSeq = (name) => {
    const value = evidence[name];
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      reasons.push(`${name}: the sequence-state record is missing or not an object`);
      return null;
    }
    if (typeof value.isCalled !== "boolean") {
      reasons.push(`${name}: isCalled is not a boolean`);
      return null;
    }
    if (typeof value.lastValue !== "number" || !Number.isSafeInteger(value.lastValue)) {
      reasons.push(`${name}: lastValue is not a finite safe integer`);
      return null;
    }
    return value;
  };
  // A REQUIRED record: canonical AND actually called (isCalled === true).
  const requireCalled = (name) => {
    const seq = canonicalSeq(name);
    if (seq === null) return null;
    if (seq.isCalled !== true) {
      reasons.push(`${name}: the sequence was never called (isCalled is false)`);
      return null;
    }
    return seq;
  };
  const arrivals = requireCalled("arrivals");
  const committerArrival = requireCalled("committerArrival");
  const committerTxid = requireCalled("committerTxid");
  const committerPid = requireCalled("committerPid");
  const waiterPid = requireCalled("waiterPid");
  const blockedSeen = requireCalled("blockedSeen");
  const waiterCommittedTxid = requireCalled("waiterCommittedTxid");
  // Exactly two arrivals: waiter (arrival 1) + designated committer (arrival
  // 2), and NO retry re-entered the one-shot barrier.  lastValue is already
  // a validated safe integer here, so === and >= below are not coercive.
  if (arrivals !== null && arrivals.lastValue !== 2) {
    reasons.push(
      `arrival count is ${arrivals.lastValue}, not exactly 2 — a retry re-entered the one-shot barrier or a request never arrived`,
    );
  }
  // The designated committer's published evidence STILL identifies arrival 2
  // (no later arrival overwrote it).
  if (committerArrival !== null && committerArrival.lastValue !== 2) {
    reasons.push(`the committer evidence identifies arrival ${committerArrival.lastValue}, not arrival 2`);
  }
  // Published transaction ids / backend pids are positive integers.
  const requirePositive = (seq, label) => {
    if (seq !== null && !(seq.lastValue >= 1)) {
      reasons.push(`${label} is not a positive identifier (got ${seq.lastValue})`);
    }
  };
  requirePositive(committerTxid, "the committer transaction id");
  requirePositive(committerPid, "the committer backend pid");
  requirePositive(waiterPid, "the waiter backend pid");
  requirePositive(waiterCommittedTxid, "the waiter observed-committed transaction id");
  // The waiter observed the designated committer commit (at least one tick).
  if (blockedSeen !== null && !(blockedSeen.lastValue >= 1)) {
    reasons.push("the waiter never observed the designated committer commit (no blocked-seen tick)");
  }
  // The waiter and the committer are two DISTINCT backends.
  if (waiterPid !== null && committerPid !== null && waiterPid.lastValue === committerPid.lastValue) {
    reasons.push("the waiter and committer are not two distinct backends");
  }
  // The held-open waiter observed the EXACT published committer transaction
  // COMMITTED and published the id it observed (the battery's barrier trigger,
  // the 'committed' branch ONLY, arrival 1 ONLY).  That observed-committed id
  // must be present (requireCalled above — the waiter did observe a commit)
  // and must EQUAL the designated committer's published id by exact integer
  // equality: the commit proof is thereby bound to the exact published
  // transaction and captured at the overlap moment, never re-derived by a
  // later, weaker post-round pg_xact_status re-query (which once returned
  // something other than the literal 'committed' for a genuine round; that
  // raw value was not captured and its micro-cause is unknown).
  // A never-published value (the waiter never observed a commit) or any
  // mismatched, stale, or overwritten id fails closed here.
  if (waiterCommittedTxid !== null && committerTxid !== null && waiterCommittedTxid.lastValue !== committerTxid.lastValue) {
    reasons.push(
      `the waiter's observed-committed transaction id (${waiterCommittedTxid.lastValue}) does not equal the designated committer's published transaction id (${committerTxid.lastValue})`,
    );
  }
  // Timeout evidence must be EXPLICIT: a canonical record with isCalled ===
  // false.  A missing or malformed record is rejected here, never
  // synthesized into "no timeout".
  const timeouts = canonicalSeq("timeouts");
  if (timeouts !== null && timeouts.isCalled !== false) {
    reasons.push(`a barrier deadline expired (${timeouts.lastValue} timeout(s))`);
  }
  return { ok: reasons.length === 0, reasons };
}

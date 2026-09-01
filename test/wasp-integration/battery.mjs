// The HTTP battery of the Wasp Confinement Profile v0 / v1 vertical
// test.
//
// Test-only tooling, deliberately outside the confined deployable
// root: it exercises the generated Action(s) exclusively through
// Wasp's real generated HTTP and authentication path (username/password
// signup and login, the bearer session, POST /operations/<route> with
// Wasp's superjson request envelope) and reaches the isolated test
// database directly only to bootstrap the scope entities and the
// authority tuples, to snapshot state, and to install and remove the
// temporary fault-injection and barrier machinery (triggers,
// functions, and sequences) that prove the production retry, error,
// and concurrency paths.  Nothing here is part of the confinement
// claim, and nothing here is added to the generated application.
//
// Environment: MITHRIL_WASP_SERVER_URL (the running built server),
// MITHRIL_WASP_MANIFEST (the generated manifest, read for the
// profile, the route(s), the target model, column, value, and
// argument names), MITHRIL_WASP_DATABASE_URL (the isolated database;
// psql must be on PATH).  With MITHRIL_WASP_BATTERY_PLAN=1 the
// battery only prints the plan it read from the manifest — the
// profile, every operation with its route and argument names, and
// the scenario groups it would run — and exits without contacting a
// server or a database (the harness self-tests pin this against both
// committed fixture manifests).
//
// The manifest selects the profile explicitly (formatVersion "0":
// Profile v0, the singular caseAction and parameters; formatVersion
// "1": Profile v1, the ordered operations array whose first entry
// must be the rule-1 change-other Action and whose second must be
// the rule-2 bounded-self-update Action).  The rule-1 battery below
// runs unchanged for both profiles; the Profile-v1 battery then adds
// the rule-2 scenarios and the cross-operation overlap test.
//
// What is pinned:
//   * signup and login through Wasp's username/password path;
//   * 401 without a bearer session (the Action's own uniform answer)
//     and 401 with an invalid session (Wasp's answer), 400 for every
//     invalid argument shape — each with the complete authority
//     relation unchanged;
//   * every denied case — a member, an outsider, the actor as the
//     target, a missing target tuple, a foreign scope, and a scope
//     that does not exist — answers exactly 403 with byte-identical
//     uniform bodies, and the complete authority relation (sentinel
//     memberships in unrelated scopes included) is byte-identical
//     before and after;
//   * the allowed path changes exactly the target tuple;
//   * with a temporary trigger raising SQLSTATE 40001 on every update
//     (and advancing sequences, which no rollback undoes), the real
//     HTTP path performs exactly three transaction attempts, each in
//     a fresh transaction (three distinct increasing transaction
//     ids), answers the pinned 409, and changes nothing;
//   * with a temporary trigger raising a generic error, the real HTTP
//     path answers the pinned 500 and changes nothing;
//   * genuine concurrency (two admins demoting each other, two DISTINCT
//     rows, a Serializable write skew): a temporary deterministic
//     barrier trigger makes the first-arriving (waiter) transaction hold
//     open, its pre-images already read, until the companion (committer)
//     has actually COMMITTED (pg_xact_status on the committer's
//     transaction id, published non-transactionally so the waiter can
//     read it) — proving the overlap and forcing exactly one demotion to
//     commit; the waiter then loses the write skew, aborts once, and its
//     fresh retry, reading the committed demotion, is denied.  The two
//     requests are dispatched over independent, non-pooled connections
//     (settleConcurrent over independentRequest) so they cannot
//     head-of-line block each other, and the barrier's give-up deadline
//     is held strictly below Prisma's interactive-transaction timeout
//     (test/wasp-integration/concurrency.mjs) so a non-overlapping round
//     records a clean barrier timeout instead of racing the transaction
//     timeout into a 500 and a torn connection; a client transport
//     failure is collected and reported as a pinned failure naming the
//     request, never an uninformative top-level throw, and never hides
//     the state, overlap, and timeout evidence or the temporary-object
//     cleanup; every round must be a row of the explicit two-admin
//     outcome table of test/wasp-integration/oracle.mjs (200/403 or
//     403/200, byte-exact bodies, exactly the row's complete relation) —
//     so write skew, a denial without a committed demotion, a 500, a
//     wrong body, and a 409 (which an isolated pair cannot produce) are
//     never accepted;
//   * every temporary trigger, function, and sequence is removed and
//     its removal verified.
//
// Profile v1 additionally pins, through the rule-2 Action
// (POST /operations/mithril-self-update-action, arguments scope and
// payload, no subject argument):
//   * 401 without a bearer session and 400 for every invalid argument
//     shape, each with the complete relation unchanged;
//   * Admin → Member self-demotion succeeds and changes exactly the
//     actor's own tuple; Admin → Admin and Member → Member equal
//     writes succeed and change nothing;
//   * Member → Admin self-promotion, a non-member self-update (to
//     either value), and a scope that does not exist are denied with
//     the same uniform 403 with the complete relation unchanged; the
//     two smuggled-subject facts are pinned separately — no
//     caller-controlled subject channel exists (a member's request
//     smuggling an admin's subject is denied with the uniform 403 and
//     changes nothing), and the untrusted extra field is dropped
//     harmlessly (an allowed equal write carrying it changes nothing,
//     and an allowed, state-changing Admin → Member self-demotion
//     carrying a subject that names another existing member changes
//     exactly the authenticated admin's own tuple, with the named
//     member's tuple and every other row of the complete relation
//     unchanged);
//   * with the conflict trigger, the rule-2 Action performs exactly
//     three attempts in three fresh transactions and answers 409; with
//     the fault trigger it answers 500; both change nothing;
//   * same-operation concurrency: the same actor's concurrent
//     self-demotion and equal self-write contend for the SAME row, so
//     the tuple lock serializes them at the same-row barrier; each round
//     must land on a row of the explicit same-operation outcome table
//     (oracle.mjs: the demotion is never denied, the equal top write
//     commits only before the demotion, a committed demotion leaves the
//     bottom value, so the pair is 200/403 or 200/200 — the blocked
//     request is decided after one committed conflict and never a 409);
//   * cross-operation concurrency: actor A's rule-1 demotion of peer P
//     and P's rule-2 request to remain at the top value contend for the
//     SAME row (P's tuple), so the tuple lock serializes them at the
//     same-row barrier; each round must land on a row of the explicit
//     cross-operation outcome table (rule 1 is never denied, P always
//     ends at the bottom value, 200/200 is valid only for the order
//     rule 2 then rule 1, so the pair is 200/403 or 200/200 — never a
//     409, and never 200/200 with P still at the top value);
//   * the same-row barrier's negative regression: an unrelated decoy
//     lock waiter (a test session blocked on a row of a test-only
//     table held by another test session) neither releases nor
//     satisfies the barrier — a lone request waits out the barrier
//     deadline and completes normally — and the decoy sessions,
//     locks, and table are released, dropped, and verified gone.
// Both Profile-v1 concurrency scenarios update the SAME row (the
// actor's own tuple), so PostgreSQL's tuple lock serializes the two
// UPDATE statements before a BEFORE UPDATE trigger can fire for the
// second one; the arrival barrier of the rule-1 scenario (two distinct
// rows) cannot prove overlap there.  The same-row barrier trigger
// therefore makes the first arriving transaction wait, inside its
// UPDATE, until PostgreSQL itself reports the expected companion
// blocked behind THIS backend on THIS row — a client backend of the
// current database with a different pid, waiting on a lock, whose
// blockers (pg_blocking_pids) include the trigger's own backend,
// whose current statement is an UPDATE of the authority relation, and
// which holds the tuple lock of the authority relation at exactly the
// ctid of the row being updated (pg_locks) — a database-observed fact
// about the identified companion, not a sleep and not any lock waiter;
// the observation (both pids and the companion's statement) is
// recorded.  Only then does it proceed; the blocked transaction then
// fails with a serialization error (SQLSTATE 40001, Prisma P2034),
// retries in a fresh transaction, passes the barrier as the second
// arrival, and is decided against the committed state.  A round counts
// as overlapping exactly when the barrier observed its identified
// companion (two distinct backend pids recorded) and no barrier
// deadline expired; the arrival count is diagnostic only, because the
// blocked transaction's retry reaches the update again only when the
// committed state still allows its request (a demoted actor's retry
// is denied at the read and never arrives).
// The rule-1 battery runs first against the same built Profile-v1
// server, which is the evidence that the rule-1 behavior is unchanged.

import { execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";

import {
  BARRIER_DEADLINE_MS,
  PRISMA_TRANSACTION_TIMEOUT_MS,
  barrierDeadlineInterval,
  evaluateTwoAdminBarrierEvidence,
  independentRequest,
  renderTransportFailure,
  settleConcurrent,
} from "./concurrency.mjs";
import {
  CROSS_OPERATION_ROWS,
  FINAL_A_BOTTOM_P_TOP,
  FINAL_A_TOP_P_BOTTOM,
  FINAL_BOTH_TOP,
  FINAL_BOTTOM,
  FINAL_TOP,
  SAME_OPERATION_ROWS,
  TWO_ADMIN_ROWS,
  judgeRound,
  renderTally,
  tallyRows,
} from "./oracle.mjs";

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

const planOnly = process.env.MITHRIL_WASP_BATTERY_PLAN === "1";
const manifest = JSON.parse(readFileSync(required("MITHRIL_WASP_MANIFEST"), "utf8"));

// The profile, read explicitly from the manifest — never inferred
// from an operation count.
const profileV1 = manifest.formatVersion === "1";
if (!profileV1 && manifest.formatVersion !== "0") {
  throw new Error(`unknown manifest formatVersion ${JSON.stringify(manifest.formatVersion)}`);
}
if (profileV1 && manifest.profile !== "wasp-confinement-profile-v1") {
  throw new Error(`manifest formatVersion 1 with profile ${JSON.stringify(manifest.profile)}`);
}
if (!profileV1 && manifest.profile !== "wasp-confinement-profile-v0") {
  throw new Error(`manifest formatVersion 0 with profile ${JSON.stringify(manifest.profile)}`);
}
const changeOtherOperation = profileV1
  ? manifest.operations[0]
  : { case: 0, rule: "rule 1 (change-other)", authored: manifest.caseAction.authored, route: manifest.caseAction.route, operation: manifest.caseAction.operation, parameters: manifest.parameters };
const selfUpdateOperation = profileV1 ? manifest.operations[1] : null;
if (profileV1) {
  if (!Array.isArray(manifest.operations) || manifest.operations.length !== 2) {
    throw new Error("a Profile-v1 manifest must list exactly two operations");
  }
  if (changeOtherOperation.rule !== "rule 1 (change-other)" || changeOtherOperation.case !== 0) {
    throw new Error("the first Profile-v1 operation must be the rule-1 change-other Action at case 0");
  }
  if (selfUpdateOperation.rule !== "rule 2 (bounded-self-update)" || selfUpdateOperation.case !== 1) {
    throw new Error("the second Profile-v1 operation must be the rule-2 bounded-self-update Action at case 1");
  }
  if (selfUpdateOperation.parameters.map((p) => p.role).join(",") !== "scope,payload") {
    throw new Error("the rule-2 Action carries exactly the scope and payload arguments");
  }
}

const serverUrl = planOnly ? "" : required("MITHRIL_WASP_SERVER_URL");
const databaseUrl = planOnly ? "" : required("MITHRIL_WASP_DATABASE_URL");

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`ok: ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL: ${name}${detail === undefined ? "" : ` — ${detail}`}`);
  }
}

// --- test-only database access ------------------------------------------

function sql(query) {
  return execFileSync("psql", [databaseUrl, "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", query], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function quoteIdentifier(name) {
  return '"' + name.replace(/"/g, '""') + '"';
}

const subjectTable = quoteIdentifier(manifest.subjectEntity.model);
const scopeTable = quoteIdentifier(manifest.scopeEntity.model);
const authorityTable = quoteIdentifier(manifest.authorityRelation.model);
const subjectColumn = quoteIdentifier(manifest.subjectEndpoint.idField);
const scopeColumn = quoteIdentifier(manifest.scopeEndpoint.idField);
const payloadColumn = quoteIdentifier(manifest.authorityRelation.payloadColumn);
const [subjectArgument, scopeArgument, payloadArgument] = changeOtherOperation.parameters.map((p) => p.argument);
const bottom = manifest.bottom.value;
const top = manifest.floor.value;
const route = changeOtherOperation.route;
const selfRoute = profileV1 ? selfUpdateOperation.route : null;
const [selfScopeArgument, selfPayloadArgument] = profileV1 ? selfUpdateOperation.parameters.map((p) => p.argument) : [null, null];

// The plan the battery read from the manifest: printed and, under
// MITHRIL_WASP_BATTERY_PLAN=1, the whole output.
function planLines() {
  const lines = [
    `profile: ${manifest.profile} (formatVersion ${manifest.formatVersion}; ${profileV1 ? "Profile v1" : "Profile v0"})`,
    `authority model: ${manifest.authorityRelation.model} (${manifest.subjectEndpoint.idField}, ${manifest.scopeEndpoint.idField}, ${manifest.authorityRelation.payloadColumn}); bottom ${bottom}, top ${top}`,
    `operation 0: ${changeOtherOperation.operation} (${changeOtherOperation.rule}, case ${changeOtherOperation.case}, authored ${JSON.stringify(changeOtherOperation.authored)}) at POST ${route}; arguments ${subjectArgument}, ${scopeArgument}, ${payloadArgument}`,
  ];
  if (profileV1) {
    lines.push(
      `operation 1: ${selfUpdateOperation.operation} (${selfUpdateOperation.rule}, case ${selfUpdateOperation.case}, authored ${JSON.stringify(selfUpdateOperation.authored)}) at POST ${selfRoute}; arguments ${selfScopeArgument}, ${selfPayloadArgument}; no subject argument`,
    );
  }
  lines.push("scenarios: rule-1 401/400/403/200, rule-1 P2034 retry and 409, rule-1 500, rule-1 barrier concurrency");
  if (profileV1) {
    lines.push("scenarios: rule-2 401/400/403/200, rule-2 P2034 retry and 409, rule-2 500, rule-2 same-operation barrier concurrency, rule-1/rule-2 cross-operation barrier concurrency, same-row barrier decoy-waiter regression");
  }
  return lines;
}

if (planOnly) {
  for (const line of planLines()) {
    console.log(line);
  }
  process.exit(0);
}

function userId(username) {
  return Number(
    sql(
      `select u.id from ${subjectTable} u join "Auth" a on a."userId" = u.id ` +
        `join "AuthIdentity" ai on ai."authId" = a.id where ai."providerUserId" = '${username}';`,
    ),
  );
}

// The relation string relationState() renders for the given tuples:
// ordered by scope then subject, numerically — never by the order the
// tuples were bootstrapped in.
function expectedRelation(tuples) {
  return tuples
    .slice()
    .sort((a, b) => a[0] - b[0] || a[1] - b[1])
    .map(([scopeId, subjectId, value]) => `${scopeId}:${subjectId}=${value}`)
    .join(",");
}

// The relation string with exactly one tuple's value replaced (entries
// are "scope:subject=value"; the match is on the whole entry prefix, so
// no other tuple can be touched).
function replaceTuple(state, scopeId, subjectId, value) {
  const prefix = `${scopeId}:${subjectId}=`;
  return state
    .split(",")
    .map((entry) => (entry.startsWith(prefix) ? `${prefix}${value}` : entry))
    .join(",");
}

// The value of one tuple in a relation string, or null when absent.
function tupleValue(state, scopeId, subjectId) {
  const prefix = `${scopeId}:${subjectId}=`;
  const entry = state.split(",").find((candidate) => candidate.startsWith(prefix));
  return entry === undefined ? null : entry.slice(prefix.length);
}

// The complete authority relation, every scope included.
function relationState() {
  return sql(
    `select coalesce(string_agg(${scopeColumn} || ':' || ${subjectColumn} || '=' || ${payloadColumn}, ',' order by ${scopeColumn}, ${subjectColumn}), '') ` +
      `from ${authorityTable};`,
  );
}

function setMembership(userIdValue, scopeId, value) {
  sql(
    `insert into ${authorityTable} (${subjectColumn}, ${scopeColumn}, ${payloadColumn}) values (${userIdValue}, ${scopeId}, '${value}') ` +
      `on conflict (${subjectColumn}, ${scopeColumn}) do update set ${payloadColumn} = excluded.${payloadColumn};`,
  );
}

function newScope() {
  return Number(sql(`insert into ${scopeTable} default values returning id;`));
}

// --- Wasp's real HTTP and authentication path -------------------------

async function post(path, body, session) {
  const headers = { "Content-Type": "application/json" };
  if (session !== undefined) {
    headers["Authorization"] = `Bearer ${session}`;
  }
  const response = await fetch(serverUrl + path, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, text };
}

async function signup(username) {
  const response = await post("/auth/username/signup", { username, password: "password1" });
  if (response.status !== 200) {
    throw new Error(`signup of ${username} failed: ${response.status} ${response.text}`);
  }
}

async function login(username) {
  const response = await post("/auth/username/login", { username, password: "password1" });
  let json = null;
  try {
    json = JSON.parse(response.text);
  } catch {
    json = null;
  }
  if (response.status !== 200 || !json || typeof json.sessionId !== "string") {
    throw new Error(`login of ${username} failed: ${response.status} ${response.text}`);
  }
  return json.sessionId;
}

// The generated Action, invoked exactly as Wasp's client would:
// POST /operations/<route> with the superjson envelope { json: args }.
async function changeRole(session, target, scope, newValue) {
  const args = {};
  args[subjectArgument] = target;
  args[scopeArgument] = scope;
  args[payloadArgument] = newValue;
  return post(route, { json: args }, session);
}

// The same real request, but over its own dedicated, non-pooled
// connection (concurrency section only): two of these dispatched at
// once use two independent sockets and genuinely overlap.
function changeRoleIndependent(session, target, scope, newValue) {
  const args = {};
  args[subjectArgument] = target;
  args[scopeArgument] = scope;
  args[payloadArgument] = newValue;
  return independentRequest(serverUrl, route, { body: { json: args }, session });
}

// The rule-2 Action (Profile v1), invoked exactly as Wasp's client
// would: POST /operations/<self-update route> with { json: { scope,
// payload } } — plus any extra members the test smuggles in.
async function selfUpdate(session, scope, newValue, extra = {}) {
  const args = { ...extra };
  args[selfScopeArgument] = scope;
  args[selfPayloadArgument] = newValue;
  return post(selfRoute, { json: args }, session);
}

function selfUpdateIndependent(session, scope, newValue) {
  const args = {};
  args[selfScopeArgument] = scope;
  args[selfPayloadArgument] = newValue;
  return independentRequest(serverUrl, selfRoute, { body: { json: args }, session });
}

async function waitForServer() {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const response = await fetch(serverUrl + "/");
      if (response.status === 200) {
        return;
      }
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error("the Wasp server did not come up");
}

// The Action's own uniform response bodies (Wasp renders an HttpError
// as { message, data } and omits an undefined data).
const body401 = JSON.stringify({ message: "authentication required" });
const body400 = JSON.stringify({ message: "invalid arguments" });
const body403 = JSON.stringify({ message: "forbidden" });
const body409 = JSON.stringify({ message: "conflict" });
const body500 = JSON.stringify({ message: "internal error" });
// Wasp's superjson envelope of the Action's void result.
const body200 = JSON.stringify({ json: null, meta: { values: ["undefined"], v: 1 } });
// The pinned body of every status a concurrency table may admit.
const bodies = { 200: body200, 403: body403, 409: body409 };

// The complete relation a two-admin table row requires, given the
// scenario's renderer of (A value, P value) states.
function twoAdminState(final, expectedState) {
  switch (final) {
    case FINAL_A_TOP_P_BOTTOM:
      return expectedState(top, bottom);
    case FINAL_A_BOTTOM_P_TOP:
      return expectedState(bottom, top);
    case FINAL_BOTH_TOP:
      return expectedState(top, top);
    default:
      return undefined;
  }
}

// --- test-only fault-injection and barrier machinery ---------------------

const testObjects = {
  functions: ["mithril_test_conflict", "mithril_test_fault", "mithril_test_barrier", "mithril_test_row_barrier"],
  triggers: ["mithril_test_conflict", "mithril_test_fault", "mithril_test_barrier", "mithril_test_row_barrier"],
  tables: ["mithril_test_observations", "mithril_test_decoy"],
  sequences: [
    "mithril_test_attempts",
    "mithril_test_txid_1",
    "mithril_test_txid_2",
    "mithril_test_txid_3",
    "mithril_test_txid_4",
    "mithril_test_arrivals",
    "mithril_test_timeouts",
    "mithril_test_blocked_seen",
    "mithril_test_committer_txid",
    "mithril_test_committer_pid",
    "mithril_test_committer_arrival",
    "mithril_test_waiter_pid",
  ],
};

function installConflictTrigger() {
  sql(
    `create sequence mithril_test_attempts;
     create sequence mithril_test_txid_1; create sequence mithril_test_txid_2;
     create sequence mithril_test_txid_3; create sequence mithril_test_txid_4;
     create function mithril_test_conflict() returns trigger language plpgsql as $$
     declare n bigint;
     begin
       n := nextval('mithril_test_attempts');
       if n <= 4 then
         execute format('select setval(%L, %s)', 'mithril_test_txid_' || n, txid_current());
       end if;
       raise exception 'mithril test serialization failure' using errcode = '40001';
     end $$;
     create trigger mithril_test_conflict before update on ${authorityTable}
       for each row execute function mithril_test_conflict();`,
  );
}

function installFaultTrigger() {
  sql(
    `create function mithril_test_fault() returns trigger language plpgsql as $$
     begin
       raise exception 'mithril test fault';
     end $$;
     create trigger mithril_test_fault before update on ${authorityTable}
       for each row execute function mithril_test_fault();`,
  );
}

// The two-admin barrier (both profiles): two admins A and P demote each
// other, writing two DISTINCT rows, so PostgreSQL takes no tuple lock that
// would serialize them — the conflict is a Serializable write skew resolved
// at COMMIT, and exactly one of the two demotions can commit (the other
// actor is then below the floor, so its retried read is denied).  An
// isolated pair's only serial results are therefore 200/403 and 403/200; a
// 409 has no serial interpretation here.
//
// What the retained evidence DIRECTLY establishes: older, heavily loaded
// runs of an EARLIER barrier returned 409 together with an arrival count of
// 4 — proof that retry attempts re-entered that barrier (it released the
// first arrival as soon as the second ARRIVED, so a retry could re-arrive
// and re-overlap).  The exact PostgreSQL commit/cancellation interleaving
// behind those 409s was NOT captured; the plausible mechanism (both
// concurrent committers cancelled as pivots, then both retrying and
// re-overlapping) is UNPROVEN, and this barrier does not depend on
// reconstructing it.
//
// Instead the barrier is deterministic and ONE-SHOT: it specifies and
// verifies exactly one history and rejects any round that deviates.  The
// first arrival is the WAITER; the second — arrival EXACTLY 2 — is the
// designated COMMITTER and the only arrival permitted to publish the
// companion evidence: its transaction id, backend pid, and arrival number,
// on non-transactional sequences the waiter can read (a committed row could
// not be read by the still-open waiter under snapshot isolation, and the
// waiter's own writes will roll back).  Not being held at the barrier, the
// committer is the first committer and wins.  The waiter holds here, its
// transaction open and its pre-images already read, polling ONLY that exact
// published transaction id until it is COMMITTED (pg_xact_status — a
// database-observed commit, never a sleep); only then does it proceed, so
// its stale snapshot deterministically loses the write skew, it aborts
// exactly once, and its fresh retry — reading the committed demotion — is
// denied (403).  The denied retry never reaches the update, so it never
// re-enters the barrier, and a genuine round therefore has EXACTLY two
// arrivals — the verified history is: arrival 2 commits, arrival 1 aborts
// once, its retry is denied before the update.  Any later arrival (a retry
// that DID re-enter, arrival >= 3) is recorded by the arrival counter but
// must NEVER overwrite the designated committer's published evidence; the
// round invariant requires the arrival count to be exactly 2, so such a
// round fails.  If the designated committer instead aborts, the waiter —
// polling only that exact, immutable id — never sees a committed companion
// (never a replacement), so it times out or proceeds without a commit and
// the round fails.  The overlap is recorded non-transactionally so it
// survives the waiter's abort: the waiter's and committer's pids (two
// distinct backends), the committer's arrival number (still 2), and a
// blocked-seen tick; a barrier deadline expiring is a timeout (a test
// failure, never an accepted outcome).
function installBarrierTrigger() {
  sql(
    `create sequence mithril_test_arrivals;
     create sequence mithril_test_timeouts;
     create sequence mithril_test_blocked_seen;
     create sequence mithril_test_committer_txid;
     create sequence mithril_test_committer_pid;
     create sequence mithril_test_committer_arrival;
     create sequence mithril_test_waiter_pid;
     create function mithril_test_barrier() returns trigger language plpgsql as $$
     declare
       deadline timestamptz := clock_timestamp() + interval '${barrierDeadlineInterval()}';
       own_pid integer := pg_backend_pid();
       arrival bigint;
       committer_txid bigint;
       committer_txid_set boolean;
       committer_state text;
     begin
       arrival := nextval('mithril_test_arrivals');
       if arrival = 2 then
         -- The DESIGNATED committer, and the ONLY arrival permitted to
         -- publish the companion evidence: its transaction id, backend pid,
         -- and its arrival number, on the non-transactional sequences the
         -- waiter reads.  Not held at the barrier, it is the first committer.
         perform setval('mithril_test_committer_txid', txid_current());
         perform setval('mithril_test_committer_pid', own_pid);
         perform setval('mithril_test_committer_arrival', arrival);
         return new;
       end if;
       if arrival > 2 then
         -- A retry (or any unexpected extra arrival) re-entered the one-shot
         -- barrier.  It must NEVER overwrite the designated committer's
         -- evidence; the arrival counter (now >= 3) records it and fails the
         -- round invariant.  Proceed so the request settles and is rejected.
         return new;
       end if;
       -- The waiter (arrival 1): hold open, pre-images already read, until
       -- the DESIGNATED committer (arrival 2) has committed.  Poll ONLY that
       -- exact transaction id (immutable once arrival 2 published it), so no
       -- later arrival can ever be accepted as a replacement companion.
       loop
         select is_called, last_value from mithril_test_committer_txid into committer_txid_set, committer_txid;
         if committer_txid_set then
           committer_state := pg_xact_status(committer_txid::text::xid8);
           if committer_state = 'committed' then
             perform setval('mithril_test_waiter_pid', own_pid);
             perform nextval('mithril_test_blocked_seen');
             return new;
           end if;
           if committer_state = 'aborted' then
             -- The designated committer aborted.  Never wait for or accept a
             -- later arrival as a replacement: proceed WITHOUT recording a
             -- commit, so the round fails the invariant (no blocked-seen
             -- tick, the exact published transaction not committed).
             return new;
           end if;
         end if;
         if clock_timestamp() > deadline then
           perform nextval('mithril_test_timeouts');
           return new;
         end if;
         perform pg_sleep(0.005);
       end loop;
     end $$;
     create trigger mithril_test_barrier before update on ${authorityTable}
       for each row execute function mithril_test_barrier();`,
  );
}

// A regression exercising the REAL barrier trigger: an unexpected arrival 3
// cannot overwrite the transaction id, backend pid, or arrival number the
// designated committer (arrival 2) published.  Two separate psql calls are
// two separate backends and transactions (distinct pids and txids); each
// UPDATE is a no-op self-write (the payload set to itself) so the authority
// relation is untouched.  Every barrier object is removed afterward.
function barrierEvidenceImmutabilityProbe({ admin, scope }) {
  const noopUpdate = `update ${authorityTable} set ${payloadColumn} = ${payloadColumn} where ${subjectColumn} = ${admin} and ${scopeColumn} = ${scope};`;
  installBarrierTrigger();
  try {
    // Arm so the next arrival is the designated committer (arrival 2).
    sql(
      `select setval('mithril_test_arrivals', 2, false); select setval('mithril_test_committer_txid', 1, false); ` +
        `select setval('mithril_test_committer_pid', 1, false); select setval('mithril_test_committer_arrival', 1, false); ` +
        `select setval('mithril_test_blocked_seen', 1, false); select setval('mithril_test_waiter_pid', 1, false); ` +
        `select setval('mithril_test_timeouts', 1, false);`,
    );
    // Arrival 2 (its own backend and transaction): publishes the evidence.
    sql(noopUpdate);
    const committerTxid = sequenceValue("mithril_test_committer_txid");
    const committerPid = sequenceValue("mithril_test_committer_pid");
    const committerArrival = sequenceValue("mithril_test_committer_arrival");
    const afterTwo = sequenceValue("mithril_test_arrivals");
    check(
      "barrier immutability: arrival 2 published the designated committer evidence (its txid, pid, and arrival number 2)",
      committerTxid.isCalled && committerPid.isCalled && committerArrival.isCalled && committerArrival.lastValue === 2 && afterTwo.lastValue === 2,
      JSON.stringify({ committerTxid, committerPid, committerArrival, afterTwo }),
    );
    // Arrival 3 (a DIFFERENT backend and transaction): must NOT overwrite.
    sql(noopUpdate);
    const committerTxidAfter = sequenceValue("mithril_test_committer_txid");
    const committerPidAfter = sequenceValue("mithril_test_committer_pid");
    const committerArrivalAfter = sequenceValue("mithril_test_committer_arrival");
    const afterThree = sequenceValue("mithril_test_arrivals");
    check(
      "barrier immutability: a third arrival re-entered the trigger (arrival count 3)",
      afterThree.isCalled && afterThree.lastValue === 3,
      JSON.stringify(afterThree),
    );
    check(
      "barrier immutability: the third arrival did NOT overwrite the designated committer's transaction id, pid, or arrival number",
      committerTxidAfter.lastValue === committerTxid.lastValue &&
        committerPidAfter.lastValue === committerPid.lastValue &&
        committerArrivalAfter.isCalled &&
        committerArrivalAfter.lastValue === 2,
      JSON.stringify({
        before: { committerTxid, committerPid, committerArrival },
        after: { committerTxidAfter, committerPidAfter, committerArrivalAfter },
      }),
    );
    // The evidence predicate rejects the re-entered round, citing the
    // arrival-count violation (even though the committer evidence, being
    // immutable, still correctly identifies arrival 2).
    const evaluation = evaluateTwoAdminBarrierEvidence({
      arrivals: afterThree,
      committerArrival: committerArrivalAfter,
      committerTxid: committerTxidAfter,
      committerPid: committerPidAfter,
      waiterPid: sequenceValue("mithril_test_waiter_pid"),
      blockedSeen: sequenceValue("mithril_test_blocked_seen"),
      timeouts: sequenceValue("mithril_test_timeouts"),
      committerCommitted: true,
    });
    check(
      "barrier immutability: the evidence predicate rejects the arrival-3 round, citing the re-entry",
      evaluation.ok === false && evaluation.reasons.some((r) => r.includes("arrival count") && r.includes("not exactly 2")),
      JSON.stringify(evaluation),
    );
  } finally {
    removeTestObjects();
  }
}

// The same-row barrier (Profile v1): the first transaction to reach
// the update of the contended row waits, holding the tuple lock, until
// PostgreSQL itself reports the expected companion blocked behind THIS
// backend on THIS row.  Every fact below must hold for one candidate
// backend at once:
//   * a pid different from the trigger backend's, a client backend of
//     the current database, waiting on a lock (wait_event_type 'Lock');
//   * blocked by this backend: pg_backend_pid() is among
//     pg_blocking_pids(candidate.pid);
//   * running an UPDATE of the authority relation (its current
//     statement text contains the UPDATE keyword and names the
//     authority model);
//   * holding the tuple lock of the authority relation at exactly the
//     ctid of the row this trigger is updating (pg_locks: locktype
//     'tuple', the authority relation, the row's page and offset).
// A stale session, or a decoy waiter blocked on an unrelated lock by
// another backend, satisfies none of the last three facts and cannot
// release the barrier (decoyWaiterRegression pins this).  Every
// iteration first discards the transaction's cached pg_stat_activity
// snapshot (pg_stat_clear_snapshot), since PostgreSQL otherwise shows
// the same first-read activity for the rest of the transaction.  The
// observation — the arrival, both pids, and the companion's
// statement — is recorded in mithril_test_observations and counted in
// mithril_test_blocked_seen; a barrier deadline expiring is recorded
// as a timeout (a test failure, never an accepted outcome).  Any later
// arrival (the blocked transaction's retry) passes immediately.
function installRowBarrierTrigger() {
  sql(
    `create sequence mithril_test_arrivals;
     create sequence mithril_test_timeouts;
     create sequence mithril_test_blocked_seen;
     create table mithril_test_observations (arrival bigint, own_pid integer, companion_pid integer, companion_query text);
     create function mithril_test_row_barrier() returns trigger language plpgsql as $$
     declare
       deadline timestamptz := clock_timestamp() + interval '${barrierDeadlineInterval()}';
       own_pid integer := pg_backend_pid();
       arrival bigint;
       row_block integer;
       row_offset integer;
       companion_pid integer;
       companion_query text;
     begin
       arrival := nextval('mithril_test_arrivals');
       if arrival >= 2 then
         return new;
       end if;
       select (ctid::text::point)[0]::integer, (ctid::text::point)[1]::integer
         into row_block, row_offset
         from ${authorityTable}
         where ${subjectColumn} = old.${subjectColumn} and ${scopeColumn} = old.${scopeColumn};
       loop
         -- pg_stat_activity is snapshotted once per transaction; discard
         -- the cached snapshot so every iteration reads the live state.
         perform pg_stat_clear_snapshot();
         select a.pid, a.query into companion_pid, companion_query
           from pg_stat_activity a
           where a.datname = current_database()
             and a.pid <> own_pid
             and a.backend_type = 'client backend'
             and a.wait_event_type = 'Lock'
             and own_pid = any (pg_blocking_pids(a.pid))
             and a.query ~* '\\mupdate\\s'
             and position('${authorityTable}' in a.query) > 0
             and exists (
               select 1 from pg_locks l
               where l.pid = a.pid
                 and l.locktype = 'tuple'
                 and l.relation = '${authorityTable}'::regclass
                 and l.page = row_block
                 and l.tuple = row_offset
             )
           limit 1;
         if companion_pid is not null then
           perform nextval('mithril_test_blocked_seen');
           insert into mithril_test_observations (arrival, own_pid, companion_pid, companion_query)
             values (arrival, own_pid, companion_pid, companion_query);
           return new;
         end if;
         if clock_timestamp() > deadline then
           perform nextval('mithril_test_timeouts');
           return new;
         end if;
         perform pg_sleep(0.01);
       end loop;
     end $$;
     create trigger mithril_test_row_barrier before update on ${authorityTable}
       for each row execute function mithril_test_row_barrier();`,
  );
}

// What the same-row barrier recorded in the current round: the number
// of observations, whether the two pids it recorded are two distinct
// backends, and whether the companion's recorded statement was an
// UPDATE of the authority relation.
function barrierObservation() {
  const rows = sql(`select own_pid, companion_pid, companion_query from mithril_test_observations order by arrival;`);
  if (rows === "") {
    return { recorded: 0, distinctBackends: false, companionUpdatesAuthority: false };
  }
  const [ownPid, companionPid, ...queryParts] = rows.split("\n")[0].split("|");
  const companionQuery = queryParts.join("|");
  return {
    recorded: rows.split("\n").length,
    distinctBackends: Number(ownPid) >= 1 && Number(companionPid) >= 1 && Number(ownPid) !== Number(companionPid),
    companionUpdatesAuthority: /\bupdate\s/i.test(companionQuery) && companionQuery.includes(manifest.authorityRelation.model),
  };
}

function removeTestObjects() {
  for (const trigger of testObjects.triggers) {
    sql(`drop trigger if exists ${trigger} on ${authorityTable};`);
  }
  for (const fn of testObjects.functions) {
    sql(`drop function if exists ${fn}();`);
  }
  for (const sequence of testObjects.sequences) {
    sql(`drop sequence if exists ${sequence};`);
  }
  for (const table of testObjects.tables) {
    sql(`drop table if exists ${table};`);
  }
}

function remainingTestObjects() {
  const triggers = sql(`select count(*) from pg_trigger where tgname like 'mithril_test_%';`);
  const functions = sql(`select count(*) from pg_proc where proname like 'mithril_test_%';`);
  const sequences = sql(`select count(*) from pg_class where relkind = 'S' and relname like 'mithril_test_%';`);
  const tables = sql(`select count(*) from pg_class where relkind = 'r' and relname like 'mithril_test_%';`);
  return `${triggers} triggers, ${functions} functions, ${sequences} sequences, ${tables} tables`;
}

function sequenceValue(name) {
  const [lastValue, isCalled] = sql(`select last_value, is_called from ${name};`).split("|");
  return { lastValue: Number(lastValue), isCalled: isCalled === "t" };
}

// --- the battery ---------------------------------------------------------

async function main() {
  await waitForServer();
  console.log(`server: ${serverUrl}`);
  for (const line of planLines()) {
    console.log(line);
  }

  const stamp = `${Date.now()}`;
  const names = {
    admin: `admin${stamp}`,
    member: `member${stamp}`,
    outsider: `outsider${stamp}`,
    peer: `peer${stamp}`,
    bystander: `bystander${stamp}`,
  };
  for (const name of Object.values(names)) {
    await signup(name);
  }
  const adminSession = await login(names.admin);
  const memberSession = await login(names.member);
  const outsiderSession = await login(names.outsider);
  const peerSession = await login(names.peer);
  const admin = userId(names.admin);
  const member = userId(names.member);
  const outsider = userId(names.outsider);
  const peer = userId(names.peer);
  const bystander = userId(names.bystander);
  check(
    "signup and login through Wasp's username/password path",
    [admin, member, outsider, peer, bystander].every((id) => Number.isInteger(id) && id >= 1),
  );

  // The relevant scope and an unrelated sentinel scope, with sentinel
  // memberships in both.
  const scope = newScope();
  const otherScope = newScope();
  setMembership(admin, scope, top);
  setMembership(member, scope, bottom);
  setMembership(bystander, scope, bottom);
  setMembership(admin, otherScope, bottom);
  setMembership(member, otherScope, top);
  setMembership(bystander, otherScope, top);
  const expectedInitial =
    `${scope}:${admin}=${top},${scope}:${member}=${bottom},${scope}:${bystander}=${bottom},` +
    `${otherScope}:${admin}=${bottom},${otherScope}:${member}=${top},${otherScope}:${bystander}=${top}`;
  const initial = relationState();
  check("bootstrap state (complete relation, sentinels included)", initial === expectedInitial, initial);

  async function unchanged(name, run, expectedStatus, expectedBody) {
    const before = relationState();
    const response = await run();
    const after = relationState();
    check(`${name}: status ${expectedStatus}`, response.status === expectedStatus, `got ${response.status} ${response.text}`);
    if (expectedBody !== undefined) {
      check(`${name}: exact response bytes`, response.text === expectedBody, `got ${response.text}`);
    }
    check(`${name}: complete relation unchanged`, before === after && after === expectedInitial, after);
    return response;
  }

  // Unauthenticated: no bearer session at all — the Action's own 401.
  await unchanged("no bearer session", () => changeRole(undefined, member, scope, top), 401, body401);
  // An invalid bearer session — Wasp's own 401; the body is Wasp's,
  // so only its status and the unchanged state are pinned, plus the
  // absence of any authority value in it.
  {
    const response = await unchanged("invalid bearer session", () => changeRole("not-a-session", member, scope, top), 401);
    check("invalid bearer session: no authority value leaks", !response.text.includes(top) && !response.text.includes(bottom), response.text);
  }
  // Invalid input shapes: a non-integer target, an unknown payload
  // value, a missing body, a zero target, and a non-object envelope.
  await unchanged(
    "non-integer target argument",
    () => post(route, { json: { [subjectArgument]: "x", [scopeArgument]: scope, [payloadArgument]: top } }, adminSession),
    400,
    body400,
  );
  await unchanged("unknown payload value", () => changeRole(adminSession, member, scope, "NotAValue"), 400, body400);
  await unchanged("empty request envelope", () => post(route, {}, adminSession), 400, body400);
  await unchanged("zero entity reference", () => changeRole(adminSession, 0, scope, top), 400, body400);
  await unchanged("array envelope", () => post(route, { json: [member, scope, top] }, adminSession), 400, body400);

  // Every denied case: exactly 403, byte-identical bodies, the
  // complete relation byte-identical before and after.
  const deniedBodies = [];
  async function denied(name, run) {
    const response = await unchanged(name, run, 403, body403);
    deniedBodies.push(response.text);
  }
  await denied("a member changing another member", () => changeRole(memberSession, admin, scope, bottom));
  await denied("an outsider with no authority tuple", () => changeRole(outsiderSession, member, scope, top));
  await denied("the actor as the target (an admin changing their own role)", () => changeRole(adminSession, admin, scope, bottom));
  await denied("a missing target tuple", () => changeRole(adminSession, outsider, scope, top));
  await denied("a scope where the actor holds only the bottom value", () => changeRole(adminSession, member, otherScope, bottom));
  await denied("a scope that does not exist", () => changeRole(adminSession, member, scope + 1000000, top));
  await denied("a member using the sentinel scope's admin session against the main scope", () => changeRole(memberSession, bystander, scope, top));
  check("every denied response is byte-identical (uniform 403)", deniedBodies.every((b) => b === deniedBodies[0]), deniedBodies.join(" | "));

  // The one allowed path: an admin changing another existing member
  // changes exactly the target tuple.
  {
    const before = relationState();
    const response = await changeRole(adminSession, member, scope, top);
    const after = relationState();
    check("an admin promoting another member succeeds with 200", response.status === 200, `${response.status} ${response.text}`);
    check("the success response is the pinned superjson envelope of the void result", response.text === body200, response.text);
    check(
      "exactly the target tuple changed",
      after === before.replace(`${scope}:${member}=${bottom}`, `${scope}:${member}=${top}`) && after !== before,
      after,
    );
    const demote = await changeRole(adminSession, member, scope, bottom);
    check("an admin demoting another member succeeds with 200", demote.status === 200 && demote.text === body200, `${demote.status} ${demote.text}`);
    check("the relation is back to its initial state", relationState() === expectedInitial, relationState());
  }

  // P2034 exhaustion through the real HTTP path.
  removeTestObjects();
  installConflictTrigger();
  try {
    const before = relationState();
    const response = await changeRole(adminSession, member, scope, top);
    const after = relationState();
    const attempts = sequenceValue("mithril_test_attempts");
    const txids = [1, 2, 3, 4].map((n) => sequenceValue(`mithril_test_txid_${n}`));
    check("exhausted P2034 answers the pinned 409", response.status === 409 && response.text === body409, `${response.status} ${response.text}`);
    check("exactly three transaction attempts reached the update", attempts.isCalled && attempts.lastValue === 3, JSON.stringify(attempts));
    check(
      "every attempt ran in a fresh transaction (three distinct increasing transaction ids, no fourth attempt)",
      txids[0].isCalled &&
        txids[1].isCalled &&
        txids[2].isCalled &&
        !txids[3].isCalled &&
        txids[0].lastValue < txids[1].lastValue &&
        txids[1].lastValue < txids[2].lastValue,
      JSON.stringify(txids),
    );
    check("exhausted P2034 leaves the complete relation unchanged", before === after && after === expectedInitial, after);
  } finally {
    removeTestObjects();
  }

  // A generic database error through the real HTTP path.
  installFaultTrigger();
  try {
    const before = relationState();
    const response = await changeRole(adminSession, member, scope, top);
    const after = relationState();
    check("a generic database failure answers the pinned 500", response.status === 500 && response.text === body500, `${response.status} ${response.text}`);
    check("a generic database failure leaves the complete relation unchanged", before === after && after === expectedInitial, after);
  } finally {
    removeTestObjects();
  }

  // Genuine concurrency with the deterministic PostgreSQL-level
  // barrier: two admins each demote the other (two distinct rows, a
  // Serializable write skew).  The barrier holds the waiter open until
  // the committer has COMMITTED, so the two transactions provably
  // overlap AND exactly one demotion commits — the waiter then loses,
  // aborts once, and its fresh retry is denied.  Every round must be a
  // row of the explicit two-admin outcome table (oracle.mjs): whichever
  // demotion commits leaves the other actor below the privilege floor,
  // so the other request's retried read is denied — the pair is 200/403
  // or 403/200.  Both succeeding (write skew), a denial without a
  // committed demotion, a 409 (which an isolated pair cannot produce), a
  // wrong body, or a wrong final relation is never accepted.
  setMembership(peer, scope, top);
  const concurrentBase = relationState();
  installBarrierTrigger();
  // Bootstrap the per-round membership (two setMembership updates), then arm
  // the barrier.  Those bootstrap updates fire the same before-update
  // trigger, so their arrival numbers depend on where the arrivals counter
  // stands when the round begins — this is NOT guaranteed to be the
  // later-arrival bypass on every execution:
  //   * Initially, the setval below leaves the counter at 2 (is_called
  //     TRUE), so the first round's two bootstrap nextval() calls return 3
  //     and 4: both take the trigger's later-arrival BYPASS branch, which
  //     returns at once and cannot publish or overwrite committer evidence.
  //   * After a round that ended with exactly two arrivals (arrival 1 the
  //     waiter, arrival 2 the committer — the accepted shape), the counter
  //     again stands at 2, so the next round's bootstrap likewise draws 3
  //     and 4 and bypasses.
  //   * After an ALREADY-REJECTED round that reached the trigger only zero
  //     or one times, the counter stands lower, so the next round's
  //     bootstrap may instead draw arrival 1 or arrival 2: arrival 2 would
  //     temporarily publish committer evidence, and arrival 1 would enter
  //     the waiter poll loop and time out.  This is harmless — that prior
  //     round is already rejected, and the per-round arm/evidence reset
  //     below clears EVERY barrier sequence (the arrival counter, the
  //     committer txid/pid/arrival, blocked-seen, timeouts, and the waiter
  //     pid) before the round's two concurrent requests run, so no bootstrap
  //     arrival or stray evidence can be mistaken for the tested pair's
  //     companion or falsely accept the round.
  // Correctness therefore rests on that reset, not on the bootstrap always
  // taking the later-arrival bypass.
  sql(`select setval('mithril_test_arrivals', 2, true);`);
  const rounds = 12;
  const outcomes = [];
  const transportFailures = [];
  const twoAdminJudgements = [];
  const arrivalCounts = [];
  let consistentRounds = 0;
  let overlappingRounds = 0;
  try {
    for (let round = 0; round < rounds; round += 1) {
      setMembership(admin, scope, top);
      setMembership(peer, scope, top);
      // Arm the deterministic barrier for exactly the two concurrent
      // requests: every barrier sequence back to its unset state, so the
      // waiter cannot mistake a stale committer id for the companion's.
      sql(
        `select setval('mithril_test_arrivals', 1, false); select setval('mithril_test_timeouts', 1, false); ` +
          `select setval('mithril_test_blocked_seen', 1, false); select setval('mithril_test_committer_txid', 1, false); ` +
          `select setval('mithril_test_committer_pid', 1, false); select setval('mithril_test_committer_arrival', 1, false); ` +
          `select setval('mithril_test_waiter_pid', 1, false);`,
      );
      // Two real HTTP requests over two independent, non-pooled
      // connections, collected with Promise.allSettled: a transport
      // rejection is recorded, not thrown, so the state, arrival, and
      // timeout evidence below is always read and the temporary
      // objects are always cleaned up.
      const labels = ["admin demotes peer", "peer demotes admin"];
      const { observations, transportFailures: roundTransport } = await settleConcurrent(
        [
          () => changeRoleIndependent(adminSession, peer, scope, bottom),
          () => changeRoleIndependent(peerSession, admin, scope, bottom),
        ],
        labels,
      );
      const [first, second] = observations;
      for (const failure of roundTransport) {
        transportFailures.push(`round ${round} ${renderTransportFailure(failure)}`);
      }
      const state = relationState();
      const arrivals = sequenceValue("mithril_test_arrivals");
      const timeouts = sequenceValue("mithril_test_timeouts");
      // The overlap and one-shot evidence, all read from non-transactional
      // sequences so it survives the waiter's abort: the waiter released only
      // after the DESIGNATED committer (arrival 2) committed (blocked_seen),
      // the committer's published evidence still identifies arrival 2
      // (committer_arrival), and the two are distinct backends.
      const blockedSeen = sequenceValue("mithril_test_blocked_seen");
      const waiterPid = sequenceValue("mithril_test_waiter_pid");
      const committerPid = sequenceValue("mithril_test_committer_pid");
      const committerTxid = sequenceValue("mithril_test_committer_txid");
      const committerArrival = sequenceValue("mithril_test_committer_arrival");
      // The commit status of the EXACT published committer transaction, read
      // straight from the clog — an independent, database-confirmed proof
      // that the very transaction the committer published committed.
      const committerCommitted =
        committerTxid.isCalled && sql(`select pg_xact_status(${committerTxid.lastValue}::text::xid8);`) === "committed";
      const distinctBackends =
        waiterPid.isCalled && committerPid.isCalled && waiterPid.lastValue !== committerPid.lastValue;
      arrivalCounts.push(arrivals.isCalled ? arrivals.lastValue : -1);
      const adminValue = state.includes(`${scope}:${admin}=${top}`) ? top : bottom;
      const peerValue = state.includes(`${scope}:${peer}=${top}`) ? top : bottom;
      const expectedState = (adminV, peerV) =>
        concurrentBase.replace(`${scope}:${admin}=${top}`, `${scope}:${admin}=${adminV}`).replace(`${scope}:${peer}=${top}`, `${scope}:${peer}=${peerV}`);
      const firstStatus = first === null ? "transport-failure" : first.status;
      const secondStatus = second === null ? "transport-failure" : second.status;
      const bothObserved = first !== null && second !== null;
      const judgement = judgeRound(
        TWO_ADMIN_ROWS,
        { first, second, state },
        { bodies, expectedState: (final) => twoAdminState(final, expectedState) },
      );
      twoAdminJudgements.push(judgement);
      // The single acceptance rule for a round's barrier evidence
      // (test/wasp-integration/concurrency.mjs): EXACTLY two arrivals
      // (arrival 1 the waiter, arrival 2 the designated committer), no retry
      // re-entering the barrier, the committer evidence still identifying
      // arrival 2, two distinct backends, the exact published transaction
      // committed, and no timeout.  The hermetic regression pins this same
      // predicate, so the harness and the battery cannot diverge.
      const barrierEvidence = evaluateTwoAdminBarrierEvidence({
        arrivals,
        committerArrival,
        committerTxid,
        committerPid,
        waiterPid,
        blockedSeen,
        timeouts,
        committerCommitted,
      });
      const overlapping = bothObserved && barrierEvidence.ok;
      outcomes.push(
        `${firstStatus}/${secondStatus}:${adminValue}/${peerValue}:arrivals=${arrivals.lastValue}:committerArrival=${committerArrival.isCalled ? committerArrival.lastValue : 0}:committed=${committerCommitted}:blocked=${blockedSeen.isCalled ? blockedSeen.lastValue : 0}${distinctBackends ? "" : ":same-or-missing-pids"}:timeouts=${timeouts.isCalled ? timeouts.lastValue : 0}${barrierEvidence.ok ? "" : `:BARRIER(${barrierEvidence.reasons.join("; ")})`}${judgement.accepted ? "" : `:REJECTED(${judgement.reason})`}`,
      );
      if (judgement.accepted) {
        consistentRounds += 1;
      }
      if (overlapping) {
        overlappingRounds += 1;
      }
    }
  } finally {
    removeTestObjects();
  }
  console.log(`concurrency outcomes: ${outcomes.join(" ")}`);
  console.log(`two-admin rows observed: ${renderTally(tallyRows(TWO_ADMIN_ROWS, twoAdminJudgements))}`);
  check("no concurrent round suffered a client transport failure", transportFailures.length === 0, transportFailures.join(" | "));
  check(
    `every concurrent round is a row of the explicit two-admin outcome table — a permitted status pair, byte-exact bodies, exactly the row's complete relation (${consistentRounds}/${rounds})`,
    consistentRounds === rounds,
    outcomes.filter((outcome) => outcome.includes("REJECTED")).join(" "),
  );
  check(
    `every two-admin round is exactly one-shot — its arrival count is exactly 2 (arrival 1 the waiter, arrival 2 the designated committer), so no retry re-entered the barrier (${arrivalCounts.filter((c) => c === 2).length}/${rounds})`,
    arrivalCounts.length === rounds && arrivalCounts.every((c) => c === 2),
    `arrival counts per round: ${arrivalCounts.join(",")}`,
  );
  check(
    `every round proved genuine overlap — the waiter held open until the DESIGNATED committer (arrival 2, a distinct backend) committed the exact published transaction, its evidence still identifying arrival 2, with no barrier timeout (${overlappingRounds}/${rounds})`,
    overlappingRounds === rounds,
    outcomes.filter((o) => o.includes("BARRIER(")).join(" "),
  );
  check(
    "no concurrent round produced a 409 — an isolated two-request pair resolves serially (one demotion commits, the other's retried read is denied), so a 409 has no serial interpretation here and is never an accepted outcome",
    outcomes.every((o) => !o.startsWith("409") && !o.includes("/409")),
    outcomes.filter((o) => o.startsWith("409") || o.includes("/409")).join(" "),
  );
  check("no concurrent round demoted both actors (no write skew)", outcomes.every((o) => !o.includes(`:${bottom}/${bottom}:`)));
  check("unrelated memberships are unchanged after the concurrency rounds", relationState().includes(`${otherScope}:${admin}=${bottom},${otherScope}:${member}=${top},${otherScope}:${bystander}=${top}`) && relationState().includes(`${scope}:${bystander}=${bottom}`), relationState());

  // The barrier's designated-committer evidence is immutable: a later
  // arrival cannot overwrite what arrival 2 published (real-trigger regression).
  barrierEvidenceImmutabilityProbe({ admin, scope });

  if (profileV1) {
    await selfUpdateBattery({ names, admin, member, outsider, peer, bystander, adminSession, memberSession, outsiderSession, peerSession, scope, otherScope });
  }

  const remaining = remainingTestObjects();
  check("every temporary trigger, function, sequence, and table was removed", remaining === "0 triggers, 0 functions, 0 sequences, 0 tables", remaining);
}

// --- the Profile-v1 battery: the rule-2 Action and the cross-operation overlap ---

async function selfUpdateBattery({ admin, member, outsider, peer, bystander, adminSession, memberSession, outsiderSession, peerSession, scope, otherScope }) {
  console.log(`rule-2 route: ${selfRoute}`);
  // The rule-2 base state: admin and peer at the top value, member and
  // bystander at the bottom value, the outsider with no tuple; the
  // sentinel scope as before.
  setMembership(admin, scope, top);
  setMembership(peer, scope, top);
  setMembership(member, scope, bottom);
  setMembership(bystander, scope, bottom);
  const selfBase = relationState();
  check(
    "rule-2 bootstrap state (complete relation, sentinels included)",
    selfBase ===
      expectedRelation([
        [scope, admin, top],
        [scope, member, bottom],
        [scope, bystander, bottom],
        [scope, peer, top],
        [otherScope, admin, bottom],
        [otherScope, member, top],
        [otherScope, bystander, top],
      ]),
    selfBase,
  );

  async function selfUnchanged(name, run, expectedStatus, expectedBody) {
    const before = relationState();
    const response = await run();
    const after = relationState();
    check(`${name}: status ${expectedStatus}`, response.status === expectedStatus, `got ${response.status} ${response.text}`);
    if (expectedBody !== undefined) {
      check(`${name}: exact response bytes`, response.text === expectedBody, `got ${response.text}`);
    }
    check(`${name}: complete relation unchanged`, before === after && after === selfBase, after);
    return response;
  }

  // 401 and 400 through the rule-2 route.
  await selfUnchanged("rule-2: no bearer session", () => selfUpdate(undefined, scope, bottom), 401, body401);
  await selfUnchanged("rule-2: non-integer scope argument", () => post(selfRoute, { json: { [selfScopeArgument]: "x", [selfPayloadArgument]: bottom } }, adminSession), 400, body400);
  await selfUnchanged("rule-2: unknown payload value", () => selfUpdate(adminSession, scope, "NotAValue"), 400, body400);
  await selfUnchanged("rule-2: missing payload argument", () => post(selfRoute, { json: { [selfScopeArgument]: scope } }, adminSession), 400, body400);
  await selfUnchanged("rule-2: empty request envelope", () => post(selfRoute, {}, adminSession), 400, body400);
  await selfUnchanged("rule-2: zero scope reference", () => selfUpdate(adminSession, 0, bottom), 400, body400);

  // Every denied case: the uniform 403, the complete relation
  // unchanged.
  const deniedBodies = [];
  async function selfDenied(name, run) {
    const response = await selfUnchanged(name, run, 403, body403);
    deniedBodies.push(response.text);
  }
  await selfDenied("rule-2: Member → Admin self-promotion", () => selfUpdate(memberSession, scope, top));
  await selfDenied("rule-2: a non-member requesting the bottom value", () => selfUpdate(outsiderSession, scope, bottom));
  await selfDenied("rule-2: a non-member requesting the top value", () => selfUpdate(outsiderSession, scope, top));
  await selfDenied("rule-2: a scope that does not exist", () => selfUpdate(adminSession, scope + 1000000, top));
  await selfDenied("rule-2: an admin in a scope where they hold only the bottom value requesting the top value", () => selfUpdate(adminSession, otherScope, top));
  await selfDenied("rule-2: no caller-controlled subject channel exists — a member's request smuggling a subject that names an admin neither promotes the admin's tuple nor the member's own (uniform 403)", () => selfUpdate(memberSession, scope, top, { [subjectArgument]: admin, subject: admin, target: admin }));
  check("rule-2: every denied response is byte-identical (uniform 403)", deniedBodies.every((b) => b === deniedBodies[0]), deniedBodies.join(" | "));

  // The allowed paths.
  {
    const before = relationState();
    const response = await selfUpdate(adminSession, scope, bottom);
    const after = relationState();
    check("rule-2: Admin → Member self-demotion succeeds with 200", response.status === 200 && response.text === body200, `${response.status} ${response.text}`);
    check(
      "rule-2: the self-demotion changed exactly the actor's own tuple",
      after === before.replace(`${scope}:${admin}=${top}`, `${scope}:${admin}=${bottom}`) && after !== before,
      after,
    );
    const promote = await selfUpdate(adminSession, scope, top);
    check("rule-2: the demoted actor cannot promote themselves back (403)", promote.status === 403 && promote.text === body403, `${promote.status} ${promote.text}`);
    setMembership(admin, scope, top);
    check("rule-2: the relation is back to its base state", relationState() === selfBase, relationState());
  }
  await selfUnchanged("rule-2: Admin → Admin equal write succeeds and changes nothing", () => selfUpdate(adminSession, scope, top), 200, body200);
  await selfUnchanged("rule-2: Member → Member equal write succeeds and changes nothing", () => selfUpdate(memberSession, scope, bottom), 200, body200);
  await selfUnchanged(
    "rule-2: the untrusted extra subject field is dropped harmlessly — an allowed equal write carrying a subject that names an admin succeeds and changes nothing, the admin's tuple included",
    () => selfUpdate(memberSession, scope, bottom, { [subjectArgument]: admin, subject: admin, target: admin }),
    200,
    body200,
  );
  // Authorized AND state-changing with a smuggled subject: the admin's
  // own Admin → Member self-demotion carrying a subject field that
  // names a different existing member.  The request succeeds, exactly
  // the authenticated admin's own (actor, scope) tuple changes, the
  // named member's tuple is unchanged, and every other row of the
  // complete relation is unchanged — the extra field is dropped, and no
  // caller-controlled subject channel redirects the write.
  {
    const before = relationState();
    const response = await selfUpdate(adminSession, scope, bottom, { [subjectArgument]: member, subject: member, target: member });
    const after = relationState();
    check(
      "rule-2: the untrusted extra subject field is dropped harmlessly — an allowed, state-changing Admin → Member self-demotion carrying a subject that names another existing member succeeds with 200",
      response.status === 200 && response.text === body200,
      `${response.status} ${response.text}`,
    );
    check(
      "rule-2: that demotion changed exactly the authenticated admin's own tuple — the named member's tuple and every other row of the complete relation are unchanged",
      after === replaceTuple(before, scope, admin, bottom) &&
        after !== before &&
        tupleValue(before, scope, admin) === top &&
        tupleValue(after, scope, admin) === bottom &&
        tupleValue(after, scope, member) === bottom &&
        tupleValue(after, scope, member) === tupleValue(before, scope, member),
      `before ${before}; after ${after}`,
    );
    setMembership(admin, scope, top);
    check("rule-2: the relation is back to its base state after the smuggled-subject demotion", relationState() === selfBase, relationState());
  }

  // P2034 exhaustion through the rule-2 route.
  removeTestObjects();
  installConflictTrigger();
  try {
    const before = relationState();
    const response = await selfUpdate(adminSession, scope, bottom);
    const after = relationState();
    const attempts = sequenceValue("mithril_test_attempts");
    const txids = [1, 2, 3, 4].map((n) => sequenceValue(`mithril_test_txid_${n}`));
    check("rule-2: exhausted P2034 answers the pinned 409", response.status === 409 && response.text === body409, `${response.status} ${response.text}`);
    check("rule-2: exactly three transaction attempts reached the update", attempts.isCalled && attempts.lastValue === 3, JSON.stringify(attempts));
    check(
      "rule-2: every attempt ran in a fresh transaction (three distinct increasing transaction ids, no fourth attempt)",
      txids[0].isCalled &&
        txids[1].isCalled &&
        txids[2].isCalled &&
        !txids[3].isCalled &&
        txids[0].lastValue < txids[1].lastValue &&
        txids[1].lastValue < txids[2].lastValue,
      JSON.stringify(txids),
    );
    check("rule-2: exhausted P2034 leaves the complete relation unchanged", before === after && after === selfBase, after);
  } finally {
    removeTestObjects();
  }

  // A generic database error through the rule-2 route.
  installFaultTrigger();
  try {
    const before = relationState();
    const response = await selfUpdate(adminSession, scope, bottom);
    const after = relationState();
    check("rule-2: a generic database failure answers the pinned 500", response.status === 500 && response.text === body500, `${response.status} ${response.text}`);
    check("rule-2: a generic database failure leaves the complete relation unchanged", before === after && after === selfBase, after);
  } finally {
    removeTestObjects();
  }

  const baseWith = (adminV, peerV) => replaceTuple(replaceTuple(selfBase, scope, admin, adminV), scope, peer, peerV);
  const rounds = 8;
  const resetRound = () => {
    setMembership(admin, scope, top);
    setMembership(peer, scope, top);
    sql(
      `select setval('mithril_test_arrivals', 1, false); select setval('mithril_test_timeouts', 1, false); select setval('mithril_test_blocked_seen', 1, false); delete from mithril_test_observations;`,
    );
  };

  // Same-operation concurrency: the same actor's self-demotion and
  // equal self-write contend for the SAME row, so the tuple lock
  // serializes them at the same-row barrier.  Every round must be a row
  // of the explicit same-operation outcome table (oracle.mjs): the
  // demotion is never denied, the equal top write commits only before
  // the demotion, a committed demotion leaves the bottom value; the
  // blocked request is decided after one committed conflict, so the pair
  // is 200/403 or 200/200 and never a 409.
  installRowBarrierTrigger();
  const sameOutcomes = [];
  const sameTransport = [];
  const sameJudgements = [];
  let sameConsistent = 0;
  let sameOverlapping = 0;
  try {
    for (let round = 0; round < rounds; round += 1) {
      resetRound();
      const { observations, transportFailures: roundTransport } = await settleConcurrent(
        [() => selfUpdateIndependent(adminSession, scope, bottom), () => selfUpdateIndependent(adminSession, scope, top)],
        ["admin demotes self", "admin keeps top"],
      );
      const [demote, keep] = observations;
      for (const failure of roundTransport) {
        sameTransport.push(`round ${round} ${renderTransportFailure(failure)}`);
      }
      const state = relationState();
      const arrivals = sequenceValue("mithril_test_arrivals");
      const timeouts = sequenceValue("mithril_test_timeouts");
      const blockedSeen = sequenceValue("mithril_test_blocked_seen");
      const adminValue = tupleValue(state, scope, admin);
      const bothObserved = demote !== null && keep !== null;
      const judgement = judgeRound(
        SAME_OPERATION_ROWS,
        { first: demote, second: keep, state },
        { bodies, expectedState: (final) => (final === FINAL_BOTTOM ? baseWith(bottom, top) : final === FINAL_TOP ? baseWith(top, top) : undefined) },
      );
      sameJudgements.push(judgement);
      const observation = barrierObservation();
      const overlapping =
        bothObserved &&
        blockedSeen.isCalled &&
        blockedSeen.lastValue >= 1 &&
        !timeouts.isCalled &&
        observation.recorded >= 1 &&
        observation.distinctBackends &&
        observation.companionUpdatesAuthority;
      sameOutcomes.push(
        `${demote === null ? "transport-failure" : demote.status}/${keep === null ? "transport-failure" : keep.status}:${adminValue}:arrivals=${arrivals.lastValue}:blocked=${blockedSeen.isCalled ? blockedSeen.lastValue : 0}:observed=${observation.recorded}${observation.distinctBackends ? "" : ":same-or-missing-pids"}${observation.companionUpdatesAuthority ? "" : ":no-authority-update"}:timeouts=${timeouts.isCalled ? timeouts.lastValue : 0}${judgement.accepted ? "" : `:REJECTED(${judgement.reason})`}`,
      );
      if (judgement.accepted) {
        sameConsistent += 1;
      }
      if (overlapping) {
        sameOverlapping += 1;
      }
    }
  } finally {
    removeTestObjects();
  }
  console.log(`rule-2 same-operation concurrency outcomes: ${sameOutcomes.join(" ")}`);
  console.log(`same-operation rows observed: ${renderTally(tallyRows(SAME_OPERATION_ROWS, sameJudgements))}`);
  check("rule-2 same-operation: no concurrent round suffered a client transport failure", sameTransport.length === 0, sameTransport.join(" | "));
  check(
    `rule-2 same-operation: every round is a row of the explicit same-operation outcome table — a permitted status pair, byte-exact bodies, exactly the row's complete relation (${sameConsistent}/${rounds})`,
    sameConsistent === rounds,
    sameOutcomes.filter((outcome) => outcome.includes("REJECTED")).join(" "),
  );
  check(
    `rule-2 same-operation: in every round the same-row barrier identified its companion — a distinct backend blocked behind the first request's backend on the actor's row, running an UPDATE of the authority relation — with no timeout (genuine overlap of two backend transactions) (${sameOverlapping}/${rounds})`,
    sameOverlapping === rounds,
  );
  check(
    "rule-2 same-operation: no round produced a 409 — the same-row tuple lock serializes the two requests, so the blocked request is decided after one committed conflict and never exhausts three attempts",
    sameOutcomes.every((o) => !o.startsWith("409") && !o.includes("/409")),
    sameOutcomes.filter((o) => o.startsWith("409") || o.includes("/409")).join(" "),
  );

  // Cross-operation concurrency: actor A (admin) demotes peer P through
  // the rule-1 Action while P requests to remain at the top value
  // through the rule-2 Action; both updates hit P's tuple (the SAME
  // row), so the tuple lock serializes them at the same-row barrier.
  // Every round must be a row of the explicit cross-operation outcome
  // table (oracle.mjs): rule 1 is never denied, P always ends at the
  // bottom value, and 200/200 is valid only for the order rule 2 then
  // rule 1; the blocked request is decided after one committed conflict,
  // so the pair is 200/403 or 200/200 and never a 409, and never 200/200
  // with P still at the top value.  A's tuple never changes (the row's
  // complete relation pins it).
  installRowBarrierTrigger();
  const crossOutcomes = [];
  const crossTransport = [];
  const crossJudgements = [];
  let crossConsistent = 0;
  let crossOverlapping = 0;
  let crossRule1Successes = 0;
  try {
    for (let round = 0; round < rounds; round += 1) {
      resetRound();
      const { observations, transportFailures: roundTransport } = await settleConcurrent(
        [() => changeRoleIndependent(adminSession, peer, scope, bottom), () => selfUpdateIndependent(peerSession, scope, top)],
        ["admin demotes peer (rule 1)", "peer keeps top (rule 2)"],
      );
      const [rule1, rule2] = observations;
      for (const failure of roundTransport) {
        crossTransport.push(`round ${round} ${renderTransportFailure(failure)}`);
      }
      const state = relationState();
      const arrivals = sequenceValue("mithril_test_arrivals");
      const timeouts = sequenceValue("mithril_test_timeouts");
      const blockedSeen = sequenceValue("mithril_test_blocked_seen");
      const peerValue = tupleValue(state, scope, peer);
      const bothObserved = rule1 !== null && rule2 !== null;
      const rule1Succeeded = bothObserved && rule1.status === 200;
      const judgement = judgeRound(
        CROSS_OPERATION_ROWS,
        { first: rule1, second: rule2, state },
        { bodies, expectedState: (final) => (final === FINAL_BOTTOM ? baseWith(top, bottom) : final === FINAL_TOP ? baseWith(top, top) : undefined) },
      );
      crossJudgements.push(judgement);
      const observation = barrierObservation();
      const overlapping =
        bothObserved &&
        blockedSeen.isCalled &&
        blockedSeen.lastValue >= 1 &&
        !timeouts.isCalled &&
        observation.recorded >= 1 &&
        observation.distinctBackends &&
        observation.companionUpdatesAuthority;
      crossOutcomes.push(
        `${rule1 === null ? "transport-failure" : rule1.status}/${rule2 === null ? "transport-failure" : rule2.status}:${peerValue}:arrivals=${arrivals.lastValue}:blocked=${blockedSeen.isCalled ? blockedSeen.lastValue : 0}:observed=${observation.recorded}${observation.distinctBackends ? "" : ":same-or-missing-pids"}${observation.companionUpdatesAuthority ? "" : ":no-authority-update"}:timeouts=${timeouts.isCalled ? timeouts.lastValue : 0}${judgement.accepted ? "" : `:REJECTED(${judgement.reason})`}`,
      );
      if (judgement.accepted) {
        crossConsistent += 1;
      }
      if (overlapping) {
        crossOverlapping += 1;
      }
      if (rule1Succeeded) {
        crossRule1Successes += 1;
      }
    }
  } finally {
    removeTestObjects();
  }
  console.log(`rule-1/rule-2 cross-operation concurrency outcomes: ${crossOutcomes.join(" ")}`);
  console.log(`cross-operation rows observed: ${renderTally(tallyRows(CROSS_OPERATION_ROWS, crossJudgements))}`);
  check("cross-operation: no concurrent round suffered a client transport failure", crossTransport.length === 0, crossTransport.join(" | "));
  check(
    `cross-operation: every round is a row of the explicit cross-operation outcome table — a permitted status pair, byte-exact bodies, exactly the row's complete relation with A unchanged (${crossConsistent}/${rounds})`,
    crossConsistent === rounds,
    crossOutcomes.filter((outcome) => outcome.includes("REJECTED")).join(" "),
  );
  check(
    `cross-operation: in every round the same-row barrier identified its companion — a distinct backend blocked behind the first request's backend on P's row, running an UPDATE of the authority relation — with no timeout (genuine overlap of two backend transactions) (${crossOverlapping}/${rounds})`,
    crossOverlapping === rounds,
  );
  check("cross-operation: no round let both requests succeed with P still at the top value (the forbidden outcome)", crossOutcomes.every((o) => !o.startsWith(`200/200:${top}:`)));
  check(
    "cross-operation: no round produced a 409 — the same-row tuple lock serializes rule 1 and rule 2, so the blocked request is decided after one committed conflict and never exhausts three attempts",
    crossOutcomes.every((o) => !o.startsWith("409") && !o.includes("/409")),
    crossOutcomes.filter((o) => o.startsWith("409") || o.includes("/409")).join(" "),
  );
  check("cross-operation: the rule-1 demotion committed in at least one round (the cross-operation conflict was actually exercised)", crossRule1Successes >= 1, `${crossRule1Successes}/${rounds}`);

  await decoyWaiterRegression({ adminSession, scope });

  setMembership(admin, scope, top);
  setMembership(peer, scope, top);
  check("rule-2: unrelated memberships are unchanged after the Profile-v1 battery", relationState() === selfBase, relationState());
}

// --- the same-row barrier's negative regression: an unrelated decoy lock waiter ---

// An unrelated decoy lock waiter — a second test session blocked on a
// row of a test-only table held by a first test session, i.e. a client
// backend of this database with wait_event_type = 'Lock' that is
// blocked by ANOTHER backend on an unrelated relation — must neither
// release nor satisfy the same-row barrier.  A lone rule-2 request
// under the barrier must therefore wait out the barrier deadline
// (exactly one recorded timeout, zero blocked observations, an empty
// observation table) and still complete normally, while the decoy
// stays blocked throughout.  The weak predicate the barrier once used
// ("any other backend of the database waiting on a lock") is shown to
// be satisfied by the decoy alone, so this regression fails under it.
// Every step is bounded: the two psql sessions are driven through
// pipes with polling deadlines, released with ROLLBACK and quit,
// killed and terminated through pg_terminate_backend if they linger,
// and verified gone before the decoy table is dropped; the decoy
// table, like every temporary object, is dropped and its removal
// verified.
async function decoyWaiterRegression({ adminSession, scope }) {
  const holderName = "mithril_test_decoy_holder";
  const waiterName = "mithril_test_decoy_waiter";
  const sessions = [];
  const openSession = (applicationName) => {
    const child = spawn("psql", [databaseUrl, "-q", "-X", "-v", "ON_ERROR_STOP=1"], { stdio: ["pipe", "pipe", "pipe"] });
    child.stdout.on("data", () => {});
    child.stderr.on("data", () => {});
    const session = {
      child,
      applicationName,
      exited: new Promise((resolve) => child.on("exit", (code, signal) => resolve({ code, signal }))),
    };
    sessions.push(session);
    child.stdin.write(`set application_name = '${applicationName}';\n`);
    return session;
  };
  const countSessions = (applicationName, extra = "") =>
    Number(sql(`select count(*) from pg_stat_activity where datname = current_database() and application_name = '${applicationName}'${extra};`));
  const waitUntil = async (label, predicate, deadlineMs = 10000) => {
    const started = Date.now();
    while (Date.now() - started < deadlineMs) {
      if (predicate()) {
        return true;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    check(`decoy regression: ${label}`, false, `not observed within ${deadlineMs} ms`);
    return false;
  };
  const releaseSessions = async () => {
    for (const session of sessions) {
      try {
        session.child.stdin.write("rollback;\n\\q\n");
        session.child.stdin.end();
      } catch {
        // the session may already be gone
      }
    }
    const deadline = Date.now() + 5000;
    for (const session of sessions) {
      const remaining = Math.max(0, deadline - Date.now());
      const outcome = await Promise.race([session.exited, new Promise((resolve) => setTimeout(resolve, remaining, null))]);
      if (outcome === null) {
        session.child.kill("SIGKILL");
        await session.exited;
      }
    }
    sql(`select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and application_name in ('${holderName}', '${waiterName}');`);
    return waitUntil("the decoy sessions are gone", () => countSessions(holderName) + countSessions(waiterName) === 0);
  };

  removeTestObjects();
  sql(`create table mithril_test_decoy (id integer primary key, n integer not null); insert into mithril_test_decoy values (1, 0);`);
  let released = false;
  try {
    const holder = openSession(holderName);
    holder.child.stdin.write("begin; update mithril_test_decoy set n = n + 1 where id = 1;\n");
    const holderReady = await waitUntil(
      "the decoy holder session holds its row lock (idle in transaction)",
      () => countSessions(holderName, " and state = 'idle in transaction'") === 1,
    );
    const waiter = openSession(waiterName);
    waiter.child.stdin.write("begin; update mithril_test_decoy set n = n + 1 where id = 1;\n");
    const waiterBlocked = await waitUntil(
      "the decoy waiter session is blocked on the holder's lock",
      () => countSessions(waiterName, " and wait_event_type = 'Lock'") === 1,
    );
    const holderPid = Number(sql(`select pid from pg_stat_activity where application_name = '${holderName}' limit 1;`));
    const waiterPid = Number(sql(`select pid from pg_stat_activity where application_name = '${waiterName}' limit 1;`));
    const blockedByHolder = holderPid >= 1 && waiterPid >= 1 && sql(`select ${holderPid} = any (pg_blocking_pids(${waiterPid}));`) === "t";
    check(
      "decoy regression: the decoy waiter is a Lock waiter of this database blocked by another backend (the decoy holder), on an unrelated relation",
      holderReady && waiterBlocked && blockedByHolder && holderPid !== waiterPid,
      `holder ${holderPid}, waiter ${waiterPid}`,
    );
    const weakWaiters = Number(sql(`select count(*) from pg_stat_activity where datname = current_database() and wait_event_type = 'Lock';`));
    check("decoy regression: the weak 'any other backend waiting on a lock' predicate would already be satisfied by the decoy alone", weakWaiters >= 1, `${weakWaiters}`);
    installRowBarrierTrigger();
    sql(`select setval('mithril_test_arrivals', 1, false); select setval('mithril_test_timeouts', 1, false); select setval('mithril_test_blocked_seen', 1, false);`);
    const before = relationState();
    const started = Date.now();
    const response = await selfUpdate(adminSession, scope, top);
    const elapsed = Date.now() - started;
    const after = relationState();
    const timeouts = sequenceValue("mithril_test_timeouts");
    const blockedSeen = sequenceValue("mithril_test_blocked_seen");
    const arrivals = sequenceValue("mithril_test_arrivals");
    const observations = Number(sql(`select count(*) from mithril_test_observations;`));
    const stillBlocked = countSessions(waiterName, " and wait_event_type = 'Lock'") === 1;
    check(
      "decoy regression: the lone rule-2 request under the same-row barrier completed normally (200, the complete relation unchanged)",
      response.status === 200 && response.text === body200 && before === after,
      `${response.status} ${response.text}`,
    );
    check(
      "decoy regression: the decoy waiter neither released nor satisfied the tightened barrier — zero blocked observations, an empty observation table, exactly one barrier timeout, one arrival",
      !blockedSeen.isCalled && observations === 0 && timeouts.isCalled && timeouts.lastValue === 1 && arrivals.isCalled && arrivals.lastValue === 1,
      JSON.stringify({ blockedSeen, observations, timeouts, arrivals }),
    );
    check(
      "decoy regression: the lone request waited out the barrier deadline (below Prisma's transaction timeout) instead of being released by the decoy",
      elapsed >= BARRIER_DEADLINE_MS - 100 && elapsed < PRISMA_TRANSACTION_TIMEOUT_MS,
      `${elapsed} ms`,
    );
    check("decoy regression: the decoy waiter stayed blocked throughout the request", stillBlocked);
    released = await releaseSessions();
    check("decoy regression: the decoy sessions were released and are gone", released);
  } finally {
    if (!released) {
      await releaseSessions();
    }
    removeTestObjects();
  }
  const remaining = remainingTestObjects();
  check("decoy regression: the decoy table and the barrier objects were removed", remaining === "0 triggers, 0 functions, 0 sequences, 0 tables", remaining);
}

try {
  await main();
} catch (error) {
  failures += 1;
  console.log(`FAIL: the battery raised: ${error && error.stack ? error.stack : error}`);
  try {
    removeTestObjects();
  } catch (cleanupError) {
    console.log(`FAIL: removing the temporary test objects raised: ${cleanupError}`);
  }
}

if (failures > 0) {
  console.log(`${failures} battery check(s) failed`);
  process.exit(1);
}
console.log("All battery checks passed.");

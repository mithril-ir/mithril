// The explicit serial-outcome oracle of the HTTP battery's concurrency
// scenarios (test/wasp-integration/battery.mjs), shared by both Wasp
// Confinement Profiles — Profile v0 (the exact singleton rule-1 plan)
// and Profile v1 (the exact ordered rule-1, rule-2 pair).  Extracted so
// the permitted-outcome tables and the judgement of one observed round
// can be exercised by a hermetic regression
// (test/wasp-integration/oracle.test.mjs) without a server or a
// database.  Test-only tooling, outside the confinement claim; nothing
// here is added to the generated application.
//
// Every scenario dispatches exactly two real HTTP requests that
// contend for one authority tuple, and the battery observes the two
// responses plus the complete authority relation afterwards.  A round
// is accepted only when ALL of the following hold:
//
//   * the pair of statuses is a row of the scenario's table below —
//     each row is derived from the initial state and the generated
//     Actions' authorization semantics and names the serial history
//     (or the abort of a request) that justifies it;
//   * each response body is byte-for-byte the pinned body of its
//     status (the Action's uniform bodies; a 200 is Wasp's superjson
//     envelope of the void result);
//   * the complete relation is byte-for-byte the state the row
//     requires.
//
// The tables list ONLY outcomes with a serial interpretation under the
// generated semantics for an ISOLATED pair of two requests — the whole
// of what each barrier scenario models.  Exactly two requests contend
// for one authority tuple; with no third party and no persistent fault,
// exactly one of the conflicting writes commits and the other request's
// retried read is decided against that committed state (a 200 equal
// write, or a 403 once the actor is below the floor).  A fresh retry
// therefore cannot exhaust all three Serializable attempts against an
// already-resolved pair, so 409 has NO serial interpretation here and
// no scenario table admits it: a barrier-scenario 409 is a lost retry
// race, not an outcome, and the battery fails the round with a
// diagnostic (it never maps a 409 into an abort history).  409 is the
// correct contract only under a genuinely persistent conflict — three
// real failing attempts — which the battery pins SEPARATELY through the
// conflict-trigger P2034 exhaustion test, not through these barriers.
// Statuses outside {200, 403} — a 409, a 500, a 400, a 401 — and a
// transport failure have no row and are never accepted by a successful
// concurrency table; the battery pins 409 (persistent P2034), 500, and
// 400 separately, under fault injection and malformed input.
//
// == Same-operation scenario (Profile v1, the rule-2 Action) ==
//
// Initial state: actor A holds the top value in scope S.  Two
// concurrent rule-2 requests by A on S: D demotes A (payload = the
// bottom value) and K keeps A at the top value (payload = the top
// value).  Both requests write A's own tuple (the SAME row), so
// PostgreSQL's tuple lock serializes them: the second UPDATE blocks
// until the first commits and is then decided against the committed
// row.  Rule 2 authorizes iff payloadRank <= actorRank at the actor's
// pre-state, so:
//
//   * D can never be denied — A starts at the top value and only D
//     lowers it, so every read D performs sees a rank that admits the
//     bottom value; D is 200;
//   * K is denied exactly when its (retried) read sees A already
//     demoted by a committed D; K is 200 or 403;
//   * whenever D committed, the final value is the bottom value; K's
//     equal write can only commit while A is still at the top value.
//
// The blocked request is decided after one committed conflict, so it
// never exhausts three attempts: D/K is 200/403 or 200/200, never 409.
//
// == Cross-operation scenario (Profile v1, rule 1 against rule 2) ==
//
// Initial state: actor A and peer P both hold the top value in S.  A
// demotes P through the rule-1 Action (subject P, payload = the
// bottom value) while P asks to remain at the top value through the
// rule-2 Action; both requests update P's tuple (the SAME row), so
// PostgreSQL's tuple lock serializes them, exactly as in the
// same-operation scenario.  Rule 1 authorizes iff the actor holds at
// least the privilege floor, the subject is not the actor, and the
// subject's tuple exists; A's tuple never changes and P's tuple always
// exists, so:
//
//   * rule 1 can never be denied; rule 1 is 200;
//   * rule 2 is denied exactly when P's (retried) read sees P already
//     demoted by a committed rule-1 request; rule 2 is 200 or 403;
//   * whenever rule 1 committed, P's final value is the bottom value;
//     200/200 is valid only for the serial order rule 2 then rule 1,
//     and P always ends at the bottom value (rule 1 commits in both
//     orders).
//
// The blocked request is decided after one committed conflict, so the
// pair is 200/403 or 200/200, both with P at the bottom value, never
// 409.
//
// == Two-admin scenario (both profiles, the rule-1 Action) ==
//
// Initial state: admins A and P both hold the top value in S; A
// demotes P while P demotes A (two DISTINCT tuples).  No tuple lock
// serializes them, so this is a Serializable write skew resolved at
// commit: exactly one demotion commits (the first committer wins), the
// other actor is then below the floor, and the losing request's fresh
// retry reads that committed demotion and is denied.  The pair is
// therefore 200/403 or 403/200; both committing (write skew) has no
// serial interpretation, and neither does a 409 — an isolated pair
// cannot fail three fresh attempts once one side has committed.  The
// battery's deterministic barrier holds the losing (waiter)
// transaction open until the winner has COMMITTED, so this resolves the
// same way under load as it does serially; a 409 here would be a lost
// retry race, not an outcome, and fails the round.

// The final-state labels of the single-tuple scenarios.
export const FINAL_BOTTOM = "bottom";
export const FINAL_TOP = "top";

// The final-state labels of the two-admin scenario: the values of
// (A, P) after the round.
export const FINAL_A_TOP_P_BOTTOM = "A=top,P=bottom";
export const FINAL_A_BOTTOM_P_TOP = "A=bottom,P=top";
export const FINAL_BOTH_TOP = "A=top,P=top";

// Same-operation rows: first = D (demote), second = K (keep top).  The
// two contend for the SAME row, so one commits and the other is decided
// against it — never a 409.
export const SAME_OPERATION_ROWS = Object.freeze([
  { first: 200, second: 403, final: FINAL_BOTTOM, history: "D committed first; K's retried read saw A at the bottom value, so the equal top write was denied" },
  { first: 200, second: 200, final: FINAL_BOTTOM, history: "K committed first (an equal write of the top value, authorized before the demotion), then D committed the demotion" },
]);

// Cross-operation rows: first = rule 1 (A demotes P), second = rule 2
// (P keeps top); final = P's value.  The two contend for the SAME row
// (P's tuple), so one commits and the other is decided against it —
// never a 409, and P always ends at the bottom value.
export const CROSS_OPERATION_ROWS = Object.freeze([
  { first: 200, second: 403, final: FINAL_BOTTOM, history: "rule 1 committed first; P's retried rule-2 read saw P at the bottom value, so the equal top write was denied" },
  { first: 200, second: 200, final: FINAL_BOTTOM, history: "rule 2 committed first (P's equal write of the top value, authorized before the demotion), then rule 1 committed the demotion" },
]);

// Two-admin rows: first = A demotes P, second = P demotes A.  Two
// DISTINCT rows (a write skew), so exactly one demotion commits and the
// other request's retried read is denied — 200/403 or 403/200, never a
// 409.
export const TWO_ADMIN_ROWS = Object.freeze([
  { first: 200, second: 403, final: FINAL_A_TOP_P_BOTTOM, history: "A's demotion of P committed first; P's retried read saw P below the privilege floor, so P's request was denied" },
  { first: 403, second: 200, final: FINAL_A_BOTTOM_P_TOP, history: "P's demotion of A committed first; A's retried read saw A below the privilege floor, so A's request was denied" },
]);

// The label of a row, as the battery reports observed rows.
export function rowLabel(row) {
  return `${row.first}/${row.second}→${row.final}`;
}

// Judge one observed round against a table.
//
//   rows        one of the tables above
//   observation { first, second, state }: the two responses ({ status,
//               text }, or null for a request that did not complete)
//               and the observed complete authority relation
//   context     { bodies, expectedState }: bodies maps each permitted
//               status (200, 403, 409) to its pinned body; expectedState
//               maps a row's final label to the complete relation the
//               battery requires for it
//
// Returns { accepted, row, reason }: accepted only when a row matches
// the pair of statuses, both bodies are the pinned ones, and the state
// is exactly the row's; row is the matched row (null when no row
// matches), reason is empty on acceptance and names the first failed
// condition otherwise.
export function judgeRound(rows, observation, context) {
  const { first, second, state } = observation;
  if (first === null || first === undefined || second === null || second === undefined) {
    return { accepted: false, row: null, reason: "a request did not complete (transport failure), so the round has no outcome to judge" };
  }
  const row = rows.find((candidate) => candidate.first === first.status && candidate.second === second.status) ?? null;
  if (row === null) {
    return { accepted: false, row: null, reason: `the status pair ${first.status}/${second.status} is not a permitted row` };
  }
  if (first.text !== context.bodies[row.first]) {
    return { accepted: false, row, reason: `the first response is a ${row.first} without the pinned ${row.first} body` };
  }
  if (second.text !== context.bodies[row.second]) {
    return { accepted: false, row, reason: `the second response is a ${row.second} without the pinned ${row.second} body` };
  }
  const expected = context.expectedState(row.final);
  if (typeof expected !== "string" || state !== expected) {
    return { accepted: false, row, reason: `the final authority relation is not the ${row.final} state that row ${rowLabel(row)} requires` };
  }
  return { accepted: true, row, reason: "" };
}

// Count, per row of a table, how many judgements accepted that row;
// rows never observed are listed with a zero count, in table order.
export function tallyRows(rows, judgements) {
  return rows.map((row) => ({
    label: rowLabel(row),
    count: judgements.filter((judgement) => judgement.accepted && judgement.row === row).length,
  }));
}

// A one-line rendering of a tally: "200/403→bottom ×5, 200/200→bottom ×3, ..."
export function renderTally(tally) {
  return tally.map((entry) => `${entry.label} ×${entry.count}`).join(", ");
}

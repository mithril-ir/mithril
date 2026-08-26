#!/bin/sh
# Terminating self-tests of the integration harness library
# (test/wasp-integration/lib.sh): the private working directory, the
# isolated-database ownership rule, identity-bound process
# termination, and the one cleanup path, driven with stubbed psql,
# pg_ctl, initdb, and kill executables on PATH, a fake proc tree, and
# a symlinked TMPDIR, so every scenario finishes in seconds without
# Wasp or a real PostgreSQL.  The one exception that needs more than
# a POSIX shell is scenario 8: it runs the built mithril executable
# (cabal build exe:mithril first; the verifier gate needs Agda 2.8.0)
# to prove that generation succeeds under a symlinked TMPDIR.
#
# Scenarios:
#   1. a pre-existing candidate-name collision fails safely and the
#      pre-existing database is never dropped;
#   2. a CREATE DATABASE failure fails safely and drops nothing;
#   3. a normal administrative-URL run drops exactly the database it
#      created and never the administrative database;
#   4. a database drop failure turns a successful run into a failure,
#      and a run that already failed reports both failures and keeps
#      its primary status;
#   5. process identities: /proc/<pid>/stat is parsed after the last
#      ")" even when the command name holds spaces and parentheses,
#      a zombie counts as exited, and the guarded sender refuses to
#      signal a pid whose identity changed;
#   6. termination lifecycle: a normal server exits after TERM; a
#      server ignoring TERM is KILLed under the same identity; an
#      already-exited server gets no signal; a pid reused after TERM
#      never receives KILL (deterministic, through the fake proc tree
#      and a kill stub that scripts the reuse); a server surviving
#      TERM and KILL is a visible cleanup failure, also when a primary
#      failure precedes it (both reported, primary status kept); an
#      identity that cannot be established sends nothing and fails
#      closed;
#   7. the local-cluster branch stops the cluster it started and
#      removes the working directory;
#   8. a TMPDIR reached through a symbolic link: mktemp succeeds, the
#      working directory is the physical path, mithril wasp generate
#      succeeds below it, and cleanup removes exactly the physical
#      working directory, leaving the link and its target untouched;
#   9. the concurrency helpers of the HTTP battery
#      (test/wasp-integration/concurrency.test.mjs, node only): the
#      barrier deadline stays strictly and substantially below Prisma's
#      transaction timeout, a client transport rejection is a pinned
#      failure naming the request, and two concurrent requests use two
#      independent sockets.
#
# Test-only tooling outside the confinement claim.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
lib=$script_dir/lib.sh
core_file=$repo_root/test/fixtures/acme-nspe.mir.json

sandbox=$(mktemp -d) || exit 1
trap 'status=$?; rm -rf "$sandbox"; exit "$status"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

stubs=$sandbox/stubs
mkdir -p "$stubs"
log=$sandbox/stub.log

failures=0
ok() {
  echo "ok: $1"
}
bad() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
assert_contains() {
  # assert_contains NAME FILE PATTERN
  if grep -q -- "$3" "$2"; then ok "$1"; else bad "$1 (missing: $3)"; cat "$2" >&2; fi
}
assert_missing() {
  if grep -q -- "$3" "$2"; then bad "$1 (unexpected: $3)"; cat "$2" >&2; else ok "$1"; fi
}
assert_count() {
  # assert_count NAME FILE PATTERN COUNT
  actual=$(grep -c -- "$3" "$2" || true)
  if [ "$actual" -eq "$4" ]; then ok "$1"; else bad "$1 (expected $4 of $3, found $actual)"; cat "$2" >&2; fi
}
assert_status() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (expected exit $3, got $2)"; fi
}

# The psql stub: logs every invocation and behaves per STUB_PSQL_MODE
# (ok, create-exists, create-error, drop-fail).
cat >"$stubs/psql" <<'STUB'
#!/bin/sh
printf 'psql %s\n' "$*" >>"$STUB_LOG"
case "$*" in
  *"create database"*)
    case "${STUB_PSQL_MODE:-ok}" in
      create-exists) echo "ERROR:  database \"stub\" already exists" >&2; exit 1 ;;
      create-error) echo "psql: error: connection to server failed" >&2; exit 2 ;;
    esac
    ;;
  *"drop database"*)
    case "${STUB_PSQL_MODE:-ok}" in
      drop-fail) echo "ERROR:  database is being accessed by other users" >&2; exit 1 ;;
    esac
    ;;
esac
exit 0
STUB
cat >"$stubs/pg_ctl" <<'STUB'
#!/bin/sh
printf 'pg_ctl %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB
cat >"$stubs/initdb" <<'STUB'
#!/bin/sh
printf 'initdb %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB
# A kill that logs and pretends every signal was delivered without
# sending anything: the unkillable-server and no-signal scenarios.
cat >"$stubs/kill-never" <<'STUB'
#!/bin/sh
printf 'kill %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB
# A kill that scripts pid reuse: on TERM it rewrites the fake stat of
# the signalled pid with a different start time, as if the original
# process had exited and another process had been given its pid.
cat >"$stubs/kill-reuse" <<'STUB'
#!/bin/sh
printf 'kill %s\n' "$*" >>"$STUB_LOG"
if [ "$1" = -TERM ]; then
  printf '%s (mithril (fake) server) S 1 %s %s 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 2000 0 0\n' "$2" "$2" "$2" >"$STUB_PROC/$2/stat"
fi
exit 0
STUB
chmod +x "$stubs/psql" "$stubs/pg_ctl" "$stubs/initdb" "$stubs/kill-never" "$stubs/kill-reuse"
export STUB_LOG="$log"

# The fake proc tree: pid 4242 with a command name holding spaces and
# parentheses, start time 1000; pid 4343 a zombie.
fake_proc=$sandbox/proc
mkdir -p "$fake_proc/4242" "$fake_proc/4343"
printf '4242 (mithril (fake) server) S 1 4242 4242 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 1000 0 0\n' >"$fake_proc/4242/stat"
printf '4343 (mithril (fake) server) Z 1 4343 4343 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 1000 0 0\n' >"$fake_proc/4343/stat"
export STUB_PROC="$fake_proc"
reset_fake_proc() {
  printf '4242 (mithril (fake) server) S 1 4242 4242 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 1000 0 0\n' >"$fake_proc/4242/stat"
}

# run_scenario NAME COMMANDS: run the commands in a subshell with the
# library sourced, the cleanup trap installed, and a private working
# directory; capture stdout+stderr and the exit status.
run_scenario() {
  name=$1
  body=$2
  : >"$log"
  scenario_work=$(mktemp -d)
  out=$sandbox/$name.out
  status=0
  (
    PATH="$stubs:$PATH"
    export PATH
    work=$scenario_work
    pg_bin=$stubs
    pg_port=54999
    # shellcheck disable=SC1090
    . "$lib"
    trap mithril_cleanup EXIT
    eval "$body"
  ) >"$out" 2>&1 || status=$?
  rm -rf "$scenario_work" 2>/dev/null || true
  scenario_status=$status
}

echo "== URL helpers =="
# shellcheck disable=SC1090
. "$lib"
[ "$(mithril_admin_database_name 'postgresql://postgres:postgres@localhost:5432/postgres')" = postgres ] && ok "the administrative database name is parsed" || bad "the administrative database name is parsed"
[ "$(mithril_admin_database_name 'postgresql://u@h/admin_db?sslmode=require')" = admin_db ] && ok "the administrative database name ignores the query string" || bad "the administrative database name ignores the query string"
[ "$(mithril_database_url 'postgresql://u@h:5432/postgres?sslmode=require' owned)" = 'postgresql://u@h:5432/owned?sslmode=require' ] && ok "the owned database URL keeps host, port, and query" || bad "the owned database URL keeps host, port, and query"
name1=$(mithril_candidate_database_name)
name2=$(mithril_candidate_database_name)
[ "$name1" != "$name2" ] && ok "candidate names are collision-resistant" || bad "candidate names are collision-resistant"
case "$name1" in mithril_wasp_*) ok "candidate names carry the mithril_wasp_ prefix" ;; *) bad "candidate names carry the mithril_wasp_ prefix" ;; esac

echo "== 1. pre-existing candidate-name collision =="
run_scenario collision 'MITHRIL_PG_ADMIN_URL=postgresql://u@h/postgres; export MITHRIL_PG_ADMIN_URL; STUB_PSQL_MODE=create-exists; export STUB_PSQL_MODE; mithril_provision_database || fail "provisioning failed as expected"'
assert_status "the collision terminates with exit 1" "$scenario_status" 1
assert_contains "the collision is reported as not owned and not dropped" "$sandbox/collision.out" "already exists on the administrative server; it was not created by this run and will not be dropped"
assert_count "exactly one CREATE DATABASE was attempted" "$log" "create database" 1
assert_missing "no DROP DATABASE was issued after the collision" "$log" "drop database"

echo "== 2. CREATE DATABASE failure =="
run_scenario create-error 'MITHRIL_PG_ADMIN_URL=postgresql://u@h/postgres; export MITHRIL_PG_ADMIN_URL; STUB_PSQL_MODE=create-error; export STUB_PSQL_MODE; mithril_provision_database || fail "provisioning failed as expected"'
assert_status "the CREATE failure terminates with exit 1" "$scenario_status" 1
assert_contains "the CREATE failure states that nothing is owned" "$sandbox/create-error.out" "nothing is owned, nothing will be dropped"
assert_missing "no DROP DATABASE was issued after the CREATE failure" "$log" "drop database"

echo "== 3. normal administrative-URL cleanup =="
run_scenario admin-ok 'MITHRIL_PG_ADMIN_URL=postgresql://u@h/postgres; export MITHRIL_PG_ADMIN_URL; mithril_provision_database || fail "provisioning failed"; echo "url=$DATABASE_URL"; echo "owned=$owned_database"'
assert_status "the normal run terminates with exit 0" "$scenario_status" 0
assert_count "exactly one DROP DATABASE was issued" "$log" "drop database" 1
assert_missing "the administrative database was never dropped" "$log" 'drop database "postgres"'
owned=$(sed -n 's/^owned=//p' "$sandbox/admin-ok.out")
assert_contains "the DROP targeted exactly the owned database" "$log" "drop database \"$owned\" with (force)"
assert_contains "DATABASE_URL names the owned database" "$sandbox/admin-ok.out" "url=postgresql://u@h/$owned"

echo "== 4. database drop failure =="
run_scenario drop-fail 'MITHRIL_PG_ADMIN_URL=postgresql://u@h/postgres; export MITHRIL_PG_ADMIN_URL; STUB_PSQL_MODE=drop-fail; export STUB_PSQL_MODE; mithril_provision_database || fail "provisioning failed"'
assert_status "a drop failure turns the successful run into exit 1" "$scenario_status" 1
assert_contains "the drop failure is visible" "$sandbox/drop-fail.out" "CLEANUP FAILURE: dropping the owned database"
run_scenario drop-fail-primary 'MITHRIL_PG_ADMIN_URL=postgresql://u@h/postgres; export MITHRIL_PG_ADMIN_URL; STUB_PSQL_MODE=drop-fail; export STUB_PSQL_MODE; mithril_provision_database || fail "provisioning failed"; fail "simulated primary failure"'
assert_status "a primary failure keeps its exit status through a cleanup failure" "$scenario_status" 1
assert_contains "the primary failure is reported" "$sandbox/drop-fail-primary.out" "primary failure (exit status 1): simulated primary failure"
assert_contains "the cleanup failure is reported alongside it" "$sandbox/drop-fail-primary.out" "dropping the owned database"

echo "== 5. process identities =="
reset_fake_proc
run_scenario identity-parse 'MITHRIL_PROC_ROOT=$STUB_PROC; export MITHRIL_PROC_ROOT; id=$(mithril_process_identity 4242) || echo "status=$?"; echo "identity=$id"; zombie=$(mithril_process_identity 4343) || echo "zombie-status=$?"; echo "zombie=[$zombie]"; missing=$(mithril_process_identity 9999) || echo "missing-status=$?"; echo "missing=[$missing]"; MITHRIL_PROC_ROOT=$STUB_PROC/absent; unknown=$(mithril_process_identity 4242) || echo "unknown-status=$?"; echo "unknown=[$unknown]"; MITHRIL_PROC_ROOT=$STUB_PROC; self=$(MITHRIL_PROC_ROOT=/proc mithril_process_identity $$) || echo "self-status=$?"; echo "self=$self"'
assert_status "the identity scenario terminates with exit 0" "$scenario_status" 0
assert_contains "a command name with spaces and parentheses parses to pid:starttime" "$sandbox/identity-parse.out" "^identity=4242:1000$"
assert_contains "a zombie counts as exited (status 1)" "$sandbox/identity-parse.out" "^zombie-status=1$"
assert_contains "a zombie prints no identity" "$sandbox/identity-parse.out" "^zombie=\[\]$"
assert_contains "a missing pid is gone (status 1)" "$sandbox/identity-parse.out" "^missing-status=1$"
assert_contains "a missing proc tree cannot establish an identity (status 2)" "$sandbox/identity-parse.out" "^unknown-status=2$"
assert_contains "the real /proc yields the shell's own identity" "$sandbox/identity-parse.out" "^self=[0-9][0-9]*:[0-9][0-9]*$"
reset_fake_proc
printf '4242 (mithril (fake) server) S 1 4242 4242 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 2000 0 0\n' >"$fake_proc/4242/stat"
run_scenario guard-reused 'MITHRIL_PROC_ROOT=$STUB_PROC; export MITHRIL_PROC_ROOT; MITHRIL_KILL=$stubs/kill-never; export MITHRIL_KILL; mithril_signal_identity 4242:1000 4242 KILL "built Wasp server" || echo "guard-status=$?"'
assert_status "the guard scenario terminates with exit 0" "$scenario_status" 0
assert_contains "the guarded sender refuses a pid whose identity changed" "$sandbox/guard-reused.out" "pid 4242 now belongs to another process (4242:2000); KILL was not sent"
assert_contains "the refusal is reported as not sent (status 1)" "$sandbox/guard-reused.out" "^guard-status=1$"
assert_missing "no kill was invoked for the reused pid" "$log" "kill"
reset_fake_proc

echo "== 6. termination lifecycle =="
run_scenario server-ok 'sleep 30 & server_pid=$!; echo "pid=$server_pid"'
assert_status "a normal server is terminated and the run exits 0" "$scenario_status" 0
pid=$(sed -n 's/^pid=//p' "$sandbox/server-ok.out")
assert_contains "the server's identity is captured before TERM" "$sandbox/server-ok.out" "is pid $pid with identity $pid:[0-9][0-9]* (start time read from /proc/$pid/stat)"
assert_contains "the normal server exited after TERM" "$sandbox/server-ok.out" "(pid $pid, identity $pid:[0-9]*) exited after TERM$"
if kill -0 "$pid" 2>/dev/null; then bad "the server process $pid was not terminated"; kill -KILL "$pid" 2>/dev/null || true; else ok "the server process was terminated"; fi

run_scenario server-ignores-term 'MITHRIL_TERMINATION_WAIT=1; export MITHRIL_TERMINATION_WAIT; sh -c "trap \"\" TERM; exec sleep 30" & server_pid=$!; echo "pid=$server_pid"; sleep 1'
assert_status "a server ignoring TERM is KILLed under the same identity and the run exits 0" "$scenario_status" 0
pid=$(sed -n 's/^pid=//p' "$sandbox/server-ignores-term.out")
assert_contains "the survival of TERM is reported with the identity" "$sandbox/server-ignores-term.out" "(pid $pid, identity $pid:[0-9]*) survived TERM for 1 s; sending KILL to that same identity"
assert_contains "the server exited after KILL" "$sandbox/server-ignores-term.out" "(pid $pid, identity $pid:[0-9]*) exited after KILL$"
if kill -0 "$pid" 2>/dev/null; then bad "the TERM-ignoring server process $pid was not killed"; kill -KILL "$pid" 2>/dev/null || true; else ok "the TERM-ignoring server process was killed"; fi

run_scenario server-exited 'MITHRIL_KILL=$stubs/kill-never; export MITHRIL_KILL; sh -c "exit 0" & server_pid=$!; wait "$server_pid" || true; echo "pid=$server_pid"'
assert_status "an already-exited server needs no signal and the run exits 0" "$scenario_status" 0
pid=$(sed -n 's/^pid=//p' "$sandbox/server-exited.out")
assert_contains "the exited server is reported as already exited" "$sandbox/server-exited.out" "(pid $pid) had already exited; no signal was sent"
assert_missing "no signal was sent to the exited pid" "$log" "kill"

reset_fake_proc
run_scenario pid-reuse 'MITHRIL_PROC_ROOT=$STUB_PROC; export MITHRIL_PROC_ROOT; MITHRIL_KILL=$stubs/kill-reuse; export MITHRIL_KILL; MITHRIL_TERMINATION_WAIT=1; MITHRIL_KILL_WAIT=1; export MITHRIL_TERMINATION_WAIT MITHRIL_KILL_WAIT; server_pid=4242'
assert_status "a pid reused after TERM terminates the cleanup deterministically with exit 0" "$scenario_status" 0
assert_contains "the original identity was captured" "$sandbox/pid-reuse.out" "is pid 4242 with identity 4242:1000"
assert_contains "the reuse is detected and reported without signalling the new process" "$sandbox/pid-reuse.out" "(pid 4242, identity 4242:1000) exited after TERM; pid 4242 now belongs to another process (4242:2000), which was not signalled"
assert_count "exactly one TERM was sent, to the original identity" "$log" "kill -TERM 4242" 1
assert_missing "no KILL was sent to the reused pid" "$log" "kill -KILL"
assert_missing "no cleanup failure was recorded for the reused pid" "$sandbox/pid-reuse.out" "CLEANUP FAILURE"
reset_fake_proc

run_scenario server-stuck 'MITHRIL_KILL=$stubs/kill-never; export MITHRIL_KILL; MITHRIL_TERMINATION_WAIT=1; MITHRIL_KILL_WAIT=1; export MITHRIL_TERMINATION_WAIT MITHRIL_KILL_WAIT; sleep 30 & server_pid=$!; echo "pid=$server_pid"'
assert_status "a server surviving TERM and KILL is a cleanup failure (exit 1)" "$scenario_status" 1
pid=$(sed -n 's/^pid=//p' "$sandbox/server-stuck.out")
assert_contains "the surviving server is reported with its identity" "$sandbox/server-stuck.out" "(pid $pid, identity $pid:[0-9]*) is still running after TERM and KILL"
assert_contains "TERM was attempted" "$log" "kill -TERM $pid"
assert_contains "KILL was attempted on the same identity" "$log" "kill -KILL $pid"
kill -KILL "$pid" 2>/dev/null || true

run_scenario server-stuck-primary 'MITHRIL_KILL=$stubs/kill-never; export MITHRIL_KILL; MITHRIL_TERMINATION_WAIT=1; MITHRIL_KILL_WAIT=1; export MITHRIL_TERMINATION_WAIT MITHRIL_KILL_WAIT; sleep 30 & server_pid=$!; echo "pid=$server_pid"; fail "simulated primary failure"'
assert_status "a primary failure keeps its status through a termination failure" "$scenario_status" 1
assert_contains "the primary failure is reported first" "$sandbox/server-stuck-primary.out" "primary failure (exit status 1): simulated primary failure"
assert_contains "the termination failure is reported alongside it" "$sandbox/server-stuck-primary.out" "is still running after TERM and KILL"
pid=$(sed -n 's/^pid=//p' "$sandbox/server-stuck-primary.out")
kill -KILL "$pid" 2>/dev/null || true

run_scenario identity-unknown 'MITHRIL_PROC_ROOT=$STUB_PROC/absent; export MITHRIL_PROC_ROOT; MITHRIL_KILL=$stubs/kill-never; export MITHRIL_KILL; server_pid=4242'
assert_status "an identity that cannot be established fails closed (exit 1)" "$scenario_status" 1
assert_contains "the unknown identity is a cleanup failure naming the proc tree" "$sandbox/identity-unknown.out" "CLEANUP FAILURE: the identity of the built Wasp server (pid 4242) could not be established from $fake_proc/absent; no signal was sent and it may still be running"
assert_missing "no signal was sent when the identity was unknown" "$log" "kill"

echo "== 7. local initdb cleanup =="
run_scenario local-ok 'unset MITHRIL_PG_ADMIN_URL; mithril_provision_database || fail "provisioning failed"; echo "url=$DATABASE_URL"; echo "cluster=$cluster_started"; echo "workdir=$work"'
assert_status "the local-cluster run terminates with exit 0" "$scenario_status" 0
assert_contains "initdb initialized the private cluster" "$log" "initdb -D"
assert_contains "pg_ctl started the private cluster" "$log" "pg_ctl -D .* start"
assert_contains "pg_ctl stopped the private cluster at cleanup" "$log" "pg_ctl -D .* -m fast -w stop"
assert_contains "the isolated database was created in the private cluster" "$log" "create database mithril_wasp;"
assert_missing "no DROP DATABASE is issued in local-cluster mode" "$log" "drop database"
workdir=$(sed -n 's/^workdir=//p' "$sandbox/local-ok.out")
if [ -e "$workdir" ]; then bad "the working directory was not removed"; else ok "the working directory was removed"; fi

echo "== 8. symlinked TMPDIR =="
mithril=${MITHRIL_BIN:-}
if [ -z "$mithril" ]; then
  mithril=$(cd "$repo_root" && cabal list-bin -v0 exe:mithril 2>/dev/null) || mithril=''
fi
if [ ! -x "$mithril" ]; then
  echo "FAIL: the built mithril executable is required for the symlinked-TMPDIR generation smoke test (run cabal build exe:mithril, or set MITHRIL_BIN)" >&2
  exit 1
fi
real_tmp=$sandbox/real-tmp
mkdir "$real_tmp"
physical_tmp=$(CDPATH='' cd -- "$real_tmp" && pwd -P)
printf 'sentinel\n' >"$real_tmp/sentinel"
ln -s "$real_tmp" "$sandbox/link-tmp"
run_scenario symlinked-tmpdir 'TMPDIR=$sandbox/link-tmp; export TMPDIR; mithril_create_work_directory || fail "creating the working directory failed"; echo "work=$work"; "$mithril" wasp generate "$core_file" "$work/app" >"$work/generate.log" 2>&1 || { cat "$work/generate.log"; fail "wasp generate below the working directory failed"; }; head -n 1 "$work/generate.log"; [ -f "$work/app/.mithril-wasp-profile" ] || fail "the generated root carries no ownership marker"; "$mithril" wasp check "$core_file" "$work/app" >/dev/null || fail "the generated root is not confined"; echo "generated=$work/app"'
assert_status "generation under a symlinked TMPDIR terminates with exit 0" "$scenario_status" 0
workdir=$(sed -n 's/^work=//p' "$sandbox/symlinked-tmpdir.out")
case $workdir in
  "$physical_tmp"/*) ok "the working directory is the physical path below the link target" ;;
  *) bad "the working directory is the physical path below the link target (got $workdir)" ;;
esac
case $workdir in
  *link-tmp*) bad "the working directory does not go through the symbolic link" ;;
  *) ok "the working directory does not go through the symbolic link" ;;
esac
assert_contains "mithril wasp generate reported the generated root below the physical path" "$sandbox/symlinked-tmpdir.out" "^$workdir/app: GENERATED (Wasp Confinement Profile v0)$"
assert_contains "the generated root was confined" "$sandbox/symlinked-tmpdir.out" "^generated=$workdir/app$"
if [ -e "$workdir" ]; then bad "cleanup removed the physical working directory"; else ok "cleanup removed the physical working directory"; fi
if [ -L "$sandbox/link-tmp" ] && [ "$(readlink "$sandbox/link-tmp")" = "$real_tmp" ]; then ok "the TMPDIR symbolic link is untouched"; else bad "the TMPDIR symbolic link is untouched"; fi
if [ "$(ls -A "$real_tmp")" = sentinel ] && [ "$(cat "$real_tmp/sentinel")" = sentinel ]; then ok "the link target holds only its sentinel after cleanup"; else bad "the link target holds only its sentinel after cleanup"; ls -la "$real_tmp" >&2; fi

echo "== 9. HTTP battery concurrency helpers (node only) =="
regression_out=$sandbox/concurrency.test.out
if node "$repo_root/test/wasp-integration/concurrency.test.mjs" >"$regression_out" 2>&1; then
  regression_status=0
else
  regression_status=$?
fi
assert_status "the concurrency-helper regression terminates with exit 0" "$regression_status" 0
assert_contains "the barrier deadline is strictly below Prisma's transaction timeout" "$regression_out" "the barrier deadline is strictly below Prisma's interactive-transaction timeout"
assert_contains "a transport rejection is reported as a pinned failure naming the request" "$regression_out" "the rendered transport failure names the request, the message, the code, and the cause"
assert_contains "two concurrent requests use two independent sockets" "$regression_out" "two distinct client sockets"
assert_contains "the regression reports all its checks passed" "$regression_out" "All concurrency-helper regression checks passed."
if grep -q "^FAIL:" "$regression_out"; then bad "the concurrency-helper regression reported a FAIL line"; cat "$regression_out" >&2; else ok "the concurrency-helper regression reported no FAIL line"; fi

if [ "$failures" -ne 0 ]; then
  echo "$failures harness self-test(s) failed" >&2
  exit 1
fi
echo "All harness self-tests passed."

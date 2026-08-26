# The shell library of the Wasp Confinement Profile v0 integration
# harness: the private working directory, isolated-database
# ownership, identity-bound process and cluster termination, and the
# one cleanup path.  Sourced by run-wasp-integration.sh (the real
# Wasp 0.25.0 / PostgreSQL vertical test) and by test-harness.sh (the
# terminating self-tests that drive these functions with stubbed
# psql, pg_ctl, initdb, and kill executables, a fake proc tree, and a
# symlinked TMPDIR).  POSIX sh on Linux (the process identities come
# from /proc).  Test-only tooling outside the confinement claim.
#
# Working-directory rule: the private working directory is created
# with mktemp -d and immediately resolved to its physical path
# (pwd -P), and every later path — generated roots, logs,
# subprocesses, cleanup — is built from that physical path.  A TMPDIR
# reached through a symbolic link therefore never becomes an ancestor
# of a generated root: the generator refuses linked ancestors, and
# that refusal is not weakened here; the harness simply never hands
# it a linked path.  Cleanup removes the physical working directory
# and nothing outside it, so a symlinked TMPDIR and its target stay
# untouched.
#
# Ownership rule of the isolated database (administrative-URL mode):
# a candidate name is chosen with a collision-resistant suffix, but
# the database counts as owned by this run — and therefore droppable
# by cleanup — ONLY after CREATE DATABASE succeeded.  A candidate
# that already exists was not created here and is never dropped; the
# run fails safely instead.  Cleanup never targets the administrative
# database of the URL.
#
# Process termination rule: a numeric pid is not a stable process
# identity, so the built server is bound to the identity token
# "<pid>:<start time>", where the start time is field 22 of
# /proc/<pid>/stat (clock ticks since boot).  The stat line is parsed
# after its LAST ")" so a command name containing spaces or
# parentheses cannot shift the fields; a zombie (state Z or X) counts
# as exited, since no signal can affect it and only reaping remains.
# The token is captured before TERM is sent; immediately before every
# signal the current token is read again and the signal is sent only
# when it is unchanged, so a process that exited — or a pid that now
# belongs to another process — is never signalled, and in particular
# KILL is never sent to a reused pid.  When the identity cannot be
# established while a signal would otherwise be sent (no proc tree,
# an unreadable or unparsable stat), no signal is sent and a cleanup
# failure is recorded: fail closed.  Residual limitation, stated
# exactly: the start-time check prevents ordinary pid-reuse mistakes;
# it is not a pidfd — the identity read and the kill are two separate
# operations — and it is not race-proof against adversarial same-user
# process manipulation between them.
#
# Cleanup rule: every cleanup failure is visible on stderr and turns
# an otherwise successful run into a failure; when the run had
# already failed, both the primary failure and the cleanup failures
# are reported and the primary exit status is kept.
#
# Variables set by the caller before the functions run:
#   work       the private working directory of this run (set by
#              mithril_create_work_directory, or by the self-tests)
#   pg_bin     the PostgreSQL server binaries (local-cluster mode)
#   pg_port    the local cluster's TCP port (local-cluster mode)
#   MITHRIL_PG_ADMIN_URL  optional administrative connection URL
# Variables owned by this library:
#   owned_database    set only after CREATE DATABASE succeeded
#   cluster_started   yes only after pg_ctl start succeeded
#   server_pid        the built server's process id, once started
#   cleanup_failures  the recorded cleanup failures, one per line
#   primary_failure   the message of the first FAIL, if any
# Injection points for the self-tests (production uses the defaults):
#   MITHRIL_PSQL  the psql command (default psql)
#   MITHRIL_KILL  the kill command (default the shell's kill)
#   MITHRIL_PROC_ROOT  the proc tree read for process identities
#                      (default /proc; the self-tests point it at a
#                      fake tree to script exits and pid reuse)
#   MITHRIL_TERMINATION_WAIT  seconds to wait after TERM (default 10)
#   MITHRIL_KILL_WAIT         seconds to wait after KILL (default 5)

owned_database=''
cluster_started=no
server_pid=''
cleanup_failures=''
primary_failure=''

mithril_psql() {
  "${MITHRIL_PSQL:-psql}" "$@"
}

mithril_kill() {
  "${MITHRIL_KILL:-kill}" "$@"
}

# fail MESSAGE: record and report the primary failure, then exit 1
# (the EXIT trap runs the cleanup).
fail() {
  primary_failure=$1
  echo "FAIL: $1" >&2
  exit 1
}

# Create the private working directory (mktemp -d) and resolve it to
# its physical path (working-directory rule above); sets work.
# Returns nonzero, with work unset, when it cannot.
mithril_create_work_directory() {
  created=$(mktemp -d) || return 1
  work=$(CDPATH='' cd -- "$created" && pwd -P) || return 1
  if [ -z "$work" ] || [ ! -d "$work" ]; then
    work=''
    return 1
  fi
  return 0
}

# The database name of an administrative URL: the path component,
# without the query string.
mithril_admin_database_name() {
  printf '%s' "$1" | sed -E 's#^[^:]+://[^/]*/([^/?]*)(\?.*)?$#\1#'
}

# A collision-resistant candidate database name.
mithril_candidate_database_name() {
  random=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || random=''
  [ -n "$random" ] || random=$(date +%N 2>/dev/null || echo 0)
  printf 'mithril_wasp_%s_%s_%s' "$(date +%s)" "$$" "$random"
}

# Replace the database of an administrative URL with NAME.
mithril_database_url() {
  printf '%s' "$1" | sed -E "s#/[^/?]*(\\?.*)?\$#/$2\\1#"
}

mithril_record_cleanup_failure() {
  cleanup_failures="${cleanup_failures}${cleanup_failures:+
}$1"
  echo "CLEANUP FAILURE: $1" >&2
}

# Provision the isolated database and export DATABASE_URL.  Returns
# nonzero (without exiting) when it cannot; the caller decides.
mithril_provision_database() {
  if [ -n "${MITHRIL_PG_ADMIN_URL:-}" ]; then
    candidate=$(mithril_candidate_database_name)
    admin_name=$(mithril_admin_database_name "$MITHRIL_PG_ADMIN_URL")
    if [ -z "$admin_name" ] || [ "$candidate" = "$admin_name" ]; then
      echo "FAIL: the administrative URL names no usable database, or the candidate name collides with it" >&2
      return 1
    fi
    output=$(mithril_psql "$MITHRIL_PG_ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "create database \"$candidate\";" 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
      case "$output" in
        *"already exists"*)
          echo "FAIL: the candidate database $candidate already exists on the administrative server; it was not created by this run and will not be dropped" >&2
          ;;
        *)
          echo "FAIL: CREATE DATABASE $candidate failed (nothing is owned, nothing will be dropped): $output" >&2
          ;;
      esac
      return 1
    fi
    owned_database=$candidate
    DATABASE_URL=$(mithril_database_url "$MITHRIL_PG_ADMIN_URL" "$candidate")
    echo "database: created $candidate on the administrative server (owned by this run)"
  else
    if [ ! -x "$pg_bin/initdb" ]; then
      echo "FAIL: initdb not found under $pg_bin (set MITHRIL_PG_BIN or MITHRIL_PG_ADMIN_URL)" >&2
      return 1
    fi
    if ! "$pg_bin/initdb" -D "$work/pgdata" -U mithril --auth=trust -E UTF8 --no-locale >"$work/initdb.log" 2>&1; then
      cat "$work/initdb.log" >&2
      echo "FAIL: initdb failed" >&2
      return 1
    fi
    if ! "$pg_bin/pg_ctl" -D "$work/pgdata" -o "-p $pg_port -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$work/pg.log" -w start >/dev/null 2>&1; then
      cat "$work/pg.log" >&2 2>/dev/null || true
      echo "FAIL: pg_ctl start failed" >&2
      return 1
    fi
    cluster_started=yes
    if ! mithril_psql -h 127.0.0.1 -p "$pg_port" -U mithril -d postgres -q -v ON_ERROR_STOP=1 -c "create database mithril_wasp;" >/dev/null 2>&1; then
      echo "FAIL: could not create the isolated database in the private cluster" >&2
      return 1
    fi
    DATABASE_URL="postgresql://mithril@127.0.0.1:$pg_port/mithril_wasp"
    echo "database: private cluster under $work/pgdata (port $pg_port)"
  fi
  export DATABASE_URL
  return 0
}

# mithril_process_identity PID: print the identity token
# "PID:starttime" of a live process (process termination rule above).
# Returns 0 for a live process, 1 when no such process exists or it
# is a zombie awaiting reaping, and 2 when the identity cannot be
# established (no proc tree, an unreadable stat, or an unparsable
# one).  Nothing is printed unless the return status is 0.
mithril_process_identity() {
  stat_pid=$1
  proc_root=${MITHRIL_PROC_ROOT:-/proc}
  [ -d "$proc_root" ] || return 2
  stat_file=$proc_root/$stat_pid/stat
  [ -e "$stat_file" ] || return 1
  stat_line=''
  if ! IFS= read -r stat_line <"$stat_file" 2>/dev/null; then
    if [ -z "$stat_line" ]; then
      if [ -e "$stat_file" ]; then return 2; else return 1; fi
    fi
  fi
  case $stat_line in
    *')'*) ;;
    *) return 2 ;;
  esac
  # Everything after the LAST ")": the command name in parentheses may
  # itself contain spaces and parentheses.  The remainder starts at
  # field 3 (the state), so the start time (field 22) is its 20th
  # word.
  stat_rest=${stat_line##*)}
  # shellcheck disable=SC2086 # word splitting is the parse
  set -- $stat_rest
  [ $# -ge 20 ] || return 2
  case $1 in
    Z | X) return 1 ;;
  esac
  case ${20} in
    '' | *[!0-9]*) return 2 ;;
  esac
  printf '%s:%s\n' "$stat_pid" "${20}"
  return 0
}

# mithril_identity_unchanged IDENTITY PID: 0 when PID is live with
# exactly IDENTITY, 1 when it is gone (or a zombie) or the pid now
# belongs to another process, 2 when the identity cannot be
# established.
mithril_identity_unchanged() {
  current=''
  current_status=0
  current=$(mithril_process_identity "$2") || current_status=$?
  case $current_status in
    0)
      if [ "$current" = "$1" ]; then return 0; else return 1; fi
      ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# mithril_signal_identity IDENTITY PID SIGNAL LABEL: send SIGNAL to
# PID only if, read immediately before, it still has IDENTITY.
# Returns 0 sent; 1 not sent because the process exited or the pid
# was reused (reported on stdout); 2 not sent because the identity
# cannot be established; 3 the kill command failed.
mithril_signal_identity() {
  current=''
  current_status=0
  current=$(mithril_process_identity "$2") || current_status=$?
  case $current_status in
    0)
      if [ "$current" != "$1" ]; then
        echo "the $4 (pid $2, identity $1) is gone and pid $2 now belongs to another process ($current); $3 was not sent"
        return 1
      fi
      ;;
    1)
      echo "the $4 (pid $2, identity $1) exited before $3 was sent; no signal was sent"
      return 1
      ;;
    *) return 2 ;;
  esac
  if mithril_kill "-$3" "$2" 2>/dev/null; then
    return 0
  fi
  return 3
}

# mithril_await_identity_exit IDENTITY PID SECONDS: wait up to SECONDS
# while PID keeps IDENTITY.  Returns 0 when it is gone or the pid was
# reused, 1 when it is still the same process, 2 when the identity
# cannot be established.
mithril_await_identity_exit() {
  waited=0
  while :; do
    same=0
    mithril_identity_unchanged "$1" "$2" || same=$?
    case $same in
      1) return 0 ;;
      2) return 2 ;;
    esac
    [ "$waited" -lt "$3" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

# mithril_report_exit IDENTITY PID LABEL SIGNAL: after IDENTITY
# stopped matching, say whether the process exited or its pid was
# reused by another process (which is never signalled).
mithril_report_exit() {
  current=''
  current_status=0
  current=$(mithril_process_identity "$2") || current_status=$?
  if [ "$current_status" -eq 0 ] && [ "$current" != "$1" ]; then
    echo "the $3 (pid $2, identity $1) exited after $4; pid $2 now belongs to another process ($current), which was not signalled"
  else
    echo "the $3 (pid $2, identity $1) exited after $4"
  fi
}

# Terminate a process reliably and only that process (process
# termination rule above): capture its identity, TERM it if it is
# still that process, wait, KILL it if it is still that same process,
# wait; a process that survives both is a recorded cleanup failure,
# and an identity that cannot be established is one too.  The pid is
# always reaped with wait.
mithril_terminate_process() {
  pid=$1
  label=$2
  proc_root=${MITHRIL_PROC_ROOT:-/proc}
  identity=''
  identity_status=0
  identity=$(mithril_process_identity "$pid") || identity_status=$?
  case $identity_status in
    0) ;;
    1)
      echo "the $label (pid $pid) had already exited; no signal was sent"
      wait "$pid" 2>/dev/null || true
      return 0
      ;;
    *)
      mithril_record_cleanup_failure "the identity of the $label (pid $pid) could not be established from $proc_root; no signal was sent and it may still be running"
      wait "$pid" 2>/dev/null || true
      return 0
      ;;
  esac
  echo "the $label is pid $pid with identity $identity (start time read from $proc_root/$pid/stat)"
  sent=0
  mithril_signal_identity "$identity" "$pid" TERM "$label" || sent=$?
  case $sent in
    0)
      exited=0
      mithril_await_identity_exit "$identity" "$pid" "${MITHRIL_TERMINATION_WAIT:-10}" || exited=$?
      case $exited in
        0) mithril_report_exit "$identity" "$pid" "$label" TERM ;;
        1)
          echo "the $label (pid $pid, identity $identity) survived TERM for ${MITHRIL_TERMINATION_WAIT:-10} s; sending KILL to that same identity"
          killed=0
          mithril_signal_identity "$identity" "$pid" KILL "$label" || killed=$?
          case $killed in
            0)
              exited=0
              mithril_await_identity_exit "$identity" "$pid" "${MITHRIL_KILL_WAIT:-5}" || exited=$?
              case $exited in
                0) mithril_report_exit "$identity" "$pid" "$label" KILL ;;
                1) mithril_record_cleanup_failure "the $label (pid $pid, identity $identity) is still running after TERM and KILL" ;;
                *) mithril_record_cleanup_failure "the identity of the $label (pid $pid) could no longer be established from $proc_root after KILL; it may still be running" ;;
              esac
              ;;
            1) ;;
            2) mithril_record_cleanup_failure "the identity of the $label (pid $pid) could not be established from $proc_root; KILL was not sent and it may still be running" ;;
            *) mithril_record_cleanup_failure "sending KILL to the $label (pid $pid, identity $identity) failed" ;;
          esac
          ;;
        *) mithril_record_cleanup_failure "the identity of the $label (pid $pid) could no longer be established from $proc_root after TERM; no further signal was sent and it may still be running" ;;
      esac
      ;;
    1) ;;
    2) mithril_record_cleanup_failure "the identity of the $label (pid $pid) could not be established from $proc_root; TERM was not sent and it may still be running" ;;
    *) mithril_record_cleanup_failure "sending TERM to the $label (pid $pid, identity $identity) failed" ;;
  esac
  wait "$pid" 2>/dev/null || true
}

# The one cleanup path (the EXIT trap): the server, the private
# cluster, the owned database, the working directory; then the exit
# status per the cleanup rule above.
mithril_cleanup() {
  status=$?
  if [ -n "$server_pid" ]; then
    mithril_terminate_process "$server_pid" "built Wasp server"
  fi
  if [ "$cluster_started" = yes ]; then
    if ! "$pg_bin/pg_ctl" -D "$work/pgdata" -m fast -w stop >/dev/null 2>&1; then
      mithril_record_cleanup_failure "stopping the private PostgreSQL cluster under $work/pgdata failed"
    fi
  fi
  if [ -n "$owned_database" ]; then
    admin_name=$(mithril_admin_database_name "${MITHRIL_PG_ADMIN_URL:-}")
    if [ "$owned_database" = "$admin_name" ]; then
      mithril_record_cleanup_failure "refusing to drop $owned_database: it is the administrative database"
    elif ! mithril_psql "$MITHRIL_PG_ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "drop database \"$owned_database\" with (force);" >/dev/null 2>&1; then
      mithril_record_cleanup_failure "dropping the owned database $owned_database failed; it remains on the administrative server"
    fi
  fi
  if [ -n "${work:-}" ] && [ -d "$work" ]; then
    if ! rm -rf "$work"; then
      mithril_record_cleanup_failure "removing the working directory $work failed"
    fi
  fi
  if [ -n "$cleanup_failures" ]; then
    if [ "$status" -ne 0 ]; then
      echo "primary failure (exit status $status): ${primary_failure:-see above}" >&2
    fi
    echo "cleanup failures:" >&2
    printf '%s\n' "$cleanup_failures" | sed 's/^/  /' >&2
    if [ "$status" -eq 0 ]; then
      status=1
    fi
  fi
  exit "$status"
}

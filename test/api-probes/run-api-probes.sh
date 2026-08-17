#!/bin/sh
# API-boundary compile-fail probes for mithril-ir: the downstream
# attacks, then the in-package identifier non-coercion attacks.
#
# Downstream probes build the probe package (test/api-probes/probe)
# against mithril-ir as an ordinary external package dependency —
# never by adding src/ to a module search path — via the dedicated
# cabal.project.probes, so hidden modules (including the private
# core-internal sublibrary), abstract types, and nominal roles are
# enforced exactly as any downstream consumer would experience them.
# All nine downstream components carry the repository warning set
# with -Werror; this script verifies that from the generated build
# plan, from probe.cabal, from every downstream probe source (no
# module-level OPTIONS_GHC pragma may sidestep the command line),
# and — decisively — from each component's own effective GHC
# invocation as recorded in its fresh verbose build log, before
# judging any compile result.
#
# In-package probes then build flag-gated executables of mithril-ir
# itself, which legitimately import the real internal identifier
# definitions from the private sublibrary: with that access proven by
# their own control, the cross-namespace coercion attacks can only
# fail on the coercibility of the identifier types — GHC itself
# refusing the coercion — never on module visibility.
#
# Each control probe must compile before its attacks run, proving the
# failures are caused by the intended boundary and not by a broken
# probe environment.  Every attack probe must FAIL to compile, and
# must fail with the message of its intended abstraction/role/
# coercibility boundary; compiling successfully, or failing with any
# other message, fails this script.
#
# Requires a POSIX shell and the pinned GHC/cabal toolchain.  It may
# be run from anywhere (it changes to the repository root itself).
# Every invocation allocates its own build root with mktemp -d, with
# downstream/ and internal/ children and the build log inside it, so
# two simultaneous invocations cannot consume or overwrite each
# other's plans, binaries, or diagnostics.  The one EXIT trap below
# is the single cleanup path: it removes the whole root — and nothing
# this invocation did not create — on success, on ordinary failure,
# and on a handled signal (HUP, INT, and TERM re-enter it via exit).

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/../.."

build_root=$(mktemp -d) || exit 1
trap 'status=$?; rm -rf "$build_root"; exit "$status"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

downstream_dir=$build_root/downstream
internal_dir=$build_root/internal
log=$build_root/build.log

# -v2 makes cabal record every compiler invocation it runs in the
# build log ("GHC response file arguments: ..." — the pinned cabal
# always hands ghc its arguments through a response file and prints
# the file's full contents at this verbosity).  The warning-policy
# verification below reads each component's effective arguments from
# exactly that record.
build() {
  cabal build -v2 \
    --project-file=cabal.project.probes \
    --builddir="$downstream_dir" \
    "mithril-ir-api-probes:exe:$1" >"$log" 2>&1
}

fail() {
  echo "FAIL: $1" >&2
  echo "---- full build output ----" >&2
  cat "$log" >&2
  exit 1
}

# --- Downstream warning-policy verification ----------------------
#
# All nine downstream components — the control plus the eight attacks
# — must compile under the repository warning set with an EFFECTIVE
# -Werror.  Four cooperating executable checks, using POSIX awk and
# grep only (no optional tooling).  Three run once, right after the
# control build: the downstream build plan just generated must list
# every probe component with the werror flag resolved to true,
# probe.cabal must route every executable through the one shared
# stanza that carries the warning set and the flag-guarded -Werror,
# and every downstream probe source must be free of module-level
# OPTIONS_GHC pragmas, which GHC applies without recording them in
# the command-line record (see the source pragma policy below).
# The fourth, verify_policy, runs for each component before its
# compile result is judged: it parses the component's effective GHC
# arguments out of the fresh -v2 log of the build this invocation
# just ran, using only the invocation records whose -this-unit-id
# names that exact component — so a comment, another component, a
# dependency, an unrelated stanza, or a stale log can never satisfy
# it — requires every option of the repository warning set plus
# -Werror to be a real argument, with no weakening override
# (-Wwarn[=...], -Wno-error[=...], -Wno-<group>, -Wdefault, -Wnot,
# -w, or the accepted legacy negation spelling -fno-warn-<warning>)
# anywhere in the invocation, and rejects any nested @response-file
# argument (quoted or not) outright: GHC would expand it only after
# this record was written, so its contents are unverifiable here and
# its presence is an unsupported escape channel, never opened and
# inspected.

required_options='-Wall -Wcompat -Widentities -Wincomplete-record-updates -Wincomplete-uni-patterns -Wmissing-export-lists -Wpartial-fields -Werror'

# verify_policy NAME: NAME's effective compiler invocation, recorded
# in the log of the build that just ran, must carry the full warning
# policy uncompromised.  Fails closed when the invocation record is
# absent.  A failure here is a warning-policy failure and is reported
# before — never mistaken for — a compile-fail attack result.
verify_policy() {
  if ! awk -v component="$1" -v required="$required_options" '
    BEGIN {
      nreq = split(required, req, " ")
      unit = "^mithril-ir-api-probes-[0-9.]+-inplace-" component "$"
    }
    /^GHC response file arguments:/ {
      target = 0
      for (i = 1; i < NF; i++)
        if ($i == "-this-unit-id" && $(i + 1) ~ unit)
          target = 1
      if (!target)
        next
      invocations++
      for (k = 1; k <= nreq; k++)
        have[k] = 0
      for (i = 1; i <= NF; i++) {
        for (k = 1; k <= nreq; k++)
          if ($i == req[k])
            have[k] = 1
        if ($i == "-w" || $i == "-Wwarn" || $i ~ /^-Wwarn=/ ||
            $i ~ /^-Wno-/ || $i == "-Wdefault" || $i == "-Wnot" ||
            $i ~ /^-fno-warn-/) {
          print "  " component ": effective ghc arguments weaken the warning policy with " $i
          bad = 1
        }
        first = substr($i, 1, 1)
        if (first == "@" ||
            ((first == "\"" || first == "\047") && substr($i, 2, 1) == "@")) {
          print "  " component ": nested response-file arguments are forbidden in the effective ghc arguments: " $i
          bad = 1
        }
      }
      for (k = 1; k <= nreq; k++)
        if (!have[k]) {
          print "  " component ": effective ghc arguments are missing " req[k]
          bad = 1
        }
    }
    END {
      if (invocations == 0) {
        print "  " component ": no effective ghc invocation for this component appears in its fresh build log"
        bad = 1
      }
      exit bad
    }
  ' "$log"; then
    fail "$1 was not compiled under the effective repository warning policy"
  fi
  echo "ok: $1 effective ghc arguments carry the full warning set and an unweakened -Werror"
}

if build probe-control; then
  control_compiled=yes
else
  control_compiled=no
fi

plan=$downstream_dir/cache/plan.json
if [ ! -f "$plan" ]; then
  fail "the downstream build plan was not generated at $plan"
fi

probe_components='probe-control probe-hidden-import probe-constructor-use probe-coerce-parsed probe-coerce-valid probe-coerce-value probe-hidden-resolved probe-hidden-syntax probe-extract-value'

if ! awk -v names="$probe_components" '
  { buffer = buffer $0 }
  END {
    count = split(names, want, " ")
    n = split(buffer, entry, /"type":"configured"/)
    for (i = 2; i <= n; i++) {
      if (index(entry[i], "\"pkg-name\":\"mithril-ir-api-probes\"") == 0)
        continue
      for (j = 1; j <= count; j++)
        if (index(entry[i], "\"component-name\":\"exe:" want[j] "\"") > 0)
          seen[j] = (index(entry[i], "\"werror\":true") > 0) ? 2 : 1
    }
    bad = 0
    for (j = 1; j <= count; j++)
      if (seen[j] != 2) {
        print "  " want[j] ": " ((seen[j] == 1) ? "planned without the werror flag" : "missing from the downstream plan")
        bad = 1
      }
    exit bad
  }
' "$plan"; then
  fail "the downstream build plan does not give every probe component the werror flag"
fi

if ! awk '
  function flush() {
    if (name != "" && !imported) {
      print "  executable " name " does not import the probe warning stanza"
      bad = 1
    }
  }
  /^executable[ \t]/ { flush(); name = $2; imported = 0 }
  name != "" && $1 == "import:" {
    for (i = 2; i <= NF; i++) {
      field = $i
      gsub(/,/, "", field)
      if (field == "probe") imported = 1
    }
  }
  END { flush(); exit bad }
' test/api-probes/probe/probe.cabal; then
  fail "not every downstream probe executable imports the shared warning stanza"
fi

echo "ok: the downstream plan and probe.cabal give every probe component the werror policy"

# --- Downstream source pragma policy -----------------------------
#
# GHC applies a module-level OPTIONS_GHC pragma (or its accepted
# legacy OPTIONS spelling) without adding it to the recorded
# command-line arguments, so a probe source could weaken the warning
# policy invisibly to verify_policy.  Every downstream probe source —
# all *.hs in test/api-probes/probe, the one shared hs-source-dirs of
# all nine components — is therefore checked structurally before any
# probe is accepted: the pragma's presence is rejected outright, with
# no attempt to reconstruct GHC's post-pragma warning state.  Only a
# real pragma opener ("{-#", then the pragma name, case-insensitive,
# with whitespace flexibility) is rejected; prose that merely
# mentions OPTIONS_GHC in an ordinary comment is not.

for probe_src in test/api-probes/probe/*.hs; do
  if ! awk -v src="$probe_src" '
    { buffer = buffer $0 "\n" }
    END {
      body = tolower(buffer)
      if (match(body, /[{]-#[[:space:]]*options_ghc/) ||
          match(body, /[{]-#[[:space:]]*options[[:space:]]/)) {
        pragma = substr(buffer, RSTART)
        gsub(/[[:space:]]+/, " ", pragma)
        p = index(pragma, "#-}")
        pragma = (p > 0) ? substr(pragma, 1, p + 2) : substr(pragma, 1, 60)
        print "  " src ": forbidden GHC options pragma in a downstream probe source: " pragma
        exit 1
      }
    }
  ' "$probe_src"; then
    fail "a downstream probe source carries a forbidden OPTIONS_GHC pragma"
  fi
done
echo "ok: no downstream probe source carries an OPTIONS_GHC pragma"

verify_policy probe-control

if [ "$control_compiled" = no ]; then
  fail "probe-control did not compile; the probe environment is broken, so attack failures would prove nothing"
fi
echo "ok: probe-control compiles (legitimate public pipeline)"

# expect NAME PATTERN...: NAME's effective warning policy is verified
# first; then NAME must fail to build, and every PATTERN (grep -E)
# must appear in the compiler output.  The .{1,3} gaps in the
# patterns absorb GHC's quote characters in both Unicode and ASCII
# locales.
expect() {
  probe_name=$1
  shift
  if build "$probe_name"; then
    probe_compiled=yes
  else
    probe_compiled=no
  fi
  verify_policy "$probe_name"
  if [ "$probe_compiled" = yes ]; then
    fail "$probe_name unexpectedly compiled; the API boundary did not hold"
  fi
  for pattern in "$@"; do
    if ! grep -E -q -- "$pattern" "$log"; then
      fail "$probe_name failed to compile, but not for the intended reason (missing: $pattern)"
    fi
  done
  echo "ok: $probe_name fails to compile for its intended reason"
}

expect probe-hidden-import \
  "Could not load module" \
  "Mithril\.Core\.Internal\.Document" \
  "member of the hidden package .{1,3}mithril-ir-[0-9.]+:core-internal"

expect probe-constructor-use \
  "Illegal term-level use of the type constructor .{1,3}CoreDocument"

expect probe-coerce-parsed \
  "match type .{1,3}Parsed.{1,3} with .{1,3}StructurallyValid" \
  "arising from a use of .{1,3}coerce"

expect probe-coerce-valid \
  "match type .{1,3}StructurallyValid.{1,3} with .{1,3}Resolved" \
  "arising from a use of .{1,3}coerce"

expect probe-coerce-value \
  "match representation of type .{1,3}Value" \
  "newtype .{1,3}CoreDocument.{1,3} is not in scope"

expect probe-hidden-resolved \
  "Could not load module" \
  "Mithril\.Core\.Internal\.Resolved" \
  "member of the hidden package .{1,3}mithril-ir-[0-9.]+:core-internal"

expect probe-hidden-syntax \
  "Could not load module" \
  "Mithril\.Core\.Internal\.Syntax" \
  "member of the hidden package .{1,3}mithril-ir-[0-9.]+:core-internal"

expect probe-extract-value \
  "match representation of type .{1,3}CoreDocument Resolved" \
  "with that of .{1,3}Value" \
  "newtype .{1,3}CoreDocument.{1,3} is not in scope"

# --- In-package identifier non-coercion probes -------------------
#
# These are executables of mithril-ir itself (test/api-probes/internal),
# gated behind the manual internal-probes flag so no canonical build
# ever touches them; the flag is enabled here through a solver
# constraint, and the internal/ child of this invocation's build root
# keeps that flagged configuration out of both the default and the
# downstream-probe build state.  Because they are in-package
# components, they may depend on the private core-internal sublibrary
# — which is exactly the point: the attacks reach the real identifier
# types and must still fail, on coercibility alone.

build_internal() {
  cabal build \
    --builddir="$internal_dir" \
    --constraint="mithril-ir +internal-probes" \
    "mithril-ir:exe:$1" >"$log" 2>&1
}

if ! build_internal probe-internal-control; then
  fail "probe-internal-control did not compile; the in-package probes cannot reach the internal identifier types, so non-coercion failures would prove nothing"
fi
echo "ok: probe-internal-control compiles (real internal identifier definitions in scope)"

# expect_internal NAME PATTERN...: like expect, for the in-package
# probes.
expect_internal() {
  probe_name=$1
  shift
  if build_internal "$probe_name"; then
    fail "$probe_name unexpectedly compiled; the identifier namespaces are coercible inside the package"
  fi
  for pattern in "$@"; do
    if ! grep -E -q -- "$pattern" "$log"; then
      fail "$probe_name failed to compile, but not for the intended reason (missing: $pattern)"
    fi
  done
  echo "ok: $probe_name fails to compile for its intended reason"
}

expect_internal probe-internal-coerce-entity-enum \
  "match representation of type .{1,3}EntityId" \
  "with that of .{1,3}EnumId" \
  "arising from a use of .{1,3}coerce"

expect_internal probe-internal-coerce-relation-action \
  "match representation of type .{1,3}RelationId" \
  "with that of .{1,3}ActionId" \
  "arising from a use of .{1,3}coerce"

echo "All API-boundary probes behaved as intended."

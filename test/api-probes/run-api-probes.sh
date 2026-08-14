#!/bin/sh
# Downstream API-boundary compile-fail probes for mithril-ir.
#
# Builds the probe package (test/api-probes/probe) against mithril-ir
# as an ordinary external package dependency — never by adding src/ to
# a module search path — via the dedicated cabal.project.probes, so
# hidden modules, abstract types, and nominal roles are enforced
# exactly as any downstream consumer would experience them.
#
# The control probe must compile: it runs the legitimate public
# pipeline, proving that the failures below are caused by the API
# boundary and not by a broken probe environment.  Every attack probe
# must FAIL to compile, and must fail with the message of its intended
# abstraction/role boundary; compiling successfully, or failing with
# any other message, fails this script.
#
# Requires a POSIX shell and the pinned GHC/cabal toolchain.  It may
# be run from anywhere (it changes to the repository root itself).
# Build state lives under dist-newstyle/probes, inside the ignored
# build directory; the only scratch file is a mktemp log removed on
# exit.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/../.."

log=$(mktemp) || exit 1
trap 'rm -f "$log"' EXIT INT HUP TERM

build() {
  cabal build \
    --project-file=cabal.project.probes \
    --builddir=dist-newstyle/probes \
    "mithril-ir-api-probes:exe:$1" >"$log" 2>&1
}

fail() {
  echo "FAIL: $1" >&2
  echo "---- full build output ----" >&2
  cat "$log" >&2
  exit 1
}

if ! build probe-control; then
  fail "probe-control did not compile; the probe environment is broken, so attack failures would prove nothing"
fi
echo "ok: probe-control compiles (legitimate public pipeline)"

# expect NAME PATTERN...: NAME must fail to build, and every PATTERN
# (grep -E) must appear in the compiler output.  The .{1,3} gaps in
# the patterns absorb GHC's quote characters in both Unicode and
# ASCII locales.
expect() {
  probe_name=$1
  shift
  if build "$probe_name"; then
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
  "hidden module in the package"

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

echo "All API-boundary probes behaved as intended."

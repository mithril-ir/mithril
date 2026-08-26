#!/bin/sh
# Self-test of the probe driver's build isolation
# (test/api-probes/run-api-probes.sh): from a clean copy of the
# repository sources — no dist-newstyle, no version-control metadata
# — two invocations of the driver run at the same time.  Both must
# succeed, each must report its own build root, the two roots must
# differ, both roots must be gone afterwards, and the copy must still
# have no default dist-newstyle: the downstream, in-package, and
# forced-visible phases all build below their run's own root.
#
# Requires a POSIX shell and the pinned GHC/cabal toolchain (the
# dependency store is shared and locked by cabal itself).  It may be
# run from anywhere.  The copy and both logs live in one sandbox
# removed by the single EXIT trap.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

sandbox=$(mktemp -d) || exit 1
trap 'status=$?; rm -rf "$sandbox"; exit "$status"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
ok() {
  echo "ok: $1"
}
bad() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

copy=$sandbox/repository
mkdir "$copy"
for entry in "$repo_root"/* "$repo_root"/.[!.]*; do
  [ -e "$entry" ] || continue
  case $(basename -- "$entry") in
    dist-newstyle | .git) continue ;;
  esac
  cp -R -- "$entry" "$copy/"
done
if [ -e "$copy/dist-newstyle" ]; then
  echo "FAIL: the clean copy unexpectedly holds a dist-newstyle" >&2
  exit 1
fi
echo "clean copy: $copy (no dist-newstyle)"

echo "== two concurrent probe-driver runs from the clean copy =="
(
  sh "$copy/test/api-probes/run-api-probes.sh" >"$sandbox/run1.log" 2>&1
  echo $? >"$sandbox/run1.status"
) &
(
  sh "$copy/test/api-probes/run-api-probes.sh" >"$sandbox/run2.log" 2>&1
  echo $? >"$sandbox/run2.status"
) &
wait

for run in run1 run2; do
  status=$(cat "$sandbox/$run.status")
  if [ "$status" -eq 0 ]; then ok "$run exited 0"; else bad "$run exited $status"; cat "$sandbox/$run.log" >&2; fi
  if grep -q "^All API-boundary probes behaved as intended\.$" "$sandbox/$run.log"; then ok "$run reported every probe as intended"; else bad "$run did not report every probe as intended"; fi
  if grep -q "^ok: the repository's default dist-newstyle was neither created nor written by this run$" "$sandbox/$run.log"; then ok "$run self-checked the default build directory"; else bad "$run did not self-check the default build directory"; fi
  if grep -q "^ok: the forced-visible phase builds and resolves its package environment inside " "$sandbox/$run.log"; then ok "$run proved the forced-visible package environment lives in its own build directory"; else bad "$run did not prove the forced-visible package environment location"; fi
done

root1=$(sed -n 's/^build root: \(.*\) (downstream.*$/\1/p' "$sandbox/run1.log")
root2=$(sed -n 's/^build root: \(.*\) (downstream.*$/\1/p' "$sandbox/run2.log")
if [ -n "$root1" ] && [ -n "$root2" ]; then ok "both runs reported a build root"; else bad "a run reported no build root"; fi
if [ "$root1" != "$root2" ]; then ok "the two build roots are disjoint ($root1, $root2)"; else bad "the two runs shared a build root ($root1)"; fi
for root in "$root1" "$root2"; do
  if [ -n "$root" ] && [ -e "$root" ]; then bad "the build root $root was not removed"; else ok "the build root was removed after its run"; fi
done
if [ -e "$copy/dist-newstyle" ]; then bad "a run created the default dist-newstyle in the clean copy"; else ok "the clean copy still has no default dist-newstyle after both runs"; fi

if [ "$failures" -ne 0 ]; then
  echo "$failures probe-driver isolation check(s) failed" >&2
  exit 1
fi
echo "All probe-driver isolation checks passed."

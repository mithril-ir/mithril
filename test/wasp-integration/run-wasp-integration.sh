#!/bin/sh
# The real Wasp 0.25.0 / PostgreSQL vertical test of the Wasp
# Confinement Profiles v0 and v1.
#
# This is the pinned integration battery of the two generated slices.
# It is deliberately separate from the ordinary Haskell test suite,
# which stays independent of Wasp, Node, and PostgreSQL: CI runs it in
# its own job (.github/workflows/wasp.yml).  Everything here is
# test-only tooling outside the confined deployable root — the
# confinement claim covers exactly the source root the checker walks
# at the time of checking, never this script, the library, the
# battery, or the private working directory below.
#
# The private working directory is created by lib.sh's
# mithril_create_work_directory: mktemp -d, then resolved to its
# physical path (pwd -P), so a TMPDIR reached through a symbolic link
# never becomes an ancestor of a generated root — the generator's
# refusal of linked ancestors is untouched; the harness simply uses
# the physical path for generation, logs, subprocesses, and cleanup.
#
# Steps, in order:
#   1. build the host tool and confirm the exact toolchain pins
#      (wasp version must print 0.25.0; node and psql must exist);
#   2. mithril wasp check the committed fixture against a fresh bundle
#      (fixture equality), then mithril wasp generate into the private
#      work root $work/app — the verifier gate runs here under the
#      real Agda 2.8.0 — and compare that fresh root byte-for-byte
#      with the committed fixture (the golden/drift check), run the
#      confinement check on it, and confirm the root carries the
#      private permission bits 0700;
#   2b. the same generation under umask 000 into $work/app-umask000:
#      the root must still be private (0700), byte-identical to the
#      fixture, confined, and must pass a real wasp install and wasp
#      build from that tree;
#   2c. Profile v1: mithril wasp check the committed Profile-v1 fixture
#      against a fresh bundle, generate the two-case fixture into the
#      private root $work/app-v1 (the verifier gate runs under the real
#      Agda 2.8.0), compare it byte-for-byte with the committed
#      Profile-v1 fixture, check its confinement and its private mode,
#      and confirm the two profiles share exactly one inventory;
#   2d. transitions through the real binary on a scratch root: v0,
#      then v1 over it (byte-identical to the Profile-v1 fixture, its
#      own check passing), then v0 over it again (byte-identical to the
#      Profile-v0 fixture), with no staging or backup sibling left;
#   3. the renamed-model compile/build matrix: every committed rename
#      variant under test/fixtures/wasp-renames is generated into its
#      own private root, must carry exactly the fixed inventory, and
#      must pass wasp install and wasp build;
#   4. wasp install and wasp compile in the freshly generated root
#      $work/app itself — never in a copy of the committed fixture;
#   5. create an isolated PostgreSQL database — inside a private
#      cluster initialized by initdb under the working directory, or,
#      when MITHRIL_PG_ADMIN_URL names an administrative connection, a
#      freshly created database owned by this run only after CREATE
#      DATABASE succeeded (lib.sh) — and initialize it with wasp db
#      migrate-dev in that same root;
#   6. wasp build, bundle, and start the built server against it;
#   7. run test/wasp-integration/battery.mjs, which exercises the
#      generated Action exclusively through Wasp's real generated HTTP
#      and authentication path and uses psql only for test-only
#      bootstrap, fault injection (temporary triggers and sequences
#      outside the confined root), and state verification;
#   8. terminate the Profile-v0 server (identity-bound), then the
#      Profile-v1 vertical in the freshly generated root $work/app-v1:
#      wasp install and compile, a second isolated database of this
#      run (each root migrates its own schema), wasp db migrate-dev,
#      wasp build, bundle, the built server on its own port, and
#      battery.mjs again in Profile-v1 mode — the rule-1 battery
#      unchanged against the Profile-v1 build, then the rule-2 Action
#      (401/400/403/200 with the complete relation pinned, the
#      trigger-proven three-attempt P2034 retry and 409, the 500), the
#      same-operation barrier concurrency, the rule-1/rule-2
#      cross-operation barrier concurrency (every concurrent round
#      judged against the explicit serial-outcome tables of
#      oracle.mjs), and the same-row barrier's decoy-waiter negative
#      regression;
#   9. the one cleanup path of lib.sh: stop the server (bound to its
#      /proc start-time identity, so a reused pid is never signalled)
#      and the private cluster, drop only the databases this run
#      created, remove the physical working directory, and fail the
#      run on any cleanup failure.
#
# Requires: a POSIX shell on Linux (/proc), the pinned GHC/cabal toolchain, Agda 2.8.0,
# Node.js >= 24.14.1 with the Wasp 0.25.0 CLI on PATH, and either the
# PostgreSQL 16 server binaries (initdb, pg_ctl, postgres, psql — found
# under MITHRIL_PG_BIN, default /usr/lib/postgresql/16/bin) or
# MITHRIL_PG_ADMIN_URL plus psql.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

# shellcheck source=test/wasp-integration/lib.sh
. "$script_dir/lib.sh"

core_file=test/fixtures/acme-nspe.mir.json
fixture_root=test/fixtures/wasp-acme
v1_core_file=test/fixtures/acme-nspe-self-update.mir.json
v1_fixture_root=test/fixtures/wasp-acme-self-update
rename_dir=test/fixtures/wasp-renames
pg_bin=${MITHRIL_PG_BIN:-/usr/lib/postgresql/16/bin}
pg_port=${MITHRIL_PG_PORT:-54932}
server_port=${MITHRIL_WASP_PORT:-3931}
v1_server_port=${MITHRIL_WASP_PORT_V1:-3932}
export WASP_TELEMETRY_DISABLE=1

mithril_create_work_directory || exit 1
trap mithril_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

app_root=$work/app
umask_root=$work/app-umask000
v1_root=$work/app-v1
transition_root=$work/transition
echo "working directory: $work (physical path; TMPDIR=${TMPDIR:-unset})"

# directory_mode DIR: the ls -l permission string of DIR itself.
directory_mode() {
  ls -ld "$1" | cut -c1-10
}

echo "== 1. toolchain =="
cabal build -v0 exe:mithril || fail "cabal build exe:mithril failed"
mithril=$(cabal list-bin exe:mithril)
"$mithril" --version
wasp_version=$(wasp version </dev/null 2>/dev/null | tail -n 1 | tr -d '[:space:]')
echo "wasp version: $wasp_version"
[ "$wasp_version" = "0.25.0" ] || fail "Wasp 0.25.0 is required, found '$wasp_version'"
node --version
psql --version
agda --version | head -n 1

echo "== 2. fixture equality, fresh generation into the private root, drift check =="
"$mithril" wasp check "$core_file" "$fixture_root" || fail "the committed fixture is not the fresh bundle"
[ ! -e "$app_root" ] || fail "the private root $app_root exists before generation"
"$mithril" wasp generate "$core_file" "$app_root" || fail "wasp generate into the private root failed"
[ -f "$app_root/.mithril-wasp-profile" ] || fail "the private root carries no ownership marker"
diff -r "$fixture_root" "$app_root" || fail "the fresh generation differs from the committed fixture (golden drift)"
"$mithril" wasp check "$core_file" "$app_root" || fail "the freshly generated root is not confined"
(cd "$app_root" && find . -type f | sort) >"$work/app.inventory"
[ "$(directory_mode "$app_root")" = "drwx------" ] || fail "the generated root is not private: $(directory_mode "$app_root")"
echo "runtime app root: $app_root — freshly generated by this run's mithril wasp generate (not a copy of $fixture_root); the committed fixture is only the golden comparison; mode $(directory_mode "$app_root")"

echo "== 2b. generation under umask 000 (private root, real install and build) =="
(umask 000 && "$mithril" wasp generate "$core_file" "$umask_root" >"$work/umask.generate.log" 2>&1) || { cat "$work/umask.generate.log"; fail "wasp generate under umask 000 failed"; }
[ "$(directory_mode "$umask_root")" = "drwx------" ] || fail "the root generated under umask 000 is not private: $(directory_mode "$umask_root")"
diff -r "$fixture_root" "$umask_root" || fail "the generation under umask 000 differs from the committed fixture"
"$mithril" wasp check "$core_file" "$umask_root" >/dev/null || fail "the root generated under umask 000 is not confined"
(cd "$umask_root" && wasp install </dev/null >"$work/umask.install.log" 2>&1) || { cat "$work/umask.install.log"; fail "wasp install failed in the root generated under umask 000"; }
(cd "$umask_root" && wasp build </dev/null >"$work/umask.build.log" 2>&1) || { cat "$work/umask.build.log"; fail "wasp build failed in the root generated under umask 000"; }
[ -d "$umask_root/.wasp/out/server" ] || fail "wasp build produced no server in the root generated under umask 000"
echo "umask 000 root: $umask_root — mode $(directory_mode "$umask_root"), byte-identical to the fixture, confined, wasp install and build ok"

echo "== 2c. Profile v1: fixture equality, fresh generation into the private root, drift check =="
"$mithril" wasp check "$v1_core_file" "$v1_fixture_root" || fail "the committed Profile-v1 fixture is not the fresh bundle"
[ ! -e "$v1_root" ] || fail "the private Profile-v1 root $v1_root exists before generation"
"$mithril" wasp generate "$v1_core_file" "$v1_root" >"$work/v1.generate.log" || { cat "$work/v1.generate.log"; fail "wasp generate of the two-case fixture into the private root failed"; }
head -n 1 "$work/v1.generate.log" | grep -q "GENERATED (Wasp Confinement Profile v1)" || { cat "$work/v1.generate.log"; fail "the two-case fixture did not generate as Wasp Confinement Profile v1"; }
grep -q "^  operations: 2$" "$work/v1.generate.log" || { cat "$work/v1.generate.log"; fail "the Profile-v1 report does not list two operations"; }
grep -q "mithrilSelfUpdateAction (POST /operations/mithril-self-update-action)" "$work/v1.generate.log" || { cat "$work/v1.generate.log"; fail "the Profile-v1 report does not name the self-update operation"; }
diff -r "$v1_fixture_root" "$v1_root" || fail "the fresh Profile-v1 generation differs from the committed fixture (golden drift)"
"$mithril" wasp check "$v1_core_file" "$v1_root" >/dev/null || fail "the freshly generated Profile-v1 root is not confined"
(cd "$v1_root" && find . -type f | sort) >"$work/app-v1.inventory"
cmp -s "$work/app.inventory" "$work/app-v1.inventory" || fail "the Profile-v1 root does not carry exactly the Profile-v0 inventory"
[ "$(directory_mode "$v1_root")" = "drwx------" ] || fail "the generated Profile-v1 root is not private: $(directory_mode "$v1_root")"
grep -q "^export const mithrilSelfUpdateAction:" "$v1_root/src/mithrilCaseAction.ts" || fail "the Profile-v1 operation file does not export the self-update Action"
echo "Profile-v1 root: $v1_root — freshly generated from $v1_core_file, byte-identical to $v1_fixture_root, confined, same fourteen paths, mode $(directory_mode "$v1_root")"

echo "== 2d. profile transitions through the real binary (v0 → v1 → v0) =="
"$mithril" wasp generate "$core_file" "$transition_root" >/dev/null || fail "generating the transition root failed"
diff -r "$fixture_root" "$transition_root" || fail "the transition root is not the Profile-v0 fixture"
"$mithril" wasp generate "$v1_core_file" "$transition_root" >"$work/transition-up.log" || { cat "$work/transition-up.log"; fail "the v0 → v1 transition failed"; }
head -n 1 "$work/transition-up.log" | grep -q "GENERATED (Wasp Confinement Profile v1)" || fail "the v0 → v1 transition did not report Profile v1"
diff -r "$v1_fixture_root" "$transition_root" || fail "the v0 → v1 transition did not install exactly the Profile-v1 fixture"
"$mithril" wasp check "$v1_core_file" "$transition_root" >/dev/null || fail "the transitioned Profile-v1 root is not confined"
if "$mithril" wasp check "$core_file" "$transition_root" >"$work/transition-cross.log"; then fail "a Profile-v1 root passed the Profile-v0 check"; fi
grep -q "the ownership marker is that of a Wasp Confinement Profile v1 root, not of the requested Wasp Confinement Profile v0" "$work/transition-cross.log" || { cat "$work/transition-cross.log"; fail "the cross-profile check did not name the other profile's marker"; }
"$mithril" wasp generate "$core_file" "$transition_root" >"$work/transition-down.log" || { cat "$work/transition-down.log"; fail "the v1 → v0 transition failed"; }
head -n 1 "$work/transition-down.log" | grep -q "GENERATED (Wasp Confinement Profile v0)" || fail "the v1 → v0 transition did not report Profile v0"
diff -r "$fixture_root" "$transition_root" || fail "the v1 → v0 transition did not restore exactly the Profile-v0 fixture"
[ ! -e "$transition_root.mithril-wasp-staging" ] || fail "a staging sibling was left behind by the transitions"
[ ! -e "$transition_root.mithril-wasp-backup" ] || fail "a backup sibling was left behind by the transitions"
[ "$(directory_mode "$transition_root")" = "drwx------" ] || fail "the transitioned root is not private: $(directory_mode "$transition_root")"
echo "transitions: v0 → v1 → v0 on $transition_root, each byte-identical to its fixture, no staging or backup left"

echo "== 3. renamed-model compile/build matrix (Wasp 0.25.0) =="
variant_count=0
for variant in "$rename_dir"/*.mir.json; do
  name=$(basename "$variant" .mir.json)
  variant_root=$work/rename-$name
  "$mithril" wasp generate "$variant" "$variant_root" >"$work/rename-$name.generate.log" || { cat "$work/rename-$name.generate.log"; fail "wasp generate failed for the renamed model $name"; }
  (cd "$variant_root" && find . -type f | sort) >"$work/rename-$name.inventory"
  cmp -s "$work/app.inventory" "$work/rename-$name.inventory" || fail "the renamed model $name did not produce the fixed inventory"
  "$mithril" wasp check "$variant" "$variant_root" >/dev/null || fail "the renamed model $name is not confined"
  (cd "$variant_root" && wasp install </dev/null >"$work/rename-$name.install.log" 2>&1) || { cat "$work/rename-$name.install.log"; fail "wasp install failed for the renamed model $name"; }
  (cd "$variant_root" && wasp build </dev/null >"$work/rename-$name.build.log" 2>&1) || { cat "$work/rename-$name.build.log"; fail "wasp build failed for the renamed model $name"; }
  [ -d "$variant_root/.wasp/out/server" ] || fail "wasp build produced no server for the renamed model $name"
  variant_count=$((variant_count + 1))
  echo "renamed model $name: fixed inventory, confined, wasp install and build ok"
done
[ "$variant_count" -ge 7 ] || fail "expected at least 7 rename variants, found $variant_count"

echo "== 4. wasp install / compile in the freshly generated root =="
cd "$app_root"
wasp install </dev/null >"$work/wasp-install.log" 2>&1 || { cat "$work/wasp-install.log"; fail "wasp install failed"; }
echo "wasp install: ok"
wasp compile </dev/null >"$work/wasp-compile.log" 2>&1 || { cat "$work/wasp-compile.log"; fail "wasp compile failed"; }
echo "wasp compile: ok"

echo "== 5. isolated PostgreSQL and migration =="
mithril_provision_database || fail "provisioning the isolated database failed"
wasp db migrate-dev --name init </dev/null >"$work/wasp-migrate.log" 2>&1 || { cat "$work/wasp-migrate.log"; fail "wasp db migrate-dev failed"; }
echo "wasp db migrate-dev: ok (private root only)"

echo "== 6. wasp build and the built server =="
wasp build </dev/null >"$work/wasp-build.log" 2>&1 || { cat "$work/wasp-build.log"; fail "wasp build failed"; }
echo "wasp build: ok"
[ -d .wasp/out/server ] || fail "wasp build produced no .wasp/out/server"
cd .wasp/out/server
npm run bundle </dev/null >"$work/server-bundle.log" 2>&1 || { cat "$work/server-bundle.log"; fail "server bundle failed"; }
JWT_SECRET="mithril-wasp-integration-jwt-secret-0123456789" \
WASP_WEB_CLIENT_URL="http://localhost:3000" \
WASP_SERVER_URL="http://127.0.0.1:$server_port" \
PORT="$server_port" \
NODE_ENV=production \
node --enable-source-maps bundle/server.js >"$work/server.log" 2>&1 </dev/null &
server_pid=$!
cd "$repo_root"
echo "server: pid $server_pid serving the build of $app_root"

echo "== 7. the HTTP battery (Profile v0) =="
MITHRIL_WASP_SERVER_URL="http://127.0.0.1:$server_port" \
MITHRIL_WASP_MANIFEST="$app_root/mithril.manifest.json" \
MITHRIL_WASP_DATABASE_URL="$DATABASE_URL" \
node test/wasp-integration/battery.mjs || { echo "---- server log ----"; cat "$work/server.log"; fail "the HTTP battery (Profile v0) failed"; }

echo "== 8. the Profile-v1 vertical in the freshly generated Profile-v1 root =="
mithril_terminate_process "$server_pid" "built Wasp server (Profile v0)"
server_pid=''
[ -z "$cleanup_failures" ] || fail "terminating the Profile-v0 server recorded a cleanup failure"
cd "$v1_root"
wasp install </dev/null >"$work/v1-wasp-install.log" 2>&1 || { cat "$work/v1-wasp-install.log"; fail "wasp install failed in the Profile-v1 root"; }
echo "wasp install (Profile v1): ok"
wasp compile </dev/null >"$work/v1-wasp-compile.log" 2>&1 || { cat "$work/v1-wasp-compile.log"; fail "wasp compile failed in the Profile-v1 root"; }
echo "wasp compile (Profile v1): ok"
mithril_provision_database v1 || fail "provisioning the isolated Profile-v1 database failed"
wasp db migrate-dev --name init </dev/null >"$work/v1-wasp-migrate.log" 2>&1 || { cat "$work/v1-wasp-migrate.log"; fail "wasp db migrate-dev failed in the Profile-v1 root"; }
echo "wasp db migrate-dev (Profile v1): ok (private root only)"
wasp build </dev/null >"$work/v1-wasp-build.log" 2>&1 || { cat "$work/v1-wasp-build.log"; fail "wasp build failed in the Profile-v1 root"; }
echo "wasp build (Profile v1): ok"
[ -d .wasp/out/server ] || fail "wasp build produced no .wasp/out/server in the Profile-v1 root"
cd .wasp/out/server
npm run bundle </dev/null >"$work/v1-server-bundle.log" 2>&1 || { cat "$work/v1-server-bundle.log"; fail "the Profile-v1 server bundle failed"; }
JWT_SECRET="mithril-wasp-integration-jwt-secret-0123456789" \
WASP_WEB_CLIENT_URL="http://localhost:3000" \
WASP_SERVER_URL="http://127.0.0.1:$v1_server_port" \
PORT="$v1_server_port" \
NODE_ENV=production \
node --enable-source-maps bundle/server.js >"$work/v1-server.log" 2>&1 </dev/null &
server_pid=$!
cd "$repo_root"
echo "server (Profile v1): pid $server_pid serving the build of $v1_root"
MITHRIL_WASP_SERVER_URL="http://127.0.0.1:$v1_server_port" \
MITHRIL_WASP_MANIFEST="$v1_root/mithril.manifest.json" \
MITHRIL_WASP_DATABASE_URL="$DATABASE_URL" \
node test/wasp-integration/battery.mjs || { echo "---- Profile-v1 server log ----"; cat "$work/v1-server.log"; fail "the HTTP battery (Profile v1) failed"; }

echo "All Wasp/PostgreSQL integration steps passed (Profile v0 and Profile v1)."

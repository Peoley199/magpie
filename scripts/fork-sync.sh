#!/usr/bin/env bash
# fork-sync: the fork's whole sync-and-build round, automated.
#
#   scripts/fork-sync.sh                      # investigate only, print the plan, change nothing
#   scripts/fork-sync.sh --yes                # investigate, merge, verify, build; no push
#   scripts/fork-sync.sh --yes --push         # also push origin main
#   scripts/fork-sync.sh --yes --suite        # also run the full 45m suite (one suite per machine)
#   scripts/fork-sync.sh --yes --install 'D:\magpie'
#                                             # also replace that folder's magpie-windows-amd64.exe,
#                                             # keeping the old one as .bak-v<its version>
#   scripts/fork-sync.sh --build-only --install 'D:\magpie'
#                                             # skip the sync, just rebuild and install this head
#
# It stops before the merge when upstream has adopted a fork fingerprint, and
# anywhere a verification step fails. Everything else runs unattended.
set -uo pipefail

PUSH=0; ASSUME_YES=0; RUN_SUITE=0; BUILD_ONLY=0; INSTALL_DIR=""
while [ $# -gt 0 ]; do case "$1" in
  --push) PUSH=1; shift;;
  --yes) ASSUME_YES=1; shift;;
  --suite) RUN_SUITE=1; shift;;
  --build-only) BUILD_ONLY=1; shift;;
  --install) [ $# -ge 2 ] || { echo "--install needs a folder" >&2; exit 2; }
             INSTALL_DIR="$2"; shift 2;;
  *) echo "unknown flag: $1 (flags: --yes --push --suite --build-only --install <dir>)" >&2; exit 2;;
esac; done

cd "$(dirname "$0")/.."
PROXY=127.0.0.1:7897
GITP=(-c http.proxy="http://$PROXY")
GOPW=(HTTPS_PROXY="http://$PROXY" HTTP_PROXY="http://$PROXY")
LOG=/tmp/fork-sync-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sync

sync() {
  step "1. fetch both remotes"
  git "${GITP[@]}" fetch upstream --prune --tags || die "upstream fetch failed (proxy $PROXY?)"
  git "${GITP[@]}" fetch origin --prune || die "origin fetch failed"
  git status --porcelain | grep -q . && die "working tree is dirty — commit or stash first"

  step "2. investigate"
  AHEAD_UP=$(git rev-list --count main..upstream/main)
  AHEAD_FORK=$(git rev-list --count upstream/main..main)
  MB=$(git merge-base main upstream/main)
  echo "upstream ahead: $AHEAD_UP commits (base $MB → $(git rev-parse --short upstream/main))"
  echo "fork ahead:     $AHEAD_FORK commits"
  if [ "$AHEAD_UP" -eq 0 ]; then
    echo "nothing to sync"
    [ "$BUILD_ONLY" -eq 1 ] || [ -n "$INSTALL_DIR" ] && return 1   # 1 = build this head anyway
    exit 0
  fi
  git log --oneline --reverse upstream/main..main
  echo "--- fork-side files changed since base ---"
  git diff --name-only "$MB"..main
  echo "--- overlap with upstream's changed files ---"
  comm -12 <(git diff --name-only "$MB"..upstream/main | sort) <(git diff --name-only "$MB"..main | sort)
  echo "(an empty list above = no overlap at all)"

  step "3. fork fingerprints upstream must not have adopted"
  local adopted=0 fp pat file
  # fingerprint | the upstream file it would live in
  for fp in \
    'path\.Clean\("/" \+ parts\[2\]\)|internal/gateway/claude_room.go' \
    'func zcodeStartPlan|internal/gateway/anthropic_shapes.go' \
    'zcodeWorkDir|internal/gateway/workdir.go'; do
    pat=${fp%|*}; file=${fp#*|}
    if git grep -qE "$pat" upstream/main -- "$file" 2>/dev/null; then
      echo "UPSTREAM HAS IT: /$pat/ in $file"; adopted=1
    fi
  done
  [ "$adopted" -eq 0 ] || die "upstream adopted a fork fix — decide by hand whether to drop ours"
  echo "none adopted — the fork fixes stay necessary"

  step "4. dry-run merge"
  if ! git merge --no-commit --no-ff upstream/main >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1
    die "the merge has conflicts — resolve by hand (docs/fork-sync.md §二)"
  fi
  local keep=0
  for pat in 'path\.Clean\("/" \+ parts\[2\]\)' 'func zcodeStartPlan' 'zcodeWorkDir'; do
    grep -rqE "$pat" internal/gateway/ || { keep=1; echo "MISSING after merge: $pat"; }
  done
  git merge --abort >/dev/null 2>&1
  [ "$keep" -eq 0 ] || die "a fingerprint did not survive the auto-merge — merge by hand"

  if [ "$ASSUME_YES" -ne 1 ]; then
    echo; echo "investigation only (no --yes): nothing changed. The report above is the plan."
    exit 0
  fi

  step "5. merge"
  local n desc
  n=$(git rev-list --count main..upstream/main)
  desc=$(git describe --tags upstream/main 2>/dev/null || git rev-parse --short upstream/main)
  git merge --no-ff upstream/main -m "Merge upstream yetone/magpie main ($(git rev-parse --short upstream/main)): $n commits, the fork's ZCode Start Plan / memLimit / workdir fixes kept

Upstream to $desc. The fork's own commits ride through the merge
unchanged (docs/fork-sync.md §二); fingerprints verified on the merged
tree before committing. Conflicts: none.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || die "merge failed"
  echo "merged as $(git rev-parse --short HEAD)"

  step "6. verify the merge head"
  env "${GOPW[@]}" go build ./... || die "go build failed"
  gofmt -l . | grep -q . && die "gofmt dirty: $(gofmt -l . | head -3)"
  env "${GOPW[@]}" go vet ./... || die "go vet failed"
  env "${GOPW[@]}" go test ./internal/gateway \
      -run 'TestWithoutZCodeSystem|TestWorkDir|TestClaudeMem|TestZCodeStartPlan|TestClaudeRunsMost' -count=1 \
    || die "the fork's own tests failed on the merge head"

  if [ "$RUN_SUITE" -eq 1 ]; then
    step "6b. full suite (45m, log kept)"
    env "${GOPW[@]}" go test -timeout 45m ./... 2>&1 | tee /tmp/fork-suite.log | grep -E '^(FAIL|ok)' | tail -5
    if grep -qE '^FAIL' /tmp/fork-suite.log; then
      echo "suite has reds — run scripts/fork-suite-compare.sh to tell regressions"
      echo "from pre-existing Windows reds before pushing"
    fi
  fi
}

# ---------------------------------------------------------------- build

build() {
  step "7. build (version = git describe of this head)"
  VERSION=$(git describe --tags --always --dirty | tr -cd 'A-Za-z0-9._+-')
  NUMVER=$(printf '%s' "${VERSION#v}" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/')
  mkdir -p dist
  if [ "$(go env GOOS)" = "windows" ]; then
    # The Makefile's release-windows build: icon and version resources from
    # build/windows/winres.json, the COM launcher embedded, and the GUI
    # subsystem (-H windowsgui) so no console window opens. A console build
    # is NOT what the desktop app is; check with the PE subsystem.
    env "${GOPW[@]}" go run github.com/tc-hib/go-winres@v0.3.3 make \
        --in build/windows/winres.json --arch amd64 --out rsrc \
        --file-version "$NUMVER" --product-version "$NUMVER" \
      || die "go-winres failed (it needs the proxy to download)"
    CGO_ENABLED=0 env "${GOPW[@]}" go build -trimpath -buildvcs=false -ldflags="-s -w" \
        -o internal/update/launcher-amd64.com ./internal/update/launcher || die "launcher build failed"
    CGO_ENABLED=0 env "${GOPW[@]}" go build -tags production,comlauncher -trimpath \
        -ldflags="-s -w -X main.version=$VERSION -H windowsgui" -o dist/magpie-windows-amd64.exe . \
      || die "Windows GUI build failed"
    rm -f rsrc_windows_*.syso internal/update/launcher-*.com
    ./dist/magpie-windows-amd64.exe --version || die "the built GUI binary does not run"
    echo "built dist/magpie-windows-amd64.exe ($VERSION, resources $NUMVER)"
  else
    env "${GOPW[@]}" go build -tags production -trimpath \
        -ldflags="-s -w -X main.version=$VERSION" -o dist/magpie.exe . || die "GUI build failed"
    echo "built dist/magpie.exe ($VERSION)"
  fi
  CGO_ENABLED=0 env "${GOPW[@]}" go build -tags nogui -trimpath \
      -ldflags="-s -w -X main.version=$VERSION" -o dist/magpie-cli.exe . || die "CLI build failed"
  ./dist/magpie-cli.exe --version || die "the built CLI does not run"

  step "7b. install"
  if [ -z "$INSTALL_DIR" ]; then
    echo "not installed (--install 'D:\\magpie' replaces that folder's desktop app)"
    return 0
  fi
  local target="$INSTALL_DIR/magpie-windows-amd64.exe" old
  [ -f "dist/magpie-windows-amd64.exe" ] || die "--install needs a Windows build; dist has none"
  [ -f "$target" ] || die "nothing to replace at $target"
  # a running app holds its .exe: replacing it then fails, or leaves two
  # versions fighting over the gateway
  if tasklist 2>/dev/null | grep -qi 'magpie'; then
    die "magpie is running — quit it from the tray, then run again"
  fi
  old=$("$target" --version 2>/dev/null | awk '{print $2}')
  cp -p "$target" "$target.bak-v${old:-unknown}" || die "backup of $target failed"
  cp dist/magpie-windows-amd64.exe "$target" || die "copy to $target failed"
  echo "installed $target ($("$target" --version))"
  echo "previous kept as $(basename "$target").bak-v${old:-unknown}"
}

# ---------------------------------------------------------------- main

if [ "$BUILD_ONLY" -eq 1 ]; then
  step "0. build-only"
  git status --porcelain | grep -q . && die "working tree is dirty — commit first"
  build
  PUSH=0   # nothing merged, nothing to push
else
  sync
  build
fi

step "8. push"
if [ "$PUSH" -eq 1 ] && [ "$ASSUME_YES" -eq 1 ]; then
  git merge-base --is-ancestor origin/main main || die "origin/main diverged — investigate before pushing"
  git push origin main || die "push failed"
  echo "pushed: origin/main is now $(git rev-parse --short origin/main)"
else
  echo "not pushed (--yes --push pushes). HEAD is $(git rev-parse --short HEAD)"
fi
echo "log: $LOG"

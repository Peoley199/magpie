#!/usr/bin/env bash
# fork-sync: the fork's whole sync round, automated.
#
#   scripts/fork-sync.sh            # investigate only, print the report, change nothing
#   scripts/fork-sync.sh --yes      # investigate, merge, verify, build; no push
#   scripts/fork-sync.sh --yes --push   # also push origin main
#   scripts/fork-sync.sh --yes --suite  # also run the full 45m suite (one suite per machine)
#
# Stops before the merge when upstream has adopted a fork fingerprint, or when
# a verification step fails. Everything else runs unattended.
set -uo pipefail

PUSH=0; ASSUME_YES=0; RUN_SUITE=0
for arg in "$@"; do case "$arg" in
  --push) PUSH=1;; --yes) ASSUME_YES=1;; --suite) RUN_SUITE=1;;
  *) echo "unknown flag: $arg (flags: --yes --push --suite)" >&2; exit 2;;
esac; done

cd "$(dirname "$0")/.."
PROXY=127.0.0.1:7897
GITP=(-c http.proxy="http://$PROXY")
GOPW=(HTTPS_PROXY="http://$PROXY" HTTP_PROXY="http://$PROXY")
LOG=/tmp/fork-sync-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

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
[ "$AHEAD_UP" -gt 0 ] || { echo "nothing to sync"; exit 0; }
git log --oneline --reverse upstream/main..main
echo "--- fork-side files changed since base ---"
git diff --name-only "$MB"..main
echo "--- overlap with upstream's changed files ---"
comm -12 <(git diff --name-only "$MB"..upstream/main | sort) <(git diff --name-only "$MB"..main | sort) | tee /tmp/fork-overlap.txt
echo "(empty list = no overlap at all)"

step "3. fork fingerprints upstream must not have adopted"
# each fingerprint: a grep pattern and the upstream file it would live in
FP=(
  'path\.Clean\("/" + parts\[2\]\)|internal/gateway/claude_room.go'
  'func zcodeStartPlan|internal/gateway/anthropic_shapes.go'
  'zcodeWorkDir|internal/gateway/workdir.go'
)
ADOPTED=0
for fp in "${FP[@]}"; do
  pat=${fp%|*}; file=${fp#*|}
  if git grep -qE "$pat" upstream/main -- "$file" 2>/dev/null; then
    echo "UPSTREAM HAS IT: /$pat/ in $file"
    ADOPTED=1
  fi
done
[ "$ADOPTED" -eq 0 ] || die "upstream adopted a fork fix — decide by hand whether to drop ours"
echo "none adopted — fork fixes stay necessary"

step "4. dry-run merge check"
git merge --no-commit --no-ff upstream/main >/dev/null 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  git merge --abort >/dev/null 2>&1
  die "merge has conflicts — resolve by hand (see docs/fork-sync.md §二)"
fi
KEEP=0
for pat in 'path\.Clean\("/" \+ parts\[2\]\)' 'func zcodeStartPlan' 'zcodeWorkDir'; do
  grep -rqE "$pat" internal/gateway/ || { KEEP=1; echo "MISSING after merge: $pat"; }
done
git merge --abort >/dev/null 2>&1
[ "$KEEP" -eq 0 ] || die "a fingerprint did not survive the auto-merge — merge by hand"

if [ "$ASSUME_YES" -ne 1 ]; then
  echo; echo "investigation only (no --yes): nothing changed. Report above is the plan."
  exit 0
fi

step "5. merge"
UP_DESC=$(git describe --tags upstream/main 2>/dev/null || git rev-parse --short upstream/main)
N=$(git rev-list --count main..upstream/main)
git merge --no-ff upstream/main -m "Merge upstream yetone/magpie main ($(git rev-parse --short upstream/main)): $N commits, the fork's ZCode Start Plan / memLimit / workdir fixes kept

Upstream to $UP_DESC. The fork's own commits ride through the merge
unchanged (see docs/fork-sync.md §二); fingerprints verified on the
merged tree before committing. Conflicts: none.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || die "merge failed"
echo "merged as $(git rev-parse --short HEAD)"

step "6. verify the merge head"
env "${GOPW[@]}" go build ./... || die "go build failed"
gofmt -l . | grep -q . && die "gofmt dirty: $(gofmt -l . | head -3)"
env "${GOPW[@]}" go vet ./... || die "go vet failed"
env "${GOPW[@]}" go test ./internal/gateway -run 'TestWithoutZCodeSystem|TestWorkDir|TestClaudeMem|TestZCodeStartPlan|TestClaudeRunsMost' -count=1 \
  || die "fork's own tests failed on the merge head"

if [ "$RUN_SUITE" -eq 1 ]; then
  step "6b. full suite (45m, log kept)"
  env "${GOPW[@]}" go test -timeout 45m ./... 2>&1 | tee /tmp/fork-suite.log | grep -E '^(FAIL|ok)' | tail -5
  grep -qE '^FAIL' /tmp/fork-suite.log && \
    echo "suite has reds — run scripts/fork-suite-compare.sh to tell regressions from pre-existing Windows reds before pushing"
fi

step "7. build (version = describe of this head)"
VERSION=$(git describe --tags --always --dirty | tr -cd 'A-Za-z0-9._+-')-fork
mkdir -p dist
env "${GOPW[@]}" go build -tags production -trimpath -ldflags="-s -w -X main.version=$VERSION" -o dist/magpie.exe . || die "GUI build failed"
CGO_ENABLED=0 env "${GOPW[@]}" go build -tags nogui -trimpath -ldflags="-s -w -X main.version=$VERSION" -o dist/magpie-cli.exe . || die "CLI build failed"
./dist/magpie-cli.exe --version || die "built CLI does not run"
echo "built dist/magpie.exe and dist/magpie-cli.exe ($VERSION)"

step "8. push"
if [ "$PUSH" -eq 1 ]; then
  git merge-base --is-ancestor origin/main main || die "origin/main diverged — investigate before pushing"
  git push origin main || die "push failed"
  echo "pushed: origin/main is now $(git rev-parse --short origin/main)"
else
  echo "not pushed (--push to push). HEAD is $(git rev-parse --short HEAD)"
fi
echo "log: $LOG"

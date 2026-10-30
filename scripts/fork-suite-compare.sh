#!/usr/bin/env bash
# fork-suite-compare: after a merge, tell regressions from pre-existing Windows reds.
#
#   scripts/fork-suite-compare.sh /tmp/fork-suite.log
#
# It re-runs only the packages that failed, at the pre-merge parent of HEAD,
# then diffs the failing-test sets with durations stripped. Verdict per test:
#   - red on the baseline with the same signature  → pre-existing, not a regression
#   - red only on the merge head                   → NEW; trace its origin
#     (upstream-new test failing on Windows is a known class — see
#     docs/fork-sync.md §三 for the catalogue before you call it a regression)
set -uo pipefail

MERGED_LOG=${1:?usage: fork-suite-compare.sh <merged-suite-log> [baseline-ref]}
cd "$(dirname "$0")/.."
PROXY=127.0.0.1:7897
GOPW=(HTTPS_PROXY="http://$PROXY" HTTP_PROXY="http://$PROXY")
# The baseline is our side of the last merge, not HEAD^1: commits often
# follow the merge (docs, script fixes), and HEAD^1 would then be the merge
# itself — the same code as the head, which makes every red "pre-existing".
BASE=${2:-$(git log --merges -1 --format=%P | awk '{print $1}')}
[ -n "$BASE" ] || BASE=$(git rev-parse HEAD^1)
echo "baseline: $BASE ($(git log -1 --format=%s "$BASE" | cut -c1-70))"
WT=$(mktemp -d)/baseline-$BASE
trap 'git worktree remove --force "$WT" 2>/dev/null' EXIT

fail_names() { grep -E '^--- FAIL:' "$1" | sed -E 's/ \([0-9.]+s\)//; s/ +$//' | sort -u; }

step() { printf '\n=== %s ===\n' "$*"; }

step "1. packages red on the merge head"
FAILED_PKGS=$(grep -E '^FAIL\s+github.com/yetone/magpie' "$MERGED_LOG" | awk '{print $2}')
[ -n "$FAILED_PKGS" ] || { echo "nothing failed in $MERGED_LOG"; exit 0; }
echo "$FAILED_PKGS"

step "2. baseline worktree at $BASE"
git worktree add "$WT" "$BASE" >/dev/null || exit 1

step "3. run the same packages on the baseline (this can take a while)"
(cd "$WT" && env "${GOPW[@]}" go test -timeout 45m $FAILED_PKGS) > /tmp/fork-baseline.log 2>&1
BASE_FAILS=$(fail_names /tmp/fork-baseline.log)
MERGED_FAILS=$(fail_names "$MERGED_LOG")
echo "$BASE_FAILS" | wc -l | xargs echo "baseline red tests:"
echo "$MERGED_FAILS" | wc -l | xargs echo "merge-head red tests:"

step "4. verdict"
NEW=$(comm -13 <(echo "$BASE_FAILS") <(echo "$MERGED_FAILS"))
GONE=$(comm -23 <(echo "$BASE_FAILS") <(echo "$MERGED_FAILS"))
if [ -z "$NEW" ]; then
  echo "NO new failures — every red on the merge head is pre-existing."
else
  echo "failures NEW on the merge head (trace each before pushing):"
  echo "$NEW"
fi
[ -n "$GONE" ] && { echo; echo "reds that the merge fixed (spot-check these, they may be order-dependent):"; echo "$GONE"; }

step "5. signature check of the pre-existing reds (same error, or different?)"
SAME=0; DIFF=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  name=${t##*FAIL: }
  b=$(grep -A2 "^--- FAIL: $name" /tmp/fork-baseline.log | sed -n 2p | sed 's/^[[:space:]]*//; s/[0-9]//g' | cut -c1-90)
  m=$(grep -A2 "^--- FAIL: $name" "$MERGED_LOG"   | sed -n 2p | sed 's/^[[:space:]]*//; s/[0-9]//g' | cut -c1-90)
  if [ "$b" = "$m" ]; then SAME=$((SAME+1)); else DIFF=$((DIFF+1)); echo "SIGNATURE CHANGED: $name"; echo "  base: $b"; echo "  merg: $m"; fi
done <<EOF
$(comm -12 <(echo "$BASE_FAILS") <(echo "$MERGED_FAILS"))
EOF
echo "same signature: $SAME, changed: $DIFF"
[ "$DIFF" -eq 0 ] || echo "→ changed signatures need a look even though the test was already red"
exit 0

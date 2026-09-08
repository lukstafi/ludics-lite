#!/usr/bin/env bash
# The live-API contract behind pr-review.sh's fixtures (ludics-lite#41).
#
# The fixture suites (test-pr-review-*.sh) drive the gate against canned answers, so they pin the
# LOGIC and take the SHAPES on faith: which fields the projections read, in what order the runs
# feed comes back, which status and conclusion strings occur, what a PR read says about its base
# and its mergeability. A renamed field, a changed default ordering or a new conclusion string
# leaves every fixture green and a merge gate reading a head wrong — the silent direction. This
# script asks the repository's own live API the same questions, one jq read per belief, and
# reports each belief on its own line, so a failure localizes to the field that moved rather than
# to "the gate said something odd". It reads only what the projections read; it never judges a
# head, and it never writes.
#
# Usage: pr-review-api-contract.sh [owner/name]      (default: $GITHUB_REPOSITORY, else the
#                                                     repository this script was written in)
# Environment, all optional:
#   CONTRACT_BASE            the base branch (default: the repository's default branch)
#   CONTRACT_STALE_BASE_PR   a MERGED PR whose `.base.sha` is NOT its merge commit's first parent
#                            (ludics-lite#53: merged behind a sibling, so the snapshot stood
#                            still) — the pulls-API belief from ludics-lite#44/#47
#   CONTRACT_REVIEWED_PR     a PR the review app reviewed AND approved (ludics-lite#39) — the
#                            reactions, reviews and comments beliefs of the status/rounds suites
#   CONTRACT_OWN_HEAD        under Actions: the head this job's own run is attached to
#                            (github.event.pull_request.head.sha, else github.sha); with
#                            GITHUB_RUN_ID it pins the job's own row as the newest for that head
#   REVIEWER                 the review app's login without its [bot] suffix (pr-review.sh's)
#
# Exit 0: every checkable belief holds. 1: at least one MOVED (listed, all of them — the script
# does not stop at the first). 3: the API did not answer, which is not a moved belief. A belief
# this repository cannot check prints as `skip`, with the reason, so the unpinned set is visible
# in every run rather than assumed away.

set -uo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-lukstafi/ludics-lite}}"
REVIEWER="${REVIEWER:-chatgpt-codex-connector}"
BOT="${REVIEWER}[bot]" # how an app's login reads in every feed: matched by prefix in pr-review.sh
STALE_BASE_PR="${CONTRACT_STALE_BASE_PR:-}"
REVIEWED_PR="${CONTRACT_REVIEWED_PR:-}"
if [ "$REPO" = lukstafi/ludics-lite ]; then
  : "${STALE_BASE_PR:=53}"
  : "${REVIEWED_PR:=39}"
fi

# The vocabularies the projections classify. conclusion_class in pr-review.sh maps failure,
# timed_out and startup_failure to red; success, skipped and neutral to green; null to pending;
# and EVERYTHING ELSE to stopped-not-judged — so a conclusion string outside this list would be
# absorbed silently, which is why membership is a belief and not a tautology.
STATUS_VOCAB='["queued","in_progress","completed","waiting","requested","pending"]'
CONCLUSION_VOCAB='["success","failure","cancelled","skipped","neutral","timed_out","action_required","stale","startup_failure"]'
MERGEABLE_STATE_VOCAB='["clean","dirty","unstable","blocked","behind","unknown","draft","has_hooks"]'
REVIEW_STATE_VOCAB='["APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED","PENDING"]'
ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
HEX40='^[0-9a-f]{40}$'

CLAIMS=0
MOVED=0
SKIPPED=0

# api <gh api args...>: one read, three attempts. A read that never answers ends the run with 3:
# an unanswered call supports no claim about the API, moved or not.
api() {
  local attempt out
  for attempt in 1 2 3; do
    if out=$(gh api "$@" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$attempt" -eq 3 ] || sleep $((attempt * 5))
  done
  echo "pr-review-api-contract.sh: the API did not answer: gh api $* -> $out" >&2
  exit 3
}

# pin <belief> <jq filter> <json>: the filter must yield true on the json.
pin() {
  CLAIMS=$((CLAIMS + 1))
  if jq -e "$2" <<<"$3" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$1"
  else
    MOVED=$((MOVED + 1))
    printf 'MOVED %s\n      filter: %s\n      read:   %s\n' "$1" "$2" \
      "$(jq -c . <<<"$3" 2>/dev/null | cut -c1-400)"
  fi
}

skip() { # <belief> <why>
  SKIPPED=$((SKIPPED + 1))
  printf 'skip  %s — %s\n' "$1" "$2"
}

section() { printf '\n== %s\n' "$*"; }

# --- the anchors ------------------------------------------------------------------------------
section "anchors on $REPO"
BASE="${CONTRACT_BASE:-$(api "repos/$REPO" --jq .default_branch)}"
tip=$(api "repos/$REPO/commits/$BASE")
pin "commits/<branch> answers the branch tip's sha and committer date (the drift anchor and the push clock)" \
  "(.sha | test(\"$HEX40\")) and (.commit.committer.date | test(\"$ISO\"))" "$tip"
HEAD=$(jq -r .sha <<<"$tip")
echo "      base $BASE tip $HEAD"

# --- actions/runs?head_sha= -------------------------------------------------------------------
section "actions/runs?head_sha=<tip> — run_signal's feed"
runs=$(api --paginate "repos/$REPO/actions/runs?head_sha=$HEAD&per_page=100" --jq '.workflow_runs' | jq -s 'add')
pin "the feed is workflow_runs[], and the base tip has at least one run" \
  'type == "array" and length >= 1' "$runs"
pin "every row carries the fields the fold indexes: numeric id and workflow_id, string event, name and status, created_at" \
  'all(.[]; (.id | type == "number") and (.workflow_id | type == "number") and (.event | type == "string" and length > 0)
             and (.name | type == "string") and (.status | type == "string") and (.created_at | test("'"$ISO"'")))' "$runs"
pin "every row's head_sha is the sha asked for (the filter filters)" \
  "all(.[]; .head_sha == \"$HEAD\")" "$runs"
pin "status strings are in the known vocabulary" \
  "all(.[]; .status as \$s | $STATUS_VOCAB | index(\$s))" "$runs"
pin "conclusion is null or in the vocabulary conclusion_class classifies" \
  "all(.[]; .conclusion == null or (.conclusion as \$c | $CONCLUSION_VOCAB | index(\$c)))" "$runs"
pin "a row that is not completed has no conclusion yet" \
  'all(.[]; .status == "completed" or .conclusion == null)' "$runs"
echo "      events seen on the tip: $(jq -r '[.[].event] | unique | join(" ")' <<<"$runs")"
echo "      status/conclusion seen: $(jq -r '[.[] | "\(.status)/\(.conclusion)"] | unique | join(" ")' <<<"$runs")"

# Newest-first is what the supersession fold rests on: the first row seen per key is the one
# that counts. One row proves nothing about order, so the claim is made on the tip when it has
# several, else on the repository's whole feed, which the same endpoint serves.
if [ "$(jq length <<<"$runs")" -ge 2 ]; then
  pin "runs?head_sha= comes back newest-first (created_at non-increasing, on the tip's $(jq length <<<"$runs") rows)" \
    '[.[].created_at] | . == (sort | reverse)' "$runs"
else
  all_runs=$(api "repos/$REPO/actions/runs?per_page=100" --jq '.workflow_runs')
  pin "actions/runs comes back newest-first (created_at non-increasing, over the latest $(jq length <<<"$all_runs") runs)" \
    '[.[].created_at] | . == (sort | reverse)' "$all_runs"
fi

if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${CONTRACT_OWN_HEAD:-}" ]; then
  own=$(api --paginate "repos/$REPO/actions/runs?head_sha=$CONTRACT_OWN_HEAD&per_page=100" --jq '.workflow_runs' | jq -s 'add')
  pin "this job's own run (id $GITHUB_RUN_ID) is a row on its head, unfinished, with no conclusion" \
    "any(.[]; .id == $GITHUB_RUN_ID and .status != \"completed\" and .conclusion == null)" "$own"
  case "${GITHUB_EVENT_NAME:-}" in
  schedule | workflow_dispatch)
    pin "on a $GITHUB_EVENT_NAME run, this job's own row is the FIRST on its head (newest-first, live)" \
      ".[0].id == $GITHUB_RUN_ID" "$own"
    ;;
  *) skip "the own run is the first row on its head" "on a ${GITHUB_EVENT_NAME:-?} run its siblings are created in the same second" ;;
  esac
else
  skip "this job's own run is the newest row on its head" "not running under Actions (GITHUB_RUN_ID and CONTRACT_OWN_HEAD unset)"
fi

wid=$(jq -r '.[0].workflow_id' <<<"$runs")
wname=$(jq -r '.[0].name' <<<"$runs")
wf=$(api "repos/$REPO/actions/workflows/$wid")
pin "workflow_id resolves to a workflow FILE whose name is the run's name (the fold keys on the file, not the display name)" \
  "(.path | startswith(\".github/workflows/\")) and .name == \"$wname\"" "$wf"

# --- actions/runs/<id>/jobs ---------------------------------------------------------------------
section "actions/runs/<id>/jobs — run_red_is_advisory_only's feed"
all_runs="${all_runs:-$(api "repos/$REPO/actions/runs?per_page=100" --jq '.workflow_runs')}"
red_run=$(jq -r '[.[] | select(.status == "completed" and .conclusion == "failure")][0].id // empty' <<<"$all_runs")
if [ -n "$red_run" ]; then
  jobs=$(api --paginate "repos/$REPO/actions/runs/$red_run/jobs?per_page=100" --jq '.jobs' | jq -s 'add')
  pin "jobs[] rows carry name, status and conclusion (run $red_run, the latest red run)" \
    'type == "array" and all(.[]; (.name | type == "string") and (.status | type == "string") and (.conclusion == null or (.conclusion | type == "string")))' "$jobs"
  pin "job conclusions are in the same vocabulary as run conclusions" \
    "all(.[]; .conclusion == null or (.conclusion as \$c | $CONCLUSION_VOCAB | index(\$c)))" "$jobs"
  pin "a red run's jobs show which job was red: at least one non-green job, or no jobs at all (the startup_failure shape)" \
    'length == 0 or any(.[]; .conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")' "$jobs"
else
  skip "a red run's jobs name the red job" "no failed run among the latest $(jq length <<<"$all_runs")"
fi

# --- commits/<sha>/check-runs ---------------------------------------------------------------------
section "commits/<tip>/check-runs?filter=latest — build_checks's feed"
checks=$(api --paginate "repos/$REPO/commits/$HEAD/check-runs?filter=latest&per_page=100" --jq '.check_runs' | jq -s 'add')
pin "the feed is check_runs[], non-empty on the base tip" 'type == "array" and length >= 1' "$checks"
pin "every check run carries name, status, conclusion (null while unfinished), html_url and app.slug" \
  'all(.[]; (.name | type == "string") and (.status | type == "string") and (.conclusion == null or (.conclusion | type == "string"))
             and (.html_url | type == "string") and (.app.slug | type == "string"))' "$checks"
pin "check-run conclusions are in the vocabulary conclusion_class classifies" \
  "all(.[]; .conclusion == null or (.conclusion as \$c | $CONCLUSION_VOCAB | index(\$c)))" "$checks"
pin "filter=latest yields one check run per name (a re-run does not add a stale twin)" \
  '[.[].name] | length == (unique | length)' "$checks"
job_names='[]'
for rid in $(jq -r '.[] | select(.status == "completed") | .id' <<<"$runs"); do
  job_names=$(api --paginate "repos/$REPO/actions/runs/$rid/jobs?per_page=100" --jq '[.jobs[].name]' | jq -s --argjson acc "$job_names" 'add + $acc')
done
pin "every github-actions check run on the tip is named after a job of one of the tip's runs (the advisory deny-list matches JOB names)" \
  "[.[] | select(.app.slug == \"github-actions\") | .name] | all(.[]; . as \$n | $job_names | index(\$n))" "$checks"

# --- pulls/<n> -----------------------------------------------------------------------------------
section "pulls/<n> — pr_head_read, gate_checks's clock, warn_base_drift and await_mergeable"
if [ -n "$STALE_BASE_PR" ]; then
  pr=$(api "repos/$REPO/pulls/$STALE_BASE_PR")
  pin "the anchor PR #$STALE_BASE_PR is merged, with a merge_commit_sha, a base.sha, a head.sha and a base.ref" \
    "(.merged == true) and (.merge_commit_sha | test(\"$HEX40\")) and (.base.sha | test(\"$HEX40\")) and (.head.sha | test(\"$HEX40\")) and (.base.ref | type == \"string\")" "$pr"
  base_sha=$(jq -r .base.sha <<<"$pr")
  merge_sha=$(jq -r .merge_commit_sha <<<"$pr")
  head_sha=$(jq -r .head.sha <<<"$pr")
  merge_commit=$(api "repos/$REPO/commits/$merge_sha")
  parent1=$(jq -r '.parents[0].sha' <<<"$merge_commit")
  pin "the merge commit's second parent is the PR's head" ".parents[1].sha == \"$head_sha\"" "$merge_commit"
  pin "\`.base.sha\` is a SNAPSHOT, not the base the merge was built on: on #$STALE_BASE_PR it differs from the merge commit's first parent" \
    ".parents[0].sha != \"$base_sha\"" "$merge_commit"
  cmp=$(api "repos/$REPO/compare/$base_sha...$parent1?per_page=1")
  pin "... and the snapshot is BEHIND that parent (an ancestor, so 'behind' counts read off it undercount)" \
    '.status == "ahead" and .behind_by == 0 and .ahead_by >= 1' "$cmp"
  pin "a merged PR's mergeability is not computed: mergeable null, mergeable_state 'unknown'" \
    '.mergeable == null and .mergeable_state == "unknown"' "$pr"
  pin "compare/<a>...<b>?per_page=1 carries behind_by, ahead_by, merge_base_commit.sha and files[].filename (the drift fixture's shape)" \
    '(.behind_by | type == "number") and (.ahead_by | type == "number") and (.merge_base_commit.sha | test("'"$HEX40"'"))
     and (.files | type == "array" and length >= 1 and all(.[]; .filename | type == "string"))' "$cmp"
  pin "... and merge_base_commit is the older side when it is an ancestor" ".merge_base_commit.sha == \"$base_sha\"" "$cmp"
  if jq -e 'any(.files[]; .status == "renamed")' <<<"$cmp" >/dev/null; then
    pin "a renamed entry carries previous_filename" 'all(.files[] | select(.status == "renamed"); .previous_filename | type == "string")' "$cmp"
  else
    skip "a renamed compare entry carries previous_filename" "no rename in the anchor compare"
  fi
else
  skip "base.sha is a stale snapshot on a merged PR" "set CONTRACT_STALE_BASE_PR to a merged PR whose base moved before it merged"
fi

recent=$(api "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=10" --jq '[.[] | select(.merged_at != null)]')
n_recent=$(jq length <<<"$recent")
if [ "$n_recent" -ge 1 ]; then
  ok_all=true
  for n in $(jq -r '.[].number' <<<"$recent"); do
    IFS=$'\t' read -r bs ms <<<"$(api "repos/$REPO/pulls/$n" --jq '[.base.sha, .merge_commit_sha] | @tsv')"
    p1=$(api "repos/$REPO/commits/$ms" --jq '.parents[0].sha')
    st=$(api "repos/$REPO/compare/$bs...$p1?per_page=1" --jq .status)
    case "$st" in identical | ahead) ;; *) ok_all=false; echo "      #$n: base.sha $bs vs first parent $p1: compare status $st" ;; esac
  done
  pin "on the $n_recent most recently merged PRs, base.sha is the merge's first parent or an ancestor of it — never off the base line" \
    ". == true" "$ok_all"
fi

# Mergeability is on the single-PR read only — the list endpoint omits mergeable and
# mergeable_state — which is why pr_head_read reads pulls/<n> per PR. So does this.
open_nums=$(api "repos/$REPO/pulls?state=open&per_page=10" --jq '[.[].number]')
if [ "$(jq length <<<"$open_nums")" -ge 1 ]; then
  open_prs='[]'
  for n in $(jq -r '.[]' <<<"$open_nums"); do
    p=$(api "repos/$REPO/pulls/$n" --jq '{number, head_sha: .head.sha, base_ref: .base.ref, updated_at, mergeable, mergeable_state}')
    cd=$(api "repos/$REPO/commits/$(jq -r .head_sha <<<"$p")" --jq .commit.committer.date)
    open_prs=$(jq -c --argjson p "$p" --arg cd "$cd" '. + [$p + {committed: $cd}]' <<<"$open_prs")
  done
  pin "an open PR's pulls/<n> read carries head.sha, base.ref, updated_at, and mergeable in {true,false,null}" \
    "all(.[]; (.head_sha | test(\"$HEX40\")) and (.base_ref | type == \"string\") and (.updated_at | test(\"$ISO\")) and (.mergeable == true or .mergeable == false or .mergeable == null))" "$open_prs"
  pin "... and a mergeable_state in the vocabulary status_state renders (dirty is CONFLICTS, unknown is not yet computed)" \
    "all(.[]; .mergeable_state as \$m | $MERGEABLE_STATE_VOCAB | index(\$m))" "$open_prs"
  pin "the PR clock is never older than the push: updated_at >= the head's committer date on every open PR (a future-dated commit excepted)" \
    'all(.[]; .updated_at >= .committed or .committed > (now | todate))' "$open_prs"
  echo "      open PRs: $(jq -r '[.[] | "#\(.number) \(.mergeable_state)"] | join(", ")' <<<"$open_prs")"
  if jq -e 'any(.[]; .mergeable_state == "dirty")' <<<"$open_prs" >/dev/null; then
    echo "      a dirty PR is open: that no pull_request run is created for a push made while dirty can be checked on it by hand"
  fi
else
  skip "open PRs' mergeability and clock fields" "no open PR right now"
fi
skip "a push made while mergeable_state=dirty gets no pull_request run" "needs a dirty PR pushed to under observation; not manufactured here"

# --- the reviewer's feeds ----------------------------------------------------------------------------
section "reactions, reviews and comments on a reviewed PR — status_state's and review_rounds's feeds"
if [ -n "$REVIEWED_PR" ]; then
  reactions=$(api --paginate "repos/$REPO/issues/$REVIEWED_PR/reactions?per_page=100" | jq -s 'add')
  pin "reactions carry content, user.login and created_at" \
    "all(.[]; (.content | type == \"string\") and (.user.login | type == \"string\") and (.created_at | test(\"$ISO\")))" "$reactions"
  pin "the app's login carries the [bot] suffix: '$BOT' reacted, and nothing is logged in as bare '$REVIEWER'" \
    "any(.[]; .user.login == \"$BOT\") and all(.[]; .user.login != \"$REVIEWER\")" "$reactions"
  pin "the approval is a '+1' reaction from the app (the merge gate's 👍)" \
    "any(.[]; .content == \"+1\" and .user.login == \"$BOT\")" "$reactions"
  reviews=$(api --paginate "repos/$REPO/pulls/$REVIEWED_PR/reviews?per_page=100" | jq -s 'add')
  pin "reviews carry numeric id, state, commit_id, submitted_at and user.login" \
    "all(.[]; (.id | type == \"number\") and (.state | type == \"string\") and (.commit_id | test(\"$HEX40\")) and (.submitted_at == null or (.submitted_at | test(\"$ISO\"))) and (.user.login | type == \"string\"))" "$reviews"
  pin "review states are in the vocabulary" "all(.[]; .state as \$s | $REVIEW_STATE_VOCAB | index(\$s))" "$reviews"
  pin "a round with findings is COMMENTED reviews from the app, and the approval is NOT an APPROVED review (it is the reaction above)" \
    "any(.[]; .user.login == \"$BOT\" and .state == \"COMMENTED\") and all(.[] | select(.user.login == \"$BOT\"); .state != \"APPROVED\")" "$reviews"
  pin "the author's own replies appear in the same feed as COMMENTED reviews (so 'new' must be id > watermark, not a count)" \
    "any(.[]; .user.login != \"$BOT\" and .state == \"COMMENTED\")" "$reviews"
  comments=$(api --paginate "repos/$REPO/issues/$REVIEWED_PR/comments?per_page=100" | jq -s 'add')
  pin "issue comments carry numeric id, created_at, updated_at, body and user.login" \
    "all(.[]; (.id | type == \"number\") and (.created_at | test(\"$ISO\")) and (.updated_at | test(\"$ISO\")) and (.body | type == \"string\") and (.user.login | type == \"string\"))" "$comments"
  pin "the app's summary comment carries the codex-pull-request-review-summary machine tag" \
    "any(.[]; .user.login == \"$BOT\" and (.body | test(\"codex-pull-request-review-summary\")))" "$comments"
  inline_all=$(api --paginate "repos/$REPO/pulls/$REVIEWED_PR/comments?per_page=100" | jq -s 'add')
  inline_page=$(api "repos/$REPO/pulls/$REVIEWED_PR/comments")
  pin "inline comments carry numeric id, pull_request_review_id, commit_id and user.login" \
    "all(.[]; (.id | type == \"number\") and (.pull_request_review_id | type == \"number\") and (.commit_id | test(\"$HEX40\")) and (.user.login | type == \"string\"))" "$inline_all"
  pin "the flat listing paginates at 30 by default: an unpaginated read of #$REVIEWED_PR's $(jq length <<<"$inline_all") inline comments returns 30" \
    "length == 30 and $(jq length <<<"$inline_all") > 30" "$inline_page"
  first_review=$(jq -r "[.[] | select(.user.login == \"$BOT\" and .state == \"COMMENTED\")][0].id" <<<"$reviews")
  per_review=$(api --paginate "repos/$REPO/pulls/$REVIEWED_PR/reviews/$first_review/comments?per_page=100" | jq -s 'add')
  pin "a review's own comments endpoint answers, and its ids are a subset of the flat listing's (the merge-by-id read)" \
    "length >= 1 and all(.[].id; . as \$i | $(jq -c '[.[].id]' <<<"$inline_all") | index(\$i))" "$per_review"
else
  skip "the reviewer feeds' shapes" "set CONTRACT_REVIEWED_PR to a PR the review app reviewed and approved"
fi
skip "reviewThreads (GraphQL) pagination at 100" "the resolve path is the one GraphQL read, and it is not exercised here"
skip "compare's 300-file cap" "no compare of that size exists in this repository"

# --- the verdict --------------------------------------------------------------------------------------
section "verdict"
echo "$CLAIMS beliefs checked, $MOVED moved, $SKIPPED unpinned here"
[ "$MOVED" -eq 0 ] || { echo "pr-review-api-contract.sh: $MOVED belief(s) the fixtures encode no longer hold on $REPO — see MOVED above" >&2; exit 1; }

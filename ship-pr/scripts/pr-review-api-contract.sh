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
#   CONTRACT_REVIEWED_PR     a PR the review app reviewed with at least one round of inline
#                            findings AND approved (ludics-lite#39) — the reactions, reviews and
#                            comments beliefs of the status/rounds suites; the pagination belief
#                            needs more than 30 inline comments and skips on a smaller anchor
#   CONTRACT_OWN_HEAD        under Actions: the head this job's own run is attached to
#                            (github.event.pull_request.head.sha, else github.sha); with
#                            GITHUB_RUN_ID it pins the job's own row as the newest for that head
#   REVIEWER                 the review app's login without its [bot] suffix (pr-review.sh's)
#
# Exit 0: every checkable belief holds. 1: at least one MOVED (listed, all of them — the script
# does not stop at the first). 3: the API did not answer (no answer, a 5xx, a request timeout —
# 408, 425 — or throttling — 429 or a 403 naming a rate limit — after retries), which is not a
# moved belief and ends the run
# at once — every read is an assignment under errexit, so a failed read cannot feed empty data
# into the claims after it. 4: an endpoint or anchor the contract addresses answered a 4xx other
# than those — the input was validated, so this is a retired or renamed endpoint (drift), or a
# wrong anchor; it ends the run the same way. 5: the read was refused (401/403 that is not a rate
# limit) — the token or the workflow's permissions, not a moved belief, but a red a schedule
# would otherwise hide. Any other exit is the contract stopping early, and the EXIT trap says
# so; the workflow reports every exit but 0 and 3, naming which. A belief this repository
# cannot check prints as `skip`, with the reason, so the unpinned set is visible in every run
# rather than assumed away.

set -euo pipefail

# pr-review.sh itself, sourced without running: the contract encodes a branch name with the
# library's own encode_ref, so the anchor read below exercises the encoder warn_base_drift uses,
# rather than a restatement of it. Every function this file defines comes after this line and
# shares no name with the library's (the trap test-pr-review-lib.sh guards the suites against).
export SHIP_PR_TEST_SOURCE_ONLY=1
# shellcheck source=pr-review.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/pr-review.sh"

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

# api <gh api args...>: one read, of the raw body — never with --jq. A projection that fails
# inside gh exits nonzero with no HTTP status, indistinguishable from transport, so every
# projection is a local jq on the body, where a wrong shape is a claim (MOVED) or an early stop
# the EXIT trap names — reported either way, never a suppressed exit 3. The HTTP status sorts
# the failures. Throttling (429, or a 403 naming a rate limit), a 5xx and no answer at all are
# retried three times and are then transport — exit 3, not drift, left to the next run. 401 and
# 403 otherwise are the token or the workflow's permissions refusing the read — exit 5, not
# drift either, but reported. Any other 4xx is the API answering "no such thing" about an input
# this script validated before asking: a retired or renamed endpoint, or a wrong anchor — exit
# 4, drift, no retry. Each ends the run from inside a command substitution too: the caller's
# assignment fails, and the script runs under errexit.
api() {
  local attempt out
  case " $* " in
  *" --jq "* | *" --jq="* | *" -q "*)
    echo "pr-review-api-contract.sh: api takes no --jq — project the body locally, where a wrong shape is a claim and not a transport failure: gh api $*" >&2
    exit 2
    ;;
  esac
  for attempt in 1 2 3; do
    if out=$(gh api "$@" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
    case "$out" in
    # The 4xx about the connection rather than the request: throttling, and a request timeout.
    *"HTTP 429"* | *"HTTP 408"* | *"HTTP 425"* | *"rate limit"* | *"Rate limit"*) ;; # retried, transport if it persists
    *"HTTP 401"* | *"HTTP 403"*)
      echo "pr-review-api-contract.sh: the API refused the read (the token or the workflow's permissions, not a moved belief): gh api $* -> ${out##*$'\n'}" >&2
      exit 5
      ;;
    *"HTTP 4"[0-9][0-9]*)
      echo "pr-review-api-contract.sh: an endpoint the contract addresses answered 4xx (retired, renamed, or a wrong anchor): gh api $* -> ${out##*$'\n'}" >&2
      exit 4
      ;;
    esac
    [ "$attempt" -eq 3 ] || sleep $((attempt * 5))
  done
  echo "pr-review-api-contract.sh: the API did not answer: gh api $* -> ${out##*$'\n'}" >&2
  exit 3
}

# Paginated wrapper lists: gh emits one body per page, and the pages' <field> lists are joined
# here — null when any page lacks the list, so the wrapper claim after the read records the
# MOVED and the row-level claims skip on an unusable input.
pages() { # <field>
  jq -s --arg f "$1" 'if length > 0 and all(.[]; type == "object" and (.[$f] | type == "array")) then map(.[$f]) | add else null end'
}

# Scratch files, for the lists a claim compares against: the paginated feed of a long-reviewed
# PR is over Linux's per-argument limit (the rounds suite's known trap), and a head's job-name
# list grows with every re-run, so a list never rides the argument vector — a claim's subject
# arrives on stdin and its comparison lists through --slurpfile (each read as $name[0]).
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/pr-review-api-contract.XXXXXX")

# Any exit this script did not choose — a jq that cannot iterate a wrapper that moved, say — is
# named here, so the log says what stopped and the workflow's reporter (every exit but 0 and 3)
# has something to point at. pr-review.sh's own trap is folded in.
on_exit() {
  local rc=$?
  rm -f "$GH_ERR_FILE"
  rm -rf "$SCRATCH"
  case "$rc" in
  0 | 1 | 2 | 3 | 4 | 5) ;;
  *) echo "pr-review-api-contract.sh: the contract stopped early with exit $rc after $CLAIMS beliefs ($MOVED moved): a shape it did not expect, most likely — read the log as drift until shown otherwise" >&2 ;;
  esac
}
trap on_exit EXIT

# pin <belief> <jq filter> <json> [jq args...]: the filter must yield true on the json. A value
# the filter compares against travels as a jq argument (--arg / --argjson), never interpolated
# into the program, so a legal but odd value (a quote in a workflow name) cannot change its syntax.
pin() {
  local belief="$1" filter="$2" json="$3"
  shift 3
  CLAIMS=$((CLAIMS + 1))
  if jq -e "$@" "$filter" <<<"$json" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$belief"
  else
    MOVED=$((MOVED + 1))
    printf 'MOVED %s\n      filter: %s\n      read:   %s\n' "$belief" "$filter" \
      "$(jq -c . <<<"$json" 2>/dev/null | cut -c1-400)"
  fi
}

# A read built from a field another read returned validates that field first: a field that moved
# has already been recorded MOVED above, and the dependent request would only turn that drift
# into a 404 — exit 3, transport — and hide every MOVED line after it.
is_sha() { case "$1" in *[!0-9a-f]* | '') return 1 ;; esac; [ "${#1}" -eq 40 ]; }
is_num() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
# A list whose wrapper moved arrives as null; row-level claims on it would crash a jq under
# errexit instead of standing behind the MOVED the wrapper claim recorded.
is_list() { jq -e 'type == "array"' <<<"$1" >/dev/null 2>&1; }
UNUSABLE="its input is not usable — see the MOVED above"

skip() { # <belief> <why>
  SKIPPED=$((SKIPPED + 1))
  printf 'skip  %s — %s\n' "$1" "$2"
}

section() { printf '\n== %s\n' "$*"; }

# --- the anchors ------------------------------------------------------------------------------
section "anchors on $REPO"
if [ -n "${CONTRACT_BASE:-}" ]; then
  BASE="$CONTRACT_BASE"
else
  repo=$(api "repos/$REPO")
  pin "repos/<owner/name> carries default_branch (the drift anchor's ref when none is given)" \
    '.default_branch | type == "string" and length > 0' "$repo"
  BASE=$(jq -r '.default_branch // empty' <<<"$repo")
  [ -n "$BASE" ] || { echo "pr-review-api-contract.sh: the repository read carries no default branch; nothing below can be anchored (1 moved)" >&2; exit 1; }
fi
# The ref goes through the library's encoder, as warn_base_drift's tip read sends it: a legal
# name such as release#1 would otherwise become a URL fragment.
tip=$(api "repos/$REPO/commits/$(encode_ref "$BASE")")
pin "commits/<encode_ref branch> answers the branch tip's sha and committer date (the drift anchor and the push clock)" \
  "(.sha | test(\"$HEX40\")) and (.commit.committer.date | test(\"$ISO\"))" "$tip"
HEAD=$(jq -r '.sha // empty' <<<"$tip")
is_sha "$HEAD" || { echo "pr-review-api-contract.sh: the tip read carries no usable sha; nothing below can be anchored (1 moved)" >&2; exit 1; }
echo "      base $BASE tip $HEAD"

# --- actions/runs?head_sha= -------------------------------------------------------------------
section "actions/runs?head_sha=<tip> — run_signal's feed"
# The newest 100 rows, not the whole history: these are shape claims, a sample carries them, and
# a tip that accumulates a scheduled run a day would otherwise grow every read without bound.
runs=$(api "repos/$REPO/actions/runs?head_sha=$HEAD&per_page=100" | pages workflow_runs)
pin "the feed is workflow_runs[]" 'type == "array"' "$runs"
# An empty list is a valid signal the gate handles (a paths-ignored push, a repository without
# push workflows), not a moved shape: the row-level claims need a sample, and say so without one.
if ! is_list "$runs"; then
  skip "the row-level claims on the tip's runs" "$UNUSABLE"
  runs='[]'
elif [ "$(jq length <<<"$runs")" -eq 0 ]; then
  skip "the row-level claims on the tip's runs" "the tip has no Actions run (a paths-ignored push, or a repository without push workflows)"
else
pin "every row carries the fields the fold indexes: numeric id and workflow_id, string event, name and status, created_at" \
  'all(.[]; (.id | type == "number") and (.workflow_id | type == "number") and (.event | type == "string" and length > 0)
             and (.name | type == "string") and (.status | type == "string") and (.created_at | test("'"$ISO"'")))' "$runs"
pin "every row's head_sha is the sha asked for (the filter filters)" \
  'all(.[]; .head_sha == $head)' "$runs" --arg head "$HEAD"
pin "status strings are in the known vocabulary" \
  "all(.[]; .status as \$s | $STATUS_VOCAB | index(\$s))" "$runs"
# A nullable field is asserted PRESENT and then null-or-valid: jq reads an absent key as null,
# so `== null` alone would pass a feed that dropped the field — which the projections would read
# as pending forever (`.conclusion // "pending"`), the silent direction.
pin "every row carries conclusion (present, null until completed) and it is in the vocabulary conclusion_class classifies" \
  "all(.[]; has(\"conclusion\") and (.conclusion == null or (.conclusion as \$c | $CONCLUSION_VOCAB | index(\$c))))" "$runs"
pin "a row that is not completed has no conclusion yet" \
  'all(.[]; .status == "completed" or .conclusion == null)' "$runs"
echo "      events seen on the tip: $(jq -r '[.[].event] | unique | join(" ")' <<<"$runs")"
echo "      status/conclusion seen: $(jq -r '[.[] | "\(.status)/\(.conclusion)"] | unique | join(" ")' <<<"$runs")"
fi

# Newest-first is what the supersession fold rests on: the first row seen per key is the one
# that counts. One row proves nothing about order, so the claim is made on the tip when it has
# several, else on the repository's whole feed, which the same endpoint serves.
if [ "$(jq length <<<"$runs")" -ge 2 ]; then
  pin "runs?head_sha= comes back newest-first (created_at non-increasing, on the tip's $(jq length <<<"$runs") rows)" \
    '[.[].created_at] | . == (sort | reverse)' "$runs"
else
  all_runs=$(api "repos/$REPO/actions/runs?per_page=100" | pages workflow_runs)
  pin "actions/runs is workflow_runs[] here too" 'type == "array"' "$all_runs"
  if is_list "$all_runs" && [ "$(jq length <<<"$all_runs")" -ge 2 ]; then
    pin "actions/runs comes back newest-first (created_at non-increasing, over the latest $(jq length <<<"$all_runs") runs)" \
      '[.[].created_at] | . == (sort | reverse)' "$all_runs"
  else
    skip "actions/runs comes back newest-first" "fewer than two runs to order, or the list is not usable"
  fi
fi

if is_num "${GITHUB_RUN_ID:-}" && is_sha "${CONTRACT_OWN_HEAD:-}"; then
  own=$(api "repos/$REPO/actions/runs?head_sha=$CONTRACT_OWN_HEAD&per_page=100" | pages workflow_runs) # the own run is among the newest on its head
  is_list "$own" || own='[]' # the wrapper claim above has recorded the MOVED; these then move too, on an empty list
  pin "this job's own run (id $GITHUB_RUN_ID) is a row on its head, unfinished, with no conclusion" \
    'any(.[]; .id == $run and .status != "completed" and .conclusion == null)' "$own" --argjson run "$GITHUB_RUN_ID"
  # On a scheduled or dispatched run the head is the base tip, whose push run came long before
  # this one, so the list has at least two rows created apart — a live newest-first check on a
  # filtered head. Not "this run is row 0": another workflow dispatched on the same SHA after
  # this run was created may rightly sit above it.
  case "${GITHUB_EVENT_NAME:-}" in
  schedule | workflow_dispatch)
    pin "on a $GITHUB_EVENT_NAME run, runs?head_sha= for this job's own head ($(jq length <<<"$own") rows) is newest-first by created_at, live" \
      'length >= 2 and ([.[].created_at] | . == (sort | reverse))' "$own"
    ;;
  *) skip "newest-first on a multi-row head, live" "on a ${GITHUB_EVENT_NAME:-?} run the head's rows are created in the same second" ;;
  esac
else
  skip "this job's own run is a row on its head, and that head is newest-first" "not running under Actions (GITHUB_RUN_ID and CONTRACT_OWN_HEAD unset)"
fi

wid=$(jq -r '.[0].workflow_id // empty' <<<"$runs")
wname=$(jq -r '.[0].name // empty' <<<"$runs")
if is_num "$wid"; then
  wf=$(api "repos/$REPO/actions/workflows/$wid")
  pin "workflow_id resolves to a workflow FILE whose name is the run's name (the fold keys on the file, not the display name)" \
    '(.path | startswith(".github/workflows/")) and .name == $wname' "$wf" --arg wname "$wname"
else
  skip "workflow_id resolves to a workflow file" "$UNUSABLE"
fi

# --- actions/runs/<id>/jobs ---------------------------------------------------------------------
section "actions/runs/<id>/jobs — run_red_is_advisory_only's feed"
all_runs="${all_runs:-$(api "repos/$REPO/actions/runs?per_page=100" | pages workflow_runs)}"
# The sample is the latest run of ANY conclusion conclusion_class calls red, since the advisory
# read runs for each of them, not only for `failure`.
red_run=""
if is_list "$all_runs"; then
  red_run=$(jq -r '[.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure"))][0].id // empty' <<<"$all_runs")
fi
if is_num "$red_run"; then
  red_concl=$(jq -r --argjson id "$red_run" '.[] | select(.id == $id) | .conclusion' <<<"$all_runs")
  jobs=$(api --paginate "repos/$REPO/actions/runs/$red_run/jobs?per_page=100" | pages jobs)
  pin "the feed is jobs[] (run $red_run, the latest red run: $red_concl)" 'type == "array"' "$jobs"
  is_list "$jobs" || jobs='[]'
  pin "jobs[] rows carry name, status and conclusion (present, null while unfinished)" \
    'all(.[]; (.name | type == "string") and (.status | type == "string") and has("conclusion") and (.conclusion == null or (.conclusion | type == "string")))' "$jobs"
  pin "job conclusions are in the same vocabulary as run conclusions" \
    "all(.[]; .conclusion == null or (.conclusion as \$c | $CONCLUSION_VOCAB | index(\$c)))" "$jobs"
  # The belief run_red_is_advisory_only rests on: it discards a run's red when no non-advisory
  # job is HARD red (failure, timed_out, startup_failure — conclusion_class's red), so a red run
  # whose jobs were all cancelled or stale would lose its red silently. A MOVED here is a gap in
  # that projection, which is the direction the contract exists to show.
  pin "a red run's jobs carry the red: at least one job concluded failure, timed_out or startup_failure, or no jobs at all (the startup_failure shape)" \
    'length == 0 or any(.[]; .conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")' "$jobs"
elif is_list "$all_runs"; then
  skip "a red run's jobs name the red job" "no failure, timed_out or startup_failure run among the latest $(jq length <<<"$all_runs")"
else
  skip "a red run's jobs name the red job" "$UNUSABLE"
fi

# --- commits/<sha>/check-runs ---------------------------------------------------------------------
section "commits/<tip>/check-runs?filter=latest — build_checks's feed"
checks=$(api "repos/$REPO/commits/$HEAD/check-runs?filter=latest&per_page=100" | pages check_runs) # the first 100: a sample, like the runs
pin "the feed is check_runs[]" 'type == "array"' "$checks"
if ! is_list "$checks"; then
  skip "the row-level claims on the tip's check runs" "$UNUSABLE"
elif [ "$(jq length <<<"$checks")" -eq 0 ]; then
  skip "the row-level claims on the tip's check runs" "the tip has no check run (nothing ran on it, or nothing has created its checks yet)"
else
pin "every check run carries name, status, conclusion (present, null while unfinished), html_url and app.slug" \
  'all(.[]; (.name | type == "string") and (.status | type == "string") and has("conclusion") and (.conclusion == null or (.conclusion | type == "string"))
             and (.html_url | type == "string") and (.app.slug | type == "string"))' "$checks"
pin "check-run conclusions are in the vocabulary conclusion_class classifies" \
  "all(.[]; .conclusion == null or (.conclusion as \$c | $CONCLUSION_VOCAB | index(\$c)))" "$checks"
pin "every check run carries a check_suite.id (build_checks reads by name across every suite and provider)" \
  'all(.[]; .check_suite.id | type == "number")' "$checks"
# What build_checks asks of filter=latest is not uniqueness — two jobs may legally share a name,
# and it emits one row per check run — but that a re-run's superseded attempt is DROPPED, since
# a stale red twin would otherwise redden the head. So the belief is stated against filter=all:
# latest is a subset of all by id, and every row all has that latest lacks is superseded by a
# newer (higher-id) row of the same suite and name. The second half needs a re-run on the tip
# to be non-vacuous, and says so when there is none.
checks_all=$(api "repos/$REPO/commits/$HEAD/check-runs?filter=all&per_page=100" | pages check_runs)
if ! is_list "$checks_all"; then
  skip "filter=latest drops a re-run's superseded attempt" "the filter=all read is not a list — $UNUSABLE"
elif [ "$(jq length <<<"$checks_all")" -ge 100 ]; then
  skip "filter=latest drops a re-run's superseded attempt" "the tip has a page or more of check runs under filter=all; the sample cannot be compared whole"
else
  jq -c '[.[].id]' <<<"$checks" >"$SCRATCH/latest_ids.json"
  printf '%s\n' "$checks" >"$SCRATCH/latest.json"
  pin "filter=latest is a subset of filter=all by id (it filters; it does not invent rows)" \
    '[.[].id] as $all | $latest[0] | all(.[]; . as $i | $all | index($i))' "$checks_all" --slurpfile latest "$SCRATCH/latest_ids.json"
  if [ "$(jq length <<<"$checks_all")" -gt "$(jq length <<<"$checks")" ]; then
    pin "every check run filter=all has that filter=latest lacks is a superseded attempt: a newer row of the same suite and name is in filter=latest (no stale twin, and no uniqueness asked of same-named jobs)" \
      '[.[] | select(.id as $i | $latest[0] | index($i) | not)]
       | all(.[]; .check_suite.id as $s | .name as $n | .id as $i | $lat[0] | any(.[]; .check_suite.id == $s and .name == $n and .id > $i))' \
      "$checks_all" --slurpfile latest "$SCRATCH/latest_ids.json" --slurpfile lat "$SCRATCH/latest.json"
  else
    skip "filter=latest drops a re-run's superseded attempt" "no re-run on the tip: filter=all and filter=latest have the same $(jq length <<<"$checks") rows"
  fi
fi
# A check run's suite is its run's — check_suite.id on the check joins check_suite_id on the run
# — so the correlation is exact (a check is named after a job of ITS run, not of some run on the
# tip) and bounded: the newest CORRELATE runs, whatever their status, since a check run exists
# only once its job does and a tip whose run is still queued has no completed run yet. One jobs
# read per run in the sample, never per run in the history: a tip accumulating a scheduled run
# a day would otherwise grow the loop without bound. Read AFTER the checks: a run exists before
# any of its checks, so a snapshot taken after the check read cannot lack the run behind a check
# — while the earlier snapshot could, for a workflow started on the tip in between. The names
# accumulate in a file and reach the claim through --slurpfile, off the argument vector.
CORRELATE=10
runs_after=$(api "repos/$REPO/actions/runs?head_sha=$HEAD&per_page=$CORRELATE" | pages workflow_runs)
correlation="every github-actions check run of the tip's newest $CORRELATE runs is named after a job of ITS run (the advisory deny-list matches JOB names)"
if ! is_list "$runs_after"; then
  skip "$correlation" "$UNUSABLE"
else
  pin "every run row carries a numeric check_suite_id (the join to a check run's check_suite.id)" \
    'all(.[]; .check_suite_id | type == "number")' "$runs_after"
  : >"$SCRATCH/suite_jobs"
  jobs_unusable=""
  for pair in $(jq -r '.[] | "\(.id // "-"):\(.check_suite_id // "-")"' <<<"$runs_after"); do
    rid=${pair%%:*}
    sid=${pair#*:}
    if ! is_num "$rid" || ! is_num "$sid"; then
      jobs_unusable=1
      continue
    fi
    api --paginate "repos/$REPO/actions/runs/$rid/jobs?per_page=100" | jq -c --argjson sid "$sid" '{suite: ($sid | tostring), jobs: [.jobs[]?.name]}' >>"$SCRATCH/suite_jobs"
  done
  jq -s 'group_by(.suite) | map({key: .[0].suite, value: (map(.jobs) | add | unique)}) | from_entries' "$SCRATCH/suite_jobs" >"$SCRATCH/suite_jobs.json"
  in_sample=$(jq --slurpfile m "$SCRATCH/suite_jobs.json" '[.[] | select(.app.slug == "github-actions") | select((.check_suite.id | tostring) as $s | $m[0] | has($s))] | length' <<<"$checks")
  if [ -n "$jobs_unusable" ]; then
    skip "$correlation" "a run row has no usable id or check_suite_id — see the MOVED above"
  elif [ "$in_sample" -eq 0 ]; then
    skip "$correlation" "none of the tip's check runs belongs to its newest $CORRELATE runs' suites (their jobs have not started yet)"
  else
    pin "$correlation, on $in_sample check runs" \
      '[.[] | select(.app.slug == "github-actions") | select((.check_suite.id | tostring) as $s | $m[0] | has($s))]
       | all(.[]; (.check_suite.id | tostring) as $s | .name as $n | $m[0][$s] | index($n))' "$checks" --slurpfile m "$SCRATCH/suite_jobs.json"
  fi
fi
fi

# --- pulls/<n> -----------------------------------------------------------------------------------
section "pulls/<n> — pr_head_read, gate_checks's clock, warn_base_drift and await_mergeable"
if [ -n "$STALE_BASE_PR" ]; then
  pr=$(api "repos/$REPO/pulls/$STALE_BASE_PR")
  pin "the anchor PR #$STALE_BASE_PR is merged, with a merge_commit_sha, a base.sha, a head.sha and a base.ref" \
    "(.merged == true) and (.merge_commit_sha | test(\"$HEX40\")) and (.base.sha | test(\"$HEX40\")) and (.head.sha | test(\"$HEX40\")) and (.base.ref | type == \"string\")" "$pr"
  pin "a merged PR's mergeability is not computed: mergeable present and null, mergeable_state 'unknown'" \
    'has("mergeable") and .mergeable == null and .mergeable_state == "unknown"' "$pr"
  base_sha=$(jq -r '.base.sha // empty' <<<"$pr")
  merge_sha=$(jq -r '.merge_commit_sha // empty' <<<"$pr")
  head_sha=$(jq -r '.head.sha // empty' <<<"$pr")
  parent1=""
  if is_sha "$base_sha" && is_sha "$merge_sha" && is_sha "$head_sha"; then
    merge_commit=$(api "repos/$REPO/commits/$merge_sha")
    parent1=$(jq -r '.parents[0].sha // empty' <<<"$merge_commit")
    pin "the merge commit's second parent is the PR's head" '.parents[1].sha == $head' "$merge_commit" --arg head "$head_sha"
    pin "\`.base.sha\` is a SNAPSHOT, not the base the merge was built on: on #$STALE_BASE_PR it differs from the merge commit's first parent" \
      '.parents[0].sha != $base' "$merge_commit" --arg base "$base_sha"
  else
    skip "the anchor PR's merge commit and the base.sha snapshot" "$UNUSABLE"
  fi
  if is_sha "$parent1" && [ "$parent1" != "$base_sha" ]; then
    cmp=$(api "repos/$REPO/compare/$base_sha...$parent1?per_page=1")
    pin "... and the snapshot is BEHIND that parent (an ancestor, so 'behind' counts read off it undercount)" \
      '.status == "ahead" and .behind_by == 0 and .ahead_by >= 1' "$cmp"
    pin "compare/<a>...<b>?per_page=1 carries behind_by, ahead_by, merge_base_commit.sha and files[].filename (the drift fixture's shape)" \
      '(.behind_by | type == "number") and (.ahead_by | type == "number") and (.merge_base_commit.sha | test($hex))
       and (.files | type == "array" and length >= 1 and all(.[]; .filename | type == "string"))' "$cmp" --arg hex "$HEX40"
    pin "... and merge_base_commit is the older side when it is an ancestor" '.merge_base_commit.sha == $base' "$cmp" --arg base "$base_sha"
    if jq -e 'any(.files[]; .status == "renamed")' <<<"$cmp" >/dev/null; then
      pin "a renamed entry carries previous_filename" 'all(.files[] | select(.status == "renamed"); .previous_filename | type == "string")' "$cmp"
    else
      skip "a renamed compare entry carries previous_filename" "no rename in the anchor compare"
    fi
  else
    skip "the compare between the base.sha snapshot and the merge's first parent" "$UNUSABLE"
  fi
else
  skip "base.sha is a stale snapshot on a merged PR" "set CONTRACT_STALE_BASE_PR to a merged PR whose base moved before it merged"
fi

# Merged first, then the cut: closed-unmerged PRs would otherwise eat the sample, silently — and
# merged_at is asserted present, since a dropped field would empty the sample the same way.
closed=$(api "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=100")
pin "pulls?state=closed is a list whose rows carry merged_at (present, null when closed unmerged)" \
  'type == "array" and all(.[]; has("merged_at"))' "$closed"
is_list "$closed" || closed='[]'
recent=$(jq -c '[.[] | select(.merged_at != null)] | .[0:10]' <<<"$closed")
n_recent=$(jq length <<<"$recent")
if [ "$n_recent" -ge 1 ]; then
  ok_all=true
  for n in $(jq -r '.[].number // "-"' <<<"$recent"); do
    if ! is_num "$n"; then
      ok_all=false
      echo "      a merged row of the closed-PR list has no numeric number ($n)"
      continue
    fi
    p=$(api "repos/$REPO/pulls/$n")
    bs=$(jq -r '.base.sha // "-"' <<<"$p")
    ms=$(jq -r '.merge_commit_sha // "-"' <<<"$p")
    if ! is_sha "$bs" || ! is_sha "$ms"; then
      ok_all=false
      echo "      #$n: base.sha or merge_commit_sha is not a sha ($bs, $ms)"
      continue
    fi
    p1=$(api "repos/$REPO/commits/$ms" | jq -r '.parents[0].sha // "-"')
    if ! is_sha "$p1"; then
      ok_all=false
      echo "      #$n: the merge commit has no first parent sha ($p1)"
      continue
    fi
    st=$(api "repos/$REPO/compare/$bs...$p1?per_page=1" | jq -r '.status // "-"')
    case "$st" in identical | ahead) ;; *) ok_all=false; echo "      #$n: base.sha $bs vs first parent $p1: compare status $st" ;; esac
  done
  pin "on the $n_recent most recently merged PRs (of the latest 100 closed), base.sha is the merge's first parent or an ancestor of it — never off the base line" \
    ". == true" "$ok_all"
else
  skip "base.sha stays on the base line across recently merged PRs" "no merged PR among the latest 100 closed"
fi

# Mergeability is on the single-PR read only — the list endpoint omits mergeable and
# mergeable_state — which is why pr_head_read reads pulls/<n> per PR. So does this.
open_list=$(api "repos/$REPO/pulls?state=open&per_page=10")
pin "pulls?state=open is a list" 'type == "array"' "$open_list"
is_list "$open_list" || open_list='[]'
if [ "$(jq length <<<"$open_list")" -ge 1 ]; then
  pin "every row of the open-PR list carries a numeric number" 'all(.[]; .number | type == "number")' "$open_list"
  # One projected row per PR, accumulated in a file: mergeable is nullable, so an absent key is
  # projected as "absent" rather than read as null, and fails the {true,false,null} claim.
  : >"$SCRATCH/open_prs"
  for n in $(jq -r '.[].number // "-"' <<<"$open_list"); do
    is_num "$n" || continue # recorded MOVED just above; no request is built from it
    api "repos/$REPO/pulls/$n" | jq -c '{number, head_sha: .head.sha, base_ref: .base.ref, updated_at,
      mergeable: (if has("mergeable") then .mergeable else "absent" end), mergeable_state}' >>"$SCRATCH/open_prs"
  done
  open_prs=$(jq -s . "$SCRATCH/open_prs")
  pin "an open PR's pulls/<n> read carries head.sha, base.ref, updated_at, and mergeable (present) in {true,false,null}" \
    "all(.[]; (.head_sha | test(\"$HEX40\")) and (.base_ref | type == \"string\") and (.updated_at | test(\"$ISO\")) and (.mergeable == true or .mergeable == false or .mergeable == null))" "$open_prs"
  pin "... and a mergeable_state in the vocabulary status_state renders (dirty is CONFLICTS, unknown is not yet computed)" \
    "all(.[]; .mergeable_state as \$m | $MERGEABLE_STATE_VOCAB | index(\$m))" "$open_prs"
  echo "      open PRs: $(jq -r '[.[] | "#\(.number) \(.mergeable_state)"] | join(", ")' <<<"$open_prs")"
  if jq -e 'any(.[]; .mergeable_state == "dirty")' <<<"$open_prs" >/dev/null; then
    echo "      a dirty PR is open: that no pull_request run is created for a push made while dirty can be checked on it by hand"
  fi
else
  skip "open PRs' mergeability and clock fields" "no open PR right now"
fi
skip "a push made while mergeable_state=dirty gets no pull_request run" "needs a dirty PR pushed to under observation; not manufactured here"
# The push clock: gate_checks reads updated_at because a push to the head branch moves it. The
# push time itself is not an API field, and a committer date is not one either (a skewed or
# assigned date can be later than the real push), so the belief was measured live on
# ludics-lite#38 (09:12:31Z before a push, 09:17:29Z five seconds after) and is not re-checkable
# without pushing; the field's shape on the single-PR read is pinned above.
skip "a push moves the PR's updated_at (the push clock)" "push time is not an API field; measured live on ludics-lite#38, not re-checkable without a push"

# --- the reviewer's feeds ----------------------------------------------------------------------------
section "reactions, reviews and comments on a reviewed PR — status_state's and review_rounds's feeds"
if [ -n "$REVIEWED_PR" ]; then
  reactions=$(api --paginate "repos/$REPO/issues/$REVIEWED_PR/reactions?per_page=100" | jq -s 'add')
  pin "the reactions feed is a list" 'type == "array"' "$reactions"
  is_list "$reactions" || reactions='[]'
  pin "reactions carry content, user.login and created_at" \
    "all(.[]; (.content | type == \"string\") and (.user.login | type == \"string\") and (.created_at | test(\"$ISO\")))" "$reactions"
  pin "the app's login carries the [bot] suffix: '$BOT' reacted, and nothing is logged in as bare '$REVIEWER'" \
    'any(.[]; .user.login == $bot) and all(.[]; .user.login != $rev)' "$reactions" --arg bot "$BOT" --arg rev "$REVIEWER"
  pin "the approval is a '+1' reaction from the app (the merge gate's 👍)" \
    'any(.[]; .content == "+1" and .user.login == $bot)' "$reactions" --arg bot "$BOT"
  reviews=$(api --paginate "repos/$REPO/pulls/$REVIEWED_PR/reviews?per_page=100" | jq -s 'add')
  pin "the reviews feed is a list" 'type == "array"' "$reviews"
  is_list "$reviews" || reviews='[]'
  pin "reviews carry numeric id, state, commit_id, submitted_at (present, null while pending), user.login and a body (poll renders it)" \
    "all(.[]; (.id | type == \"number\") and (.state | type == \"string\") and (.commit_id | test(\"$HEX40\")) and has(\"submitted_at\") and (.submitted_at == null or (.submitted_at | test(\"$ISO\"))) and (.user.login | type == \"string\") and has(\"body\"))" "$reviews"
  pin "review states are in the vocabulary" "all(.[]; .state as \$s | $REVIEW_STATE_VOCAB | index(\$s))" "$reviews"
  pin "a round with findings is COMMENTED reviews from the app, and the approval is NOT an APPROVED review (it is the reaction above)" \
    'any(.[]; .user.login == $bot and .state == "COMMENTED") and all(.[] | select(.user.login == $bot); .state != "APPROVED")' "$reviews" --arg bot "$BOT"
  pin "the author's own replies appear in the same feed as COMMENTED reviews (so 'new' must be id > watermark, not a count)" \
    'any(.[]; .user.login != $bot and .state == "COMMENTED")' "$reviews" --arg bot "$BOT"
  comments=$(api --paginate "repos/$REPO/issues/$REVIEWED_PR/comments?per_page=100" | jq -s 'add')
  pin "the issue-comments feed is a list" 'type == "array"' "$comments"
  is_list "$comments" || comments='[]'
  pin "issue comments carry numeric id, created_at, updated_at, body and user.login" \
    "all(.[]; (.id | type == \"number\") and (.created_at | test(\"$ISO\")) and (.updated_at | test(\"$ISO\")) and (.body | type == \"string\") and (.user.login | type == \"string\"))" "$comments"
  pin "the app's summary comment carries the codex-pull-request-review-summary machine tag" \
    'any(.[]; .user.login == $bot and (.body | test("codex-pull-request-review-summary")))' "$comments" --arg bot "$BOT"
  inline_all=$(api --paginate "repos/$REPO/pulls/$REVIEWED_PR/comments?per_page=100" | jq -s 'add')
  inline_page=$(api "repos/$REPO/pulls/$REVIEWED_PR/comments")
  # Two claims, each fed on stdin: the paginated feed of a long-reviewed PR is over Linux's
  # per-argument limit (the rounds suite's known trap), so it never travels as an argument.
  pin "the paginated inline-comments feed is a list" 'type == "array"' "$inline_all"
  pin "the unpaginated inline-comments read is a list" 'type == "array"' "$inline_page"
  is_list "$inline_all" || inline_all='[]'
  is_list "$inline_page" || inline_page='[]'
  pin "inline comments carry numeric id, pull_request_review_id, commit_id, user.login, path, body, and the line/original_line pair poll renders" \
    "all(.[]; (.id | type == \"number\") and (.pull_request_review_id | type == \"number\") and (.commit_id | test(\"$HEX40\")) and (.user.login | type == \"string\") and (.path | type == \"string\") and (.body | type == \"string\") and has(\"line\") and has(\"original_line\"))" "$inline_all"
  n_inline=$(jq length <<<"$inline_all")
  if [ "$n_inline" -gt 30 ]; then
    pin "the flat listing paginates at 30 by default: an unpaginated read of #$REVIEWED_PR's $n_inline inline comments returns 30" \
      'length == 30' "$inline_page"
  else
    skip "the flat listing paginates at 30 by default" "#$REVIEWED_PR has $n_inline inline comments, not more than a page; a larger anchor shows it"
  fi
  # The review whose comments are read is one the flat listing NAMES (a pull_request_review_id
  # it carries), the way the merge-by-id read is made — not the app's first COMMENTED review,
  # which may be a summary with no inline comment — so the claim is exact: the per-review feed
  # is the flat listing's rows for that review, as a set of ids.
  named_review=$(jq -r '[.[]?.pull_request_review_id | select(type == "number")][0] // empty' <<<"$inline_all")
  if is_num "$named_review"; then
    per_review=$(api --paginate "repos/$REPO/pulls/$REVIEWED_PR/reviews/$named_review/comments?per_page=100" | jq -s 'add')
    jq -c --argjson r "$named_review" '[.[]? | select(.pull_request_review_id == $r) | .id] | sort' <<<"$inline_all" >"$SCRATCH/named_ids.json"
    pin "a review's own comments endpoint answers with exactly the flat listing's rows for that review, by id (the merge-by-id read; review $named_review)" \
      'type == "array" and ([.[].id] | sort) == $ids[0]' "$per_review" --slurpfile ids "$SCRATCH/named_ids.json"
  else
    skip "a review's own comments endpoint" "the flat listing names no review — $UNUSABLE"
  fi
else
  skip "the reviewer feeds' shapes" "set CONTRACT_REVIEWED_PR to a PR the review app reviewed and approved"
fi
skip "reviewThreads (GraphQL) pagination at 100" "the resolve path is the one GraphQL read, and it is not exercised here"
skip "compare's 300-file cap" "no compare of that size exists in this repository"

# --- the verdict --------------------------------------------------------------------------------------
section "verdict"
echo "$CLAIMS beliefs checked, $MOVED moved, $SKIPPED unpinned here"
[ "$MOVED" -eq 0 ] || { echo "pr-review-api-contract.sh: $MOVED belief(s) the fixtures encode no longer hold on $REPO — see MOVED above" >&2; exit 1; }

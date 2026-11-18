#!/usr/bin/env bash
# Close old pull requests that have merge conflicts, in all repositories of one organization.
#
# Phase 1 (warn):  Find open PRs with no update for INACTIVE_DAYS.
#                  If a PR has a merge conflict, add LABEL and write a comment.
# Phase 2 (close): Find open PRs with LABEL.
#                  If the conflict is resolved, or KEEP_LABEL is present, remove LABEL.
#                  If the conflict still exists after GRACE_DAYS, close the PR.
#
# Requirements: gh (GitHub CLI), jq, GNU date. GH_TOKEN must be set.

set -uo pipefail

ORG="${ORG:?Set ORG to the organization name}"
INACTIVE_DAYS="${INACTIVE_DAYS:-90}"
GRACE_DAYS="${GRACE_DAYS:-7}"
LABEL="${LABEL:-stale-conflict}"
KEEP_LABEL="${KEEP_LABEL:-keep-open}"
DRY_RUN="${DRY_RUN:-true}"

CUTOFF=$(date -u -d "${INACTIVE_DAYS} days ago" +%Y-%m-%d)
NOW=$(date -u +%s)

WARNED=0; CLOSED=0; CLEARED=0; ERRORS=0

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Print the HTML URL of each PR that matches the search query. One URL on each line.
# Note: the GitHub search API returns a maximum of 1000 results for each query.
search_prs() {
  gh api -X GET search/issues --paginate \
    -f q="$1" -f per_page=100 \
    --jq '.items[].html_url'
}

# Print MERGEABLE, CONFLICTING or UNKNOWN.
# GitHub calculates this value lazily, so retry while the value is UNKNOWN.
get_mergeable() {
  local url="$1" status="UNKNOWN"
  for _ in 1 2 3 4 5 6; do
    status=$(gh pr view "$url" --json mergeable --jq .mergeable) || status="UNKNOWN"
    [ "$status" != "UNKNOWN" ] && break
    sleep 5
  done
  echo "$status"
}

# URL format: https://github.com/OWNER/REPO/pull/NUMBER
repo_of()   { echo "$1" | cut -d/ -f4,5; }
number_of() { echo "$1" | cut -d/ -f7; }

# Print the ISO 8601 time when LABEL was last added to the PR.
label_added_at() {
  gh api graphql -f url="$1" -f query='
    query($url: URI!) {
      resource(url: $url) {
        ... on PullRequest {
          timelineItems(itemTypes: [LABELED_EVENT], last: 50) {
            nodes { ... on LabeledEvent { createdAt label { name } } }
          }
        }
      }
    }' --jq "[.data.resource.timelineItems.nodes[] | select(.label.name == \"${LABEL}\") | .createdAt] | last"
}

warn_pr() {
  local url="$1" repo num
  repo=$(repo_of "$url"); num=$(number_of "$url")

  # Create the label if it does not exist. --force updates an existing label.
  gh label create "$LABEL" --repo "$repo" --color "B60205" \
    --description "Inactive PR with merge conflicts. It will be closed automatically." \
    --force >/dev/null || return 1

  gh api -X POST "repos/${repo}/issues/${num}/labels" -f "labels[]=${LABEL}" >/dev/null || return 1

  gh pr comment "$url" --body "This pull request has had no activity for ${INACTIVE_DAYS} days and it has merge conflicts.

It will be closed automatically in ${GRACE_DAYS} days if the conflicts are not resolved.

To keep it open, do one of these:
- Rebase or merge the base branch and resolve the conflicts.
- Ask a maintainer to add the \`${KEEP_LABEL}\` label." >/dev/null || return 1
}

remove_label() {
  local url="$1"
  gh api -X DELETE "repos/$(repo_of "$url")/issues/$(number_of "$url")/labels/${LABEL}" >/dev/null
}

close_pr() {
  gh pr close "$1" --comment "This pull request was closed automatically. It had no activity for more than ${INACTIVE_DAYS} days and its merge conflicts were not resolved within ${GRACE_DAYS} days.

The branch was not deleted. To continue, resolve the conflicts and reopen this pull request." >/dev/null
}

log "Organization: ${ORG}. Inactive days: ${INACTIVE_DAYS}. Grace days: ${GRACE_DAYS}. Dry run: ${DRY_RUN}."

# ---------------------------------------------------------------- Phase 1
QUERY_WARN="org:${ORG} is:pr is:open draft:false archived:false updated:<${CUTOFF} -label:${LABEL} -label:${KEEP_LABEL} -author:app/dependabot -author:app/renovate"
log "Phase 1: search: ${QUERY_WARN}"

URLS=$(search_prs "$QUERY_WARN") || { log "ERROR: Phase 1 search failed."; exit 1; }

for url in $URLS; do
  status=$(get_mergeable "$url")
  if [ "$status" != "CONFLICTING" ]; then
    log "Skip (${status}): ${url}"
    continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN: would warn: ${url}"
    WARNED=$((WARNED + 1))
    continue
  fi
  if warn_pr "$url"; then
    log "Warned: ${url}"
    WARNED=$((WARNED + 1))
  else
    log "ERROR: could not warn: ${url}"
    ERRORS=$((ERRORS + 1))
  fi
done

# ---------------------------------------------------------------- Phase 2
# Note: the warning comment changes the "updated" date of the PR.
# Thus, phase 2 searches by label, not by date.
QUERY_CLOSE="org:${ORG} is:pr is:open archived:false label:${LABEL}"
log "Phase 2: search: ${QUERY_CLOSE}"

URLS=$(search_prs "$QUERY_CLOSE") || { log "ERROR: Phase 2 search failed."; exit 1; }

for url in $URLS; do
  labels=$(gh pr view "$url" --json labels --jq '[.labels[].name] | join(",")') || labels=""
  status=$(get_mergeable "$url")

  # The author resolved the conflict, or a maintainer added KEEP_LABEL.
  if [ "$status" = "MERGEABLE" ] || [[ ",${labels}," == *",${KEEP_LABEL},"* ]]; then
    if [ "$DRY_RUN" = "true" ]; then
      log "DRY RUN: would remove label: ${url}"
    elif remove_label "$url"; then
      log "Label removed (${status}): ${url}"
    else
      log "ERROR: could not remove label: ${url}"; ERRORS=$((ERRORS + 1)); continue
    fi
    CLEARED=$((CLEARED + 1))
    continue
  fi

  if [ "$status" != "CONFLICTING" ]; then
    log "Skip (status ${status}): ${url}"
    continue
  fi

  added=$(label_added_at "$url") || added=""
  if [ -z "$added" ] || [ "$added" = "null" ]; then
    log "Skip (label date not found): ${url}"
    continue
  fi

  age_days=$(( (NOW - $(date -u -d "$added" +%s)) / 86400 ))
  if [ "$age_days" -lt "$GRACE_DAYS" ]; then
    log "Wait (warned ${age_days} of ${GRACE_DAYS} days ago): ${url}"
    continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN: would close: ${url}"
    CLOSED=$((CLOSED + 1))
  elif close_pr "$url"; then
    log "Closed: ${url}"
    CLOSED=$((CLOSED + 1))
  else
    log "ERROR: could not close: ${url}"
    ERRORS=$((ERRORS + 1))
  fi
done

log "Summary: warned=${WARNED} closed=${CLOSED} label_removed=${CLEARED} errors=${ERRORS} dry_run=${DRY_RUN}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Stale conflicting PR sweep"
    echo "| Warned | Closed | Label removed | Errors | Dry run |"
    echo "|---|---|---|---|---|"
    echo "| ${WARNED} | ${CLOSED} | ${CLEARED} | ${ERRORS} | ${DRY_RUN} |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$ERRORS" -eq 0 ]

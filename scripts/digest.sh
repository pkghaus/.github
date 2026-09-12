#!/usr/bin/env bash
#
# One weekly view of the org's dependency and security state, because this
# account cannot have the other one: GitHub's organization Security Overview
# needs GitHub Team and pkghaus is on free, so /orgs/<org>/security 404s. The
# org-level APIs it would have been built from DO answer on free, which is the
# only reason this script can exist.
#
#   digest.sh collect          gather everything, one TSV row per finding
#   digest.sh render <file>    that TSV as an issue body
#   digest.sh findings <file>  exit 0 when there is something to report
#
# Split three ways so the two that decide anything can be tested without a
# network: render and findings are pure functions of the TSV.
#
# It reports three things and the third is the one experience argues for.
# Dependabot pull requests and their checks are the obvious half. `npm audit` is
# here because GitHub's alerts under-report: measured 2026-09-12, the alerts API
# said 2 findings across this org while npm audit found 16, and three repos that
# read as clean were not. A digest that only mirrors GitHub inherits GitHub's
# blind spot and reassures you weekly. Per-repo security settings are here
# because not one of them is inherited by a new repository, the checklist is
# kept by hand, and it has already been missed twice: `packages` was created
# with three of them off, and three dependabot.yml files named a directory
# holding no manifest, which reads exactly like coverage.
#
# The issue exists only when something is wrong; a clean week closes it. That
# rule is borrowed from pkghaus/packages' bump.yml, whose comment explains the
# cost of breaking it - listing successes leaves an issue standing that names
# things already dealt with, "which trains the reader to stop opening the one
# surface that reports failures".
#
# TSV schema, one finding per row, tab separated:
#   pr     <repo> <number> <checks> <age-days> <title>
#   alert  <repo> <severity> <package> <ghsa>
#   audit  <repo> <manifest-dir> <severity> <package>
#   cover  <repo> <setting> <state>

set -euo pipefail
shopt -s inherit_errexit

ORG="${DIGEST_ORG:-pkghaus}"
# A pull request open this long has stopped being in flight and started being
# ignored. Reported either way; this only changes how it is described.
STALE_DAYS="${DIGEST_STALE_DAYS:-7}"

# --- pure, and therefore the parts worth testing -----------------------------

# Anything at all to report? Blank lines and comments do not count, so a file
# that is technically non-empty but says nothing still closes the issue.
findings() { # <file>
    [ -s "${1:?findings needs a file}" ] || return 1
    grep -qvE '^\s*(#|$)' "$1"
}

# Rows in, markdown out. Sections are omitted entirely when they have no rows:
# an empty heading reads as a clean bill of health for something that was never
# checked.
render() { # <file>
    local f="${1:?render needs a file}" n

    printf '%s\n\n' "This issue is opened by \`digest.yml\` when something needs attention and closed when nothing does. It is not a status page."
    # A team cannot be an issue assignee on GitHub, so the team reaches its
    # members through a mention instead. The assignee is set separately by the
    # workflow and must be a user.
    [ -z "${DIGEST_TEAM:-}" ] || printf '%s\n\n' "cc @${DIGEST_TEAM}"

    n="$(awk -F'\t' '$1=="pr"' "$f" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Open Dependabot pull requests (%s)\n\n' "$n"
        printf '| repo | PR | checks | age | title |\n|---|---|---|---|---|\n'
        awk -F'\t' -v s="$STALE_DAYS" '$1=="pr" {
            age = ($5 >= s) ? $5 " days, stale" : $5 " days"
            printf "| %s | #%s | %s | %s | %s |\n", $2, $3, $4, age, $6
        }' "$f"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="audit"' "$f" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## npm audit (%s)\n\n' "$n"
        printf 'What the alerts API does not report. Run against each committed lockfile.\n\n'
        printf '| repo | manifest | severity | package |\n|---|---|---|---|\n'
        awk -F'\t' '$1=="audit" { printf "| %s | %s | %s | %s |\n", $2, $3, $4, $5 }' "$f"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="alert"' "$f" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Dependabot alerts (%s)\n\n' "$n"
        printf '| repo | severity | package | advisory |\n|---|---|---|---|\n'
        awk -F'\t' '$1=="alert" { printf "| %s | %s | %s | %s |\n", $2, $3, $4, $5 }' "$f"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="cover"' "$f" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Security settings not enabled (%s)\n\n' "$n"
        printf 'None of these is inherited by a new repository.\n\n'
        printf '| repo | setting | state |\n|---|---|---|\n'
        awk -F'\t' '$1=="cover" { printf "| %s | %s | %s |\n", $2, $3, $4 }' "$f"
        printf '\n'
    fi
}

# npm audit JSON for one manifest into rows. Severity and package only: the
# version ranges belong in the repo, not in a digest nobody can act on from.
audit_rows() { # <repo> <manifest-dir>   (JSON on stdin)
    local repo="${1:?}" dir="${2:?}"
    # shellcheck disable=SC2016  # python source, the shell must expand nothing
    python3 -c '
import json,sys
repo, d = sys.argv[1], sys.argv[2]
try: a = json.load(sys.stdin)
except Exception: sys.exit(0)
for name, v in sorted(a.get("vulnerabilities", {}).items()):
    print("\t".join(("audit", repo, d, v.get("severity","?"), name)))
' "$repo" "$dir"
}

# Repository JSON into rows for whatever is off.
#
# PRIVATE repositories are exempt from all of it on this plan, and that is not
# leniency. Rulesets are REFUSED outright ("Upgrade to GitHub Pro or make this
# repository public"), and secret scanning on a private repository needs paid
# Advanced Security, so both read as absent on wiki and brand every week
# forever. A finding nobody can act on is how a report gets ignored, which is
# the failure this whole script is written against. Caught by running the
# collector against the live org before shipping it: the first run reported
# four such rows.
coverage_rows() { # <repo> <visibility> <ruleset-count|na>   (repo JSON on stdin)
    local repo="${1:?}" vis="${2:?}" rulesets="${3:?}"
    # shellcheck disable=SC2016  # python source, the shell must expand nothing
    python3 -c '
import json,sys
repo, vis, rulesets = sys.argv[1], sys.argv[2], sys.argv[3]
# Read FIRST, decide after. Exiting without draining stdin hands the producer
# an EPIPE, which under `set -o pipefail` fails the pipeline and, under `set
# -e`, ends the whole run. That aborted a live dry run after the alerts and
# before a single audit, and the digest rendered as a quiet week.
data = sys.stdin.read()
if vis.upper() != "PUBLIC":
    sys.exit(0)
r = json.loads(data)
sa = r.get("security_and_analysis") or {}
def state(key):
    return ((sa.get(key) or {}).get("status")) or "unset"
for key, label in (("secret_scanning","secret scanning"),
                   ("secret_scanning_push_protection","push protection")):
    if state(key) != "enabled":
        print("\t".join(("cover", repo, label, state(key))))
if rulesets.isdigit() and int(rulesets) == 0:
    print("\t".join(("cover", repo, "ruleset", "none")))
' "$repo" "$vis" "$rulesets"
}

# --- collection, which needs a network and a token ---------------------------

# Non-archived repositories, one per line.
repos() {
    gh repo list "$ORG" --limit 200 --json name,isArchived,visibility \
        --jq '.[] | select(.isArchived == false) | "\(.name)\t\(.visibility)"'
}

# Open Dependabot pull requests with a rolled-up check verdict. A pull request
# nobody merges is the point of this section, so all of them are reported and
# age only changes the wording.
collect_prs() { # <repo>
    local repo="$1" now
    now="$(date -u +%s)"
    gh pr list --repo "$ORG/$repo" --state open --author app/dependabot \
        --json number,title,createdAt,statusCheckRollup 2>/dev/null \
    | python3 -c '
import json,sys,datetime
repo, now = sys.argv[1], int(sys.argv[2])
for pr in json.load(sys.stdin):
    roll = pr.get("statusCheckRollup") or []
    states = {(c.get("conclusion") or c.get("state") or "").upper() for c in roll}
    if not roll:                      checks = "none"
    elif states & {"FAILURE","ERROR","TIMED_OUT","CANCELLED"}: checks = "failing"
    elif states & {"PENDING","QUEUED","IN_PROGRESS",""}:       checks = "running"
    else:                              checks = "passing"
    created = datetime.datetime.fromisoformat(pr["createdAt"].replace("Z","+00:00"))
    age = (now - int(created.timestamp())) // 86400
    title = pr["title"].replace("\t"," ").replace("|","\\|")
    print("\t".join(("pr", repo, str(pr["number"]), checks, str(age), title)))
' "$repo" "$now"
}

# Org-level Dependabot alerts. This endpoint answers on free even though the
# dashboard built on it does not exist here.
collect_alerts() {
    gh api "/orgs/$ORG/dependabot/alerts?state=open&per_page=100" \
        --jq '.[] | ["alert", .repository.name, (.security_advisory.severity|ascii_upcase),
                     .dependency.package.name, .security_advisory.ghsa_id] | @tsv' 2>/dev/null || true
}

# Every committed lockfile, audited. Fetched rather than cloned: two files per
# manifest against a full checkout of every repository.
collect_audit() { # <repo>
    local repo="$1" lock dir work
    for lock in $(gh api "repos/$ORG/$repo/git/trees/HEAD?recursive=1" \
            --jq '.tree[] | select(.path | endswith("package-lock.json"))
                  | select(.path | contains("node_modules") | not) | .path' 2>/dev/null); do
        dir="$(dirname "$lock")"
        work="$(mktemp -d)"
        if gh api "repos/$ORG/$repo/contents/$lock" --jq '.content' 2>/dev/null \
               | base64 -d > "$work/package-lock.json" \
           && gh api "repos/$ORG/$repo/contents/${dir#./}/package.json" --jq '.content' 2>/dev/null \
               | base64 -d > "$work/package.json"; then
            ( cd "$work" && npm audit --json 2>/dev/null || true ) \
                | audit_rows "$repo" "${dir#./}"
        fi
        rm -rf "$work"
    done
}

# Security settings. Rulesets are read separately because a private repository
# on a free plan is REFUSED the endpoint rather than returning zero, and an
# every-week finding nobody can act on is how a report gets ignored.
collect_coverage() { # <repo> <visibility>
    local repo="$1" vis="$2" rulesets=na
    # Exempt on this plan (see coverage_rows), so do not spend the call either.
    [ "$vis" = PUBLIC ] || return 0
    if [ "$vis" = PUBLIC ]; then
        rulesets="$(gh api "repos/$ORG/$repo/rulesets" --jq 'length' 2>/dev/null || echo na)"
    fi
    gh api "repos/$ORG/$repo" 2>/dev/null | coverage_rows "$repo" "$vis" "$rulesets"
}

collect() {
    local repo vis
    collect_alerts
    while IFS=$'\t' read -r repo vis; do
        [ -n "$repo" ] || continue
        collect_prs "$repo"
        collect_audit "$repo"
        collect_coverage "$repo" "$vis"
    done < <(repos)
}

# Sourced by the tests to reach the pure functions above. Without the guard the
# dispatch below runs on source and exits, and the suite tests nothing.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

case "${1:-}" in
    collect)  collect ;;
    render)   render "${2:?usage: digest.sh render <file>}" ;;
    findings) findings "${2:?usage: digest.sh findings <file>}" ;;
    *) echo "usage: digest.sh {collect|render <file>|findings <file>}" >&2; exit 2 ;;
esac

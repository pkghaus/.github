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
#   audit  <repo> <manifest-dir> <severity> <package> <advisory>
#   cover  <repo> <setting> <state>

set -euo pipefail
shopt -s inherit_errexit

ORG="${DIGEST_ORG:-pkghaus}"
# A pull request open this long has stopped being in flight and started being
# ignored. Reported either way; this only changes how it is described.
STALE_DAYS="${DIGEST_STALE_DAYS:-7}"

# --- pure, and therefore the parts worth testing -----------------------------

# Split rows into the ones that need attention and the ones already known.
#
# A suppression says "known, understood, cannot be fixed here yet". It does not
# hide the finding: the row still renders, in its own section, with the reason
# and a date. What it does is stop the finding holding the issue open, because
# an issue that can never close stops being read, which is the same disease as
# one that lists successes.
#
# Every suppression carries a review date and STOPS APPLYING once it passes, so
# the finding returns and the issue reopens. A suppression without an expiry is
# a silent pin.
#
# mode is "active" or "blocked". Blocked rows gain the review date and reason as
# two more fields.
classify() { # <mode> <rows-file> [<suppressions-file>] [<today>]
    local mode="${1:?}" rows="${2:?}"
    local sup="${3:-$(dirname "${BASH_SOURCE[0]}")/../suppressions.tsv}"
    local today="${4:-$(date -u +%F)}"
    # shellcheck disable=SC2016  # python source, the shell must expand nothing
    python3 -c '
import sys
mode, rows, sup, today = sys.argv[1:5]
KEY = {"audit": 5, "alert": 4, "cover": 2, "pr": 2}   # zero-based field index

rules = {}
try:
    for line in open(sup):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 5:
            continue
        rules[(f[0], f[1], f[2])] = (f[3], f[4])
except FileNotFoundError:
    pass

for line in open(rows):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    f = line.split("\t")
    idx = KEY.get(f[0])
    rule = rules.get((f[0], f[1], f[len(f) > idx and idx or 0])) if idx is not None and len(f) > idx else None
    # An expired suppression is no suppression. Past the date the finding counts
    # again, which is what forces a second look instead of a permanent pin.
    if rule and rule[0] >= today:
        if mode == "blocked":
            print(line + "\t" + rule[0] + "\t" + rule[1])
    elif mode == "active":
        print(line)
' "$mode" "$rows" "$sup" "$today"
}

# Anything at all to report? Blank lines and comments do not count, so a file
# that is technically non-empty but says nothing still closes the issue.
findings() { # <file> [<suppressions-file>] [<today>]
    local rows="${1:?findings needs a file}"
    [ -s "$rows" ] || return 1
    # Suppressed rows still render; they just do not hold the issue open.
    [ -n "$(classify active "$@")" ]
}

# Rows in, markdown out.
#
# Every field that came from outside has its @ replaced with &#64;, which
# renders identically and means nothing to GitHub's mention parser. A bare @name
# in issue text is a link and a notification to whoever owns it, and every
# scoped npm package begins with one: "@cloudflare/vitest-pool-workers" in a
# table cell linked a real organization mid-sentence. Package names, pull
# request titles and suppression reasons are all escaped. The cc line is not,
# because that mention is the point. Sections are omitted entirely when they have no rows:
# an empty heading reads as a clean bill of health for something that was never
# checked.
render() { # <file> [<suppressions-file>] [<today>]
    : "${1:?render needs a file}"
    # The rows file reaches classify through "$@", along with the optional
    # suppressions path and date, so it is not referenced again by name here.
    local n act blk
    act="$(mktemp)"; blk="$(mktemp)"
    classify active "$@" > "$act"
    classify blocked "$@" > "$blk"

    # Short on purpose. Someone opening this wants to act, not to read the case
    # for the tool existing; that lives in the runbook. Only the two things
    # that look like bugs and are not get explained.
    #
    # ONE LINE PER PARAGRAPH, however long. GitHub Flavored Markdown renders a
    # single newline inside a paragraph as a line break in ISSUES and comments,
    # unlike a .md file in a repository where it reflows. A comfortably wrapped
    # heredoc therefore came out broken at every one of its source line
    # endings, which is what it looked like: text wrapping where nothing should
    # wrap. Let the browser wrap it.
    cat <<PREAMBLE
Dependency and security state across this organization, written weekly by \`digest.yml\`.

**Not a status page.** It opens only when something needs attention and closes when nothing does: open means work, closed means clean.

Two things that look wrong and are not. A repository under **npm audit** but not under **Dependabot alerts** is the expected case, because GitHub's alerts under-report and this runs the auditor itself. And **Known and blocked** findings are understood and cannot be fixed here yet, so they are listed without holding the issue open (see \`suppressions.tsv\`).

PREAMBLE
    # A team cannot be an issue assignee on GitHub, so the team reaches its
    # members through a mention instead. The assignee is set separately by the
    # workflow and must be a user.
    [ -z "${DIGEST_TEAM:-}" ] || printf '%s\n\n' "cc @${DIGEST_TEAM}"

    n="$(awk -F'\t' '$1=="pr"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Open Dependabot pull requests (%s)\n\n' "$n"
        # Every delimiter row is left-aligned (:---). GitHub's markdown CSS sets
        # no text-align on th, so the browser default centres every header over
        # a left-aligned column, and a narrow table then reads as misaligned.
        printf '| repo | PR | checks | age | title |\n|:---|:---|:---|:---|:---|\n'
        awk -F'\t' -v s="$STALE_DAYS" '$1=="pr" {
            age = ($5 >= s) ? $5 " days, stale" : $5 " days"
            t = $6; gsub(/@/, "\\&#64;", t)
            printf "| %s | #%s | %s | %s | %s |\n", $2, $3, $4, age, t
        }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="audit"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## npm audit (%s)\n\n' "$n"
        printf 'One row per advisory, not per package in the chain.\n\n'
        printf '| repo | manifest | severity | package | advisory |\n|:---|:---|:---|:---|:---|\n'
        awk -F'\t' '$1=="audit" { p = $5; gsub(/@/, "\\&#64;", p)
            printf "| %s | %s | %s | %s | %s |\n", $2, $3, $4, p, $6 }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="alert"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Dependabot alerts (%s)\n\n' "$n"
        printf '| repo | severity | package | advisory |\n|:---|:---|:---|:---|\n'
        awk -F'\t' '$1=="alert" { p = $4; gsub(/@/, "\\&#64;", p)
            printf "| %s | %s | %s | %s |\n", $2, $3, p, $5 }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="cover"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Security settings not enabled (%s)\n\n' "$n"
        printf 'None of these is inherited by a new repository.\n\n'
        printf '| repo | setting | state |\n|:---|:---|:---|\n'
        awk -F'\t' '$1=="cover" { printf "| %s | %s | %s |\n", $2, $3, $4 }' "$act"
        printf '\n'
    fi

    # Known and blocked: rendered so nothing is hidden, but not counted, so the
    # issue can still close. The review date is what stops a suppression
    # becoming permanent: past it the finding counts again and this reopens.
    n="$(grep -c . "$blk" || true)"
    if [ "$n" -gt 0 ]; then
        printf '## Known and blocked (%s)\n\n' "$n"
        printf 'Not counted as needing attention. Each stops being suppressed on its review date, at which point it returns to the sections above.\n\n'
        # A list, NOT a table. The reason is free text and runs to a few
        # hundred characters; in a table cell it dominates the column widths
        # and GitHub squeezes every other column until the repository name and
        # the advisory id wrap mid-token. The short-celled sections above stay
        # tables because they render fine as one.
        awk -F'\t' '{
            key = ($1=="audit") ? $6 : ($1=="alert") ? $5 : $3
            n = NF
            why = $n; gsub(/@/, "\\&#64;", why)
            printf "- **%s** %s `%s`, review by **%s**\n  %s\n", $2, $1, key, $(n-1), why
        }' "$blk"
        printf '\n'
    fi

    printf -- '---\n\n'
    printf 'Last run %s' "${DIGEST_RUN_AT:-$(date -u +'%Y-%m-%d %H:%M:%S UTC')}"
    [ -z "${DIGEST_RUN_URL:-}" ] || printf ' ([run](%s))' "$DIGEST_RUN_URL"
    printf '. The body is rewritten in place on every run, so this timestamp is the age of what you are reading.\n'

    rm -f "$act" "$blk"
}

# npm audit JSON for one manifest into rows, ONE PER ADVISORY.
#
# npm reports every package in the chain, so a single advisory on a leaf
# becomes a row for the leaf and a row for each dependent. Measured on apt's
# lockfile: three rows, one advisory. Counting those rows as separate findings
# inflated an estate-wide figure roughly threefold before anyone asked what it
# counted, so this deliberately does not.
#
# The carrier is the package whose `via` holds the advisory OBJECT; a
# dependent's `via` holds only the name of what it pulls in. Filtering on that
# leaves exactly the packages actually carrying a vulnerability. One package
# with two advisories is still two findings, which is why the key is the pair.
audit_rows() { # <repo> <manifest-dir>   (JSON on stdin)
    local repo="${1:?}" dir="${2:?}"
    # shellcheck disable=SC2016  # python source, the shell must expand nothing
    python3 -c '
import json,sys
repo, d = sys.argv[1], sys.argv[2]
try: a = json.load(sys.stdin)
except Exception: sys.exit(0)
seen = set()
for name, v in sorted(a.get("vulnerabilities", {}).items()):
    for src in v.get("via", []):
        if not isinstance(src, dict):
            continue
        ident = (src.get("url") or "").rsplit("/", 1)[-1] or str(src.get("source") or "?")
        if (name, ident) in seen:
            continue
        seen.add((name, ident))
        print("\t".join(("audit", repo, d, v.get("severity","?"), name, ident)))
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

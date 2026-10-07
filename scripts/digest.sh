#!/usr/bin/env bash
#
# The org's dependency and security state as one weekly issue. Stands in for
# GitHub's organization Security Overview, which needs GitHub Team; the
# org-level APIs underneath it answer on the free plan.
#
#   digest.sh collect          gather everything, one TSV row per finding
#   digest.sh render <file>    that TSV as an issue body
#   digest.sh findings <file>  exit 0 something to report, 1 nothing, else unknown
#
# render and findings are pure functions of the TSV, so they test without a
# network. npm audit runs beside the Dependabot alerts, which under-report.
#
# TSV schema, one finding per row, tab separated:
#   pr     <repo> <number> <checks> <age-days> <title>
#   alert  <repo> <severity> <package> <ghsa>
#   audit  <repo> <manifest-dir> <severity> <package> <advisory>
#   cover  <repo> <setting> <state>
#   updater <repo> <job> <failing-since>

set -euo pipefail
shopt -s inherit_errexit

ORG="${DIGEST_ORG:-pkghaus}"
# A pull request open this long has stopped being in flight and started being
# ignored. Reported either way; this only changes how it is described.
STALE_DAYS="${DIGEST_STALE_DAYS:-7}"

# --- pure, and therefore the parts worth testing -----------------------------

# Split rows into the ones that need attention and the ones already known.
#
# What a suppression does, and why it expires, is in suppressions.tsv.
#
# mode "active" prints the rows that count, as they are. Mode "blocked" prints
# kind, repo, key, review-by and reason for each suppressed one.
classify() { # <mode> <rows-file> [<suppressions-file>] [<today>]
    local mode="${1:?}" rows="${2:?}"
    local sup="${3:-$(dirname "${BASH_SOURCE[0]}")/../suppressions.tsv}"
    local today="${4:-$(date -u +%F)}"
    # shellcheck disable=SC2016  # python source, the shell must expand nothing
    python3 -c '
import re, sys
mode, rows, sup, today = sys.argv[1:5]
KEY = {"audit": 5, "alert": 4, "cover": 2, "pr": 2, "updater": 2}   # zero-based field index

# A security-update job ("npm_and_yarn in /. for sharp") never runs again once
# its package is fixed, so its failure counts only while this repo still has an
# alert or audit row for that package. Any other job name always counts.
SECURITY_JOB = re.compile(r"^\S+ in \S+ for ([^\s,]+)$")

lines = []
for line in open(rows):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    lines.append(line)

carried = set()
for line in lines:
    f = line.split("\t")
    if f[0] == "alert" and len(f) > 3:
        carried.add((f[1], f[3]))
    elif f[0] == "audit" and len(f) > 4:
        carried.add((f[1], f[4]))

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

for line in lines:
    f = line.split("\t")
    if f[0] == "updater" and len(f) > 2:
        m = SECURITY_JOB.match(f[2])
        if m and (f[1], m.group(1)) not in carried:
            continue   # settled: nothing left for this job to fix
    idx = KEY.get(f[0])
    key = f[idx] if idx is not None and len(f) > idx else None
    rule = rules.get((f[0], f[1], key)) if key is not None else None
    # review-by is inclusive: the finding counts again from the next day.
    if rule and rule[0] >= today:
        if mode == "blocked":
            print("\t".join((f[0], f[1], key, rule[0], rule[1])))
    elif mode == "active":
        print(line)
' "$mode" "$rows" "$sup" "$today"
}

# Anything at all to report? Blank lines and comments do not count, so a file
# that is technically non-empty but says nothing still closes the issue.
# Returns 2 when classify fails: 1 closes the issue, so a crash must not be 1.
findings() { # <file> [<suppressions-file>] [<today>]
    : "${1:?findings needs a file}"
    local active
    # Suppressed rows still render; they just do not hold the issue open.
    active="$(classify active "$@")" || return 2
    [ -n "$active" ]
}

# Rows in, markdown out.
#
# Every row has its @ replaced with &#64; on the way in: it renders the same and
# is not a mention, and every scoped npm package starts with one. The cc line is
# printed separately, because that mention is the point. Sections are omitted
# entirely when they have no rows: an empty heading reads as a clean bill of
# health for something that was never checked.
render() { # <file> [<suppressions-file>] [<today>]
    : "${1:?render needs a file}"
    # The rows file reaches classify through "$@", along with the optional
    # suppressions path and date, so it is not referenced again by name here.
    local n act blk
    act="$(mktemp)"; blk="$(mktemp)"
    classify active "$@" | sed 's/@/\&#64;/g' > "$act"
    classify blocked "$@" | sed 's/@/\&#64;/g' > "$blk"

    # Short on purpose, and ONE LINE PER PARAGRAPH: in an issue body GitHub
    # renders a newline inside a paragraph as a line break.
    cat <<PREAMBLE
Dependency and security state across this organization, written weekly by \`digest.yml\`.

**Not a status page.** It opens only when something needs attention and closes when nothing does: open means work, closed means clean.

Two things that look wrong and are not. A repository under **npm audit** but not under **Dependabot alerts** is the expected case, because GitHub's alerts under-report and this runs the auditor itself. And **Known and blocked** findings are understood and cannot be fixed here yet, so they are listed without holding the issue open (see \`suppressions.tsv\`).

PREAMBLE
    [ -z "${DIGEST_TEAM:-}" ] || printf '%s\n\n' "cc @${DIGEST_TEAM}"

    n="$(awk -F'\t' '$1=="pr"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Open Dependabot pull requests (%s)\n\n' "$n"
        # Every delimiter row is left-aligned (:---). GitHub's markdown CSS sets
        # no text-align on th, so the browser default centres every header over
        # a left-aligned column, and a narrow table then reads as misaligned.
        printf '| repo | PR | checks | age | title |\n|:---|:---|:---|:---|:---|\n'
        # A bare #N resolves against the repository holding this issue, not $2.
        awk -F'\t' -v s="$STALE_DAYS" -v org="$ORG" '$1=="pr" {
            age = ($5 >= s) ? $5 " days, stale" : $5 " days"
            printf "| %s | [#%s](https://github.com/%s/%s/pull/%s) | %s | %s | %s |\n", $2, $3, org, $2, $3, $4, age, $6
        }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="audit"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## npm audit (%s)\n\n' "$n"
        printf 'One row per advisory, not per package in the chain.\n\n'
        printf '| repo | manifest | severity | package | advisory |\n|:---|:---|:---|:---|:---|\n'
        awk -F'\t' '$1=="audit" { printf "| %s | %s | %s | %s | %s |\n", $2, $3, $4, $5, $6 }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="alert"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Dependabot alerts (%s)\n\n' "$n"
        printf '| repo | severity | package | advisory |\n|:---|:---|:---|:---|\n'
        awk -F'\t' '$1=="alert" { printf "| %s | %s | %s | %s |\n", $2, $3, $4, $5 }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="updater"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Dependabot updater failing (%s)\n\n' "$n"
        printf 'The update job itself errored, so it opened no pull request and changed no alert. A repository whose updater is broken otherwise looks exactly like one with nothing to do.\n\n'
        printf '| repo | update job | failing since |\n|:---|:---|:---|\n'
        awk -F'\t' '$1=="updater" { printf "| %s | %s | %s |\n", $2, $3, $4 }' "$act"
        printf '\n'
    fi

    n="$(awk -F'\t' '$1=="cover"' "$act" | wc -l)"
    if [ "$n" -gt 0 ]; then
        printf '## Security settings not enabled or not readable (%s)\n\n' "$n"
        printf '%s\n\n' "None of these is inherited by a new repository. **not readable** means \`DIGEST_TOKEN\` has no admin access to that repository, which is true of any public repository created or recreated after the token until it is added to the token's repository selection."
        printf '| repo | setting | state |\n|:---|:---|:---|\n'
        awk -F'\t' '$1=="cover" { printf "| %s | %s | %s |\n", $2, $3, $4 }' "$act"
        printf '\n'
    fi

    n="$(grep -c . "$blk" || true)"
    if [ "$n" -gt 0 ]; then
        printf '## Known and blocked (%s)\n\n' "$n"
        printf 'Not counted as needing attention. Each counts again the day after its review date, back in the sections above.\n\n'
        # Unfixable crowding: GitHub strips <nobr> and styled spans; U+2011 breaks copy-paste.
        printf '| repo | finding | review by | why |\n|:---|:---|:---|:---|\n'
        awk -F'\t' '{ printf "| %s | %s %s | %s | %s |\n", $2, $1, $3, $4, $5 }' "$blk"
        printf '\n'
    fi

    printf -- '---\n\n'
    printf 'Last run %s' "${DIGEST_RUN_AT:-$(date -u +'%Y-%m-%d %H:%M:%S UTC')}"
    [ -z "${DIGEST_RUN_URL:-}" ] || printf ' ([run](%s))' "$DIGEST_RUN_URL"
    printf '. The body is rewritten in place on every run, so this timestamp is the age of what you are reading.\n'

    rm -f "$act" "$blk"
}

# npm audit JSON for one manifest into rows, ONE PER ADVISORY. npm lists every
# package in the chain; only the carrier's `via` holds the advisory object, and
# one package with two advisories is two rows.
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

# Repository JSON into rows for whatever is off. Private repositories are
# exempt: on this plan rulesets are refused and secret scanning needs paid
# Advanced Security, so those rows could never be acted on.
coverage_rows() { # <repo> <visibility> <ruleset-count|na>   (repo JSON on stdin)
    local repo="${1:?}" vis="${2:?}" rulesets="${3:?}"
    # shellcheck disable=SC2016  # python source, the shell must expand nothing
    python3 -c '
import json,sys
repo, vis, rulesets = sys.argv[1], sys.argv[2], sys.argv[3]
# Drain stdin before exiting, or the producer gets EPIPE and pipefail with
# set -e aborts the whole run.
data = sys.stdin.read()
if vis.upper() != "PUBLIC":
    sys.exit(0)
r = json.loads(data)
# GitHub returns this block only to an admin caller. Absent, it means
# DIGEST_TOKEN cannot read this repo, not that scanning is off.
if "security_and_analysis" not in r:
    print("\t".join(("cover", repo, "security settings", "not readable")))
    sa = None
else:
    sa = r.get("security_and_analysis") or {}
def state(key):
    return ((sa.get(key) or {}).get("status")) or "unset"
for key, label in (("secret_scanning","secret scanning"),
                   ("secret_scanning_push_protection","push protection")):
    if sa is not None and state(key) != "enabled":
        print("\t".join(("cover", repo, label, state(key))))
if rulesets.isdigit() and int(rulesets) == 0:
    print("\t".join(("cover", repo, "ruleset", "none")))
' "$repo" "$vis" "$rulesets"
}

# --- collection, which needs a network and a token ---------------------------
#
# A failed read fails collect. Swallowed, it would render as a quiet week.

# Non-archived repositories, one per line: name, visibility, isEmpty.
repos() {
    gh repo list "$ORG" --limit 200 --json name,isArchived,visibility,isEmpty \
        --jq '.[] | select(.isArchived == false) | "\(.name)\t\(.visibility)\t\(.isEmpty)"'
}

# Open Dependabot pull requests with a rolled-up check verdict. A pull request
# nobody merges is the point of this section, so all of them are reported and
# age only changes the wording.
collect_prs() { # <repo>
    local repo="$1" now
    now="$(date -u +%s)"
    gh pr list --repo "$ORG/$repo" --state open --author app/dependabot \
        --json number,title,createdAt,statusCheckRollup \
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
# dashboard built on it does not exist here. --jq runs once per page, so the
# filter must not aggregate.
collect_alerts() {
    gh api "/orgs/$ORG/dependabot/alerts?state=open&per_page=100" --paginate \
        --jq '.[] | ["alert", .repository.name, (.security_advisory.severity|ascii_upcase),
                     .dependency.package.name, .security_advisory.ghsa_id] | @tsv'
}

# Each Dependabot update job whose newest run failed. Per job, because a newer
# run of another job must not hide a failure; run names end " - Update #<id>".
# Asked of the workflow, since /actions/runs on a busy repo crowds them out.
collect_updater() { # <repo>
    local repo="$1" wf
    wf="$(gh api "repos/$ORG/$repo/actions/workflows" \
          --jq '.workflows[] | select(.path=="dynamic/dependabot/dependabot-updates") | .id')"
    # No such workflow means Dependabot has never run here, not a failed read.
    [ -n "$wf" ] || return 0
    gh api "repos/$ORG/$repo/actions/workflows/$wf/runs?per_page=100" \
    | jq -r --arg repo "$repo" '
        [.workflow_runs[] | {job: (.name | sub(" - Update #[0-9]+$"; "")),
                             c: .conclusion, d: .created_at}]
        | group_by(.job) | map(max_by(.d))
        | .[] | select(.c == "failure")
        | ["updater", $repo, (.job | gsub("\t"; " ")), .d[0:10]] | @tsv'
}

# Every committed lockfile, audited. Fetched rather than cloned: two files per
# manifest against a full checkout of every repository.
collect_audit() { # <repo>
    local repo="$1" locks lock dir work
    # Assigned first: a command substitution failing in a for list trips nothing.
    locks="$(gh api "repos/$ORG/$repo/git/trees/HEAD?recursive=1" \
            --jq '.tree[] | select(.path | endswith("package-lock.json"))
                  | select(.path | contains("node_modules") | not) | .path')"
    for lock in $locks; do
        dir="$(dirname "$lock")"
        work="$(mktemp -d)"
        gh api "repos/$ORG/$repo/contents/$lock" --jq '.content' \
            | base64 -d > "$work/package-lock.json"
        gh api "repos/$ORG/$repo/contents/${dir#./}/package.json" --jq '.content' \
            | base64 -d > "$work/package.json"
        # npm audit exits 1 whenever it finds something; the JSON is the result.
        ( cd "$work" && npm audit --json 2>/dev/null || true ) \
            | audit_rows "$repo" "${dir#./}"
        rm -rf "$work"
    done
}

# Security settings, public repositories only (coverage_rows says why).
collect_coverage() { # <repo> <visibility>
    local repo="$1" vis="$2" rulesets
    [ "$vis" = PUBLIC ] || return 0
    rulesets="$(gh api "repos/$ORG/$repo/rulesets" --jq 'length')"
    gh api "repos/$ORG/$repo" | coverage_rows "$repo" "$vis" "$rulesets"
}

collect() {
    local list repo vis empty
    collect_alerts
    # Assigned, not read from < <(repos): a failed process substitution trips nothing.
    list="$(repos)"
    # No repository at all is a read that went wrong, never a clean org.
    [ -n "$list" ] || { echo "digest.sh: no repositories listed for $ORG" >&2; return 1; }
    while IFS=$'\t' read -r repo vis empty; do
        [ -n "$repo" ] || continue
        collect_prs "$repo"
        collect_updater "$repo"
        # An empty repository has no HEAD tree to list lockfiles from.
        if [ "$empty" != true ]; then
            collect_audit "$repo"
        fi
        collect_coverage "$repo" "$vis"
    done <<< "$list"
}

# Sourced by the tests to reach the pure functions above. Without the guard the
# dispatch below runs on source and exits, and the suite tests nothing.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

case "${1:-}" in
    collect)  collect ;;
    render)   render "${2:?usage: digest.sh render <file>}" ;;
    findings) [ -n "${2:-}" ] || { echo "usage: digest.sh findings <file>" >&2; exit 2; }
              findings "$2" ;;
    *) echo "usage: digest.sh {collect|render <file>|findings <file>}" >&2; exit 2 ;;
esac

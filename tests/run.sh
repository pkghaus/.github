#!/usr/bin/env bash
#
# The two functions that decide anything are pure functions of the TSV, which is
# the reason digest.sh is split the way it is: everything here runs without a
# network or a token.
#
#   tests/run.sh
#
# What stops this reporting success for work it did not do: groups report
# failure by exit status, which says nothing about an assertion that never RAN.
# Update the count deliberately, so the edit is someone noticing it moved.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_ASSERTIONS=74
fail=0
TALLY="$(mktemp)"
trap 'rm -f "$TALLY"' EXIT

ok() { printf '  ok   %s\n' "$1"; echo ok >> "$TALLY"; }
no() { printf '  FAIL %s\n    %s\n' "$1" "${2:-}"; fail=$((fail + 1)); echo no >> "$TALLY"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$3] want [$2]"; fi; }

# shellcheck source=scripts/digest.sh
. "$ROOT/scripts/digest.sh"

work="$(mktemp -d)"
trap 'rm -f "$TALLY"; rm -rf "$work"' EXIT
t() { printf '%b' "$1" > "$work/rows.tsv"; printf '%s' "$work/rows.tsv"; }

echo "== findings: the issue exists only when something is wrong =="
f="$(t '')"
if findings "$f"; then no "an empty file reports nothing"; else ok "an empty file reports nothing"; fi

f="$(t '\n\n')"
if findings "$f"; then no "blank lines alone report nothing"; else ok "blank lines alone report nothing"; fi

# A file that is technically non-empty but says nothing must still close the
# issue, or a stray newline keeps a stale issue standing forever.
f="$(t '# nothing this week\n')"
if findings "$f"; then no "a comment alone reports nothing"; else ok "a comment alone reports nothing"; fi

f="$(t 'alert\tapt\tHIGH\tsharp\tGHSA-x\n')"
if findings "$f"; then ok "one row reports something"; else no "one row reports something"; fi

# 1 closes the issue, so a failure must come back as something else. A Latin-1
# byte in suppressions.tsv makes classify raise UnicodeDecodeError.
latin1="$work/latin1-sup.tsv"
printf 'alert\tapt\tGHSA-zz\t2026-12-01\tr\xe9sum\xe9\n' > "$latin1"
rc=0; findings "$f" "$latin1" 2026-09-12 2>/dev/null || rc=$?
eq "a classify crash is not read as nothing" 2 "$rc"
rc=0; findings "$work/absent.tsv" 2>/dev/null || rc=$?
eq "a missing findings file is not read as nothing" 2 "$rc"

echo "== digest.yml: only findings exit 1 closes the issue =="
# The step's own run block, executed with gh and digest.sh stubbed.
step="$work/step.sh"
awk '
    /- name: Open, update or close the issue/ { want = 1; next }
    { l = $0; sub(/^ +/, "", l); ind = length($0) - length(l) }
    want && l == "run: |" { runind = ind; inrun = 1; next }
    inrun && l != "" && ind <= runind { exit }
    inrun { print substr($0, runind + 3) }
' "$ROOT/.github/workflows/digest.yml" > "$step"
# shellcheck disable=SC2016  # stub source, expanded when the stub runs
run_step() { # <findings-exit-code>; the step exit code in $rc, gh calls in $d/gh.log
    d="$work/step-$1"
    mkdir -p "$d/scripts" "$d/bin"
    printf '#!/bin/sh\n[ "$1" = findings ] && exit %s\necho body\n' "$1" > "$d/scripts/digest.sh"
    printf '#!/bin/sh\necho "$*" >> "%s/gh.log"\n[ "$1 $2" = "issue list" ] && echo 5\nexit 0\n' "$d" > "$d/bin/gh"
    : > "$d/gh.log"
    chmod +x "$d/scripts/digest.sh" "$d/bin/gh"
    rc=0
    ( cd "$d" && PATH="$d/bin:$PATH" REPO=pkghaus/.github ASSIGNEE='' \
        bash -e "$step" >/dev/null 2>&1 ) || rc=$?
}
run_step 1
case "$rc $(cat "$d/gh.log")" in
    "0 "*"issue close 5"*) ok "findings exit 1 closes the open issue" ;;
    *) no "findings exit 1 closes the open issue" "rc=$rc gh: $(cat "$d/gh.log")" ;; esac
run_step 2
case "$rc $(cat "$d/gh.log")" in
    0*|*"issue close"*|*"issue edit"*|*"issue create"*)
        no "findings exit 2 fails the job and leaves the issue alone" "rc=$rc gh: $(cat "$d/gh.log")" ;;
    *) ok "findings exit 2 fails the job and leaves the issue alone" ;; esac
run_step 0
case "$rc $(cat "$d/gh.log")" in
    "0 "*"issue edit 5"*) ok "findings exit 0 updates the open issue" ;;
    *) no "findings exit 0 updates the open issue" "rc=$rc gh: $(cat "$d/gh.log")" ;; esac

echo "== suppressions: known findings render but do not hold the issue open =="
sup="$work/sup.tsv"
cat > "$sup" <<'SUPEOF'
# comment, ignored
audit	plausible-worker	GHSA-x	2026-12-01	upstream has shipped nothing to move to
SUPEOF

f="$(t 'audit\tplausible-worker\t.\thigh\tsharp\tGHSA-x\n')"
if findings "$f" "$sup" 2026-09-12; then
    no "a suppressed finding does not hold the issue open"
else
    ok "a suppressed finding does not hold the issue open"
fi
case "$(render "$f" "$sup" 2026-09-12)" in
    *"Known and blocked (1)"*) ok "a suppressed finding is still rendered, not hidden" ;;
    *) no "a suppressed finding is still rendered, not hidden" ;; esac
case "$(render "$f" "$sup" 2026-09-12)" in
    *"upstream has shipped nothing"*) ok "the reason travels with it" ;;
    *) no "the reason travels with it" ;; esac
# A failed Dependabot UPDATE JOB is its own finding. It opens no pull request
# and changes no alert, so every other section reads clean while the updater is
# broken - which is the whole reason this section exists.
#
# Distinct files, not t(): that helper reuses one path, so a second call would
# clobber the fixture the assertions below still refer to.
#
# A VERSION-update job here, deliberately. It runs on a schedule whatever the
# findings, so its failure always counts. A security-update job ("... for
# sharp") counts only while its package still has a finding, which the next
# group tests; used here with no finding beside it, it would be settled.
u="$work/updater.tsv"
printf 'updater\tplausible-worker\tnpm_and_yarn in /.\t2026-09-11\n' > "$u"
usup="$work/updater-sup.tsv"
printf 'updater\tplausible-worker\tnpm_and_yarn in /.\t2099-01-01\tblocked upstream\n' > "$usup"
nofail="$work/no-updater.tsv"
printf 'alert\tapt\tHIGH\tsharp\tGHSA-x\n' > "$nofail"

case "$(render "$u")" in
    *"## Dependabot updater failing (1)"*) ok "a failed updater gets its own section" ;;
    *) no "a failed updater gets its own section" ;; esac
case "$(render "$u")" in
    *"| plausible-worker | npm_and_yarn in /. | 2026-09-11 |"*)
        ok "the failing job and the date both render" ;;
    *) no "the failing job and the date both render" \
          "$(render "$u" | grep '^| plausible' || echo 'no row')" ;; esac
if findings "$u"; then ok "a failed updater holds the issue open"
else no "a failed updater holds the issue open"; fi
# The section is omitted when nothing failed: an empty heading reads as a clean
# bill of health for something that was never checked.
case "$(render "$nofail")" in
    *"Dependabot updater"*) no "no updater section when none failed" ;;
    *) ok "no updater section when none failed" ;; esac
# And it suppresses on the job name, like every other kind.
case "$(render "$u" "$usup" 2026-09-13)" in
    *"## Dependabot updater failing"*) no "a suppressed updater leaves the active section" ;;
    *) ok "a suppressed updater leaves the active section" ;; esac
case "$(render "$u" "$usup" 2026-09-13)" in
    *"Known and blocked (1)"*) ok "a suppressed updater lands in blocked" ;;
    *) no "a suppressed updater lands in blocked" ;; esac

# A table, matching the sections above. Its header is left-aligned like theirs;
# the reason column crowding the others is inherent to a paragraph in a cell.
case "$(render "$f" "$sup" 2026-09-12)" in
    *"| repo | finding | review by | why |"*) ok "blocked findings render as a table" ;;
    *) no "blocked findings render as a table" "no header row" ;; esac
case "$(render "$f" "$sup" 2026-09-12)" in
    *"| plausible-worker | audit GHSA-x | 2026-12-01 |"*)
        ok "a blocked finding reads as one table row" ;;
    *) no "a blocked finding reads as one table row" \
          "$(render "$f" "$sup" 2026-09-12 | grep -A4 'Known and blocked' | tail -1)" ;; esac
case "$(render "$f" "$sup" 2026-09-12)" in
    *"## npm audit"*) no "a suppressed row is not double counted in its own section" ;;
    *) ok "a suppressed row is not double counted in its own section" ;; esac

# The expiry is the whole point: past the date it counts again, so a
# suppression cannot quietly become permanent.
if findings "$f" "$sup" 2026-12-02; then
    ok "an expired suppression counts again"
else
    no "an expired suppression counts again" "still suppressed after its review date"
fi
if findings "$f" "$sup" 2026-12-01; then
    no "the review date itself is still suppressed"
else
    ok "the review date itself is still suppressed"
fi
# A suppression is per repo: another repo with the same advisory still counts.
f="$(t 'audit\tstats\t.\thigh\tsharp\tGHSA-x\n')"
if findings "$f" "$sup" 2026-09-12; then
    ok "a suppression does not leak to another repo"
else
    no "a suppression does not leak to another repo"
fi
# And per advisory: a different one in the same repo still counts.
f="$(t 'audit\tplausible-worker\t.\thigh\tsharp\tGHSA-other\n')"
if findings "$f" "$sup" 2026-09-12; then
    ok "a suppression does not leak to another advisory"
else
    no "a suppression does not leak to another advisory"
fi

echo "== updater: a security update counts only while its package has a finding =="
# The case that held the issue open for months: a security-update job failed,
# the advisory was then fixed another way, and the job - named for a package
# that no longer needs it - never ran again. Its failure stayed its latest run.
sec='updater\tplausible-worker\tnpm_and_yarn in /. for sharp\t2026-09-11\n'
f="$(t "$sec")"
if findings "$f"; then no "a settled security update does not hold the issue open"
else ok "a settled security update does not hold the issue open"; fi
case "$(render "$f")" in
    *"## Dependabot updater"*|*"## Known and blocked"*) no "a settled security update is not rendered anywhere" ;;
    *) ok "a settled security update is not rendered anywhere" ;; esac
# Still live while the package has a finding, from either source.
f="$(t "${sec}alert\tplausible-worker\tHIGH\tsharp\tGHSA-x\n")"
case "$(render "$f")" in
    *"## Dependabot updater failing (1)"*) ok "an open alert keeps the failed security update live" ;;
    *) no "an open alert keeps the failed security update live" ;; esac
f="$(t "${sec}audit\tplausible-worker\t.\thigh\tsharp\tGHSA-x\n")"
case "$(render "$f")" in
    *"## Dependabot updater failing (1)"*) ok "an audit finding keeps the failed security update live" ;;
    *) no "an audit finding keeps the failed security update live" ;; esac
# A suppressed finding is still a finding: the job still has something to fix.
f="$(t "${sec}audit\tplausible-worker\t.\thigh\tsharp\tGHSA-x\n")"
case "$(render "$f" "$sup" 2026-09-12)" in
    *"## Dependabot updater failing (1)"*) ok "a suppressed finding keeps the failed security update live" ;;
    *) no "a suppressed finding keeps the failed security update live" ;; esac
# Matched per repo and per package, never across them.
f="$(t "${sec}alert\tstats\tHIGH\tsharp\tGHSA-x\n")"
case "$(render "$f")" in
    *"Dependabot updater"*) no "another repo's finding does not keep it live" ;;
    *) ok "another repo's finding does not keep it live" ;; esac
f="$(t "${sec}alert\tplausible-worker\tHIGH\tesbuild\tGHSA-y\n")"
case "$(render "$f")" in
    *"Dependabot updater"*) no "another package's finding does not keep it live" ;;
    *) ok "another package's finding does not keep it live" ;; esac
# A name that is not "<ecosystem> in <dir> for <one package>" is kept: it is
# reported rather than guessed away.
f="$(t 'updater\tplausible-worker\tnpm_and_yarn in /. for the minor group\t2026-09-11\n')"
if findings "$f"; then ok "a job name that does not parse is still reported"
else no "a job name that does not parse is still reported"; fi

echo "== render: a section with no rows is omitted, not shown empty =="
f="$(t 'alert\tapt\tHIGH\tsharp\tGHSA-x\n')"
body="$(render "$f")"
case "$body" in *"Dependabot alerts (1)"*) ok "the alert section renders with its count" ;;
                *) no "the alert section renders" "$body" ;; esac
case "$body" in *"## npm audit"*) no "an empty section is omitted" "the heading is present with no rows" ;;
                *) ok "an empty section is omitted" ;; esac
case "$body" in *"Not a status page"*) ok "the body says what the issue is for" ;;
                *) no "the body says what the issue is for" ;; esac
# The case for the tool existing belongs in the runbook, not in front of
# someone trying to act. What must survive is the one thing that reads as a
# defect and is not: npm audit naming a repository the alerts do not.
case "$body" in *"under-report"*) ok "the body explains why npm audit differs from alerts" ;;
                *) no "the body explains why npm audit differs from alerts" ;; esac
# And it must stay short, or it stops being read at all.
lines="$(printf '%s\n' "$body" | sed -n '1,/^## /p' | grep -c .)"
if [ "$lines" -le 14 ]; then ok "the preamble stays short ($lines lines)"
else no "the preamble stays short" "$lines lines before the first section"; fi

# One line per paragraph, however long. GitHub renders a single newline inside a
# paragraph as a LINE BREAK in issues, unlike a .md file in a repository, so a
# hand-wrapped paragraph comes out broken at every source line ending. The
# signature of the bug is a non-blank line followed by another non-blank line.
wrapped="$(printf '%s\n' "$body" | sed -n '1,/^## /p' | awk '
    /^#|^-|^\||^cc /  { prev=""; next }
    NF && prev        { n++ }
    { prev = NF ? $0 : "" }
    END { print n+0 }')"
eq "no preamble paragraph is hand-wrapped" 0 "$wrapped"

# Every table delimiter row left-aligns. GitHub sets no text-align on th, so the
# browser default centres each header over its left-aligned column. Asserted
# against the SCRIPT, not one rendered body: no single fixture reaches all four
# tables, and a table this fixture misses is exactly the one that ships wrong.
centred="$(grep -c -- '|---' "$ROOT/scripts/digest.sh" || true)"
eq "no table header is left at GitHub's centred default" 0 "$centred"
aligned="$(grep -c -- '|:---' "$ROOT/scripts/digest.sh" || true)"
eq "all six tables declare their alignment" 6 "$aligned"
# A body rewritten in place looks equally fresh whenever you read it.
case "$(DIGEST_RUN_AT='2026-01-02 03:04:05 UTC' render "$f")" in
    *"Last run 2026-01-02 03:04:05 UTC"*) ok "the body stamps which run wrote it" ;;
    *) no "the body stamps which run wrote it" ;; esac
case "$(DIGEST_RUN_AT=x DIGEST_RUN_URL=https://example.invalid/r/1 render "$f")" in
    *"https://example.invalid/r/1"*) ok "the stamp links the run when one is known" ;;
    *) no "the stamp links the run when one is known" ;; esac
case "$body" in *"cc @"*) no "no team is mentioned when none is configured" ;;
                *) ok "no team is mentioned when none is configured" ;; esac
# A team cannot be an assignee on GitHub, so this mention is how it is reached.
case "$(DIGEST_TEAM=pkghaus/maintainers render "$f")" in
    *"cc @pkghaus/maintainers"*) ok "a configured team is mentioned in the body" ;;
    *) no "a configured team is mentioned in the body" ;; esac

echo "== render: an @ from outside is not a mention =="
# Every scoped npm package starts with one, and @cloudflare is a real
# organization: the first digest linked it mid-sentence from a table cell.
f="$(t 'audit\tplausible-worker\t.\thigh\t@cloudflare/vitest-pool-workers\tGHSA-x\n')"
case "$(render "$f")" in
    *"&#64;cloudflare/vitest-pool-workers"*) ok "a scoped package name is escaped" ;;
    *) no "a scoped package name is escaped" "$(render "$f" | grep cloudflare)" ;; esac
case "$(render "$f")" in
    *"| @cloudflare"*) no "no bare @ survives in a table cell" ;;
    *) ok "no bare @ survives in a table cell" ;; esac
f="$(t 'pr\tapt\t7\tpassing\t1\tbump @scope/thing\n')"
case "$(render "$f")" in
    *"&#64;scope/thing"*) ok "a pull request title is escaped too" ;;
    *) no "a pull request title is escaped too" ;; esac
# Columns that never had an escape of their own: a manifest path and a blocked
# key. The suppression is written with the raw @ and must still match.
f="$(t 'audit\tapt\tpackages/@pkghaus/x\thigh\tsharp\tGHSA-y\n')"
case "$(render "$f")" in
    *"| apt | packages/&#64;pkghaus/x | high |"*) ok "an @ in an audit manifest path is escaped" ;;
    *) no "an @ in an audit manifest path is escaped" "$(render "$f" | grep '^| apt' || echo 'no row')" ;; esac
scoped='npm_and_yarn in /. for @cloudflare/vitest-pool-workers'
f="$(t "updater\tplausible-worker\t$scoped\t2026-09-11\nalert\tplausible-worker\tHIGH\t@cloudflare/vitest-pool-workers\tGHSA-q\n")"
ssup="$work/scoped-sup.tsv"
printf 'updater\tplausible-worker\t%s\t2099-01-01\tblocked upstream\n' "$scoped" > "$ssup"
case "$(render "$f" "$ssup" 2026-09-13)" in
    *"| plausible-worker | updater npm_and_yarn in /. for &#64;cloudflare/vitest-pool-workers | 2099-01-01 |"*)
        ok "an @ in a blocked updater key is escaped" ;;
    *) no "an @ in a blocked updater key is escaped" \
          "$(render "$f" "$ssup" 2026-09-13 | grep '^| plausible-worker | updater' || echo 'no row')" ;; esac
# The cc line is a mention on purpose and must survive.
f="$(t 'alert\tapt\tHIGH\tsharp\tGHSA-x\n')"
case "$(DIGEST_TEAM=pkghaus/maintainers render "$f")" in
    *"cc @pkghaus/maintainers"*) ok "the deliberate team mention is left alone" ;;
    *) no "the deliberate team mention is left alone" ;; esac

echo "== render: pull request age becomes stale wording at the threshold =="
f="$(t 'pr\tapt\t7\tpassing\t2\tbump x\n')"
case "$(render "$f")" in *"2 days |"*) ok "a fresh pull request is not called stale" ;;
                         *) no "a fresh pull request is not called stale" ;; esac
f="$(t 'pr\tapt\t7\tpassing\t9\tbump x\n')"
case "$(render "$f")" in *"9 days, stale"*) ok "an old pull request is called stale" ;;
                         *) no "an old pull request is called stale" ;; esac
# The boundary itself, because >= and > is exactly the kind of thing that is
# wrong for a week before anyone notices.
f="$(t "pr\tapt\t7\tpassing\t$STALE_DAYS\tbump x\n")"
case "$(render "$f")" in *"stale"*) ok "the threshold day itself counts as stale" ;;
                         *) no "the threshold day itself counts as stale" ;; esac

echo "== render: a pull request links into its own repository =="
# GitHub resolves a bare #N against the repository holding the issue, so the
# first digest to list a PR linked to itself.
f="$(t 'pr\tplausible-worker\t17\tpassing\t0\tbump x\n')"
case "$(render "$f")" in
    *"| plausible-worker | [#17](https://github.com/pkghaus/plausible-worker/pull/17) |"*)
        ok "a pull request links into its own repository" ;;
    *) no "a pull request links into its own repository" "$(render "$f" | grep '^| plausible' || echo 'no row')" ;; esac
case "$(render "$f")" in
    *"| #17 |"*) no "no bare #N reaches the body" ;;
    *) ok "no bare #N reaches the body" ;; esac

echo "== render: a title containing a pipe cannot break the table =="
f="$(t 'pr\tapt\t7\tpassing\t1\tbump a\\|b\n')"
case "$(render "$f")" in *'a\|b'*) ok "a pipe in a title stays escaped" ;;
                         *) no "a pipe in a title stays escaped" "$(render "$f")" ;; esac

echo "== audit_rows: one row per ADVISORY, not per package in the chain =="
# The real shape npm emits: the carrier's via holds the advisory object, every
# dependent's via holds only a name. Measured on apt's lockfile, 3 rows came
# from 1 advisory, and counting the rows inflated an estate figure threefold.
chain='{"vulnerabilities":{
  "sharp":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-rgj7-g3m4-5g8c"}]},
  "miniflare":{"severity":"high","via":["sharp"]},
  "wrangler":{"severity":"high","via":["miniflare"]}}}'
out="$(printf '%s' "$chain" | audit_rows apt worker)"
eq "a three-package chain is one row" 1 "$(printf '%s\n' "$out" | grep -c .)"
eq "the row names the carrier, not a dependent" "sharp" "$(printf '%s' "$out" | cut -f5)"
eq "the row carries the advisory id" "GHSA-rgj7-g3m4-5g8c" "$(printf '%s' "$out" | cut -f6)"

two='{"vulnerabilities":{
  "sharp":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-aaaa"}]},
  "nanoid":{"severity":"moderate","via":[{"url":"https://github.com/advisories/GHSA-bbbb"}]}}}'
out="$(printf '%s' "$two" | audit_rows apt worker)"
eq "two real advisories are two rows" 2 "$(printf '%s\n' "$out" | grep -c .)"
eq "rows are sorted by package" "nanoid" "$(printf '%s\n' "$out" | head -1 | cut -f5)"

# One package can carry two advisories, and that is genuinely two findings.
dbl='{"vulnerabilities":{"sharp":{"severity":"high","via":[
  {"url":"https://github.com/advisories/GHSA-aaaa"},{"url":"https://github.com/advisories/GHSA-bbbb"}]}}}'
eq "one package with two advisories is two rows" 2 \
   "$(printf '%s' "$dbl" | audit_rows apt worker | grep -c .)"

out="$(printf '%s' '{"vulnerabilities":{}}' | audit_rows apt worker)"
eq "a clean audit yields no rows" "" "$out"
# npm has emitted non-JSON on failure before; a crash here would take the whole
# digest down with it rather than losing one manifest.
out="$(printf '%s' 'npm error code ENOTFOUND' | audit_rows apt worker)"
eq "unparseable audit output yields no rows rather than failing" "" "$out"

echo "== coverage_rows: only what is OFF, and rulesets only where they are possible =="
on='{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
eq "a fully covered public repo yields nothing" "" "$(printf '%s' "$on" | coverage_rows apt PUBLIC 1)"
case "$(printf '%s' "$on" | coverage_rows apt PUBLIC 0)" in
    *$'cover\tapt\truleset\tnone'*) ok "a public repo with no ruleset is a finding" ;;
    *) no "a public repo with no ruleset is a finding" ;; esac
off='{"security_and_analysis":{"secret_scanning":{"status":"disabled"}}}'
out="$(printf '%s' "$off" | coverage_rows new PUBLIC 1)"
eq "both scanning settings are reported when off or unset" 2 "$(printf '%s\n' "$out" | grep -c .)"

# GitHub returns security_and_analysis only to a caller with admin access, so a
# repo the token cannot see has no block at all. That is not two settings off:
# it rendered as "unset" twice for reproducible, whose settings were on.
out="$(printf '%s' '{"name":"x"}' | coverage_rows reproducible PUBLIC 1)"
eq "a repo the token cannot see is one not-readable row" \
   "$(printf 'cover\treproducible\tsecurity settings\tnot readable')" "$out"
case "$out" in
    *unset*) no "and it is never reported as unset" "$out" ;;
    *) ok "and it is never reported as unset" ;; esac
f="$(t 'cover\treproducible\tsecurity settings\tnot readable\n')"
case "$(render "$f")" in
    *"## Security settings not enabled or not readable (1)"*"**not readable** means"*"| reproducible | security settings | not readable |"*)
        ok "the section names both cases and explains not readable" ;;
    *) no "the section names both cases and explains not readable" ;; esac

# On this plan a private repository is refused rulesets outright and secret
# scanning needs paid Advanced Security, so every check here would fire on wiki
# and brand every week forever. The live dry run produced exactly those four
# rows before this exemption existed.
eq "a private repo yields nothing at all" "" "$(printf '%s' "$off" | coverage_rows wiki PRIVATE na)"
eq "a private repo is not faulted for having no ruleset" "" "$(printf '%s' "$on" | coverage_rows brand PRIVATE na)"

# It must DRAIN stdin before deciding. Exiting early hands the producer an
# EPIPE, which pipefail turns into a failed pipeline and set -e turns into an
# aborted run. A live dry run died that way after the alerts and before any
# audit, and rendered as a quiet week. Reproduced with a producer large enough
# that it cannot have been buffered away.
if ( set -o pipefail
     python3 -c 'print("x" * 200000)' | coverage_rows wiki PRIVATE na >/dev/null ); then
    ok "an exempt repo still drains stdin, so the producer sees no EPIPE"
else
    no "an exempt repo still drains stdin" "the pipeline failed, which set -e would make fatal"
fi

printf '\n%s passed, %s failed\n' "$(grep -c ok "$TALLY")" "$fail"
ran=$(grep -c . "$TALLY")
if [ "$ran" -ne "$EXPECTED_ASSERTIONS" ]; then
    printf 'FAIL  %s assertions ran, expected %s.\n' "$ran" "$EXPECTED_ASSERTIONS" >&2
    exit 1
fi
[ "$fail" -eq 0 ]

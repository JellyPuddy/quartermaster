#!/usr/bin/env bash
# Usage: branch-stats.sh [base-ref] [head-ref]
# Prints markdown tables of lines changed on head since its merge base with base:
# whole-branch totals by category, then one row per commit with per-category columns.
set -euo pipefail

base_ref="${1:-}"
head_ref="${2:-HEAD}"

if [ -z "$base_ref" ]; then
  git fetch -q origin main 2>/dev/null || true
  if git rev-parse -q --verify origin/main >/dev/null; then base_ref=origin/main; else base_ref=main; fi
fi

base=$(git merge-base "$base_ref" "$head_ref")
branch=$(git rev-parse --abbrev-ref "$head_ref")

cat_awk='
function cat(f) {
  if (f ~ /__generated__\// || f ~ /^app\/javascript\/api\// || f ~ /\.generated\./ || f == "db/schema.rb" || f ~ /(^|\/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|Gemfile\.lock)$/) return "generated";
  if (f ~ /^spec\// || f ~ /^test\// || f ~ /__tests__\// || f ~ /\.(spec|test)\.[jt]sx?$/ || f ~ /^app\/javascript\/tests\// || f ~ /^e2e\//) return "tests";
  if (f ~ /^docs\/api\// || f ~ /openapi\.ya?ml$/) return "openapi";
  if (f ~ /^docs\// || f ~ /\.md$/) return "docs";
  if (f ~ /^config\/locales\//) return "locales";
  if (f ~ /^db\/migrate\//) return "migration";
  if (f ~ /^app\/javascript\// || f ~ /\.(erb|tsx?|jsx?|s?css)$/) return "frontend";
  if (f ~ /^(Gemfile|package\.json|\.github\/|\.claude\/|lefthook|\.rubocop|\.oxlint|\.oxfmt|tsconfig|vite\.config|config\/environments\/|config\/application\.rb)/) return "config";
  return "backend";
}
'
order="backend frontend tests generated openapi docs locales migration config"

summarize() {  # reads numstat on stdin; prints "cat added removed files" lines plus TOTAL
  awk "$cat_awk"'
  $1 == "-" { next }
  { c=cat($3); add[c]+=$1; del[c]+=$2; n[c]++; ta+=$1; td+=$2; tn++ }
  END { for (c in add) print c, add[c], del[c], n[c]; print "TOTAL", ta+0, td+0, tn+0 }'
}

echo "# Branch stats: \`$branch\` vs \`$base_ref\` (merge base \`${base:0:10}\`)"
echo
git diff --numstat "$base..$head_ref" > "${TMPDIR:-/tmp}/branch-stats-numstat.$$"
trap 'rm -f "${TMPDIR:-/tmp}/branch-stats-numstat.$$"' EXIT

summarize < "${TMPDIR:-/tmp}/branch-stats-numstat.$$" | awk -v order="$order" '
  { a[$1]=$2; d[$1]=$3; n[$1]=$4 }
  END {
    printf "**Whole branch: %d files, +%d / -%d**\n\n", n["TOTAL"], a["TOTAL"], d["TOTAL"];
    print "| Category | Files | Added | Removed | Share of additions |";
    print "|---|---|---|---|---|";
    split(order, o, " ");
    for (i=1; i<=length(o); i++) { c=o[i]; if (!(c in a)) continue;
      printf "| %s | %d | %d | %d | %d%% |\n", c, n[c], a[c], d[c], (a["TOTAL"] ? 100*a[c]/a["TOTAL"] : 0) }
  }'

echo
echo "**Largest files (by lines added):**"
echo
sort -rn "${TMPDIR:-/tmp}/branch-stats-numstat.$$" | awk '$1 != "-" && NR<=8 { printf "- `%s` +%d / -%d\n", $3, $1, $2 }'

echo
echo "**Per commit** (branch order; per-commit sums can exceed the branch total when later commits rework earlier files):"
echo
echo "| Commit | Files | Total | Backend | Frontend | Tests | Generated | Other |"
echo "|---|---|---|---|---|---|---|---|"
for c in $(git rev-list --reverse "$base..$head_ref"); do
  short=$(git log -1 --format='%h' "$c"); subject=$(git log -1 --format='%s' "$c")
  git show --numstat --format= "$c" | summarize | awk -v short="$short" -v subject="$subject" -v order="$order" '
    function cell(c) { if (!(c in a)) return ""; return (d[c] ? sprintf("+%d / -%d", a[c], d[c]) : sprintf("+%d", a[c])) }
    { a[$1]=$2; d[$1]=$3; n[$1]=$4 }
    END {
      other=""; split(order, o, " ");
      for (i=5; i<=length(o); i++) { c=o[i]; if (c in a) other = other (other ? ", " : "") c " " cell(c) }
      printf "| `%s` %s | %d | %s | %s | %s | %s | %s | %s |\n", short, subject, n["TOTAL"], cell("TOTAL"), cell("backend"), cell("frontend"), cell("tests"), cell("generated"), other
    }'
done

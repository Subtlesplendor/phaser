#!/usr/bin/env bash
#
# Plan one night's mutation rotation group.
#
# A whole-repository campaign is far too expensive to run nightly: the oracle
# rebuilds the project from a cold cache for every mutant, so the full set costs
# hours. DEVELOPMENT_WORKFLOW.md section 5.3 allows a documented rotation for
# exactly this case, and this script computes the schedule.
#
# The unit scheduled is one (file, mutation operator) cell rather than one file.
# Cells are what the pinned zentinel can actually select — its v0.1.0 `run`
# takes `--operator` and reads the include list from a configuration file, and
# has no file-scoping flag — and they divide the work far more evenly. Phaser's
# largest source file carries about a fifth of all mutants, so a file-granular
# rotation could never make a night smaller than that file; splitting it by
# operator brings the worst night down by roughly a factor of three.
#
# Cells are packed by descending mutant count, each going to the group that
# currently holds the fewest mutants, with ties broken on the cell name. The
# packing is a pure function of the mutant listing, so the same commit and group
# index always select the same work.
#
# The mutant listing is read on standard input in `zentinel list-mutants
# --format text` form, whose second field is the operator and whose third is
# `path:line:column`.
#
# One configuration is written per operator in the selected group, because a
# zentinel run covers a single operator. Each is the base configuration with its
# `include` list replaced; operators, oracle command, and timeout stay as
# `zentinel.toml` declares them. The plan is printed on standard output, one
# invocation per line, as `OPERATOR CONFIG_PATH MUTANT_COUNT`.
#
# Usage:
#   zentinel list-mutants --format text |
#     tools/ci/mutation_rotation.sh BASE_CONFIG GROUP_COUNT GROUP_INDEX OUT_DIR
#
# OUT_DIR must sit inside the project root: zentinel rejects a `--config` path
# outside it.

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 BASE_CONFIG GROUP_COUNT GROUP_INDEX OUT_DIR" >&2
  exit 2
fi

readonly base_config=$1
readonly group_count=$2
readonly group_index=$3
readonly out_dir=$4

if [[ ! -f "$base_config" ]]; then
  echo "$0: base configuration not found: $base_config" >&2
  exit 2
fi

if [[ ! "$group_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "$0: GROUP_COUNT must be a positive integer, got: $group_count" >&2
  exit 2
fi

if [[ ! "$group_index" =~ ^(0|[1-9][0-9]*)$ ]] || ((group_index >= group_count)); then
  echo "$0: GROUP_INDEX must be in [0, $group_count), got: $group_index" >&2
  exit 2
fi

if ! grep -q '^include = \[' "$base_config"; then
  echo "$0: no \`include = [\` in the base configuration: $base_config" >&2
  exit 2
fi

mkdir -p "$out_dir"

# `OPERATOR<TAB>PATH<TAB>COUNT` for every cell in the selected group.
readonly cells=$(
  awk -v groups="$group_count" -v want="$group_index" '
    {
      split($3, location, ":")
      path = location[1]
      operator = $2
      if (path == "" || operator == "") next
      count[operator "\t" path] += 1
    }
    END {
      total = 0
      for (cell in count) {
        total += 1
        cells[total] = cell
      }
      # Descending mutant count, ascending cell name.
      for (i = 1; i <= total; i += 1) {
        for (j = i + 1; j <= total; j += 1) {
          a = cells[i]; b = cells[j]
          if (count[b] > count[a] || (count[b] == count[a] && b < a)) {
            cells[i] = b; cells[j] = a
          }
        }
      }
      for (g = 0; g < groups; g += 1) load[g] = 0
      for (i = 1; i <= total; i += 1) {
        lightest = 0
        for (g = 1; g < groups; g += 1) {
          if (load[g] < load[lightest]) lightest = g
        }
        load[lightest] += count[cells[i]]
        if (lightest == want) print cells[i] "\t" count[cells[i]]
      }
    }
  '
)

if [[ -z "$cells" ]]; then
  echo "$0: rotation group $group_index of $group_count is empty" >&2
  echo "$0: there are fewer mutant cells than groups; reduce GROUP_COUNT" >&2
  exit 1
fi

# Record the plan in the job log. The report names the mutants; this names the
# work the night was sized against.
{
  echo "mutation rotation group $group_index of $group_count"
  printf '%s\n' "$cells" |
    awk -F'\t' '{ printf "  %5s mutants  %-20s %s\n", $3, $1, $2 }'
  printf '  %5s mutants  TOTAL\n' \
    "$(printf '%s\n' "$cells" | awk -F'\t' '{ s += $3 } END { print s }')"
} >&2

include_list=$(mktemp)
trap 'rm -f "$include_list"' EXIT

readonly operators=$(printf '%s\n' "$cells" | cut -f1 | sort -u)

for operator in $operators; do
  config="$out_dir/$operator.toml"

  # The include list is passed to the rewriter in a file rather than in an awk
  # variable, because `awk -v` cannot carry newlines. A trailing comma is not
  # part of the TOML subset zentinel accepts, so separators go between entries.
  printf '%s\n' "$cells" |
    awk -F'\t' -v operator="$operator" '
      $1 == operator {
        if (emitted > 0) printf ",\n"
        printf "  \"%s\"", $2
        emitted += 1
      }
      END { printf "\n" }
    ' > "$include_list"

  # Replace the `include` array in the `[project]` table and copy the rest
  # verbatim. The array is matched from `include = [` to its closing bracket, so
  # a multi-line list in the base configuration is replaced whole.
  awk -v listfile="$include_list" '
    in_include == 1 {
      if ($0 ~ /\]/) in_include = 0
      next
    }
    /^include = \[/ {
      print "# Generated by tools/ci/mutation_rotation.sh. Do not edit."
      print "include = ["
      while ((getline entry < listfile) > 0) print entry
      close(listfile)
      print "]"
      if ($0 !~ /\]/) in_include = 1
      next
    }
    { print }
  ' "$base_config" > "$config"

  count=$(
    printf '%s\n' "$cells" |
      awk -F'\t' -v operator="$operator" '$1 == operator { s += $3 } END { print s }'
  )
  printf '%s %s %s\n' "$operator" "$config" "$count"
done

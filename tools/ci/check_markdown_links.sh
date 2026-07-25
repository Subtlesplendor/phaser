#!/usr/bin/env bash

set -euo pipefail

readonly link_pattern='\[[^][]*\]\(([^()]*)\)'

checked_files=0
checked_links=0
broken_links=0

while IFS= read -r -d '' file; do
  ((checked_files += 1))
  directory=${file%/*}
  if [[ "$directory" == "$file" ]]; then
    directory=.
  fi

  line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    remaining=$line

    while [[ "$remaining" =~ $link_pattern ]]; do
      full_match=${BASH_REMATCH[0]}
      target=${BASH_REMATCH[1]}
      remaining=${remaining#*"$full_match"}

      if [[ "$target" == \<*\> ]]; then
        target=${target#<}
        target=${target%>}
      else
        target=${target%%[[:space:]]*}
      fi

      case "$target" in
        "" | \#* | http://* | https://* | mailto:*)
          continue
          ;;
      esac

      local_path=${target%%#*}
      if [[ "$local_path" == /* ]]; then
        resolved_path=.${local_path}
      else
        resolved_path=$directory/$local_path
      fi

      ((checked_links += 1))
      if [[ ! -e "$resolved_path" ]]; then
        printf '%s:%d: broken local link: %s\n' \
          "$file" "$line_number" "$target" >&2
        ((broken_links += 1))
      fi
    done
  done < "$file"
done < <(git ls-files -z -- '*.md')

printf 'Checked %d local links across %d Markdown files.\n' \
  "$checked_links" "$checked_files"

if ((broken_links > 0)); then
  printf 'Found %d broken local link(s).\n' "$broken_links" >&2
  exit 1
fi

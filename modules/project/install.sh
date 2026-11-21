# Usage: agent-tools-install <links-file>
#
# Links each "<destination>\t<store path>" line of the links file into the
# project. The links made are recorded in the repository's git directory; a
# recorded link is ours only while it is still that link, and nothing else in
# the project is ever replaced or removed.

links_file=$1

if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "agent-tools: not inside a git repository; skills are not linked" >&2
  exit 0
fi
cd "$root"
state=$(git rev-parse --git-path agent-tools-links)

declare -A wanted=()
while IFS=$'\t' read -r destination target; do
  wanted[$destination]=$target
done < "$links_file"

declare -A recorded=()
if [[ -f $state ]]; then
  while IFS=$'\t' read -r destination target; do
    [[ -n $destination && -n $target ]] || continue
    recorded[$destination]=$target
  done < "$state"
fi

links_to() {
  [[ -L $1 && $(readlink "$1") == "$2" ]]
}

for destination in "${!recorded[@]}"; do
  if links_to "$destination" "${recorded[$destination]}" \
    && [[ ${wanted[$destination]:-} != "${recorded[$destination]}" ]]; then
    rm "$destination"
  fi
done

linked=()
for destination in "${!wanted[@]}"; do
  if links_to "$destination" "${wanted[$destination]}"; then
    linked+=("$destination")
  elif [[ -e $destination || -L $destination ]]; then
    echo "agent-tools: $destination exists and is not managed by agent-tools; leaving it alone" >&2
  else
    mkdir -p "$(dirname "$destination")"
    ln -s "${wanted[$destination]}" "$destination"
    linked+=("$destination")
  fi
done

if ((${#linked[@]})); then
  for destination in "${linked[@]}"; do
    printf '%s\t%s\n' "$destination" "${wanted[$destination]}"
  done | sort > "$state"
else
  rm -f "$state"
fi

# The links point into this machine's store, so keep them out of commits
# without editing the project's own .gitignore.
exclude=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"
touch "$exclude"
rewritten=$(mktemp)
sed '/^# agent-tools begin$/,/^# agent-tools end$/d' "$exclude" > "$rewritten"
if ((${#linked[@]})); then
  {
    echo '# agent-tools begin'
    printf '/%s\n' "${linked[@]}" | sort
    echo '# agent-tools end'
  } >> "$rewritten"
fi
if ! cmp --silent "$rewritten" "$exclude"; then
  cat "$rewritten" > "$exclude"
fi
rm "$rewritten"

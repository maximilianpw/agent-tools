# Usage: agent-tools-install <links-file> <skills-dir>...
#
# Links each "<destination>\t<store path>" line of the links file into the
# project, and removes links it made earlier that are no longer listed. A
# symlink into /nix/store inside a skills directory is ours; anything else
# there belongs to the project and is never touched.

links_file=$1
shift

root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
cd "$root"

declare -A wanted=()
while IFS=$'\t' read -r destination source; do
  wanted[$destination]=$source
done < "$links_file"

is_ours() {
  [[ -L $1 && $(readlink "$1") == /nix/store/* ]]
}

for dir in "$@"; do
  [[ -d $dir ]] || continue
  for entry in "$dir"/*; do
    if is_ours "$entry" && [[ -z ${wanted[$entry]:-} ]]; then
      rm "$entry"
    fi
  done
  rmdir --parents --ignore-fail-on-non-empty "$dir"
done

linked=()
for destination in "${!wanted[@]}"; do
  if [[ -e $destination || -L $destination ]] && ! is_ours "$destination"; then
    echo "agent-tools: $destination exists and is not managed by agent-tools; leaving it alone" >&2
    continue
  fi
  mkdir -p "$(dirname "$destination")"
  ln -sfn "${wanted[$destination]}" "$destination"
  linked+=("$destination")
done

# The links point into this machine's store, so keep them out of commits
# without editing the project's own .gitignore.
if exclude=$(git rev-parse --git-path info/exclude 2>/dev/null); then
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
fi

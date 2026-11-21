# Usage: agent-tools-link-config <clean|link> <state-file> <config-dir> <source-dir> [<excluded-name>...]
#
# Links every entry of the source directory into the harness's configuration
# directory, so a checkout can be edited in place. The state file records each
# link made, as "<name>\t<target>". A recorded link is ours only while it is
# still that link: once something replaces it with a file of its own, it is
# never touched again.
#
# `clean` removes our links that are no longer wanted and makes none; it runs
# before Home Manager checks for files in its way, so an entry can move from
# the checkout to a declared file. `link` does both. An empty source directory
# argument wants nothing.

mode=$1
state=$2
dest=$3
source=$4
shift 4

declare -A excluded=()
for name in "$@"; do
  excluded[$name]=1
done

declare -A wanted=()
if [[ -n $source ]]; then
  if [[ -d $source ]]; then
    for entry in "$source"/*; do
      [[ -e $entry || -L $entry ]] || continue
      name=$(basename "$entry")
      # The state file is line- and tab-separated.
      [[ $name != *$'\n'* && $name != *$'\t'* ]] || continue
      [[ -n ${excluded[$name]:-} ]] || wanted[$name]=$entry
    done
  elif [[ $mode == link ]]; then
    echo "agent-tools: $source does not exist; nothing from it is linked into $dest" >&2
  fi
fi

declare -A recorded=()
if [[ -f $state ]]; then
  while IFS=$'\t' read -r name target; do
    [[ -n $name && -n $target ]] || continue
    recorded[$name]=$target
  done < "$state"
fi

links_to() {
  [[ -L $dest/$1 && $(readlink "$dest/$1") == "$2" ]]
}

declare -A kept=()
for name in "${!recorded[@]}"; do
  links_to "$name" "${recorded[$name]}" || continue
  if [[ ${wanted[$name]:-} == "${recorded[$name]}" ]]; then
    kept[$name]=${recorded[$name]}
  else
    rm "$dest/$name"
  fi
done

if [[ $mode == link ]]; then
  for name in "${!wanted[@]}"; do
    link=$dest/$name
    if links_to "$name" "${wanted[$name]}"; then
      kept[$name]=${wanted[$name]}
    elif [[ -e $link || -L $link ]]; then
      # A link into the store is Home Manager's; it wins without comment.
      if [[ ! -L $link || $(readlink "$link") != /nix/store/* ]]; then
        echo "agent-tools: $link exists and is not managed by agent-tools; leaving it alone" >&2
      fi
    else
      mkdir -p "$dest"
      ln -s "${wanted[$name]}" "$link"
      kept[$name]=${wanted[$name]}
    fi
  done
fi

if ((${#kept[@]})); then
  mkdir -p "$(dirname "$state")"
  for name in "${!kept[@]}"; do
    printf '%s\t%s\n' "$name" "${kept[$name]}"
  done | sort > "$state"
else
  rm -f "$state"
fi

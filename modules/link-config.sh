# Usage: agent-tools-link-config <state-file> <config-dir> <source-dir> [<excluded-name>...]
#
# Links every entry of the source directory into the harness's configuration
# directory, so a checkout can be edited in place. The state file lists the
# links made last time; only those are ever replaced or removed. An empty
# source directory argument just removes them.

state=$1
dest=$2
source=$3
shift 3

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
      [[ -n ${excluded[$name]:-} ]] || wanted[$name]=$entry
    done
  else
    echo "agent-tools: $source does not exist; nothing from it is linked into $dest" >&2
  fi
fi

declare -A ours=()
if [[ -f $state ]]; then
  while IFS= read -r name; do
    ours[$name]=1
    if [[ -L $dest/$name && -z ${wanted[$name]:-} ]]; then
      rm "$dest/$name"
    fi
  done < "$state"
fi

linked=()
for name in "${!wanted[@]}"; do
  link=$dest/$name
  if [[ -e $link || -L $link ]] && [[ -z ${ours[$name]:-} ]]; then
    # A link into the store is Home Manager's; it wins without comment.
    if [[ ! -L $link || $(readlink "$link") != /nix/store/* ]]; then
      echo "agent-tools: $link exists and is not managed by agent-tools; leaving it alone" >&2
    fi
    continue
  fi
  mkdir -p "$dest"
  ln -sfn "${wanted[$name]}" "$link"
  linked+=("$name")
done

if ((${#linked[@]})); then
  mkdir -p "$(dirname "$state")"
  printf '%s\n' "${linked[@]}" | sort > "$state"
else
  rm -f "$state"
fi

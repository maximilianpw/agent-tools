# Usage: agent-tools status
#
# Expects `base` (the directory the skills directories are relative to) and
# the `dirs` array from the wrapper. Lists skills that agent-tools did not
# put there: anything in a skills directory that is not a link into
# /nix/store.

if [[ ${1:-} != status || $# -ne 1 ]]; then
  echo "usage: agent-tools status" >&2
  exit 2
fi

cd "$base"

for dir in "${dirs[@]}"; do
  managed=0
  unmanaged=()
  for entry in "$dir"/*; do
    [[ -e $entry || -L $entry ]] || continue
    if [[ -L $entry && $(readlink "$entry") == /nix/store/* ]]; then
      managed=$((managed + 1))
    elif [[ -L $entry ]]; then
      unmanaged+=("$(basename "$entry") -> $(readlink "$entry")")
    elif [[ -d $entry ]]; then
      unmanaged+=("$(basename "$entry")")
    fi
  done

  echo "$dir: $managed managed, ${#unmanaged[@]} unmanaged"
  if ((${#unmanaged[@]})); then
    printf '  %s\n' "${unmanaged[@]}"
  fi
done

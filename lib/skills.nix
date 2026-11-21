{lib}: let
  isSkill = dir: builtins.pathExists "${dir}/SKILL.md";

  skipped = [".git" "node_modules"];

  find = depth: dir:
    if isSkill dir
    then [dir]
    else if depth == 0
    then []
    else
      lib.concatMap (name: find (depth - 1) "${dir}/${name}") (
        lib.attrNames (
          lib.filterAttrs (name: type: type == "directory" && !lib.elem name skipped) (builtins.readDir dir)
        )
      );

  # Store paths carry string context, which attribute names may not.
  idOf = dir: builtins.unsafeDiscardStringContext (baseNameOf dir);

  discover = sourceName: source: let
    root = "${source.path}";
    found =
      if isSkill root
      then [
        {
          id = sourceName;
          path = root;
        }
      ]
      else
        map (path: {
          id = idOf path;
          inherit path;
        }) (find source.depth root);
    foundIds = map (skill: skill.id) found;
    missing = lib.subtractLists foundIds (lib.optionals (source.include != null) source.include ++ source.exclude);
    selected =
      lib.filter (
        skill:
          (source.include == null || lib.elem skill.id source.include)
          && !lib.elem skill.id source.exclude
      )
      found;
  in
    if missing != []
    then
      throw ''
        skill source `${sourceName}`: no skill named ${lib.concatStringsSep ", " missing}.
        Found: ${lib.concatStringsSep ", " foundIds}''
    else
      map (skill: {
        id = source.prefix + skill.id;
        inherit (skill) path;
        source = sourceName;
      })
      selected;
in {
  /*
  Turn a `skills.sources` set into `{ <skill id> = <directory>; }`.

  A source that is itself a skill takes its attribute name as id; otherwise
  every directory holding a SKILL.md, up to `depth` levels down, is a skill
  named after its directory. Two skills with one id is an error, resolved with
  a source's `include`, `exclude` or `prefix`.
  */
  resolve = sources: let
    skills = lib.concatLists (lib.mapAttrsToList discover sources);
    byId = lib.groupBy (skill: skill.id) skills;
    conflicts = lib.filterAttrs (_: group: lib.length group > 1) byId;
    describe = id: group: "  ${id}: ${lib.concatMapStringsSep ", " (skill: "${skill.source} (${skill.path})") group}";
  in
    if conflicts != {}
    then
      throw ''
        agents: several skills share an id. Set `include`, `exclude` or `prefix` on a source.
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList describe conflicts)}''
    else lib.mapAttrs (_: group: (lib.head group).path) byId;
}

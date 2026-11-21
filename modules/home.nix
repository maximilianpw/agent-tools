{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.agents;
  instructionsType = types.either types.path types.lines;

  fileType = types.coercedTo types.path (source: {inherit source;}) (types.submodule {
    options = {
      source = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File or directory to link.";
      };
      text = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Contents of the file, in place of `source`.";
      };
      recursive = mkOption {
        type = types.bool;
        default = false;
        description = "Link the files inside a source directory one by one, leaving the directory writable.";
      };
      force = mkOption {
        type = types.bool;
        default = false;
        description = "Replace a file that is already there.";
      };
    };
  });

  configFiles =
    lib.concatMapAttrs (
      name: harness:
        if harness.files != {} && harness.home.configDir == null
        then throw "agents.${name}.files: set agents.${name}.home.configDir, the directory these files are relative to."
        else
          lib.mapAttrs' (
            file: value:
              lib.nameValuePair "${harness.home.configDir}/${file}" (lib.filterAttrs (_: field: field != null) value)
          )
          harness.files
    )
    cfg.resolved.harnesses;
  isText = instructions: lib.isString instructions && !lib.hasPrefix "/" instructions;

  instructionsFor = harness: let
    base =
      if harness.instructions != null
      then harness.instructions
      else cfg.defaults.instructions;
  in
    if harness.extraInstructions != ""
    then {
      text = lib.concatStringsSep "\n" (
        lib.optional (base != null) (
          if isText base
          then base
          else builtins.readFile base
        )
        ++ [harness.extraInstructions]
      );
    }
    else if base == null
    then null
    else if isText base
    then {text = base;}
    else {source = base;};

  instructionFiles = lib.filterAttrs (_: file: file != null) (
    lib.mapAttrs' (_: harness: lib.nameValuePair harness.home.instructionsFile (instructionsFor harness)) (
      lib.filterAttrs (_: harness: harness.home.instructionsFile != null) cfg.resolved.harnesses
    )
  );

  skillsDirs = lib.unique (
    lib.filter (dir: dir != null) (lib.mapAttrsToList (_: harness: harness.home.skillsDir) cfg.resolved.harnesses)
  );
  status = import ../lib/status.nix {inherit lib pkgs;} {
    base = ''"$HOME"'';
    dirs = skillsDirs;
  };
in {
  imports = [
    (import ./agents.nix {
      agentsModules = [
        {
          options.defaults.instructions = mkOption {
            type = types.nullOr instructionsType;
            default = null;
            example = lib.literalExpression "./AGENTS.md";
            description = ''
              Instructions every enabled harness reads at user level: a file,
              or the text itself. A file is linked as given, so
              `config.lib.file.mkOutOfStoreSymlink` keeps it editable in place.
            '';
          };
        }
      ];
      harnessModules = [
        {
          options = {
            instructions = mkOption {
              type = types.nullOr instructionsType;
              default = null;
              description = "Instructions for this harness in place of `agents.defaults.instructions`.";
            };
            files = mkOption {
              type = types.attrsOf fileType;
              default = {};
              example = lib.literalExpression ''
                {
                  "settings.json" = ./claude-settings.json;
                  commands = {
                    source = ./commands;
                    recursive = true;
                  };
                }
              '';
              description = ''
                Files in this harness's configuration directory, named by their
                path inside it. Takes a path, or `{ source; text; recursive;
                force; }`. A harness that rewrites a file needs it writable:
                link it with `config.lib.file.mkOutOfStoreSymlink`.
              '';
            };
            extraInstructions = mkOption {
              type = types.lines;
              default = "";
              description = ''
                Appended to this harness's instructions. The result is rendered
                into the store, so the instructions it is appended to must be
                readable during evaluation.
              '';
            };
          };
        }
      ];
    })
    ./harnesses.nix
  ];

  config.home = {
    packages = cfg.resolved.packages ++ lib.optional (skillsDirs != []) status;
    # One link per skill, so skills installed by other means can share the directory.
    file = lib.mkMerge [
      instructionFiles
      # One link per skill, so skills installed by other means can share the directory.
      (lib.mapAttrs (_: path: {source = path;}) cfg.resolved.homeSkillLinks)
      configFiles
    ];
  };
}

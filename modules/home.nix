{
  config,
  lib,
  options,
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
  # A string is a path only when it looks like one; instructions may well
  # start with a slash command.
  isText = instructions:
    lib.isString instructions
    && (!lib.hasPrefix "/" instructions || builtins.match "[^[:space:]]*" instructions == null);

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

  instructionFiles = let
    perHarness = lib.mapAttrsToList (name: harness: {
      inherit name;
      file = harness.home.instructionsFile;
      value = instructionsFor harness;
    }) (lib.filterAttrs (_: harness: harness.home.instructionsFile != null) cfg.resolved.harnesses);
    pick = file: entries:
      if lib.length (lib.unique (map (entry: entry.value) entries)) > 1
      then throw "agents: ${lib.concatMapStringsSep ", " (entry: entry.name) entries} share ${file} but their instructions differ."
      else (lib.head entries).value;
  in
    lib.mapAttrs pick (lib.groupBy (entry: entry.file) (lib.filter (entry: entry.value != null) perHarness));

  skillsDirs = lib.unique (
    lib.filter (dir: dir != null) (lib.mapAttrsToList (_: harness: harness.home.skillsDir) cfg.resolved.harnesses)
  );
  linkConfig = pkgs.writeShellApplication {
    name = "agent-tools-link-config";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./link-config.sh;
  };

  # Shell word for a path that may start with `~/`.
  shellPath = path:
    if lib.hasPrefix "~/" path
    then ''"$HOME"/${lib.escapeShellArg (lib.removePrefix "~/" path)}''
    else lib.escapeShellArg path;

  # What this module already puts in a configuration directory wins over the
  # same name in `configFrom`.
  declaredIn = configDir:
    lib.unique (
      map (file: lib.head (lib.splitString "/" (lib.removePrefix "${configDir}/" file))) (
        lib.filter (lib.hasPrefix "${configDir}/") (
          lib.attrNames (instructionFiles // cfg.resolved.homeSkillLinks // configFiles)
        )
      )
    );

  linkConfigCommands = mode:
    lib.concatStrings (lib.mapAttrsToList (
      name: harness: let
        from = harness.configFrom;
        active = harness.enable && from != null;
      in
        if active && !(lib.hasPrefix "/" from.path || lib.hasPrefix "~/" from.path)
        then throw "agents.${name}.configFrom: `${from.path}` must be absolute or start with `~/`."
        else ''
          run ${lib.getExe linkConfig} ${mode} \
            "''${XDG_STATE_HOME:-$HOME/.local/state}"/agent-tools/${lib.escapeShellArg name}.links \
            "$HOME"/${lib.escapeShellArg harness.home.configDir} \
            ${
            if active
            then "${shellPath from.path} ${lib.escapeShellArgs (from.exclude ++ declaredIn harness.home.configDir)}"
            else "''"
          }
        ''
    ) (lib.filterAttrs (_: harness: harness.home.configDir != null) (removeAttrs cfg declared)));
  declared = lib.attrNames (options.agents.type.getSubOptions []);

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
            configFrom = mkOption {
              type = types.nullOr (types.coercedTo types.str (path: {inherit path;}) (types.submodule {
                options = {
                  path = mkOption {
                    type = types.str;
                    description = "Directory on this machine, absolute or starting with `~/`.";
                  };
                  exclude = mkOption {
                    type = types.listOf types.str;
                    default = [];
                    description = "Entries of the directory to leave out.";
                  };
                };
              }));
              default = null;
              example = "~/pi-config";
              description = ''
                A directory on this machine, such as a checkout, whose entries
                are all linked into this harness's configuration directory when
                the configuration is activated. Edits there apply at once, and
                new entries are picked up on the next activation. Hidden
                entries are skipped, and nothing already in the configuration
                directory is replaced.
              '';
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
    activation = {
      # Before Home Manager looks for files in its way: an entry that moved
      # from the checkout to a declared file must not block its own successor.
      agentToolsCleanConfig = {
        after = [];
        before = ["checkLinkTargets"];
        data = linkConfigCommands "clean";
      };
      # After Home Manager's own links, which take precedence.
      agentToolsLinkConfig = {
        after = ["linkGeneration"];
        before = [];
        data = linkConfigCommands "link";
      };
    };
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

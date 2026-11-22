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

  mcpServerType = types.submodule {
    options = {
      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Program of a stdio server. Set this or `url`.";
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Arguments of a stdio server.";
      };
      env = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Environment of a stdio server.";
      };
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Address of a streamable HTTP server. Set this or `command`.";
      };
      headers = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Headers sent to an HTTP server. Codex cannot take them.";
      };
      settings = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        example = {timeout = 60;};
        description = "Keys in the harness's own format, merged into its entry. Codex cannot take them.";
      };
    };
  };

  mcpServersFor = name: harness:
    lib.mapAttrs (server: value:
      if (value.command == null) == (value.url == null)
      then throw "agents MCP server `${server}` for ${name}: set exactly one of `command` and `url`."
      else value)
    (lib.filterAttrs (_: value: value != null) (cfg.defaults.mcpServers // harness.mcpServers));

  # The JSON entry Claude Code and Pi both read.
  mcpJsonEntry = typed: value:
    (
      if value.command != null
      then
        lib.optionalAttrs typed {type = "stdio";}
        // {inherit (value) command args;}
        // lib.optionalAttrs (value.env != {}) {inherit (value) env;}
      else
        lib.optionalAttrs typed {type = "http";}
        // {inherit (value) url;}
        // lib.optionalAttrs (value.headers != {}) {inherit (value) headers;}
    )
    // value.settings;

  codexAddArgs = server: value:
    if value.headers != {} || value.settings != {}
    then throw "agents MCP server `${server}` for codex: `codex mcp add` takes neither headers nor settings."
    else if value.command != null
    then ["mcp" "add" server] ++ lib.concatMap (key: ["--env" "${key}=${value.env.${key}}"]) (lib.attrNames value.env) ++ ["--" value.command] ++ value.args
    else ["mcp" "add" server "--url" value.url];

  # Harnesses whose MCP servers live in a file the harness itself rewrites;
  # their CLI registers them instead.
  mcpCli = {
    claude-code = {
      kind = "claude";
      program = "claude";
      remove = ["mcp" "remove" "--scope" "user"];
      add = server: value: ["mcp" "add-json" "--scope" "user" server (builtins.toJSON (mcpJsonEntry true value))];
    };
    codex = {
      kind = "codex";
      program = "codex";
      remove = ["mcp" "remove"];
      add = codexAddArgs;
    };
  };
  mcpFile = {
    pi = servers: {"mcp.json".text = builtins.toJSON {mcpServers = lib.mapAttrs (_: mcpJsonEntry false) servers;};};
  };

  unsupportedMcp = lib.attrNames (lib.filterAttrs (
      name: harness: harness.mcpServers != {} && !(mcpCli ? ${name}) && !(mcpFile ? ${name})
    )
    cfg.resolved.harnesses);

  harnessFiles = name: harness: let
    servers = mcpServersFor name harness;
  in
    lib.optionalAttrs (mcpFile ? ${name} && servers != {}) (mcpFile.${name} servers) // harness.files;

  linkMcp = pkgs.writeShellApplication {
    name = "agent-tools-link-mcp";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text = builtins.readFile ./link-mcp.sh;
  };

  # Disabled harnesses are listed too, so servers registered earlier are removed.
  mcpWanted =
    lib.mapAttrs (name: cli: {
      inherit (cli) remove;
      servers =
        lib.mapAttrs (server: value: let
          add = cli.add server value;
        in {
          inherit add;
          fingerprint = builtins.hashString "sha256" (builtins.toJSON add);
        }) (
          if cfg.${name}.enable
          then mcpServersFor name cfg.${name}
          else {}
        );
    })
    mcpCli;

  linkMcpCommands = lib.concatStrings (lib.mapAttrsToList (name: cli: let
      harness = cfg.${name};
      program =
        if harness.enable && harness.package != null
        then lib.getExe' harness.package cli.program
        else cli.program;
      wanted = pkgs.writeText "agent-tools-${name}-mcp.json" (builtins.toJSON cfg.resolved.mcp.${name});
    in ''
      run ${lib.getExe linkMcp} ${cli.kind} \
        "''${XDG_STATE_HOME:-$HOME/.local/state}"/agent-tools/${lib.escapeShellArg name}.mcp \
        ${lib.escapeShellArg program} ${wanted}
    '')
    mcpCli);

  configFiles =
    lib.concatMapAttrs (
      name: harness: let
        files = harnessFiles name harness;
      in
        if files != {} && harness.home.configDir == null
        then throw "agents.${name}.files: set agents.${name}.home.configDir, the directory these files are relative to."
        else
          lib.mapAttrs' (
            file: value:
              lib.nameValuePair "${harness.home.configDir}/${file}" (lib.filterAttrs (_: field: field != null) value)
          )
          files
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
          options.resolved.mcp = mkOption {
            type = types.attrsOf types.raw;
            internal = true;
            readOnly = true;
          };
          options.defaults.mcpServers = mkOption {
            type = types.attrsOf mcpServerType;
            default = {};
            example = lib.literalExpression ''
              {
                docs.url = "https://example.com/mcp";
                browser = {
                  command = "browser-mcp";
                  args = ["--headless"];
                };
              }
            '';
            description = ''
              MCP servers every enabled harness that supports them gets:
              Claude Code and Codex through their own CLI, which keeps
              servers registered by other means, and Pi through its
              `mcp.json`. agent-tools removes only servers it registered.
            '';
          };
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
            mcpServers = mkOption {
              type = types.attrsOf (types.nullOr mcpServerType);
              default = {};
              description = ''
                MCP servers for this harness only. One with the name of a
                default server replaces it; `null` removes it.
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

  config.agents.resolved.mcp = mcpWanted;

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
      agentToolsMcp = {
        after = ["linkGeneration"];
        before = [];
        data =
          if unsupportedMcp != []
          then throw "agents: ${lib.concatStringsSep ", " unsupportedMcp} cannot take MCP servers; agent-tools writes them for claude-code, codex and pi."
          else linkMcpCommands;
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

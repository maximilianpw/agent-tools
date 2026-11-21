/*
The `agents` option tree shared by every backend. A backend adds its own
options through `agentsModules` (the `agents` set itself) and `harnessModules`
(each `agents.<harness>`).
*/
{
  agentsModules ? [],
  harnessModules ? [],
}: {lib, ...}: let
  inherit (lib) mkOption types;
  skills = import ../lib/skills.nix {inherit lib;};

  sourceType = types.coercedTo types.path (path: {inherit path;}) (types.submodule {
    options = {
      path = mkOption {
        type = types.path;
        description = "A skill directory, or a directory tree containing skills. Flake inputs work.";
      };
      include = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Skill ids to take from this source; `null` takes all of them.";
      };
      exclude = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Skill ids to leave out.";
      };
      prefix = mkOption {
        type = types.str;
        default = "";
        description = "Prepended to every skill id from this source.";
      };
      depth = mkOption {
        type = types.ints.unsigned;
        default = 4;
        description = "How many directory levels below `path` to search for SKILL.md.";
      };
    };
  });

  sourcesOption = description:
    mkOption {
      type = types.attrsOf sourceType;
      default = {};
      example = lib.literalExpression ''
        {
          mine = ./skills;
          upstream = {
            path = inputs.some-skills;
            include = ["code-review"];
          };
        }
      '';
      inherit description;
    };

  harnessModule = packageSet: {name, ...}: {
    options = {
      enable = lib.mkEnableOption "this harness";

      package = mkOption {
        type = types.nullOr types.package;
        default =
          packageSet.${name}
          or (throw "agents.${name}.package: `${name}` is not in agents.packageSet; set the package explicitly.");
        defaultText = lib.literalExpression "config.agents.packageSet.<name>";
        description = "Package installed for this harness. `null` configures a harness installed by other means.";
      };

      skills = {
        sources = sourcesOption ''
          Skills for this harness only, added to `agents.defaults.skills.sources`.
          A source with the same name as a default one replaces it.
        '';
        include = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "The only skill ids this harness gets; `null` gives it all of them.";
        };
        exclude = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Skill ids this harness does not get.";
        };
      };

      home = {
        instructionsFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "User-level instructions file the harness reads, relative to the home directory.";
        };
        skillsDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "User-level skills directory the harness reads, relative to the home directory.";
        };
      };

      project.skillsDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Project-level skills directory the harness reads, relative to the project root.";
      };
    };
  };

  agentsModule = {
    config,
    options,
    ...
  }: let
    harnesses = lib.filterAttrs (_: harness: harness.enable) (removeAttrs config (lib.attrNames options));

    skillsFor = name: harness: let
      resolved = skills.resolve (config.defaults.skills.sources // harness.skills.sources);
      included = lib.optionals (harness.skills.include != null) harness.skills.include;
      unknown = lib.subtractLists (lib.attrNames resolved) (included ++ harness.skills.exclude);
    in
      if unknown != []
      then
        throw ''
          agents.${name}.skills: no skill named ${lib.concatStringsSep ", " unknown}.
          Available: ${lib.concatStringsSep ", " (lib.attrNames resolved)}''
      else
        removeAttrs (
          if harness.skills.include == null
          then resolved
          else lib.getAttrs harness.skills.include resolved
        )
        harness.skills.exclude;

    # Harnesses may read the same directory; it then holds the union of their skills.
    linksIn = dirOf: let
      perHarness =
        lib.mapAttrsToList (
          name: harness:
            lib.mapAttrs' (id: path: lib.nameValuePair "${dirOf harness}/${id}" path) (skillsFor name harness)
        )
        (lib.filterAttrs (_: harness: dirOf harness != null) harnesses);
      pick = destination: paths:
        if lib.length (lib.unique paths) > 1
        then throw "agents: harnesses sharing ${destination} disagree on that skill: ${lib.concatStringsSep ", " (lib.unique paths)}"
        else lib.head paths;
    in
      lib.zipAttrsWith pick perHarness;
  in {
    freeformType = types.attrsOf (types.submodule {
      imports = [(harnessModule config.packageSet)] ++ harnessModules;
    });

    options = {
      packageSet = mkOption {
        type = types.raw;
        description = "Attribute set a harness's default package is looked up in, by harness name.";
      };

      defaults.skills.sources = sourcesOption "Skill directories or trees of them, given to every enabled harness.";

      resolved = {
        harnesses = mkOption {
          type = types.attrsOf types.raw;
          internal = true;
          readOnly = true;
        };
        packages = mkOption {
          type = types.listOf types.package;
          internal = true;
          readOnly = true;
        };
        homeSkillLinks = mkOption {
          type = types.attrsOf types.str;
          internal = true;
          readOnly = true;
        };
        projectSkillLinks = mkOption {
          type = types.attrsOf types.str;
          internal = true;
          readOnly = true;
        };
      };
    };

    config.resolved = {
      inherit harnesses;
      packages = lib.filter (package: package != null) (lib.mapAttrsToList (_: harness: harness.package) harnesses);
      homeSkillLinks = linksIn (harness: harness.home.skillsDir);
      projectSkillLinks = linksIn (harness: harness.project.skillsDir);
    };
  };
in {
  options.agents = mkOption {
    type = types.submodule {imports = [agentsModule] ++ agentsModules;};
    default = {};
    description = ''
      Coding-agent harnesses. `agents.<harness>` configures one harness and
      `agents.defaults` holds what every enabled harness gets.
    '';
  };
}

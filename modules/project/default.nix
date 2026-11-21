{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.agents;

  links = pkgs.writeText "agent-tools-links" (
    lib.concatStrings (lib.mapAttrsToList (destination: path: "${destination}\t${path}\n") cfg.resolved.projectSkillLinks)
  );

  # Every known harness directory is swept, enabled or not, so links left by
  # a harness that was since disabled are cleaned up too.
  declared = lib.attrNames (options.agents.type.getSubOptions []);
  sweptDirs = lib.unique (
    lib.filter (dir: dir != null) (lib.mapAttrsToList (_: harness: harness.project.skillsDir) (removeAttrs cfg declared))
  );

  status = import ../../lib/status.nix {inherit lib pkgs;} {
    base = ''"$(git rev-parse --show-toplevel 2>/dev/null || pwd)"'';
    dirs = lib.unique (
      lib.filter (dir: dir != null) (lib.mapAttrsToList (_: harness: harness.project.skillsDir) cfg.resolved.harnesses)
    );
  };

  install = pkgs.writeShellApplication {
    name = "agent-tools-install";
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.gnused];
    text = builtins.readFile ./install.sh;
  };
in {
  imports = [(import ../agents.nix {}) ../harnesses.nix];

  options.project = {
    packages = mkOption {
      type = types.listOf types.package;
      readOnly = true;
      description = "Packages for the project's development shell.";
    };
    shellHook = mkOption {
      type = types.str;
      readOnly = true;
      description = "Shell hook that links the project's skills into its working tree.";
    };
  };

  config.project = {
    packages = cfg.resolved.packages ++ [status];
    shellHook = ''
      ${lib.getExe install} ${links} ${lib.escapeShellArgs sweptDirs}
    '';
  };
}

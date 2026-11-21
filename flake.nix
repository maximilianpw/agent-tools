{
  description = "Declarative coding-agent setup: packages, shared instructions and skills, per user or per project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    llm-agents,
    ...
  }: let
    inherit (nixpkgs) lib;
    eachSystem = lib.genAttrs ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];

    # `key` lets the module system deduplicate this when it is imported twice.
    llmAgentsPackages = {
      pkgs,
      lib,
      ...
    }: {
      key = "agent-tools#llm-agents-packages";
      agents.packageSet = lib.mkDefault llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    };
  in {
    homeModules.default = {
      imports = [./modules/home.nix llmAgentsPackages];
    };

    lib.mkProject = {
      pkgs,
      modules ? [],
    }:
      (lib.evalModules {
        modules = [./modules/project llmAgentsPackages {_module.args.pkgs = pkgs;}] ++ modules;
      })
      .config
      .project;

    templates.default = {
      path = ./templates/project;
      description = "Development shell that installs agents and links skills into the project";
    };

    checks = eachSystem (system:
      import ./tests {
        inherit lib;
        pkgs = nixpkgs.legacyPackages.${system};
      });

    formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.alejandra);
  };
}

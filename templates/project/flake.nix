{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    agent-tools.url = "github:maximilianpw/agent-tools";
  };

  outputs = {
    nixpkgs,
    agent-tools,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    agents = agent-tools.lib.mkProject {
      inherit pkgs;
      modules = [
        {
          agents = {
            defaults.skills.sources.project = ./skills;
            claude-code.enable = true;
            codex.enable = true;
          };
        }
      ];
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      inherit (agents) packages shellHook;
    };
  };
}

{lib, ...}: let
  # Most harnesses read `.agents/skills` whatever else they read, so giving
  # them a directory of their own would only show them every skill twice.
  shared = ".agents/skills";

  harness = configDir: instructions: homeSkills: projectSkills: {
    home = {
      inherit configDir;
      instructionsFile = "${configDir}/${instructions}";
      skillsDir = homeSkills;
    };
    project.skillsDir = projectSkills;
  };
in {
  agents = lib.mapAttrs (_: lib.mapAttrsRecursive (_: lib.mkDefault)) {
    amp = harness ".config/amp" "AGENTS.md" shared shared;
    claude-code = harness ".claude" "CLAUDE.md" ".claude/skills" ".claude/skills";
    codex = harness ".codex" "AGENTS.md" shared shared;
    gemini-cli = harness ".gemini" "GEMINI.md" shared shared;
    grok = harness ".grok" "AGENTS.md" ".grok/skills" ".grok/skills";
    opencode = harness ".config/opencode" "AGENTS.md" shared shared;
    pi = harness ".pi/agent" "AGENTS.md" shared shared;
  };
}

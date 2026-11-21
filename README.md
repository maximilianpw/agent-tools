# agent-tools

Declare your coding agents once: which ones to install, the instructions they
share, and the skills they get. Use it per user through Home Manager, or per
project through a development shell.

Packages come from [llm-agents.nix](https://github.com/numtide/llm-agents.nix)
by default.

## Home Manager

```nix
{
  inputs.agent-tools.url = "github:maximilianpw/agent-tools";

  # in your Home Manager configuration:
  imports = [inputs.agent-tools.homeModules.default];

  agents = {
    defaults = {
      instructions = ./AGENTS.md;
      skills.sources = {
        mine = ./skills;
        upstream = inputs.some-skills-repo; # a `flake = false` input
      };
    };

    claude-code = {
      enable = true;
      extraInstructions = "Comments default to none.";
      skills.sources.claude-only = ./claude-skills;
    };
    codex = {
      enable = true;
      skills.exclude = ["code-review"];
    };
    pi.enable = true;
  };
}
```

`agents.defaults` is what every enabled harness gets; `agents.<harness>` adds
to it or trims it for one harness.

## Project shell

```nix
agents = agent-tools.lib.mkProject {
  inherit pkgs;
  modules = [{
    agents.defaults.skills.sources.project = ./skills;
    agents.claude-code.enable = true;
    agents.codex.enable = true;
  }];
};

devShells.default = pkgs.mkShell {
  inherit (agents) packages shellHook;
};
```

`nix flake init -t github:maximilianpw/agent-tools` writes a starting point.

Entering the shell links each skill into the project's skill directories and
lists the links in `.git/info/exclude`. Only symlinks into `/nix/store` are
ever replaced or removed; skills committed to the project are left alone.

`agent-tools status` lists what is in each skills directory and names the
skills something else put there, such as a product CLI's installer. Those are
never touched; pin their source to bring one under management.

## Options

| Option | Meaning |
| --- | --- |
| `agents.defaults.instructions` | A file or text, written to every enabled harness's user-level instructions file. Home Manager only. |
| `agents.defaults.skills.sources.<name>` | A skill directory or a tree of them. Takes a path, or `{ path; include; exclude; prefix; depth; }`. |
| `agents.<harness>.enable` | Install the harness and give it instructions and skills. |
| `agents.<harness>.package` | Defaults to `agents.packageSet.<harness>`; `null` configures a harness you install another way. |
| `agents.<harness>.instructions` | Instructions for this harness in place of the shared ones. Home Manager only. |
| `agents.<harness>.extraInstructions` | Text appended to this harness's instructions. Home Manager only. |
| `agents.<harness>.skills.sources.<name>` | Skills for this harness only. The same name as a default source replaces it. |
| `agents.<harness>.skills.include` | The only skill names this harness gets; unset means all. |
| `agents.<harness>.skills.exclude` | Skill names this harness does not get. |
| `agents.packageSet` | Where default packages come from. Defaults to llm-agents.nix; set it to `pkgs` to use your own overlay. |

A skill is any directory containing `SKILL.md`, named after its directory. Two
skills with the same name in one harness is an evaluation error; resolve it
with a source's `include`, `exclude` or `prefix`.

To keep the instructions file editable without rebuilding, pass
`config.lib.file.mkOutOfStoreSymlink "/absolute/path/AGENTS.md"`.

## Harnesses

| Harness | User instructions | User skills | Project skills |
| --- | --- | --- | --- |
| `amp` | `~/.config/amp/AGENTS.md` | `~/.agents/skills` | `.agents/skills` |
| `claude-code` | `~/.claude/CLAUDE.md` | `~/.claude/skills` | `.claude/skills` |
| `codex` | `~/.codex/AGENTS.md` | `~/.agents/skills` | `.agents/skills` |
| `gemini-cli` | `~/.gemini/GEMINI.md` | `~/.agents/skills` | `.agents/skills` |
| `grok` | `~/.grok/AGENTS.md` | `~/.grok/skills` | `.grok/skills` |
| `opencode` | `~/.config/opencode/AGENTS.md` | `~/.agents/skills` | `.agents/skills` |
| `pi` | `~/.pi/agent/AGENTS.md` | `~/.agents/skills` | `.agents/skills` |

Harnesses that share a directory get the union of their skills there, so
per-harness `skills` settings only separate harnesses with different
directories. Amp, Gemini CLI, OpenCode and Pi also have directories of their
own (set `home.skillsDir` to use one), but each still reads `~/.agents/skills`,
and several harnesses read `~/.claude/skills` too.

Any other name works too. Enabling it installs `agents.packageSet.<name>`, and
it gets files once you say where it reads them:

```nix
agents.my-agent = {
  enable = true;
  home.instructionsFile = ".my-agent/AGENTS.md";
  home.skillsDir = ".my-agent/skills";
  project.skillsDir = ".agents/skills";
};
```

Settings, hooks, plugins and MCP servers differ per harness and are not managed
here.

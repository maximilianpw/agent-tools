{
  lib,
  pkgs,
}: let
  stubPackages = {
    claude-code = pkgs.hello;
    codex = pkgs.hello;
    pi = pkgs.hello;
    ccusage = pkgs.jq;
  };

  # Stands in for Home Manager: only the two options the module writes to.
  homeStub = {
    options.home = {
      packages = lib.mkOption {type = lib.types.listOf lib.types.package;};
      file = lib.mkOption {type = lib.types.attrsOf (lib.types.attrsOf lib.types.raw);};
      activation = lib.mkOption {type = lib.types.attrsOf lib.types.raw;};
    };
  };

  evalHome = agents:
    (lib.evalModules {
      modules = [../modules/home.nix homeStub {_module.args.pkgs = pkgs;} {agents = {packageSet = stubPackages;} // agents;}];
    })
    .config
    .home;

  evalProject = agents:
    (lib.evalModules {
      modules = [../modules/project {_module.args.pkgs = pkgs;} {agents = {packageSet = stubPackages;} // agents;}];
    })
    .config
    .project;

  fails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
  skillLinks = home: lib.filter (lib.hasInfix "/skills/") (lib.attrNames home.file);

  home = evalHome {
    defaults = {
      instructions = ./fixtures/pack/README.md;
      skills.sources.pack = ./fixtures/pack;
    };
    claude-code = {
      enable = true;
      skills.sources.single = ./fixtures/single;
    };
    codex = {
      enable = true;
      extraInstructions = "codex only";
      skills.exclude = ["lint"];
    };
    ccusage.enable = true;
    pi.extraInstructions = "not enabled";
  };

  failures = lib.runTests {
    testEachHarnessGetsDefaultSkillsPlusItsOwnMinusItsExclusions = {
      expr = skillLinks home;
      expected = [
        ".agents/skills/deploy"
        ".agents/skills/review"
        ".claude/skills/deploy"
        ".claude/skills/lint"
        ".claude/skills/review"
        ".claude/skills/single"
      ];
    };

    testInstructionsLinkTheSharedFileUnlessAHarnessAppends = {
      expr = {
        claude = home.file.".claude/CLAUDE.md" ? source;
        codex = home.file.".codex/AGENTS.md".text;
        disabled = home.file ? ".pi/agent/AGENTS.md";
      };
      expected = {
        claude = true;
        codex = "# pack\n\ncodex only";
        disabled = false;
      };
    };

    testHarnessInstructionsStandAloneWithoutSharedOnes = {
      expr =
        (evalHome {
          codex = {
            enable = true;
            extraInstructions = "codex only";
          };
          claude-code.enable = true;
        })
        .file;
      expected = {".codex/AGENTS.md".text = "codex only";};
    };

    testHarnessInstructionsReplaceTheSharedOnes = {
      expr = let
        inherit
          (evalHome {
            defaults.instructions = "shared";
            claude-code = {
              enable = true;
              instructions = ./fixtures/single/SKILL.md;
            };
            codex = {
              enable = true;
              instructions = "codex";
              extraInstructions = "more";
            };
            pi.enable = true;
          })
          file
          ;
      in {
        claude = file.".claude/CLAUDE.md".source == ./fixtures/single/SKILL.md;
        codex = file.".codex/AGENTS.md".text;
        pi = file.".pi/agent/AGENTS.md".text;
      };
      expected = {
        claude = true;
        codex = "codex\nmore";
        pi = "shared";
      };
    };

    testFilesLandInTheHarnessConfigDirectory = {
      expr =
        (evalHome {
          claude-code = {
            enable = true;
            package = null;
            files = {
              "settings.json" = ./fixtures/pack/README.md;
              commands = {
                source = ./fixtures/pack;
                recursive = true;
                force = true;
              };
              "rules/note.md".text = "note";
            };
          };
          codex.files."config.toml".text = "not enabled";
        })
        .file;
      expected = {
        ".claude/settings.json" = {
          source = ./fixtures/pack/README.md;
          recursive = false;
          force = false;
        };
        ".claude/commands" = {
          source = ./fixtures/pack;
          recursive = true;
          force = true;
        };
        ".claude/rules/note.md" = {
          text = "note";
          recursive = false;
          force = false;
        };
      };
    };

    testFilesNeedAConfigDirectory = {
      expr =
        fails
        (evalHome {
          ccusage = {
            enable = true;
            files."config.json".text = "{}";
          };
        })
      .file;
      expected = true;
    };

    testConfigFromLinksACheckoutAndYieldsToDeclaredFiles = {
      expr = let
        words = lib.filter (word: word != "" && word != "\\") (
          lib.splitString " " (
            lib.replaceStrings ["\n"] [" "]
            (evalHome {
              defaults.instructions = "shared";
              pi = {
                enable = true;
                package = null;
                configFrom = {
                  path = "~/pi-config";
                  exclude = ["README.md"];
                };
                files."settings.json".text = "{}";
              };
              claude-code.configFrom = "/srv/claude";
            })
            .activation
            .agentToolsLinkConfig
            .data
          )
        );
        after = word: lib.sublist (lib.lists.findFirstIndex (other: other == word) null words + 1) 4 words;
        before = word: lib.elemAt words (lib.lists.findFirstIndex (other: other == word) null words - 2);
      in {
        pi = after "\"$HOME\"/.pi/agent";
        disabled = lib.take 1 (after "\"$HOME\"/.claude");
        mode = before "\"$HOME\"/.pi/agent";
      };
      expected = {
        pi = ["\"$HOME\"/pi-config" "README.md" "AGENTS.md" "settings.json"];
        disabled = ["''"];
        mode = "link";
      };
    };

    testInstructionTextMayStartWithASlash = {
      expr =
        (evalHome {
          defaults.instructions = "/plan before editing";
          claude-code = {
            enable = true;
            package = null;
          };
        })
        .file
        .".claude/CLAUDE.md";
      expected = {text = "/plan before editing";};
    };

    testHarnessesSharingAnInstructionsFileMustAgree = {
      expr =
        fails
        (evalHome {
          defaults.instructions = "shared";
          claude-code.enable = true;
          codex = {
            enable = true;
            home.instructionsFile = ".claude/CLAUDE.md";
            extraInstructions = "codex only";
          };
        })
      .file;
      expected = true;
    };

    testConfigFromMustBeAbsolute = {
      expr =
        fails
        (evalHome {
          pi = {
            enable = true;
            configFrom = "pi-config";
          };
        })
      .activation
      .agentToolsLinkConfig
      .data;
      expected = true;
    };

    testEnabledNameWithoutHarnessEntryInstallsItsPackage = {
      expr = map lib.getName home.packages;
      expected = ["jq" "hello" "hello" "agent-tools"];
    };

    testHarnessWithoutPackageIsStillConfigured = {
      expr = let
        config = evalHome {
          claude-code = {
            enable = true;
            package = null;
            skills.sources.single = ./fixtures/single;
          };
        };
      in {
        packages = map lib.getName config.packages;
        files = lib.attrNames config.file;
      };
      expected = {
        packages = ["agent-tools"];
        files = [".claude/skills/single"];
      };
    };

    testSourceIncludeExcludeAndPrefixSelectSkills = {
      expr = skillLinks (evalHome {
        claude-code.enable = true;
        defaults.skills.sources = {
          a = {
            path = ./fixtures/pack;
            include = ["review" "deploy"];
            exclude = ["deploy"];
          };
          b = {
            path = ./fixtures/pack;
            include = ["review"];
            prefix = "b-";
          };
        };
      });
      expected = [".claude/skills/b-review" ".claude/skills/review"];
    };

    testHarnessSourceReplacesDefaultSourceOfTheSameName = {
      expr = skillLinks (evalHome {
        defaults.skills.sources.pack = ./fixtures/pack;
        claude-code = {
          enable = true;
          skills.sources.pack = {
            path = ./fixtures/pack;
            include = ["review"];
          };
        };
      });
      expected = [".claude/skills/review"];
    };

    testHarnessIncludeLimitsItsSkills = {
      expr = skillLinks (evalHome {
        defaults.skills.sources.pack = ./fixtures/pack;
        claude-code = {
          enable = true;
          skills.include = ["review" "lint"];
          skills.exclude = ["lint"];
        };
      });
      expected = [".claude/skills/review"];
    };

    testHarnessesSharingADirectoryGetTheUnion = {
      expr = skillLinks (evalHome {
        claude-code = {
          enable = true;
          skills.sources.single = ./fixtures/single;
        };
        codex = {
          enable = true;
          home.skillsDir = ".claude/skills";
          skills.sources.pack = {
            path = ./fixtures/pack;
            include = ["review"];
          };
        };
      });
      expected = [".claude/skills/review" ".claude/skills/single"];
    };

    testSameSkillIdFromTwoSourcesIsAnError = {
      expr =
        fails
        (evalHome {
          claude-code.enable = true;
          defaults.skills.sources = {
            a = ./fixtures/pack;
            b = ./fixtures/pack;
          };
        })
      .file;
      expected = true;
    };

    testUnknownSkillNamesAreErrors = {
      expr = {
        include =
          fails
          (evalHome {
            claude-code.enable = true;
            defaults.skills.sources.a = {
              path = ./fixtures/pack;
              include = ["reveiw"];
            };
          })
        .file;
        harnessInclude =
          fails
          (evalHome {
            claude-code = {
              enable = true;
              skills.include = ["reveiw"];
            };
            defaults.skills.sources.a = ./fixtures/pack;
          })
        .file;
        harnessExclude =
          fails
          (evalHome {
            claude-code = {
              enable = true;
              skills.exclude = ["reveiw"];
            };
            defaults.skills.sources.a = ./fixtures/pack;
          })
        .file;
      };
      expected = {
        include = true;
        harnessInclude = true;
        harnessExclude = true;
      };
    };

    testEnabledNameMissingFromPackageSetIsAnError = {
      expr = fails (evalHome {no-such-agent.enable = true;}).packages;
      expected = true;
    };
  };

  project = skillSources:
    evalProject {
      defaults.skills.sources = skillSources;
      claude-code.enable = true;
      codex.enable = true;
    };
  projectBefore = project {pack = ./fixtures/pack;};
  projectAfter = project {
    pack = {
      path = ./fixtures/pack;
      exclude = ["lint"];
    };
  };
  projectCodexDisabled = evalProject {
    defaults.skills.sources.pack = ./fixtures/pack;
    claude-code.enable = true;
  };
in {
  eval =
    if failures == []
    then pkgs.runCommand "agent-tools-eval-tests" {} "touch $out"
    else throw "eval tests failed:\n${lib.generators.toPretty {} failures}";

  link-config = let
    link = lib.getExe (pkgs.writeShellApplication {
      name = "agent-tools-link-config";
      runtimeInputs = [pkgs.coreutils];
      text = builtins.readFile ../modules/link-config.sh;
    });
  in
    pkgs.runCommand "agent-tools-link-config-test" {} ''
      absent() { if grep --quiet "$@"; then echo "unexpected match: $*" >&2; exit 1; fi; }
      checkout=$PWD/checkout
      mkdir -p "$checkout/extensions" "$checkout/.git" agent
      echo settings > "$checkout/settings.json"
      echo readme > "$checkout/README.md"
      echo theirs > "$checkout/auth.json"
      echo theirs > "$checkout/AGENTS.md"
      echo mine > agent/auth.json
      ln -s /nix/store/managed agent/AGENTS.md

      ${link} link state/pi.links agent "$checkout" README.md 2> warnings

      [[ $(cat agent/settings.json) == settings && -L agent/settings.json ]]
      [[ $(readlink agent/extensions) == "$checkout/extensions" ]]
      [[ ! -e agent/README.md && ! -e agent/.git ]]
      [[ $(cat agent/auth.json) == mine ]]
      [[ $(readlink agent/AGENTS.md) == /nix/store/managed ]]
      grep --quiet 'agent/auth.json exists' warnings
      absent AGENTS.md warnings
      [[ $(cut -f1 state/pi.links | tr '\n' ' ') == 'extensions settings.json ' ]]

      # A harness that saves by replacing the file now owns it.
      rm agent/settings.json
      echo rewritten > agent/settings.json
      rm "$checkout/extensions/.." 2> /dev/null || true
      echo new > "$checkout/models.json"
      printf '\n' >> state/pi.links
      ${link} link state/pi.links agent "$checkout" README.md 2> warnings

      [[ $(cat agent/settings.json) == rewritten && ! -L agent/settings.json ]]
      grep --quiet 'agent/settings.json exists' warnings
      [[ -L agent/models.json ]]
      absent settings.json state/pi.links

      # `clean` drops what is no longer wanted and links nothing new.
      echo later > "$checkout/later.json"
      ${link} clean state/pi.links agent "$checkout" README.md models.json
      [[ ! -e agent/models.json && ! -e agent/later.json && -L agent/extensions ]]

      ${link} link state/pi.links agent "" 2> /dev/null

      [[ ! -L agent/extensions && ! -e state/pi.links ]]
      [[ $(cat agent/settings.json) == rewritten && $(cat agent/auth.json) == mine && -L agent/AGENTS.md ]]

      ${link} link state/pi.links agent "$PWD/missing" 2> warnings
      grep --quiet 'missing does not exist' warnings

      touch $out
    '';

  project-install =
    pkgs.runCommand "agent-tools-project-install-test" {
      nativeBuildInputs = [pkgs.git];
    } ''
      absent() { if grep --quiet "$@"; then echo "unexpected match: $*" >&2; exit 1; fi; }
      export HOME=$TMPDIR

      # Outside a repository there is no project to link into.
      mkdir -p loose/.claude/skills
      ln -s /nix/store/home-manager-link loose/.claude/skills/review
      (cd loose && ${projectBefore.shellHook}) 2> warnings
      grep --quiet 'not inside a git repository' warnings
      [[ $(readlink loose/.claude/skills/review) == /nix/store/home-manager-link && ! -e loose/.agents ]]

      mkdir project && cd project
      git init --quiet
      mkdir -p .claude/skills/review sub
      echo mine > .claude/skills/review/SKILL.md
      # A store link someone else made is not ours either.
      ln -s /nix/store/home-manager-link .claude/skills/deploy

      (cd sub && ${projectBefore.shellHook}) 2> warnings

      [[ -f .claude/skills/review/SKILL.md && ! -L .claude/skills/review ]]
      grep --quiet '.claude/skills/review exists' warnings
      [[ $(readlink .claude/skills/deploy) == /nix/store/home-manager-link ]]
      [[ -f .claude/skills/lint/SKILL.md && -L .claude/skills/lint ]]
      [[ -f .agents/skills/review/SKILL.md && -L .agents/skills/review ]]
      grep --quiet --line-regexp '/.agents/skills/lint' .git/info/exclude
      absent --line-regexp '/.claude/skills/review' .git/info/exclude
      [[ -z $(git status --porcelain -- .agents) ]]

      mkdir .agents/skills/from-a-cli
      ln -s ../../elsewhere .agents/skills/linked
      PATH=${lib.makeBinPath projectBefore.packages}:$PATH agent-tools status > status
      grep --quiet --line-regexp '.agents/skills: 3 managed, 2 unmanaged' status
      grep --quiet --line-regexp '  from-a-cli' status
      grep --quiet --line-regexp '  linked -> ../../elsewhere' status
      grep --quiet --line-regexp '.claude/skills: 2 managed, 1 unmanaged' status
      rm -r .agents/skills/from-a-cli .agents/skills/linked

      ${projectAfter.shellHook} 2> /dev/null

      [[ ! -e .claude/skills/lint && ! -L .agents/skills/lint ]]
      [[ -L .agents/skills/deploy ]]
      absent lint .git/info/exclude
      [[ $(grep --count 'agent-tools begin' .git/info/exclude) == 1 ]]

      ${projectCodexDisabled.shellHook} 2> /dev/null

      [[ ! -e .agents/skills/review && ! -e .agents/skills/deploy ]]
      [[ -L .claude/skills/lint ]]

      ${(project {}).shellHook}

      [[ -f .claude/skills/review/SKILL.md && ! -e .claude/skills/lint ]]
      [[ $(readlink .claude/skills/deploy) == /nix/store/home-manager-link ]]
      absent agent-tools .git/info/exclude

      # A skills directory that is itself a link to another one.
      rm -r .claude/skills .agents
      mkdir -p .agents/skills
      ln -s ../.agents/skills .claude/skills
      ${projectBefore.shellHook}
      ${projectBefore.shellHook}
      [[ -L .agents/skills/review && -f .claude/skills/lint/SKILL.md ]]

      touch $out
    '';
}

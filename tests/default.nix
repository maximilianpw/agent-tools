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

  project-install =
    pkgs.runCommand "agent-tools-project-install-test" {
      nativeBuildInputs = [pkgs.git];
    } ''
      export HOME=$TMPDIR
      mkdir project && cd project
      git init --quiet
      mkdir -p .claude/skills/review sub
      echo mine > .claude/skills/review/SKILL.md

      (cd sub && ${projectBefore.shellHook}) 2> warnings

      [[ -f .claude/skills/review/SKILL.md && ! -L .claude/skills/review ]]
      grep --quiet '.claude/skills/review exists' warnings
      [[ -f .claude/skills/lint/SKILL.md && -L .claude/skills/lint ]]
      [[ -f .agents/skills/review/SKILL.md && -L .agents/skills/review ]]
      grep --quiet --line-regexp '/.agents/skills/lint' .git/info/exclude
      ! grep --quiet --line-regexp '/.claude/skills/review' .git/info/exclude
      [[ -z $(git status --porcelain -- .agents) ]]

      mkdir .agents/skills/from-a-cli
      ln -s ../../elsewhere .agents/skills/linked
      PATH=${lib.makeBinPath projectBefore.packages}:$PATH agent-tools status > status
      grep --quiet --line-regexp '.agents/skills: 3 managed, 2 unmanaged' status
      grep --quiet --line-regexp '  from-a-cli' status
      grep --quiet --line-regexp '  linked -> ../../elsewhere' status
      grep --quiet --line-regexp '.claude/skills: 2 managed, 1 unmanaged' status
      rm -r .agents/skills/from-a-cli .agents/skills/linked

      ${projectAfter.shellHook}

      [[ ! -e .claude/skills/lint && ! -L .agents/skills/lint ]]
      [[ -L .agents/skills/deploy ]]
      ! grep --quiet lint .git/info/exclude
      [[ $(grep --count 'agent-tools begin' .git/info/exclude) == 1 ]]

      ${projectCodexDisabled.shellHook} 2> /dev/null

      [[ ! -e .agents ]]
      [[ -L .claude/skills/lint ]]

      ${(project {}).shellHook}

      [[ -f .claude/skills/review/SKILL.md && ! -e .claude/skills/lint ]]
      ! grep --quiet agent-tools .git/info/exclude

      touch $out
    '';
}

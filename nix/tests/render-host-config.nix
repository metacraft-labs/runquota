# `nix/host-config.nix` put through the module system with nothing but
# nixpkgs' `lib`, so the rendering can be checked where the flake's inputs
# cannot be fetched. `unexpected` is empty when every case came out as it
# must:
#
#   nix-instantiate --eval --strict --json nix/tests/render-host-config.nix \
#     --arg lib 'import <nixpkgs/lib>' -A unexpected
#
# `checks.module-eval` in `flake.nix` asserts that, and the same rendering
# through the real NixOS and nix-darwin modules.
{ lib }:
let
  hostConfig = import ../host-config.nix { inherit lib; };
  evaluatedAll =
    values:
    (lib.evalModules {
      modules = [
        { options.hostConfig = lib.mkOption { type = hostConfig.optionType; }; }
      ] ++ map (value: { config.hostConfig = value; }) values;
    }).config.hostConfig;
  evaluated = value: evaluatedAll [ value ];
  # Whether a configuration is refused at evaluation by an option's type.
  refused = value: !(builtins.tryEval (builtins.deepSeq (evaluated value) true)).success;
  machineAndPoolsOnlyText = ''
    # Written by the runquotad Nix module (services.runquotad.hostConfig).
    # Change it there: `runquota config set` refuses a file linked into the store.
    schema = "runquota.host-config.v1"

    [machine]
    memory_bytes = 103079215104
    cpu_milli = 16000

    [pools]
    compile = 8
  '';
  self = {
    full = hostConfig.render (evaluated (import ./host-config-full.nix));
    fullProblems = hostConfig.problems { } (evaluated (import ./host-config-full.nix));

    # What the module rendered before it knew any other table, byte for byte:
    # a configuration that sets none of them writes none of their headers, so
    # a daemon older than a table still reads the file.
    machineAndPoolsOnly = hostConfig.render (evaluated {
      memoryBytes = 103079215104;
      cpuMilli = 16000;
      pools.compile = 8;
    });

    # Empty when every case below came out as it must: each of `refusals`
    # refused by an option's type, each of `crossKeyProblems` named by exactly
    # one problem, `acceptedByTheTypes` by none.
    unexpected =
      builtins.attrNames (lib.filterAttrs (_: wasRefused: !wasRefused) self.refusals)
      ++ builtins.attrNames (lib.filterAttrs (_: found: builtins.length found != 1) self.crossKeyProblems)
      ++ builtins.attrNames (lib.filterAttrs (_: found: found != [ ]) self.acceptedByTheTypes)
      ++ lib.optional (self.full != builtins.readFile ./host-config-full.toml) "full"
      ++ lib.optional (self.machineAndPoolsOnly != machineAndPoolsOnlyText) "machineAndPoolsOnly";

    refusals = {
      orderUnknown = refused { admission.order = [ "fifo" ]; };
      maxWaitWithoutUnit = refused { admission.maxWait = "90"; };
      horizonZero = refused { admission.horizon = "0s"; };
      # More milliseconds than the reader's 64 bits hold.
      maxWaitOverflows = refused { admission.maxWait = "9223372036854775807s"; };
      holdOverflows = refused { benchmark.maxHold = "99999999999999999999999m"; };
      poolNameWithDot = refused { pools."a.b" = 1; };
      oversubscriptionPercent = refused { admission.oversubscription = "10"; };
      pressureAboveHundred = refused { admission.pressureHigh = "101"; };
      benchmarkUserWithQuote = refused { benchmark.allowedUsers = [ "a\"b" ]; };
      benchmarkUserWithComma = refused { benchmark.allowedUsers = [ "a,b" ]; };
      benchmarkHoldZero = refused { benchmark.maxHold = "0m"; };
      poolNameWithNewline = refused { pools."a\n[admission]" = 1; };
    };

    crossKeyProblems = {
      orderEmpty = hostConfig.problems { } (evaluated {
        admission.order = [ ];
      });
      orderTwice = hostConfig.problems { } (evaluated {
        admission.order = [
          "arrival"
          "arrival"
        ];
      });
      # Each definition is a valid order; the module system joins them.
      orderTwiceAcrossModules = hostConfig.problems { } (evaluatedAll [
        { admission.order = [ "priority" ]; }
        { admission.order = [ "priority" ]; }
      ]);
      classNameWithDot = hostConfig.problems { } (evaluated {
        reservations."a.b" = { };
      });
      classNameTooLong = hostConfig.problems { } (evaluated {
        reservations.${lib.concatStrings (lib.genList (_: "a") 65)} = { };
      });
      pressureLowAboveDefaultHigh = hostConfig.problems { } (evaluated {
        admission.pressureLow = "11";
      });
      pressureHighBelowDefaultLow = hostConfig.problems { } (evaluated {
        admission.pressureHigh = "4";
      });
      reservedCpuAboveBudget = hostConfig.problems { } (evaluated {
        cpuMilli = 4000;
        reservations.ci.cpuMilli = 3000;
        reservations.dev.cpuMilli = 2000;
      });
      # The sum saturates instead of aborting the evaluation.
      reservedNearTheTopOf64Bits = hostConfig.problems { } (evaluated {
        memoryBytes = 1024;
        reservations.a.memoryBytes = 9223372036854775807;
        reservations.b.memoryBytes = 9223372036854775807;
      });
      reservedMemoryAboveBudget = hostConfig.problems { } (evaluated {
        memoryBytes = 1024;
        reservations.ci.memoryBytes = 2048;
      });
    };

    acceptedByTheTypes = {
      # A flag wins over the file, so only the daemon knows the budget.
      reservedAboveFileBudgetUnderAFlag = hostConfig.problems { budgetFromFlags = true; } (evaluated {
        cpuMilli = 4000;
        reservations.ci.cpuMilli = 6000;
      });
      twelveDigitMinutes = hostConfig.problems { } (evaluated {
        admission.maxWait = "999999999999m";
      });
      full = self.fullProblems;
      # No budget declared here: only the daemon knows the one in force.
      reservedWithoutDeclaredBudget = hostConfig.problems { } (evaluated {
        reservations.ci.cpuMilli = 3000;
      });
      pressureWithinDefaults = hostConfig.problems { } (evaluated {
        admission.pressureLow = "9.5";
      });
    };
  };
in
self

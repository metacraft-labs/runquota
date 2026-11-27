# The host budget file, `runquotad.toml`, for the Nix modules: the option
# type a module declares it with, and the TOML it renders.
#
# THE SAME PATH AND SHAPE AS `runquota_daemon/host_config`. The daemon reads
# `/etc/runquota/runquotad.toml` (`hostConfigPath`) with a reader
# (`parseHostConfig`) that accepts exactly one subset of TOML and refuses
# anything else, so what is rendered here is that subset and nothing more.
#
# EVERY TABLE AND KEY THE READER ACCEPTS HAS AN OPTION HERE: `[machine]`,
# `[pools]`, `[admission]`, `[benchmark]`, `[enforcement]` and
# `[reservation.<class>]`. With `hostConfig` set the file is a link into the
# store, and `runquota config set` refuses a link, so this module is then the
# only way to write the file: a key it could not express could not be set on
# that host at all. A KEY ADDED TO THE READER IS ADDED HERE IN THE SAME
# CHANGE. `libs/runquota_daemon/tests/t_host_config_nix_module_covers_reader`
# refuses a reader key that `nix/tests/host-config-full.toml` does not set,
# and `checks.module-eval` in `flake.nix` refuses a rendering of
# `nix/tests/host-config-full.nix` that differs from that file.
#
# A table other than `[machine]` and `[pools]` is rendered only when one of
# its keys is set. A daemon older than a table refuses a file that has it,
# so a configuration that does not use a table must not write its header.
#
# The option types refuse at evaluation what the reader refuses line by
# line. `problems` lists what is left, for the modules' `assertions`: the
# rules the reader judges across keys, and the class names.
{ lib }:
let
  inherit (lib) types;
  positive = types.ints.positive;
  # The reader keeps CPU figures and pool sizes in 32 bits.
  positive32 = types.ints.between 1 4294967295;
  unsigned32 = types.ints.between 0 4294967295;

  # A bare key of the subset (`isBareKey`), which is also the class-name
  # rule (`reservationClassProblem`) once the length is bounded.
  bareKey = "[A-Za-z0-9_-]+";
  isBareKey = name: builtins.match bareKey name != null;
  isClassName = name: isBareKey name && builtins.stringLength name <= 64;

  # A whole number and a unit: `1500ms`, `90s`, `2m` (`parseDurationMillis`).
  # Twelve digits at most: the reader keeps milliseconds in 64 bits and
  # refuses a figure that does not fit, and twelve digits of minutes do.
  duration = types.strMatching "[0-9]{1,12}(ms|s|m)";
  positiveDuration = types.addCheck duration (text: builtins.match "0+(ms|s|m)" text == null) // {
    description = "positive duration such as \"90s\", \"1500ms\" or \"2m\"";
  };
  # A decimal percentage from 0 to 100, as the file quotes it.
  percent = types.strMatching "(100(\\.0+)?|[1-9]?[0-9](\\.[0-9]+)?)";
  # A decimal fraction from 0 to 1 with at most three decimals.
  fraction = types.strMatching "(0(\\.[0-9]{1,3})?|1(\\.0{1,3})?)";
  # The memory-cap factor as the file writes it (a bare number, at most
  # three decimals: `parseFactorMilli`), and at least 1.5, the reader's
  # floor (`MinMemoryCapFactorMilli`). Spelled so it is also a JSON number,
  # which is how the floor is checked.
  memoryCapFactor =
    types.addCheck (types.strMatching "(0|[1-9][0-9]{0,5})(\\.[0-9]{1,3})?") (
      text: builtins.fromJSON text >= 1.5
    )
    // {
      description = "number of at least 1.5 with at most three decimals, such as \"2\" or \"1.5\"";
    };
  # A string of the subset: no quote, no escape. An array item is split at
  # commas, so it carries none either.
  # A user or group name, or a decimal id: no quote, no escape, no space.
  accountName = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.-]*" // {
    description = "user or group name, or decimal id";
  };
  # `ClassSocketModes` of the daemon's reader.
  classSocketModes = [
    "0600"
    "0660"
    "0666"
  ];
  arrayItem = types.strMatching "[^\"\\\\,\n\r]+" // {
    description = "non-empty string without a quote, a backslash, a comma or a line break";
  };

  admissionOrderKeys = [
    "starvation"
    "priority"
    "cache-deadline"
    "fair-share"
    "arrival"
  ];

  # `DefaultPressureHighPct` / `DefaultPressureLowPct` of the daemon: the
  # reader fills an absent threshold with them before it compares the two.
  defaultPressureHigh = "10";
  defaultPressureLow = "5";

  nullable =
    type: description:
    lib.mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };

  quoted = value: "\"${value}\"";
  onOff = value: quoted (if value then "on" else "off");
  stringArray = items: "[${lib.concatMapStringsSep ", " quoted items}]";
  entry =
    key: value: spell:
    lib.optional (value != null) "${key} = ${spell value}";
  # A table that is written only when it has a line.
  table =
    header: lines:
    lib.optionals (lines != [ ]) (
      [
        ""
        header
      ]
      ++ lines
    );

  # Saturating, as the daemon adds reservations: two figures near the top
  # of 64 bits are a refusal to report, not an evaluation that aborts.
  maxInt = 9223372036854775807;
  sum = lib.foldl' (total: next: if total > maxInt - next then maxInt else total + next) 0;
in
{
  path = "/etc/runquota/runquotad.toml";

  # The class sockets a configuration declares, for a module that has
  # systemd create them (socket activation): one entry per reservation, with
  # the values the daemon would apply itself. The daemon checks the socket
  # it is handed against its own reading of the file, so these must agree.
  inherit classSocketModes;
  classSockets =
    cfg:
    lib.mapAttrsToList (name: class: {
      inherit name;
      fileName = "class-${name}.sock";
      owner = class.socketOwner;
      group = class.socketGroup;
      mode = if class.socketMode == null then "0600" else class.socketMode;
    }) cfg.reservations;

  # Relative to /etc, for `environment.etc`.
  etcName = "runquota/runquotad.toml";

  schema = "runquota.host-config.v1";

  optionType = types.submodule {
    options = {
      memoryBytes = nullable positive "`[machine] memory_bytes`: the host memory budget.";
      cpuMilli = nullable positive32 "`[machine] cpu_milli`: the host CPU budget; 1000 is one core.";
      writeBytesPerSec = nullable positive ''
        `[machine] write_bytes_per_sec`: what this host's storage sustains,
        in bytes per second. Reported, not enforced.
      '';
      pools = lib.mkOption {
        type = types.addCheck (types.attrsOf positive32) (
          pools: lib.all isBareKey (builtins.attrNames pools)
        );
        default = { };
        description = ''
          `[pools]`: named counters, NAME = UNITS. A name holds only letters,
          digits, `_` and `-`, the file's bare-key rule. A pool whose name
          has a `.` or a `/` cannot be sized in the file: it takes the
          capacity its builds declare, or a `--pool` flag in `extraArgs`.
        '';
      };

      admission = {
        order = nullable (types.listOf (types.enum admissionOrderKeys)) ''
          `[admission] order`: the admission keys, most significant first,
          each of ${lib.concatStringsSep ", " admissionOrderKeys} at most
          once, and at least one.
        '';
        maxWait = nullable duration ''
          `[admission] max-wait`: the starvation bound, as `"120s"`,
          `"1500ms"` or `"2m"`; `"0s"` turns it off.
        '';
        shareBetweenUsers = nullable (types.enum [
          "drf"
          "none"
        ]) "`[admission] share-between-users`.";
        predictive = nullable types.bool ''
          `[admission] predictive`: admit into predicted slack. Rendered
          `"on"` or `"off"`.
        '';
        horizon = nullable positiveDuration "`[admission] horizon`: the admission horizon, a positive duration.";
        pressureHigh = nullable percent ''
          `[admission] pressure-high`: the CPU pressure, a percentage such as
          `"10"` or `"2.5"`, above which reclaim and widening stop.
        '';
        pressureLow = nullable percent ''
          `[admission] pressure-low`: the CPU pressure below which they
          resume. Not above `pressureHigh`.
        '';
        oversubscription = nullable fraction ''
          `[admission] oversubscription`: the CPU oversubscription target, a
          fraction of the budget from `"0"` to `"1"` with at most three
          decimals (`"0.1"` is ten percent).
        '';
      };

      benchmark = {
        allowedUsers = lib.mkOption {
          type = types.listOf arrayItem;
          default = [ ];
          description = ''
            `[benchmark] allowed-users`: user names or decimal uids that may
            take a benchmark lease besides the daemon's own user and root.
          '';
        };
        allowedGroups = lib.mkOption {
          type = types.listOf arrayItem;
          default = [ ];
          description = "`[benchmark] allowed-groups`: groups whose members may take a benchmark lease.";
        };
        maxQueueWait = nullable positiveDuration "`[benchmark] max-queue-wait`: how long a benchmark may sit queued.";
        maxHold = nullable positiveDuration "`[benchmark] max-hold`: how long a granted benchmark gates admission.";
      };

      enforcement = {
        cgroups = nullable types.bool ''
          `[enforcement] cgroups`: RunQuota's launchers place their trees in
          cgroups (Linux). Rendered `"on"` or `"off"`.
        '';
        jobPriority = nullable types.bool ''
          `[enforcement] job-priority`: the Windows key. The reader accepts
          it on every platform and only Windows launchers act on it.
        '';
        qos = nullable types.bool ''
          `[enforcement] qos`: RunQuota's launchers put reclaimed and
          low-priority trees under the background policy (macOS).
        '';
        memoryCap =
          nullable
            (types.enum [
              "off"
              "advisory"
              "kill"
            ])
            ''
              `[enforcement] memoryCap`: what RunQuota's launchers do with each
              grant's memory cap: nothing (`off`, the daemon's default),
              measure and report a breach (`advisory`), or kill the tree that
              passes it (`kill`).
            '';
        memoryCapFactor = nullable memoryCapFactor ''
          `[enforcement] memoryCapFactor`: the factor runquotad multiplies a
          command's largest successful tree peak by to compute its memory
          cap; at least 1.5 (the daemon's default is 2). A string, rendered
          as a bare number.
        '';
      };

      reservations = lib.mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              cpuMilli = nullable unsigned32 "`cpu-milli`: the CPU the class reserves, in milli-CPUs.";
              memoryBytes = nullable types.ints.unsigned "`memory-bytes`: the memory the class reserves.";
              lend = nullable types.bool ''
                `lend`: whether the class's idle reserved CPU may be lent
                (the daemon's default is true).
              '';
              socketOwner = nullable accountName ''
                `socket-owner`: the owner of the class's socket, a user name
                or decimal uid (the daemon's default: its own user). Only a
                daemon running as root can give the socket to another user.
              '';
              socketGroup = nullable accountName ''
                `socket-group`: the group of the class's socket, a group name
                or decimal gid (the daemon's default: its primary group). The
                daemon's account must be in it.
              '';
              socketMode = nullable (types.enum classSocketModes) ''
                `socket-mode`: who may claim the class by connecting to its
                socket: `"0600"` the owner only (the daemon's default),
                `"0660"` the owner and the group, `"0666"` every local user
                who can reach the rendezvous.
              '';
            };
          }
        );
        default = { };
        description = ''
          `[reservation.<class>]`: one table per class. A class name is 1 to
          64 letters, digits, `_` and `-`. Together the reservations must
          fit the budget in force.
        '';
      };
    };
  };

  # The `runquotad` flags that set the budget. A flag wins over the file, so
  # with one in `extraArgs` the reservations are judged against a budget
  # this configuration does not hold.
  budgetFlags = [
    "--cpu-milli"
    "--memory-bytes"
    "--machine"
  ];

  # What the reader would refuse although every option is well-formed by
  # itself: the rules it judges across keys, the class names, and an
  # admission order that is empty or lists a key twice. Empty when there is
  # none. The modules turn each into a failed assertion, so a system is
  # never built from a file with one.
  #
  # Two of these are judged here and not by an option's type. The module
  # system rebuilds a type that holds a submodule, which drops a check added
  # to it (the class names). And a check added to a list type sees each
  # definition by itself, before two modules' lists are joined (the order).
  #
  # The reservations are compared with the budget only where this
  # configuration sets one and no flag does (`budgetFromFlags`). Against a
  # built-in default (a share of the machine's memory, its processor count)
  # or a `runquotad` flag, only the daemon can judge, and it does: it
  # refuses the file.
  problems =
    {
      budgetFromFlags ? false,
    }:
    cfg:
    let
      order = cfg.admission.order;
      high =
        if cfg.admission.pressureHigh == null then defaultPressureHigh else cfg.admission.pressureHigh;
      low = if cfg.admission.pressureLow == null then defaultPressureLow else cfg.admission.pressureLow;
      # The percent type admits only what is also a JSON number.
      number = builtins.fromJSON;
      classes = builtins.attrValues cfg.reservations;
      reserved = key: sum (map (class: if class.${key} == null then 0 else class.${key}) classes);
    in
    map (
      name:
      "hostConfig.reservations: `${name}` is not a class name (1 to 64 letters, digits, `_` and `-`)"
    ) (builtins.filter (name: !isClassName name) (builtins.attrNames cfg.reservations))
    ++ lib.optional (order == [ ]) "hostConfig.admission.order is empty; list at least one key"
    ++ lib.optional (
      order != null && lib.unique order != order
    ) "hostConfig.admission.order lists a key twice: ${lib.concatStringsSep ", " order}"
    ++
      lib.optional (number low > number high)
        "hostConfig.admission: pressureLow (${low}) is above pressureHigh (${high}); an unset one is the daemon's default"
    ++
      lib.optional (!budgetFromFlags && cfg.cpuMilli != null && reserved "cpuMilli" > cfg.cpuMilli)
        "hostConfig.reservations: the classes reserve ${toString (reserved "cpuMilli")} milli-CPUs, more than cpuMilli (${toString cfg.cpuMilli})"
    ++
      lib.optional
        (!budgetFromFlags && cfg.memoryBytes != null && reserved "memoryBytes" > cfg.memoryBytes)
        "hostConfig.reservations: the classes reserve ${toString (reserved "memoryBytes")} bytes, more than memoryBytes (${toString cfg.memoryBytes})";

  render =
    cfg:
    lib.concatStringsSep "\n" (
      [
        "# Written by the runquotad Nix module (services.runquotad.hostConfig)."
        "# Change it there: `runquota config set` refuses a file linked into the store."
        "schema = \"runquota.host-config.v1\""
        ""
        "[machine]"
      ]
      ++ entry "memory_bytes" cfg.memoryBytes toString
      ++ entry "cpu_milli" cfg.cpuMilli toString
      ++ entry "write_bytes_per_sec" cfg.writeBytesPerSec toString
      ++ [
        ""
        "[pools]"
      ]
      ++ lib.mapAttrsToList (name: units: "${name} = ${toString units}") cfg.pools
      ++ table "[admission]" (
        entry "order" cfg.admission.order stringArray
        ++ entry "max-wait" cfg.admission.maxWait quoted
        ++ entry "share-between-users" cfg.admission.shareBetweenUsers quoted
        ++ entry "predictive" cfg.admission.predictive onOff
        ++ entry "horizon" cfg.admission.horizon quoted
        ++ entry "pressure-high" cfg.admission.pressureHigh quoted
        ++ entry "pressure-low" cfg.admission.pressureLow quoted
        ++ entry "oversubscription" cfg.admission.oversubscription quoted
      )
      ++ table "[benchmark]" (
        lib.optional (
          cfg.benchmark.allowedUsers != [ ]
        ) "allowed-users = ${stringArray cfg.benchmark.allowedUsers}"
        ++ lib.optional (
          cfg.benchmark.allowedGroups != [ ]
        ) "allowed-groups = ${stringArray cfg.benchmark.allowedGroups}"
        ++ entry "max-queue-wait" cfg.benchmark.maxQueueWait quoted
        ++ entry "max-hold" cfg.benchmark.maxHold quoted
      )
      ++ table "[enforcement]" (
        entry "cgroups" cfg.enforcement.cgroups onOff
        ++ entry "job-priority" cfg.enforcement.jobPriority onOff
        ++ entry "qos" cfg.enforcement.qos onOff
        ++ entry "memoryCap" cfg.enforcement.memoryCap quoted
        ++ entry "memoryCapFactor" cfg.enforcement.memoryCapFactor (value: value)
      )
      # A class declared without a key still gets its header: the reader
      # takes a table without keys as a class that reserves nothing.
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: class:
          [
            ""
            "[reservation.${name}]"
          ]
          ++ entry "cpu-milli" class.cpuMilli toString
          ++ entry "memory-bytes" class.memoryBytes toString
          ++ entry "lend" class.lend lib.boolToString
          ++ entry "socket-owner" class.socketOwner quoted
          ++ entry "socket-group" class.socketGroup quoted
          ++ entry "socket-mode" class.socketMode quoted
        ) cfg.reservations
      )
    )
    + "\n";
}

# A `services.runquotad.hostConfig` that sets EVERY key the daemon's host
# file reader accepts. `nix/host-config.nix` renders it to exactly
# `host-config-full.toml` beside this file (`checks.module-eval` in
# `flake.nix`, and `nix/tests/render-host-config.nix` without the flake), and
# `libs/runquota_daemon/tests/t_host_config_nix_module_covers_reader` holds
# that file to the reader. A key added to the reader is added to all three.
{
  memoryBytes = 103079215104;
  cpuMilli = 16000;
  writeBytesPerSec = 524288000;
  pools = {
    compile = 8;
    fetch = 2;
  };
  admission = {
    order = [
      "starvation"
      "fair-share"
      "arrival"
    ];
    maxWait = "90s";
    shareBetweenUsers = "none";
    predictive = true;
    horizon = "10s";
    pressureHigh = "12.5";
    pressureLow = "4";
    oversubscription = "0.125";
  };
  benchmark = {
    allowedUsers = [
      "alice"
      "1001"
    ];
    allowedGroups = [ "bench" ];
    maxQueueWait = "5m";
    maxHold = "30m";
  };
  enforcement = {
    cgroups = true;
    jobPriority = false;
    qos = true;
  };
  reservations = {
    ci = {
      cpuMilli = 8000;
      memoryBytes = 34359738368;
      lend = false;
      socketOwner = "1001";
      socketGroup = "2000";
      socketMode = "0660";
    };
    interactive = { };
  };
}

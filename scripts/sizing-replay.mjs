#!/usr/bin/env node
// Reference offline sizing replay.
//
// Reads the records `runquota observations export --format sizing` writes
// (NDJSON: a header, then runs each followed by their executions, then the
// ambient samples) and prints the figures `runquota sizing --json` prints for
// the same query: the runs replayed and excluded, the missing-data counts,
// the foreign-RSS baseline, and per N the quantile and maximum over runs of
// the peak concurrent memory, the makespan and the peak write rate.
//
// It is a SECOND, INDEPENDENT implementation of the sizing replay, whose
// numbered definition (steps 1-10) is the module comment of
// libs/runquota_observation_store/.../sizing_replay.nim; it follows those
// steps and shares no code with the daemon. Both work in integer milliseconds, bytes and
// milli-CPUs, with the quantile the only floating-point value, so for the
// same records they agree exactly; tests/integration/
// t_sizing_end_to_end.nim checks that against a real daemon.
//
// Integer products that can exceed 2^53 (a time in a run times a stretched
// duration) are computed with BigInt.
//
// Usage:
//   runquota observations export --format sizing --project P > sizing.ndjson
//   node scripts/sizing-replay.mjs --cpus 2,8 [--quantile 0.99]
//        [--host-profile current|all] [sizing.ndjson]   (stdin without a file)

import { readFileSync } from "node:fs";

const MiB = 1024 * 1024;

// The largest value of a non-empty array. Not `Math.max(...values)`, which
// passes every value as an argument and fails on a long array.
function maxOf(values) {
  let best = values[0];
  for (const value of values) if (value > best) best = value;
  return best;
}

function parseArgs(argv) {
  const options = { cpus: [], quantile: 0.99, allProfiles: false, file: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--cpus") {
      options.cpus = argv[++i].split(",").map((s) => {
        const n = Number.parseInt(s, 10);
        if (!(n >= 1)) throw new Error(`--cpus: bad count ${s}`);
        return n;
      });
    } else if (arg === "--quantile") {
      options.quantile = Number.parseFloat(argv[++i]);
      if (!(options.quantile > 0 && options.quantile <= 1)) {
        throw new Error("--quantile takes a number in (0, 1]");
      }
    } else if (arg === "--host-profile") {
      const value = argv[++i];
      if (value !== "current" && value !== "all") {
        throw new Error("--host-profile is current or all");
      }
      options.allProfiles = value === "all";
    } else if (!arg.startsWith("--") && options.file === null) {
      options.file = arg;
    } else {
      throw new Error(`unrecognised argument ${arg}`);
    }
  }
  if (options.cpus.length === 0) throw new Error("--cpus N[,N...] is required");
  return options;
}

// ceil(a / b) for a >= 0, b > 0 (integers as Numbers below 2^53).
function ceilDiv(a, b) {
  if (a <= 0) return 0;
  return Number((BigInt(a) + BigInt(b) - 1n) / BigInt(b));
}

// floor(a * b / c) exactly, for non-negative integers.
function mulDiv(a, b, c) {
  return Number((BigInt(a) * BigInt(b)) / BigInt(c));
}

// Step 9's nearest rank: v[max(1, ceil(q*n - 1e-9))], 1-based.
function nearestRank(values, q) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((x, y) => x - y);
  const rank = Math.max(1, Math.ceil(q * sorted.length - 1e-9));
  return sorted[Math.min(sorted.length, rank) - 1];
}

function orderTime(e) {
  return e.requested_at_unix_millis ?? e.started_at_unix_millis;
}

function compareOrder(a, b) {
  const ta = orderTime(a), tb = orderTime(b);
  if (ta !== tb) return ta < tb ? -1 : 1;
  const la = a.lease_id ?? -1, lb = b.lease_id ?? -1;
  if (la !== lb) return la < lb ? -1 : 1;
  if (a.execution_id === b.execution_id) return 0;
  return a.execution_id < b.execution_id ? -1 : 1;
}

// Step 1: why a run is not replayed, or "included".
function classify(run, currentProfile, allProfiles) {
  const es = run.executions;
  if (es.length === 0) return "empty";
  if (run.open) return "open";
  if (!run.complete || es.some((e) => !e.complete)) return "incomplete";
  const first = [...es].sort(compareOrder)[0];
  const profile = first.host_profile_id;
  const mixed = es.some((e) => e.host_profile_id !== profile);
  if (!allProfiles) {
    if (mixed) return "mixed_profiles";
    if (profile !== currentProfile) return "other_profile";
  }
  return "included";
}

// Step 4.
function stretched(e, width, granted) {
  const d = Math.max(0, e.duration_millis);
  if (granted >= width) return d;
  const p = e.cpu_profile;
  if (p && p.interval_ms > 0 && p.samples.length > 0 && d > 0) {
    const k = Math.min(p.samples.length, ceilDiv(d, p.interval_ms));
    let total = 0;
    for (let i = 0; i < k; i++) {
      const len = i < k - 1 ? p.interval_ms : d - (k - 1) * p.interval_ms;
      total += Math.max(len, ceilDiv(len * p.samples[i], granted));
    }
    return total;
  }
  if (e.cpu_user_millis !== null || e.cpu_sys_millis !== null) {
    const cpu = (e.cpu_user_millis ?? 0) + (e.cpu_sys_millis ?? 0);
    return Math.max(d, ceilDiv(cpu * 1000, granted));
  }
  return ceilDiv(d * width, granted);
}

// The maximum of a sum of [start, end) segments; every change at one instant
// is applied before the sum is read.
function peakOf(segments) {
  const events = [];
  for (const [s, e, amount] of segments) {
    if (e > s && amount !== 0) {
      events.push([s, amount]);
      events.push([e, -amount]);
    }
  }
  events.sort((x, y) => x[0] - y[0]);
  let current = 0, peak = 0, i = 0;
  while (i < events.length) {
    const t = events[i][0];
    while (i < events.length && events[i][0] === t) current += events[i++][1];
    peak = Math.max(peak, current);
  }
  return peak;
}

// Steps 2-8 for one run at n tokens.
function replay(run, n, counts) {
  const es = [...run.executions].sort(compareOrder);
  const m = es.length;
  let t0 = run.started_at_unix_millis;
  for (const e of es) t0 = Math.min(t0, orderTime(e));
  const index = new Map(es.map((e, i) => [e.execution_id, i]));
  const req = [], recFinish = [], width = [], tokens = [], duration = [];
  for (const e of es) {
    req.push(Math.max(0, orderTime(e) - t0));
    recFinish.push(e.finished_at_unix_millis - t0);
    const w = e.cpu_granted_milli === null ? 1000 : Math.max(0, e.cpu_granted_milli);
    width.push(w);
    const tok = Math.min(n, Math.max(1, ceilDiv(w, 1000)));
    tokens.push(tok);
    duration.push(stretched(e, w, tok * 1000));
    if (counts) {
      counts.replayed++;
      if (e.requested_at_unix_millis === null) counts.ready_time_unknown++;
      if (e.cpu_granted_milli === null) counts.width_unknown++;
      if (!e.memory_profile) counts.memory_from_peak++;
      if (!e.cpu_profile && e.cpu_user_millis === null && e.cpu_sys_millis === null) {
        counts.cpu_unknown++;
      }
    }
  }
  // Step 6.
  const preds = es.map((e, i) => {
    if (!e.after) return [];
    const list = [];
    for (const id of e.after) {
      const j = index.get(id);
      if (j !== undefined && j < i && !list.includes(j)) list.push(j);
    }
    return list;
  });
  const usesAfter = preds.map((p) => p.length > 0);
  const potentials = es.map((_, i) => {
    if (usesAfter[i]) return [];
    const list = [];
    for (let j = 0; j < i; j++) if (recFinish[j] <= req[i]) list.push(j);
    return list;
  });
  // Step 7.
  const started = new Array(m).fill(false);
  const done = new Array(m).fill(false);
  const startAt = new Array(m).fill(0), finishAt = new Array(m).fill(0);
  const readyOf = (i) => {
    const deps = usesAfter[i] ? preds[i] : potentials[i];
    if (!deps.every((j) => done[j])) return null;
    if (usesAfter[i]) return maxOf(deps.map((j) => finishAt[j]));
    if (deps.length === 0) return req[i];
    const shift = maxOf(deps.map((j) => finishAt[j] - recFinish[j]));
    return Math.max(0, req[i] + shift);
  };
  let free = n, finished = 0, t = 0;
  let running = [];
  while (finished < m) {
    let again = true;
    while (again) {
      again = false;
      const still = [];
      for (const r of running) {
        if (finishAt[r] <= t) {
          done[r] = true;
          finished++;
          free += tokens[r];
          again = true;
        } else {
          still.push(r);
        }
      }
      running = still;
      for (let i = 0; i < m; i++) {
        if (started[i]) continue;
        const ready = readyOf(i);
        if (ready !== null && ready <= t && tokens[i] <= free) {
          started[i] = true;
          startAt[i] = t;
          finishAt[i] = t + duration[i];
          free -= tokens[i];
          running.push(i);
          if (duration[i] === 0) again = true;
        }
      }
    }
    if (finished >= m) break;
    let next = Infinity;
    for (const r of running) if (finishAt[r] > t) next = Math.min(next, finishAt[r]);
    for (let i = 0; i < m; i++) {
      if (started[i]) continue;
      const ready = readyOf(i);
      if (ready !== null && ready > t) next = Math.min(next, ready);
    }
    if (next === Infinity) break;
    t = next;
  }
  // Step 8.
  const memory = [], writes = [];
  let makespan = 0;
  es.forEach((e, i) => {
    if (!started[i]) return;
    const d = Math.max(0, e.duration_millis);
    const dPrime = duration[i];
    makespan = Math.max(makespan, finishAt[i]);
    const mp = e.memory_profile;
    if (mp && mp.interval_ms > 0 && mp.samples_mib.length > 0) {
      if (d > 0) {
        for (let j = 0; j < mp.samples_mib.length; j++) {
          const a = j * mp.interval_ms;
          if (a >= d) break;
          const b = Math.min((j + 1) * mp.interval_ms, d);
          const aPrime = mulDiv(a, dPrime, d), bPrime = mulDiv(b, dPrime, d);
          if (bPrime > aPrime) {
            memory.push([startAt[i] + aPrime, startAt[i] + bPrime, mp.samples_mib[j] * MiB]);
          }
        }
      }
    } else {
      memory.push([startAt[i], startAt[i] + dPrime, Math.max(0, e.peak_rss_bytes)]);
    }
    if (e.io_write_bytes !== null && dPrime > 0) {
      writes.push([startAt[i], startAt[i] + dPrime,
        mulDiv(Math.max(0, e.io_write_bytes), 1000, dPrime)]);
    }
  });
  return { peak: peakOf(memory), makespan, write: peakOf(writes) };
}

function runWindow(run) {
  let t0 = run.started_at_unix_millis, last = run.started_at_unix_millis;
  for (const e of run.executions) {
    t0 = Math.min(t0, orderTime(e));
    last = Math.max(last, e.finished_at_unix_millis);
  }
  return [t0, last];
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const text = readFileSync(options.file ?? 0, "utf8");
  let header = null;
  const runs = [], ambient = [];
  const byKey = new Map();
  for (const line of text.split("\n")) {
    if (line.trim() === "") continue;
    const record = JSON.parse(line);
    if (record.type === "header") header = record;
    else if (record.type === "run") {
      const run = { ...record, executions: [] };
      byKey.set(`${record.host_id}\0${record.run_id}`, run);
      runs.push(run);
    } else if (record.type === "execution") {
      const run = byKey.get(`${record.host_id}\0${record.run_id}`);
      if (!run) throw new Error(`execution ${record.execution_id} before its run`);
      run.executions.push(record);
    } else if (record.type === "ambient") ambient.push(record);
  }
  if (!header || header.format !== "runquota-sizing/1") {
    throw new Error("not a runquota-sizing/1 export");
  }
  const exclusions = {
    included: 0, incomplete: 0, open: 0, empty: 0, other_profile: 0, mixed_profiles: 0,
  };
  const included = [];
  for (const run of runs) {
    const verdict = classify(run, header.current_host_profile, options.allProfiles);
    exclusions[verdict]++;
    if (verdict === "included") included.push(run);
  }
  const counts = {
    replayed: 0, ready_time_unknown: 0, width_unknown: 0, memory_from_peak: 0, cpu_unknown: 0,
  };
  const q = options.quantile;
  const sizes = options.cpus.map((n, ni) => {
    const peaks = [], spans = [], writes = [];
    for (const run of included) {
      const r = replay(run, n, ni === 0 ? counts : null);
      peaks.push(r.peak);
      spans.push(r.makespan);
      writes.push(r.write);
    }
    if (peaks.length === 0) return { cpus: n };
    return {
      cpus: n,
      memory_quantile_bytes: nearestRank(peaks, q),
      memory_max_bytes: maxOf(peaks),
      makespan_quantile_millis: nearestRank(spans, q),
      makespan_max_millis: maxOf(spans),
      write_quantile_bytes_per_sec: nearestRank(writes, q),
      write_max_bytes_per_sec: maxOf(writes),
    };
  });
  // Step 10.
  const foreign = [];
  for (const point of ambient) {
    for (const run of included) {
      const [a, b] = runWindow(run);
      if (point.host_id === run.host_id && point.sampled_at_unix_millis >= a &&
          point.sampled_at_unix_millis <= b) {
        foreign.push(point.foreign_rss_bytes);
        break;
      }
    }
  }
  const known = foreign.length > 0;
  const baselineQ = known ? nearestRank(foreign, q) : null;
  for (const size of sizes) {
    if (size.memory_quantile_bytes !== undefined) {
      size.total_bytes = known ? size.memory_quantile_bytes + baselineQ : null;
    }
  }
  const out = {
    quantile: q,
    host_profile: options.allProfiles ? "all" : "current",
    runs: {
      candidates: runs.length,
      replayed: exclusions.included,
      incomplete: exclusions.incomplete,
      open: exclusions.open,
      empty: exclusions.empty,
      other_profile: exclusions.other_profile,
      mixed_profiles: exclusions.mixed_profiles,
      // The daemon spends a bounded work budget and counts the runs it did
      // not reach here; this replay has none, so it replays every run.
      over_budget: 0,
    },
    executions: counts,
    baseline: {
      known,
      samples: foreign.length,
      quantile_bytes: baselineQ,
      max_bytes: known ? maxOf(foreign) : null,
    },
    sizes,
  };
  process.stdout.write(JSON.stringify(out) + "\n");
}

main();

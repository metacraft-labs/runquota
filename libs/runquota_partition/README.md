# runquota_partition

Generic typed multi-way DAG partitioning library. Given a weighted-node DAG,
a set of roots, a shard count, and a shared-input policy, `computePartition`
returns a `PartitionPlan` assigning each root to a shard and reporting the
per-shard accumulated cost.

The algorithm is greedy LPT (Longest Processing Time first) with a
local-search refinement pass:

1. Each root's total cost is computed under the selected policy.
   - `sipIndependent`: closure cost (weight of root + every node reachable
     through `deps`). Each shard pays for every node it touches.
   - `sipShared`: just the root's own `weight`. Closure cost is paid once
     across the whole partition, so adding or removing a root does not
     change the closure cost contribution from that shard.
2. Roots are sorted by descending total cost.
3. Each root is assigned to the shard with the lowest current accumulated
   cost (classic LPT).
4. A local-search pass runs up to `refinementPasses` times. For each pair
   `(heaviest shard, lightest shard)`, the planner attempts a single-root
   swap and accepts it only if it strictly reduces `max_k W(k)`.

## Quality Bound

For the `sipIndependent` case, plain LPT has the classic
`(4/3 - 1/(3N))`-approximation bound from Graham (1969) where `N` is the
shard count. With the refinement pass, the worst-case bound is unchanged
but real-world build graphs see noticeably tighter packings.

The bound returned in `PartitionPlan.bound` is:

```
bound_ns = sumRootCostNs * (4/3 - 1/(3*N))
```

This is the LPT upper bound on `max_k W(k)` when each root contributes its
own cost (the cost the partitioner actually packs). For the
`sipShared` case the same expression applies because the closure cost
collapses to a constant shared across every shard, leaving the LPT bound
on the root weights themselves.

## Degradation Conditions

- When a single root's closure cost exceeds `total_cost / N`, the bound is
  loose because LPT cannot split a single root across shards.
- For `sipIndependent` with heavy overlap between root closures, the
  effective per-shard cost grows because shared dependencies are
  double-counted. Callers that care about overlap should use
  `sipShared`.
- The refinement pass is greedy; pathological symmetric inputs can leave
  it stuck in a local minimum. In practice, build graphs with diverse
  closure weights converge within a handful of passes.

## Dependencies

- `runquota_core` (for shared types and version helpers).
- `std/times` (for `Duration`).
- `std/sets` (for closure bookkeeping).
- `std/algorithm` (for sort).
- `std/hashes` (for `HashSet[NodeId]`).

No imports from `repro_*` or `ct_*`. The library is callable by anything
that needs joint cost-aware multi-way partitioning.

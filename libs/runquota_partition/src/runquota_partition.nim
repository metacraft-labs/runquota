## runquota_partition: generic typed multi-way DAG partitioner.
##
## This library exposes a typed API for partitioning a weighted-node
## DAG across `N` shards. Callers supply a list of `PartitionNode`
## records (the cost graph), a list of `PartitionRoot` records (the
## items being partitioned), a shard count, and a shared-input policy.
## `computePartition` returns a `PartitionPlan` with one
## `PartitionAssignment` per root, the per-shard accumulated cost, and
## a quality bound on `max_k W(k)`.
##
## Algorithm
## =========
##
## Greedy LPT (Longest Processing Time first) with a local-search
## refinement pass. Roots are sorted by descending policy-aware cost,
## each is assigned to the currently-lowest shard, and then up to
## `refinementPasses` swap-or-move passes are run between the heaviest
## and lightest shards. A swap is accepted only when it strictly
## reduces `max_k W(k)`.
##
## Quality Bound
## =============
##
## For the classic multiprocessor-scheduling case (`sipIndependent`
## with disjoint root closures) plain LPT has the Graham (1969)
## `(4/3 - 1/(3N))`-approximation bound, where `N` is the shard count.
## The refinement pass does not improve the worst-case bound but
## empirically yields tighter packings on real-world build graphs.
##
## The bound returned in `PartitionPlan.bound` is computed as:
##
## ```text
## bound_ns = sumOfRootCostsNs * (4/3 - 1/(3*N))
## ```
##
## For `sipShared`, this is exact for the bin-packing problem on root
## weights alone (the closure cost collapses to a constant shared
## across every shard). For `sipIndependent`, this is the LPT upper
## bound on the policy-aware weight function the partitioner actually
## packs; if root closures heavily overlap, the realised
## `max_k W(k)` may differ because shared dependencies are
## double-counted.
##
## Degradation Conditions
## ======================
##
## - A single root whose closure cost exceeds `total / N` cannot be
##   split; the bound is loose in that case.
## - For `sipIndependent` with heavily overlapping closures, callers
##   may prefer `sipShared` to avoid double-counting shared
##   dependencies in the per-shard cost.
## - The refinement pass is greedy; symmetric inputs can trap it in a
##   local minimum. Production callers should treat the returned
##   `bound` as authoritative and `perShardCost` as best-effort.
##
## Boundary
## ========
##
## This library knows nothing about reprobuild, codetracer, build
## graphs, or test binaries. Its only Nim dependencies are
## `runquota_core` (for shared types and the version helper),
## `std/times`, `std/sets`, `std/algorithm`, `std/hashes`, and
## `std/tables`. No imports from `repro_*` or `ct_*`.

import runquota_core
import runquota_partition/types
import runquota_partition/partition

export types
export partition
export runquota_core

const libraryName* = "runquota_partition"

proc libraryInfo*(): tuple[name: string, version: string] =
  (name: libraryName, version: versionString())

## Verify the (4/3 - 1/(3N)) LPT bound under sipIndependent across a
## variety of synthetic DAGs. Small cases are compared against a
## brute-force optimum; larger cases are compared against the bound
## the partitioner reports.

import std/[times, unittest]
import runquota_partition

proc dns(value: int64): Duration =
  initDuration(nanoseconds = value)

proc maxShardCostNs(plan: PartitionPlan): int64 =
  result = 0
  for d in plan.perShardCost:
    let n = d.inNanoseconds
    if n > result:
      result = n

proc shardCostNsIndependent(roots: seq[PartitionRoot];
                            nodes: seq[PartitionNode];
                            shardRoots: openArray[int]): int64 =
  ## Union-of-closures cost for a single shard.
  var visited: seq[uint64] = @[]
  proc seen(n: uint64): bool =
    for v in visited:
      if v == n: return true
    false
  result = 0
  for ri in shardRoots:
    result += roots[ri].weight.inNanoseconds
    let rid = uint64(roots[ri].id)
    var present = false
    for n in nodes:
      if uint64(n.id) == rid:
        present = true
        break
    if not present: continue
    if seen(rid): continue
    visited.add(rid)
    var stack: seq[uint64] = @[rid]
    while stack.len > 0:
      let cur = stack.pop()
      for n in nodes:
        if uint64(n.id) == cur:
          result += n.weight.inNanoseconds
          for dep in n.deps:
            let dn = uint64(dep)
            if not seen(dn):
              var depExists = false
              for nn in nodes:
                if uint64(nn.id) == dn:
                  depExists = true
                  break
              if depExists:
                visited.add(dn)
                stack.add(dn)
          break

proc intPow(base, exp: int): int =
  result = 1
  for _ in 0 ..< exp:
    result = result * base

proc bruteForceOptimum(roots: seq[PartitionRoot];
                       nodes: seq[PartitionNode];
                       shardCount: int): int64 =
  result = high(int64)
  let total = intPow(shardCount, roots.len)
  for assignment in 0 ..< total:
    var shardRootIdx = newSeq[seq[int]](shardCount)
    var a = assignment
    for r in 0 ..< roots.len:
      let s = a mod shardCount
      shardRootIdx[s].add(r)
      a = a div shardCount
    var maxNs: int64 = 0
    for s in 0 ..< shardCount:
      let ns = shardCostNsIndependent(roots, nodes, shardRootIdx[s])
      if ns > maxNs: maxNs = ns
    if maxNs < result:
      result = maxNs

proc buildLineCase(rootCount: int; shardCount: int;
                   weights: openArray[int64]):
                   tuple[req: PartitionRequest, roots: seq[PartitionRoot],
                         nodes: seq[PartitionNode]] =
  ## Each root has its own dedicated singleton dep (root_i depends on
  ## node_i). Closure cost == rootWeight + nodeWeight.
  var roots = newSeq[PartitionRoot](rootCount)
  var nodes = newSeq[PartitionNode](rootCount)
  for i in 0 ..< rootCount:
    let depId = nodeId(uint64(i + 1000))
    nodes[i] = PartitionNode(id: depId, weight: dns(weights[i] div 2),
                             deps: @[])
    roots[i] = PartitionRoot(id: depId, weight: dns(weights[i] - weights[i] div 2))
  let req = PartitionRequest(
    nodes: nodes,
    roots: roots,
    shardCount: shardCount,
    policy: sipIndependent,
    refinementPasses: DefaultRefinementPasses
  )
  (req, roots, nodes)

proc lptBoundFactor(shardCount: int): float =
  4.0 / 3.0 - 1.0 / (3.0 * float(shardCount))

suite "runquota_partition LPT bound (sipIndependent)":

  test "case 1: 4 roots / 2 shards / equal weights":
    let weights = @[100'i64, 100, 100, 100]
    let (req, roots, nodes) = buildLineCase(4, 2, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 2)
    check actualMax.float <= opt.float * lptBoundFactor(2) + 1.0
    check plan.bound.inNanoseconds >= actualMax

  test "case 2: 5 roots / 2 shards / skewed weights":
    let weights = @[500'i64, 300, 200, 100, 50]
    let (req, roots, nodes) = buildLineCase(5, 2, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 2)
    check actualMax.float <= opt.float * lptBoundFactor(2) + 1.0

  test "case 3: 6 roots / 3 shards / Fibonacci weights":
    let weights = @[13'i64, 8, 5, 3, 2, 1]
    let (req, roots, nodes) = buildLineCase(6, 3, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 3)
    check actualMax.float <= opt.float * lptBoundFactor(3) + 1.0

  test "case 4: 4 roots / 4 shards / single-shard-each":
    let weights = @[1000'i64, 999, 998, 997]
    let (req, roots, nodes) = buildLineCase(4, 4, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 4)
    check actualMax.float <= opt.float * lptBoundFactor(4) + 1.0

  test "case 5: 7 roots / 3 shards / one heavy outlier":
    let weights = @[1000'i64, 100, 100, 100, 100, 100, 100]
    let (req, roots, nodes) = buildLineCase(7, 3, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 3)
    check actualMax.float <= opt.float * lptBoundFactor(3) + 1.0

  test "case 6: 6 roots / 2 shards / two heavy + tail":
    let weights = @[400'i64, 400, 200, 200, 100, 100]
    let (req, roots, nodes) = buildLineCase(6, 2, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 2)
    check actualMax.float <= opt.float * lptBoundFactor(2) + 1.0

  test "case 7: 8 roots / 4 shards / uniform":
    let weights = @[50'i64, 50, 50, 50, 50, 50, 50, 50]
    let (req, roots, nodes) = buildLineCase(8, 4, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 4)
    check actualMax.float <= opt.float * lptBoundFactor(4) + 1.0

  test "case 8: 5 roots / 3 shards / mixed":
    let weights = @[300'i64, 250, 200, 150, 100]
    let (req, roots, nodes) = buildLineCase(5, 3, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    let opt = bruteForceOptimum(roots, nodes, 3)
    check actualMax.float <= opt.float * lptBoundFactor(3) + 1.0

  test "case 9: larger 12 roots / 4 shards (bound only)":
    var weights: seq[int64] = @[]
    for i in 0 ..< 12:
      weights.add(int64(100 + i * 37 mod 50))
    let (req, _, _) = buildLineCase(12, 4, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    check actualMax <= plan.bound.inNanoseconds

  test "case 10: larger 16 roots / 4 shards (bound only)":
    var weights: seq[int64] = @[]
    for i in 0 ..< 16:
      weights.add(int64(50 + (i * i) mod 90))
    let (req, _, _) = buildLineCase(16, 4, weights)
    let plan = computePartition(req)
    let actualMax = maxShardCostNs(plan)
    check actualMax <= plan.bound.inNanoseconds

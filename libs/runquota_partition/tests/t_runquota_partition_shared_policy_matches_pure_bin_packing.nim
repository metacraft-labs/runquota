## Under sipShared, the produced plan matches a canonical greedy
## bin-packing on root weights alone. Closure cost collapses to a
## constant added to every shard, so the partitioner's job is just
## LPT on the root weights.

import std/[algorithm, sets, tables, times, unittest]
import runquota_partition

proc dns(value: int64): Duration =
  initDuration(nanoseconds = value)

proc canonicalLptOnRoots(roots: seq[PartitionRoot];
                         shardCount: int): seq[int] =
  ## Returns 0-indexed shard for each root using vanilla LPT on root
  ## weights. Ties: lowest shard index. Stable on equal weights.
  var order = newSeq[int](roots.len)
  for i in 0 ..< roots.len: order[i] = i
  order.sort do (a, b: int) -> int:
    let aNs = roots[a].weight.inNanoseconds
    let bNs = roots[b].weight.inNanoseconds
    if aNs > bNs: -1
    elif aNs < bNs: 1
    elif a < b: -1
    elif a > b: 1
    else: 0
  var shardCostNs = newSeq[int64](shardCount)
  result = newSeq[int](roots.len)
  for r in order:
    var pick = 0
    for k in 1 ..< shardCount:
      if shardCostNs[k] < shardCostNs[pick]:
        pick = k
    result[r] = pick
    shardCostNs[pick] += roots[r].weight.inNanoseconds

proc planAssignmentMap(plan: PartitionPlan): Table[uint64, int] =
  ## Map root id -> 0-indexed shard.
  result = initTable[uint64, int]()
  for a in plan.assignments:
    result[uint64(a.root)] = a.shardIndex - 1

suite "runquota_partition sipShared matches greedy bin-packing":

  test "matches canonical LPT on root weights with shared deps":
    # 6 roots, shared dependency chain. Closure cost is dominated by
    # the shared deps; under sipShared, those should not influence the
    # assignment.
    let depA = nodeId(1000)
    let depB = nodeId(1001)
    let nodes = @[
      PartitionNode(id: depA, weight: dns(10_000), deps: @[depB]),
      PartitionNode(id: depB, weight: dns(20_000), deps: @[])
    ]
    var roots: seq[PartitionRoot] = @[]
    let rootWeights = @[400'i64, 300, 250, 200, 150, 100]
    for i, w in rootWeights:
      roots.add(PartitionRoot(id: nodeId(uint64(i)), weight: dns(w)))
    let req = PartitionRequest(
      nodes: nodes,
      roots: roots,
      shardCount: 3,
      policy: sipShared,
      refinementPasses: DefaultRefinementPasses
    )
    let plan = computePartition(req)
    let expected = canonicalLptOnRoots(roots, 3)
    let actual = planAssignmentMap(plan)
    for i in 0 ..< roots.len:
      check actual[uint64(roots[i].id)] == expected[i]

  test "per-shard cost equals sum of assigned root weights only":
    var roots: seq[PartitionRoot] = @[]
    let rootWeights = @[100'i64, 80, 60, 40, 20]
    for i, w in rootWeights:
      roots.add(PartitionRoot(id: nodeId(uint64(100 + i)), weight: dns(w)))
    # Some nodes the roots never reference, plus one node a root does
    # reference. Under sipShared none of these should appear in the
    # per-shard cost.
    let extraNode = nodeId(99)
    let nodes = @[
      PartitionNode(id: extraNode, weight: dns(9_999_999), deps: @[])
    ]
    let req = PartitionRequest(
      nodes: nodes,
      roots: roots,
      shardCount: 2,
      policy: sipShared,
      refinementPasses: DefaultRefinementPasses
    )
    let plan = computePartition(req)
    let assignmentMap = planAssignmentMap(plan)
    var expectedShardCostNs = newSeq[int64](2)
    for i in 0 ..< roots.len:
      let s = assignmentMap[uint64(roots[i].id)]
      expectedShardCostNs[s] += roots[i].weight.inNanoseconds
    for k in 0 ..< 2:
      check plan.perShardCost[k].inNanoseconds == expectedShardCostNs[k]

  test "explainedCost equals root weight under sipShared":
    var roots: seq[PartitionRoot] = @[]
    for i in 0 ..< 8:
      roots.add(PartitionRoot(id: nodeId(uint64(i)), weight: dns(int64((i + 1) * 50))))
    let req = PartitionRequest(
      nodes: @[],
      roots: roots,
      shardCount: 4,
      policy: sipShared,
      refinementPasses: DefaultRefinementPasses
    )
    let plan = computePartition(req)
    var rootWeightByIndex = initTable[uint64, int64]()
    for r in roots:
      rootWeightByIndex[uint64(r.id)] = r.weight.inNanoseconds
    for a in plan.assignments:
      check a.explainedCost.inNanoseconds == rootWeightByIndex[uint64(a.root)]

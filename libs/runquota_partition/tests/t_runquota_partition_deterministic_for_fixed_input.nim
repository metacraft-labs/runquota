## Two calls to computePartition with the same PartitionRequest must
## return identical PartitionPlan values. Required so CI matrix
## workers all see the same plan when they compute it locally without
## a planner job.

import std/[times, unittest]
import runquota_partition

proc dns(value: int64): Duration =
  initDuration(nanoseconds = value)

proc samePlan(a, b: PartitionPlan): bool =
  if a.shardCount != b.shardCount: return false
  if a.assignments.len != b.assignments.len: return false
  if a.perShardCost.len != b.perShardCost.len: return false
  if a.bound.inNanoseconds != b.bound.inNanoseconds: return false
  for i in 0 ..< a.assignments.len:
    let aa = a.assignments[i]
    let bb = b.assignments[i]
    if uint64(aa.root) != uint64(bb.root): return false
    if aa.shardIndex != bb.shardIndex: return false
    if aa.explainedCost.inNanoseconds != bb.explainedCost.inNanoseconds:
      return false
  for k in 0 ..< a.perShardCost.len:
    if a.perShardCost[k].inNanoseconds != b.perShardCost[k].inNanoseconds:
      return false
  true

proc buildRequest(policy: SharedInputPolicy; passes: int): PartitionRequest =
  let depA = nodeId(100)
  let depB = nodeId(101)
  let depC = nodeId(102)
  let nodes = @[
    PartitionNode(id: depA, weight: dns(40), deps: @[depB, depC]),
    PartitionNode(id: depB, weight: dns(30), deps: @[depC]),
    PartitionNode(id: depC, weight: dns(20), deps: @[])
  ]
  let roots = @[
    PartitionRoot(id: depA, weight: dns(50)),
    PartitionRoot(id: depB, weight: dns(70)),
    PartitionRoot(id: depC, weight: dns(60)),
    PartitionRoot(id: nodeId(200), weight: dns(45)),
    PartitionRoot(id: nodeId(201), weight: dns(80)),
    PartitionRoot(id: nodeId(202), weight: dns(35))
  ]
  PartitionRequest(
    nodes: nodes,
    roots: roots,
    shardCount: 3,
    policy: policy,
    refinementPasses: passes
  )

suite "runquota_partition determinism":

  test "sipIndependent: two calls produce identical plans":
    let req = buildRequest(sipIndependent, DefaultRefinementPasses)
    let plan1 = computePartition(req)
    let plan2 = computePartition(req)
    check samePlan(plan1, plan2)

  test "sipShared: two calls produce identical plans":
    let req = buildRequest(sipShared, DefaultRefinementPasses)
    let plan1 = computePartition(req)
    let plan2 = computePartition(req)
    check samePlan(plan1, plan2)

  test "sipIndependent zero refinement passes is deterministic":
    let req = buildRequest(sipIndependent, 0)
    let plan1 = computePartition(req)
    let plan2 = computePartition(req)
    check samePlan(plan1, plan2)

  test "five repeated calls all produce the same plan":
    let req = buildRequest(sipIndependent, DefaultRefinementPasses)
    let first = computePartition(req)
    for _ in 0 ..< 4:
      let again = computePartition(req)
      check samePlan(first, again)

  test "deterministic on a heavily-tied input":
    # All roots identical weight: tie-breaking by original index must
    # produce a stable plan.
    var roots: seq[PartitionRoot] = @[]
    for i in 0 ..< 12:
      roots.add(PartitionRoot(id: nodeId(uint64(i)), weight: dns(100)))
    let req = PartitionRequest(
      nodes: @[],
      roots: roots,
      shardCount: 4,
      policy: sipShared,
      refinementPasses: DefaultRefinementPasses
    )
    let plan1 = computePartition(req)
    let plan2 = computePartition(req)
    check samePlan(plan1, plan2)

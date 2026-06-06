## Greedy LPT + local-search refinement implementation of
## `computePartition`.

import std/[algorithm, sets, tables, times]
import ./types

proc closureCost(rootId: NodeId;
                 nodeIndex: Table[NodeId, int];
                 nodes: openArray[PartitionNode];
                 rootWeight: Duration): Duration =
  ## Sum of weights over the transitive closure reachable from `rootId`
  ## via `deps`. Returns just `rootWeight` if `rootId` is not present in
  ## the node table (a root with no dependency record).
  ##
  ## Deterministic: traversal order is fully driven by the dep arrays
  ## that the caller supplies.
  var visited = initHashSet[NodeId]()
  var stack: seq[NodeId] = @[]
  result = rootWeight

  if nodeIndex.hasKey(rootId):
    stack.add(rootId)
    visited.incl(rootId)
    # rootWeight is what the planner attributes to the root; if the root
    # also appears as a node we add the node's weight on top so callers
    # who model "root + dependency closure" cleanly can do so.
    while stack.len > 0:
      let current = stack.pop()
      let idx = nodeIndex[current]
      result = result + nodes[idx].weight
      for dep in nodes[idx].deps:
        if dep notin visited and nodeIndex.hasKey(dep):
          visited.incl(dep)
          stack.add(dep)

proc nanos(d: Duration): int64 =
  d.inNanoseconds

proc fromNanos(n: int64): Duration =
  initDuration(nanoseconds = n)

proc indexOfMin(values: openArray[int64]): int =
  ## Returns the index of the smallest value. Ties broken by smallest
  ## index for determinism.
  result = 0
  for i in 1 ..< values.len:
    if values[i] < values[result]:
      result = i

proc indexOfMax(values: openArray[int64]): int =
  ## Returns the index of the largest value. Ties broken by smallest
  ## index for determinism.
  result = 0
  for i in 1 ..< values.len:
    if values[i] > values[result]:
      result = i

proc computeLptBound(sumNs: int64; shardCount: int): Duration =
  ## Classic Graham (1969) LPT approximation bound:
  ##   bound = sum * (4/3 - 1/(3N))
  ## Computed from total nanoseconds to keep precision sane for short
  ## actions; the result is rounded toward zero.
  if shardCount <= 0 or sumNs <= 0:
    return fromNanos(0)
  let factor = 4.0 / 3.0 - 1.0 / (3.0 * float(shardCount))
  let boundNs = int64(float(sumNs) * factor)
  fromNanos(boundNs)

proc computePartition*(req: PartitionRequest): PartitionPlan =
  ## Partition the request's roots across `shardCount` shards using
  ## greedy LPT with a local-search refinement pass. See README.md and
  ## the top-of-module docstring for the algorithm, bound, and
  ## degradation conditions.
  ##
  ## The function is deterministic: given the same `PartitionRequest`
  ## (same field iteration order, same data), it returns the same
  ## `PartitionPlan`. Ties in shard selection break toward the lowest
  ## shard index.
  doAssert req.shardCount >= 1, "shardCount must be >= 1"

  let passes =
    if req.refinementPasses < 0: 0
    else: req.refinementPasses

  # Build a node lookup table for closure traversal.
  var nodeIndex = initTable[NodeId, int]()
  for i, node in req.nodes:
    nodeIndex[node.id] = i

  # Per-root cost under the policy. `rootCost[i]` is what shard
  # accumulators pay when root `i` is assigned to that shard.
  var rootCost = newSeq[Duration](req.roots.len)
  case req.policy
  of sipIndependent:
    for i, root in req.roots:
      rootCost[i] = closureCost(root.id, nodeIndex, req.nodes, root.weight)
  of sipShared:
    for i, root in req.roots:
      rootCost[i] = root.weight

  # Sort root indices by descending cost; ties break by original index
  # (stable order) for determinism.
  var order = newSeq[int](req.roots.len)
  for i in 0 ..< req.roots.len:
    order[i] = i
  order.sort do (a, b: int) -> int:
    let aNs = nanos(rootCost[a])
    let bNs = nanos(rootCost[b])
    if aNs > bNs: -1
    elif aNs < bNs: 1
    elif a < b: -1
    elif a > b: 1
    else: 0

  # `shardCostNs[k]` is the accumulated nanoseconds on shard k (0-indexed).
  # For `sipIndependent` it is the recomputed union-of-closures cost.
  # For `sipShared` it is the simple sum of root weights.
  var shardCostNs = newSeq[int64](req.shardCount)
  var rootShard = newSeq[int](req.roots.len)
    ## 0-indexed shard for each root.
  for i in 0 ..< req.roots.len:
    rootShard[i] = -1

  proc shardClosureNs(shardIdx: int): int64 =
    ## Recompute a shard's closure cost from scratch under sipIndependent.
    ## Used after a swap.
    var visited = initHashSet[NodeId]()
    var totalNs: int64 = 0
    for ri, sk in rootShard:
      if sk != shardIdx:
        continue
      totalNs += nanos(req.roots[ri].weight)
      let rid = req.roots[ri].id
      if not nodeIndex.hasKey(rid):
        continue
      var stack: seq[NodeId] = @[rid]
      if rid notin visited:
        visited.incl(rid)
      else:
        # Already counted via another root in this shard.
        continue
      while stack.len > 0:
        let current = stack.pop()
        let idx = nodeIndex[current]
        totalNs += nanos(req.nodes[idx].weight)
        for dep in req.nodes[idx].deps:
          if dep notin visited and nodeIndex.hasKey(dep):
            visited.incl(dep)
            stack.add(dep)
    totalNs

  # LPT assignment pass.
  case req.policy
  of sipShared:
    for rootIdx in order:
      let target = indexOfMin(shardCostNs)
      rootShard[rootIdx] = target
      shardCostNs[target] += nanos(rootCost[rootIdx])
  of sipIndependent:
    # Track per-shard visited sets so additional roots only pay for
    # nodes not already covered by an earlier root on the same shard.
    var shardVisited = newSeq[HashSet[NodeId]](req.shardCount)
    for k in 0 ..< req.shardCount:
      shardVisited[k] = initHashSet[NodeId]()
    for rootIdx in order:
      let target = indexOfMin(shardCostNs)
      rootShard[rootIdx] = target
      # Incrementally add the new portion of the closure to the shard.
      let rid = req.roots[rootIdx].id
      var addedNs: int64 = nanos(req.roots[rootIdx].weight)
      if nodeIndex.hasKey(rid) and rid notin shardVisited[target]:
        shardVisited[target].incl(rid)
        var stack: seq[NodeId] = @[rid]
        while stack.len > 0:
          let current = stack.pop()
          let idx = nodeIndex[current]
          addedNs += nanos(req.nodes[idx].weight)
          for dep in req.nodes[idx].deps:
            if dep notin shardVisited[target] and nodeIndex.hasKey(dep):
              shardVisited[target].incl(dep)
              stack.add(dep)
      shardCostNs[target] += addedNs

  # Local-search refinement: swap a root between the heaviest and
  # lightest shards whenever the swap strictly reduces max W(k).
  if req.shardCount >= 2 and passes > 0:
    for pass in 0 ..< passes:
      var improved = false
      let heavy = indexOfMax(shardCostNs)
      let light = indexOfMin(shardCostNs)
      if heavy == light:
        break
      let currentMaxNs = shardCostNs[heavy]

      # Collect roots on each side, ordered by original index for a
      # deterministic search.
      var heavyRoots: seq[int] = @[]
      var lightRoots: seq[int] = @[]
      for ri in 0 ..< req.roots.len:
        if rootShard[ri] == heavy: heavyRoots.add(ri)
        elif rootShard[ri] == light: lightRoots.add(ri)

      block searchPair:
        case req.policy
        of sipShared:
          # Cost change is local: swapping rH<->rL changes heavy by
          # (-rH + rL) and light by (-rL + rH).
          for rH in heavyRoots:
            for rL in lightRoots:
              let newHeavyNs = shardCostNs[heavy] - nanos(rootCost[rH]) +
                  nanos(rootCost[rL])
              let newLightNs = shardCostNs[light] - nanos(rootCost[rL]) +
                  nanos(rootCost[rH])
              let newMaxNs = max(newHeavyNs, newLightNs)
              # Also consider the maximum across all shards.
              var globalMaxNs = newMaxNs
              for k in 0 ..< req.shardCount:
                if k == heavy or k == light: continue
                if shardCostNs[k] > globalMaxNs:
                  globalMaxNs = shardCostNs[k]
              if globalMaxNs < currentMaxNs:
                rootShard[rH] = light
                rootShard[rL] = heavy
                shardCostNs[heavy] = newHeavyNs
                shardCostNs[light] = newLightNs
                improved = true
                break searchPair
          # Also try one-way moves (move a heavy root to light without a swap back).
          for rH in heavyRoots:
            let newHeavyNs = shardCostNs[heavy] - nanos(rootCost[rH])
            let newLightNs = shardCostNs[light] + nanos(rootCost[rH])
            let newMaxNs = max(newHeavyNs, newLightNs)
            var globalMaxNs = newMaxNs
            for k in 0 ..< req.shardCount:
              if k == heavy or k == light: continue
              if shardCostNs[k] > globalMaxNs:
                globalMaxNs = shardCostNs[k]
            if globalMaxNs < currentMaxNs:
              rootShard[rH] = light
              shardCostNs[heavy] = newHeavyNs
              shardCostNs[light] = newLightNs
              improved = true
              break searchPair
        of sipIndependent:
          # Under sipIndependent we recompute closure cost after each
          # candidate swap. More expensive but correct on overlapping
          # closures.
          for rH in heavyRoots:
            for rL in lightRoots:
              rootShard[rH] = light
              rootShard[rL] = heavy
              let newHeavyNs = shardClosureNs(heavy)
              let newLightNs = shardClosureNs(light)
              var globalMaxNs = max(newHeavyNs, newLightNs)
              for k in 0 ..< req.shardCount:
                if k == heavy or k == light: continue
                if shardCostNs[k] > globalMaxNs:
                  globalMaxNs = shardCostNs[k]
              if globalMaxNs < currentMaxNs:
                shardCostNs[heavy] = newHeavyNs
                shardCostNs[light] = newLightNs
                improved = true
                break searchPair
              else:
                # Revert
                rootShard[rH] = heavy
                rootShard[rL] = light
          for rH in heavyRoots:
            rootShard[rH] = light
            let newHeavyNs = shardClosureNs(heavy)
            let newLightNs = shardClosureNs(light)
            var globalMaxNs = max(newHeavyNs, newLightNs)
            for k in 0 ..< req.shardCount:
              if k == heavy or k == light: continue
              if shardCostNs[k] > globalMaxNs:
                globalMaxNs = shardCostNs[k]
            if globalMaxNs < currentMaxNs:
              shardCostNs[heavy] = newHeavyNs
              shardCostNs[light] = newLightNs
              improved = true
              break searchPair
            else:
              rootShard[rH] = heavy

      if not improved:
        break

  # Build the plan. Assignments are emitted in original root order for
  # determinism.
  var plan = PartitionPlan(
    shardCount: req.shardCount,
    assignments: newSeq[PartitionAssignment](req.roots.len),
    perShardCost: newSeq[Duration](req.shardCount),
    bound: fromNanos(0)
  )

  # explainedCost for each root: the cost attributed to that root under
  # the policy (root's contribution alone — closure cost for
  # sipIndependent, root weight for sipShared).
  for ri in 0 ..< req.roots.len:
    plan.assignments[ri] = PartitionAssignment(
      root: req.roots[ri].id,
      shardIndex: rootShard[ri] + 1,
      explainedCost: rootCost[ri]
    )

  for k in 0 ..< req.shardCount:
    plan.perShardCost[k] = fromNanos(shardCostNs[k])

  # Bound: classic LPT bound over the sum of root-attributed costs.
  var sumNs: int64 = 0
  for c in rootCost:
    sumNs += nanos(c)
  plan.bound = computeLptBound(sumNs, req.shardCount)

  plan

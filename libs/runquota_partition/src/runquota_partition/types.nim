## Public types for the runquota_partition library.
##
## See the top-level `runquota_partition` module docstring for the
## algorithm and quality bound details.

import std/[hashes, times]

type
  NodeId* = distinct uint64
    ## Opaque identity for a node or root.

  PartitionNode* = object
    id*: NodeId            ## Identity of this node.
    weight*: Duration      ## Estimated cost contribution of this node.
    deps*: seq[NodeId]     ## Other nodes this one depends on (DAG only).

  PartitionRoot* = object
    id*: NodeId            ## Root node identity.
    weight*: Duration      ## Weight attributed to the root itself.

  SharedInputPolicy* = enum
    sipIndependent         ## Every shard pays cost for every node it touches.
    sipShared              ## Nodes are paid for once across the whole partition.

  PartitionRequest* = object
    nodes*: seq[PartitionNode]
    roots*: seq[PartitionRoot]
    shardCount*: int
    policy*: SharedInputPolicy
    refinementPasses*: int  ## Max local-search passes. 0 disables refinement.

  PartitionAssignment* = object
    root*: NodeId
    shardIndex*: int        ## 1-indexed shard number.
    explainedCost*: Duration

  PartitionPlan* = object
    shardCount*: int
    assignments*: seq[PartitionAssignment]
    perShardCost*: seq[Duration]
    bound*: Duration        ## Partitioner's upper bound on max W(k).

const DefaultRefinementPasses* = 32
  ## Default number of local-search refinement passes.

proc nodeId*(value: uint64): NodeId =
  NodeId(value)

proc value*(id: NodeId): uint64 =
  uint64(id)

proc `==`*(a, b: NodeId): bool {.borrow.}

proc hash*(id: NodeId): Hash =
  hash(uint64(id))

proc `$`*(id: NodeId): string =
  $uint64(id)

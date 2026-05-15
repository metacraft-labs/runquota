type
  SessionId* = distinct uint64
  LeaseId* = distinct uint64
  MilliCpu* = distinct int
  Bytes* = distinct int64
  ResourceVector* = object
    cpu*: MilliCpu
    memory*: Bytes

proc resourceVector*(cpu: MilliCpu; memory: Bytes): ResourceVector =
  ResourceVector(cpu: cpu, memory: memory)

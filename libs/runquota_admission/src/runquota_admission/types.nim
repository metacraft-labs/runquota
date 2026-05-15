type
  LibraryInfo* = object
    name*: string
  AdmissionDecision* = enum
    adGrant
    adQueue
    adDeny

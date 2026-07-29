# ref in a comment is not a finding.
const decoy = "ref in a string is not a finding"
type
  ForbiddenReference = ref object
    value: int

#[ A nested comment containing ref:
  #[ ref object ]#
]#
type SecondForbiddenReference = ref object

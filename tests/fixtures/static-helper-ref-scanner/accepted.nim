# A line comment may explain why a r_e_f type is forbidden.
## Documentation comments may also mention rEf object.
#[ An outer block comment may contain ref.
  #[ Nested block comments may contain r_e_f object too. ]#
]#
##[ A documentation block may contain ref, r_e_f, and rEf object.
  ##[ Nested documentation blocks may contain ref too. ]##
]##

const
  normalString = "ref # this hash is part of the string"
  escapedString = "escaped \"ref\" token"
  rawString = r"raw ""ref"" token"
  tripleString = """triple ref
#[ this block-comment marker is string data ]#
"""
  character = '#'

let refinement = normalString
let preferred = rawString
let myref = escapedString
let `ref` = tripleString

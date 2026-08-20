## A self-contained SHA-256 (FIPS 180-4), used to hash a hardware profile
## into ``host_profiles.profile_hash``.
##
## Why it lives here rather than being imported: ``std/sha1`` is deprecated
## in Nim 2.2 and is the wrong width to label ``sha256:``; adding a package
## dependency to the one library that has to keep working when everything
## else is broken (OS-4) is a worse trade than 60 lines of well-specified
## arithmetic.
##
## Correctness here is not asserted, it is tested:
## ``tests/unit/t_observation_store_host_profile.nim`` runs the published
## FIPS 180-4 vectors, including the multi-block one, through this code. A
## hash function that is only ever compared against itself would agree with
## itself while being wrong.

import std/strutils

const roundConstants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(x: uint32; n: uint32): uint32 {.inline.} =
  (x shr n) or (x shl (32'u32 - n))

proc sha256Hex*(data: string): string =
  ## Lowercase hex digest of ``data``.
  var state: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

  var message = data
  let bitLength = uint64(data.len) * 8'u64
  message.add('\x80')
  while message.len mod 64 != 56:
    message.add('\0')
  for shiftIndex in countdown(7, 0):
    message.add(char((bitLength shr (uint64(shiftIndex) * 8'u64)) and 0xff'u64))

  var schedule: array[64, uint32]
  var offset = 0
  while offset < message.len:
    for i in 0 ..< 16:
      let base = offset + i * 4
      schedule[i] =
        (uint32(byte(message[base])) shl 24) or
        (uint32(byte(message[base + 1])) shl 16) or
        (uint32(byte(message[base + 2])) shl 8) or
        uint32(byte(message[base + 3]))
    for i in 16 ..< 64:
      let s0 = rotr(schedule[i - 15], 7) xor rotr(schedule[i - 15], 18) xor
        (schedule[i - 15] shr 3'u32)
      let s1 = rotr(schedule[i - 2], 17) xor rotr(schedule[i - 2], 19) xor
        (schedule[i - 2] shr 10'u32)
      schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1

    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]

    for i in 0 ..< 64:
      let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let choose = (e and f) xor ((not e) and g)
      let temp1 = h + s1 + choose + roundConstants[i] + schedule[i]
      let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let majority = (a and b) xor (a and c) xor (b and c)
      let temp2 = s0 + majority
      h = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2

    state[0] += a
    state[1] += b
    state[2] += c
    state[3] += d
    state[4] += e
    state[5] += f
    state[6] += g
    state[7] += h
    offset += 64

  result = newStringOfCap(64)
  for word in state:
    result.add(toHex(word, 8).toLowerAscii)

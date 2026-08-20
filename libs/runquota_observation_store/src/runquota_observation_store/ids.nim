## Clock and identifier primitives shared by the store, the host identity
## file and the background writer.
##
## These used to live in ``store.nim``. They moved so that
## ``identity.nim`` can mint a ``host_id`` without importing the store,
## which would be circular: the store needs the identity to write a row,
## not the other way round.

import std/[os, strutils, sysrand, times]

const opaqueIdBytes* = 16
  ## 128 bits of randomness per identifier. Wide enough that two machines
  ## in a merged database never collide by accident, which is the only
  ## property a ``host_id`` has to have.

proc unixMillisNow*(): int64 =
  int64(epochTime() * 1000.0)

proc opaqueId*(prefix: string): string =
  ## An identifier with no meaning outside this store.
  ##
  ## ``host_id`` in particular MUST NOT be derived from the hostname:
  ## hostnames are renamed and reused, which silently merges the histories
  ## of unrelated machines. Nothing about the machine is an input here —
  ## not its name, not its address, not its hardware — so the merge cannot
  ## happen by construction.
  var raw = newSeq[byte](opaqueIdBytes)
  if not urandom(raw):
    # `urandom` failing is a broken host, not a normal condition. Falling
    # back to time and pid keeps the daemon running; it does not pretend
    # to the same collision resistance, which is why it is last.
    let fallback = unixMillisNow() * 1_000_003 + int64(getCurrentProcessId())
    for i in 0 ..< raw.len:
      raw[i] = byte((fallback shr (i mod 8 * 8)) and 0xff)
  result = prefix
  for value in raw:
    result.add(toHex(int(value), 2).toLowerAscii)

proc isOpaqueId*(value, prefix: string): bool =
  ## Whether ``value`` has the exact shape ``opaqueId(prefix)`` produces:
  ## the prefix followed by ``2 * opaqueIdBytes`` lowercase hex digits and
  ## nothing else. Used to reject an identity file somebody hand-edited,
  ## and by the tests that assert a ``host_id`` carries no host detail —
  ## a fixed-width hex string cannot smuggle a hostname through.
  if not value.startsWith(prefix):
    return false
  let body = value[prefix.len .. ^1]
  if body.len != opaqueIdBytes * 2:
    return false
  for c in body:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

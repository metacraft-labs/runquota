## The identity of a ``runquotad`` image: which build of the daemon a file is.
##
## A version string does not say that. Two installs can carry the same
## ``runquota --version`` and differ by many commits, so a client that wants
## to know whether the daemon serving its endpoint is the one it would have
## started compares CONTENT, not names. The daemon digests its own image when
## it starts, before an installer can rename the file aside, and a client
## digests the ``runquotad`` it would launch; ``RetireDaemon`` carries the
## client's digest and the daemon compares it with its own
## (reprobuild-specs/RunQuota-Host-Configuration.md, "A daemon from another
## build makes way").
##
## Both sides call this one proc, so they cannot compute the identity two
## different ways.

import runquota_core/sha256

const ImageDigestPrefix* = "sha256:"
  ## Names the algorithm in the value, so a later change of hash is a
  ## visible mismatch rather than two hex strings that happen to differ.

proc imageDigestOf*(path: string): string =
  ## ``sha256:<hex>`` of the file at ``path``, or ``""`` when it cannot be
  ## read. An empty answer proves nothing about the file and callers treat it
  ## that way: a daemon that cannot digest itself reports ``""``, and a
  ## client that cannot digest its candidate does not ask anything of the
  ## daemon on the strength of it.
  if path.len == 0:
    return ""
  let content =
    try:
      readFile(path)
    except IOError, OSError:
      return ""
  ImageDigestPrefix & sha256Hex(content)

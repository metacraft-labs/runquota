## SHA-256, re-exported from ``runquota_core/sha256``.
##
## The implementation moved to ``runquota_core`` so the client -- a static
## helper that cannot import this library -- can derive the same Windows
## owner id the daemon records (see ``runquota_core/owner_id``). This module
## stays so the store's own importers, and every test that reaches for
## ``sha256Hex`` through ``runquota_observation_store``, did not move.

import runquota_core/sha256 as coreSha256

export coreSha256

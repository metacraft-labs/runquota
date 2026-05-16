#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."
nim c -r \
  --threads:on \
  --nimcache:"build/nimcache/t_e2e_runquota_multi_client_fairness" \
  --out:"build/test-bin/t_e2e_runquota_multi_client_fairness" \
  tests/e2e/multi-session-fairness/t_e2e_runquota_multi_client_fairness.nim

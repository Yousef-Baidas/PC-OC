#!/usr/bin/env bash
set -euo pipefail
# stability.sh cpu [minutes] | scan <since>: y-cruncher, stress-ng, then a kernel journal scan; PASS or FAIL.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

die bench "not implemented"

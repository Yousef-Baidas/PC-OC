#!/usr/bin/env bash
set -euo pipefail
# sudo os/install.sh: copy the reviewed root scripts to ${DESTDIR:-}/usr/local/lib/pc-oc/
# and install etc/sudoers.d/pc-oc (docs/adr/0001). Stub: contract #26.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"

die os "install.sh not implemented"

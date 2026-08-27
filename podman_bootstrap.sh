#!/usr/bin/env bash

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
printf '%s\n' 'podman_bootstrap.sh is retained for compatibility; use ./setup.sh' >&2
exec "$repository/setup.sh" "$@"

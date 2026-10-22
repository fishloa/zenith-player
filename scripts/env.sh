# Sourced by the maintainer scripts: loads .env from the repo root if present.
_zenith_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_zenith_root/.env" ]; then set -a; . "$_zenith_root/.env"; set +a; fi
unset _zenith_root

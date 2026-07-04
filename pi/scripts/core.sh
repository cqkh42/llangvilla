SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

source $SCRIPT_DIR/.env

error() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "⚠️  $*" >&2
}

info() {
    echo "$*"
}

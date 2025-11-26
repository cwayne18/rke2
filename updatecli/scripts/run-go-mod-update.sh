#!/bin/bash
set -eu

info() {
    echo '[INFO] ' "$@"
}

fatal() {
    echo '[ERROR] ' "$@" >&2
    exit 1
}

if [ -z "${1:-}" ]; then
    fatal "Usage: $0 <package@version>"
fi

PACKAGE_VERSION="${1}"

info "Updating ${PACKAGE_VERSION}"
go get "${PACKAGE_VERSION}"
go mod tidy

info "Done updating ${PACKAGE_VERSION}"

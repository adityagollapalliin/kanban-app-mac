#!/bin/bash
#
# The product promise is that nothing leaves this Mac. Two things enforce it:
# the sandbox, which withholds the network entitlements, and this check, which
# fails the build if the code grows a way to ask.
#
# Subprocess spawning is banned alongside the network APIs. Without that,
# `localboard` could shell out to curl and route around the whole thing, which
# is why Sources/localboard/main.swift opens the app through NSWorkspace.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0

report() {
    status=1
    echo "verify-no-network: $1" >&2
    echo "$2" | sed 's/^/    /' >&2
    echo >&2
}

# Symbol, and what it would let through.
# Comment lines are skipped: this file and the sources discuss the very symbols
# being banned, and prose describing a rule must not trip it.
check() {
    local pattern="$1" label="$2" hits
    hits="$(grep -rnE "$pattern" Sources App --include='*.swift' 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' || true)"
    if [[ -n "$hits" ]]; then
        report "$label" "$hits"
    fi
}

check '\bURLSession\b'                    'URLSession — HTTP client'
check '\bNSURLConnection\b'               'NSURLConnection — HTTP client'
check '^[[:space:]]*import[[:space:]]+Network\b' 'import Network — raw sockets'
check '\bNWConnection\b|\bNWListener\b'   'Network.framework connection'
check '\bCFSocket|\bsocket\(|\bgetaddrinfo\b' 'BSD sockets'
check '\bProcess\(|\bNSTask\b'            'subprocess — could exec curl'

# The sandbox is the other half. These entitlements must never appear.
ENTITLEMENTS="App/LocalBoard.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
    # Parsed, not grepped: the file explains in a comment which keys must stay
    # absent, and only a real <key> counts.
    for key in com.apple.security.network.client com.apple.security.network.server; do
        if plutil -extract "$key" raw "$ENTITLEMENTS" > /dev/null 2>&1; then
            report "network entitlement present in $ENTITLEMENTS" "$key"
        fi
    done
else
    report "missing $ENTITLEMENTS" "the sandbox half of the guarantee is not in the build"
fi

if [[ $status -eq 0 ]]; then
    echo "verify-no-network: clean — no network or subprocess APIs, no network entitlements"
fi

exit $status

#!/usr/bin/env bash
#
# Test suite for assert-ios-signing. Builds fixtures, then asserts the exit code
# and the presence of expected text for each case.
#
# Usage: run-tests.sh [fixture_dir]
#   Exit 0 if every case passes.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="$HERE/../bin/assert-ios-signing"
FIX="${1:-$(mktemp -d)/fixtures}"

if [[ ! -d "$FIX" ]]; then
    "$HERE/make-fixtures.sh" "$FIX" >/dev/null
fi

PASSED=0; FAILED=0
export NO_COLOR=1

# check <name> <expected_exit> <expect_text|-> -- <args...>
check() {
    local name="$1" want_exit="$2" want_text="$3"; shift 4
    local out rc
    out="$("$A" "$@" 2>&1)"; rc=$?
    local ok=true
    [[ "$rc" == "$want_exit" ]] || ok=false
    if [[ "$want_text" != "-" ]] && ! printf '%s' "$out" | grep -qF "$want_text"; then ok=false; fi
    if [[ "$ok" == true ]]; then
        PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s\n        expected exit %s + %s, got exit %s\n' "$name" "$want_exit" "$want_text" "$rc"
        printf '%s\n' "$out" | sed 's/^/        | /'
    fi
}

printf '\n== input formats ==\n'
export IOS_CERT_PASSWORD=hunter2
check "raw p12"                 0 "PASS:" -- --profile "$FIX/dev.mobileprovision"     --cert "$FIX/primary.p12"
check "base64 p12"              0 "PASS:" -- --profile "$FIX/dev.mobileprovision"     --cert "$FIX/primary.p12.b64"
check "base64 profile"          0 "PASS:" -- --profile "$FIX/dev.mobileprovision.b64" --cert "$FIX/primary.p12"
check "both base64"             0 "PASS:" -- --profile "$FIX/dev.mobileprovision.b64" --cert "$FIX/primary.p12.b64"
check "encrypted PEM"           0 "PASS:" -- --profile "$FIX/dev.mobileprovision"     --cert "$FIX/primary-enc.pem"
check "bare xml plist"          0 "PASS:" -- --profile "$FIX/bare.plist"              --cert "$FIX/primary.p12"
check "binary plist"            0 "PASS:" -- --profile "$FIX/bare-binary.plist"       --cert "$FIX/primary.p12"
check "legacy positional"       0 "PASS:" -- "$FIX/dev.mobileprovision" "Apple Development: Test User (E394HWR6G8)" "$FIX/primary.p12" hunter2
unset IOS_CERT_PASSWORD
check "unencrypted PEM"         0 "PASS:" -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.pem"
check "base64 PEM"              0 "PASS:" -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.pem.b64"
check "p12 with no password"    0 "PASS:" -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary-nopass.p12"
export IOS_CERT_PASSWORD=hunter2

printf '\n== credentials passed as environment content (how a CI secret arrives) ==\n'
# check() cannot carry per-case environment, so these run inline.
env_check() {  # env_check <name> <expected_exit> <expect_text> -- <args...>
    local name="$1" want_exit="$2" want_text="$3"; shift 4
    local out rc
    out="$(IOS_PROFILE_BASE64="$EP" IOS_CERT_BASE64="$EC" IOS_CERT_PASSWORD=hunter2 "$A" "$@" 2>&1)"; rc=$?
    if [[ "$rc" == "$want_exit" ]] && printf '%s' "$out" | grep -qF "$want_text"; then
        PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  FAIL  %s (exit %s)\n' "$name" "$rc"; printf '%s\n' "$out" | sed 's/^/        | /'
    fi
}
EP="$(cat "$FIX/dev.mobileprovision.b64")"; EC="$(cat "$FIX/primary.p12.b64")"
env_check "both from environment"   0 "PASS:"              -- --bundle-id com.example.myapp
env_check "env + assertions"        0 "PASS:"              -- --bundle-id com.example.myapp --profile-type development --team-id E394HWR6G8
env_check "env, bundle mismatch"    1 "bundle ID mismatch"  -- --bundle-id com.example.nope
EP="$(cat "$FIX/stale.mobileprovision.b64")"
env_check "env, stale profile"      1 "same team, different certificate" --
EP="$(cat "$FIX/dev.mobileprovision.b64")"

# The environment must not be the only way in: flags still win.
out="$(IOS_PROFILE_BASE64="garbage" NO_COLOR=1 "$A" --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.pem" 2>&1)"
if printf '%s' "$out" | grep -qF "PASS:"; then
    PASSED=$((PASSED + 1)); printf '  ok    --profile overrides the environment\n'
else
    FAILED=$((FAILED + 1)); printf '  FAIL  --profile did not override the environment\n'
fi

printf '\n== bundle identifier ==\n'
check "exact match"             0 "matches exactly"   -- --profile "$FIX/dev.mobileprovision"      --cert "$FIX/primary.p12" --bundle-id com.example.myapp
check "mismatch"                1 "bundle ID mismatch" -- --profile "$FIX/dev.mobileprovision"     --cert "$FIX/primary.p12" --bundle-id com.example.other
check "wildcard match"          0 "wildcard"          -- --profile "$FIX/wildcard.mobileprovision" --cert "$FIX/primary.p12" --bundle-id com.example.myapp
check "wildcard deeper match"   0 "wildcard"          -- --profile "$FIX/wildcard.mobileprovision" --cert "$FIX/primary.p12" --bundle-id com.example.myapp.watch
check "wildcard non-match"      1 "only covers"       -- --profile "$FIX/wildcard.mobileprovision" --cert "$FIX/primary.p12" --bundle-id com.other.app
check "team wildcard"           0 "fully wildcard"    -- --profile "$FIX/wildall.mobileprovision"  --cert "$FIX/primary.p12" --bundle-id com.anything.at.all

printf '\n== profile type ==\n'
check "development"             0 "a development profile"  -- --profile "$FIX/dev.mobileprovision"        --cert "$FIX/primary.p12" --profile-type development
check "adhoc"                   0 "a adhoc profile"        -- --profile "$FIX/adhoc.mobileprovision"      --cert "$FIX/primary.p12" --profile-type adhoc
check "appstore"                0 "a appstore profile"     -- --profile "$FIX/store.mobileprovision"      --cert "$FIX/primary.p12" --profile-type appstore
check "enterprise"              0 "a enterprise profile"   -- --profile "$FIX/enterprise.mobileprovision" --cert "$FIX/primary.p12" --profile-type enterprise
check "type alias app-store"    0 "a appstore profile"     -- --profile "$FIX/store.mobileprovision"      --cert "$FIX/primary.p12" --profile-type "App Store"
check "type mismatch"           1 "profile type mismatch"  -- --profile "$FIX/store.mobileprovision"      --cert "$FIX/primary.p12" --profile-type development
check "bad type value"          2 "unknown --profile-type" -- --profile "$FIX/store.mobileprovision"      --cert "$FIX/primary.p12" --profile-type nonsense

printf '\n== expiry ==\n'
check "expired profile"         1 "profile expired"        -- --profile "$FIX/expired.mobileprovision" --cert "$FIX/primary.p12"
check "expiring soon warns"     0 "under 30 days"          -- --profile "$FIX/soon.mobileprovision"    --cert "$FIX/primary.p12"
check "expired certificate"     1 "certificate itself expired" -- --profile "$FIX/certexpired.mobileprovision" --cert "$FIX/expired.p12"
check "cert expiring soon ok"   0 "PASS:"                  -- --profile "$FIX/dev-multi.mobileprovision" --cert "$FIX/renewed.p12"

printf '\n== certificate authorisation ==\n'
check "stale profile"           1 "same team, different certificate" -- --profile "$FIX/stale.mobileprovision"   --cert "$FIX/primary.p12"
check "foreign team"            1 "different Apple Developer accounts" -- --profile "$FIX/foreign.mobileprovision" --cert "$FIX/primary.p12"
check "profile with no certs"   1 "embeds no developer certificates" -- --profile "$FIX/nocerts.mobileprovision" --cert "$FIX/primary.p12"
check "multi-cert profile"      0 "PASS:"                  -- --profile "$FIX/dev-multi.mobileprovision" --cert "$FIX/primary.p12"
check "multi-cert, second one"  0 "PASS:"                  -- --profile "$FIX/dev-multi.mobileprovision" --cert "$FIX/renewed.p12"
check "cert name assertion ok"  0 "PASS:"                  -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.p12" --cert-name "Apple Development: Test User (E394HWR6G8)"
check "cert name mismatch"      1 "certificate name mismatch" -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.p12" --cert-name "Apple Development: Nobody (X)"

printf '\n== team ==\n'
check "team match"              0 "team matches"    -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.p12" --team-id E394HWR6G8
check "team mismatch"           1 "team mismatch"   -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.p12" --team-id NOPE12345

printf '\n== private key ==\n'
check "cert with no key"        1 "no private key"  -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary-cert.pem"
check "wrong password"          2 "password protected" -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.p12" --cert-password wrong-password

printf '\n== bad input ==\n'
check "missing profile"         2 "not found"       -- --profile "$FIX/nope.mobileprovision" --cert "$FIX/primary.p12"
check "missing cert"            2 "not found"       -- --profile "$FIX/dev.mobileprovision"  --cert "$FIX/nope.p12"
check "junk cert"               2 "unrecognised"    -- --profile "$FIX/dev.mobileprovision"  --cert "$FIX/junk.txt"
check "junk profile"            2 "is not a provisioning profile" -- --profile "$FIX/junk.txt" --cert "$FIX/primary.p12"
check "no cert at all"          2 "no certificate given" -- --profile "$FIX/dev.mobileprovision"
check "unknown option"          2 "unknown option"  -- --profile "$FIX/dev.mobileprovision" --cert "$FIX/primary.p12" --wat

printf '\n== multiple failures reported together ==\n'
out="$("$A" --profile "$FIX/expired.mobileprovision" --cert "$FIX/primary.p12" --bundle-id com.example.other --profile-type development 2>&1)"
if printf '%s' "$out" | grep -qF "3 check(s) failed"; then
    PASSED=$((PASSED + 1)); printf '  ok    reports all three failures in one run\n'
else
    FAILED=$((FAILED + 1)); printf '  FAIL  did not report three failures\n%s\n' "$out"
fi

printf '\n== summary ==\n  %d passed, %d failed\n\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))

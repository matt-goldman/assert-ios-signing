#!/usr/bin/env bash
#
# Builds a set of signing fixtures to test against: certificates, keys, and
# provisioning profiles covering each profile type and each way they can be
# mismatched. Everything here is throwaway; the keys are generated on the spot.
#
# Usage: make-fixtures.sh <output_dir>

set -euo pipefail

OUT="${1:?usage: make-fixtures.sh <output_dir>}"
OPENSSL="${OPENSSL:-openssl}"
PYTHON="${PYTHON:-python3}"

TEAM="E394HWR6G8"
OTHER_TEAM="K6L7U8688D"
BUNDLE="com.example.myapp"

rm -rf "$OUT"; mkdir -p "$OUT"
cd "$OUT"

# --- identities -------------------------------------------------------------
# $1 out-prefix  $2 common name  $3 team (OU)  $4 days valid
make_identity() {
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$4" \
        -keyout "$1-key.pem" -out "$1-cert.pem" \
        -subj "/CN=$2/OU=$3/O=Example Pty Ltd/C=AU" 2>/dev/null
    cat "$1-cert.pem" "$1-key.pem" > "$1.pem"
    "$OPENSSL" pkcs12 -export -inkey "$1-key.pem" -in "$1-cert.pem" \
        -out "$1.p12" -passout pass:hunter2 2>/dev/null
    "$OPENSSL" pkcs12 -export -inkey "$1-key.pem" -in "$1-cert.pem" \
        -out "$1-nopass.p12" -passout pass: 2>/dev/null
    base64 < "$1.p12"  | tr -d '\n' > "$1.p12.b64"
    base64 < "$1.pem"  | tr -d '\n' > "$1.pem.b64"
    # encrypted-PEM variant
    "$OPENSSL" rsa -in "$1-key.pem" -aes256 -passout pass:hunter2 -out "$1-enckey.pem" 2>/dev/null
    cat "$1-cert.pem" "$1-enckey.pem" > "$1-enc.pem"
}

make_identity primary  "Apple Development: Test User ($TEAM)"          "$TEAM"       825
make_identity renewed  "Apple Development: Test User ($TEAM)"          "$TEAM"       825
make_identity foreign  "Apple Development: Other Person ($OTHER_TEAM)" "$OTHER_TEAM" 825
make_identity expiring "Apple Distribution: Example Pty Ltd ($TEAM)"   "$TEAM"       1

# A genuinely expired certificate. openssl req rejects a negative -days, so this
# goes through `openssl ca`, which takes explicit start and end dates.
make_expired_identity() {
    mkdir -p ca; : > ca/index.txt; echo 1000 > ca/serial
    cat > ca/openssl.cnf <<'CNF'
[ca]
default_ca = CA_default
[CA_default]
dir            = ./ca
database       = $dir/index.txt
serial         = $dir/serial
new_certs_dir  = $dir
certificate    = ./primary-cert.pem
private_key    = ./primary-key.pem
default_md     = sha256
policy         = policy_any
email_in_dn    = no
unique_subject = no
[policy_any]
commonName             = supplied
organizationalUnitName = optional
organizationName       = optional
countryName            = optional
CNF
    "$OPENSSL" req -new -newkey rsa:2048 -nodes \
        -keyout expired-key.pem -out expired.csr \
        -subj "/CN=Apple Distribution: Expired Cert ($TEAM)/OU=$TEAM" 2>/dev/null
    "$OPENSSL" ca -config ca/openssl.cnf -batch -notext \
        -startdate 20200101000000Z -enddate 20200201000000Z \
        -in expired.csr -out expired-cert.pem >/dev/null 2>&1
    cat expired-cert.pem expired-key.pem > expired.pem
    "$OPENSSL" pkcs12 -export -inkey expired-key.pem -in expired-cert.pem \
        -out expired.p12 -passout pass:hunter2 2>/dev/null
}
make_expired_identity

# --- provisioning profiles --------------------------------------------------
# A real .mobileprovision is a CMS container wrapping this plist, so the
# fixtures are signed the same way.
# $1 out-name  $2 profile-name  $3 app-id-suffix  $4 type  $5 expiry-days  $6.. signer certs
make_profile() {
    local out="$1" name="$2" appid="$3" ptype="$4" days="$5"; shift 5
    local team="${PROFILE_TEAM:-$TEAM}"
    local certs_xml="" c
    for c in "$@"; do
        certs_xml+="        <data>$("$OPENSSL" x509 -in "$c" -outform der | base64 | tr -d '\n')</data>"$'\n'
    done

    local devices_xml="" extra_xml="" task_allow=false
    case "$ptype" in
        development) task_allow=true
            devices_xml="    <key>ProvisionedDevices</key><array><string>00008030-001122334455667788</string></array>" ;;
        adhoc)
            devices_xml="    <key>ProvisionedDevices</key><array><string>00008030-001122334455667788</string></array>" ;;
        enterprise)
            extra_xml="    <key>ProvisionsAllDevices</key><true/>" ;;
        appstore) ;;
    esac

    local expiry
    expiry="$("$PYTHON" - "$days" <<'PY'
import sys, datetime
d = int(sys.argv[1])
t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=d)
print(t.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

    cat > "$out.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Name</key><string>$name</string>
    <key>UUID</key><string>11111111-2222-3333-4444-555555555555</string>
    <key>TeamName</key><string>Example Pty Ltd</string>
    <key>TeamIdentifier</key><array><string>$team</string></array>
    <key>ApplicationIdentifierPrefix</key><array><string>$team</string></array>
    <key>ExpirationDate</key><date>$expiry</date>
$devices_xml
$extra_xml
    <key>Entitlements</key>
    <dict>
        <key>application-identifier</key><string>$team.$appid</string>
        <key>com.apple.developer.team-identifier</key><string>$team</string>
        <key>get-task-allow</key><$task_allow/>
    </dict>
    <key>DeveloperCertificates</key>
    <array>
$certs_xml
    </array>
</dict>
</plist>
PLIST

    "$OPENSSL" smime -sign -nodetach -noattr -outform DER \
        -in "$out.plist" -out "$out.mobileprovision" \
        -signer primary-cert.pem -inkey primary-key.pem 2>/dev/null
    base64 < "$out.mobileprovision" | tr -d '\n' > "$out.mobileprovision.b64"
    rm -f "$out.plist"
}

make_profile dev        "Example Dev Profile"        "$BUNDLE"      development 300 primary-cert.pem
make_profile dev-multi  "Example Dev Multi"          "$BUNDLE"      development 300 primary-cert.pem renewed-cert.pem
make_profile adhoc      "Example Ad Hoc"             "$BUNDLE"      adhoc       300 primary-cert.pem
make_profile store      "Example App Store"          "$BUNDLE"      appstore    300 primary-cert.pem
make_profile enterprise "Example In House"           "$BUNDLE"      enterprise  300 primary-cert.pem
make_profile wildcard   "Example Wildcard"           "com.example.*" appstore   300 primary-cert.pem
make_profile wildall    "Example Team Wildcard"      "*"            appstore    300 primary-cert.pem
make_profile expired    "Example Expired"            "$BUNDLE"      appstore    -5  primary-cert.pem
make_profile soon       "Example Expiring Soon"      "$BUNDLE"      appstore    10  primary-cert.pem
PROFILE_TEAM="$OTHER_TEAM" make_profile foreign "Example Other Team" "$BUNDLE" appstore 300 foreign-cert.pem
make_profile stale      "Example Stale Cert"         "$BUNDLE"      appstore    300 renewed-cert.pem
make_profile certexpired "Example Expired Cert"      "$BUNDLE"      appstore    300 expired-cert.pem
make_profile nocerts    "Example No Certs"           "$BUNDLE"      appstore    300

# a bare plist, and a binary plist, to test the non-CMS input paths
"$OPENSSL" smime -verify -noverify -inform DER -in dev.mobileprovision > bare.plist 2>/dev/null
"$PYTHON" -c "import plistlib,sys; plistlib.dump(plistlib.load(open('bare.plist','rb')), open('bare-binary.plist','wb'), fmt=plistlib.FMT_BINARY)"

echo "not a certificate" > junk.txt
printf 'fixtures in %s\n' "$PWD"

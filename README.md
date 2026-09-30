# assert-ios-signing

Prove a provisioning profile and a signing certificate can actually sign your app
— in about a second, on a Linux runner, before a macOS build spends ten minutes
finding out for you.

A signing mismatch normally surfaces at `xcodebuild -exportArchive`: the very end
of the longest job in the pipeline, as an error that does not name the actual
problem. You then re-run with verbose logging and read a couple of thousand lines
to work out which of the four possible causes it was.

This checks the same things up front, and says which one failed.

```
1. Provisioning profile validity
   [PASS] profile valid for 231 more day(s), until 2027-05-16 02:14:08 UTC

2. Bundle identifier
   [FAIL] bundle ID mismatch: this profile is for 'com.example.myapp',
          the build wants 'com.example.myapp.dev'

3. Signing certificate
   [PASS] certificate is present and within its validity window

4. Private key
   [PASS] private key is present and pairs with the certificate

5. Certificate is authorised by the profile
   [FAIL] this certificate is not one of the 2 the profile authorises

   What the profile authorises:
     BE9BFF106FD0CBB746C678598EF68CA531271515  Apple Distribution: Example Pty Ltd (ABC123)  [team ABC123]
     4DD95C0AB47C3108627A16D29267DDBAB33210E6  Apple Development: Someone Else (ABC123)      [team ABC123]

   What the build supplied:
     E31ED4BA32DE4BAF034D2FC09A70EE35F3568B89  Apple Distribution: Example Pty Ltd (ABC123)  [team ABC123]

   Likely cause: same team, different certificate. The profile was generated
   before this certificate existed, or against one that has since been revoked.
   Regenerate the profile in the Apple Developer portal so it picks up the
   current certificate.
```

Every check runs even after one fails, so a single run reports everything wrong
rather than making you fix them one round trip at a time.

## What it checks

| | Check |
| --- | --- |
| 1 | The profile decodes, and has not expired. Warns under 30 days. |
| 2 | The bundle ID is one the profile covers, wildcards included. |
| 3 | The profile is the kind you expect — development, ad hoc, App Store or enterprise. |
| 4 | The team identifier matches. |
| 5 | The certificate is present and inside its own validity window. |
| 6 | The private key is present and pairs with that certificate. |
| 7 | The profile's `DeveloperCertificates` authorises that certificate. |

Checks 2, 3 and 4 only run if you supply something to compare against.

## Use as a GitHub Action

Put it in front of the macOS job. A Linux runner costs about a tenth of a macOS
one, so this is close to free either way — but the point is that you find out in
the first few seconds, with a straight answer, instead of ten minutes in.

```yaml
jobs:
  preflight:
    runs-on: ubuntu-latest
    steps:
      - uses: matt-goldman/assert-ios-signing@v1
        with:
          profile: ${{ secrets.IOS_PROFILE_BASE64 }}
          certificate: ${{ secrets.IOS_CERT_BASE64 }}
          certificate-password: ${{ secrets.IOS_CERT_PASSWORD }}
          bundle-id: com.example.myapp
          profile-type: appstore

  build:
    needs: preflight
    runs-on: macos-latest
    steps:
      - run: echo "credentials already proven good"
```

### Inputs

| Input | Required | Description |
| --- | --- | --- |
| `profile` | yes | The provisioning profile: a workspace path, or base64 content. |
| `certificate` | no | PKCS#12 or PEM with the private key: a path, or base64 content. |
| `certificate-password` | no | Certificate password. |
| `certificate-name` | no | Assert the certificate's common name. See the note below. |
| `bundle-id` | no | The bundle identifier the build will sign. |
| `profile-type` | no | `development`, `adhoc`, `appstore` or `enterprise`. |
| `team-id` | no | Expected Apple Developer team identifier. |
| `summary` | no | `false` to skip the job summary table. |

Paths and base64 content are both accepted in the same input, and told apart by
whether the value names an existing file. The format of each input — raw or
base64, PEM or PKCS#12, CMS or plain plist — is detected, so there are no format
flags to get wrong.

### Outputs

`result`, `bundle-id`, `profile-name`, `profile-type`, `profile-uuid`, `team-id`,
`expires`, `days-remaining`, `cert-sha1`, `cert-name`.

Useful for tagging artefacts or gating a step:

```yaml
- id: signing
  uses: matt-goldman/assert-ios-signing@v1
  with:
    profile: ${{ secrets.IOS_PROFILE_BASE64 }}
    certificate: ${{ secrets.IOS_CERT_BASE64 }}
    certificate-password: ${{ secrets.IOS_CERT_PASSWORD }}

- if: steps.signing.outputs.days-remaining < 30
  run: echo "::warning::signing profile expires in ${{ steps.signing.outputs.days-remaining }} days"
```

A failed check fails the step. Add `continue-on-error: true` if you would rather
warn than block.

## Use on the command line

Same script, same checks. Useful when a local build will not sign either.

```bash
# against a certificate file
assert-ios-signing \
  --profile ~/Downloads/Example_Dev.mobileprovision \
  --cert ~/Downloads/certs.p12 \
  --bundle-id com.example.myapp

# against whatever is already in your keychains (macOS only)
assert-ios-signing \
  --profile ~/Downloads/Example_Dev.mobileprovision \
  --cert-name "Apple Distribution: Example Pty Ltd (ABC123)"
```

Pass the password in `$IOS_CERT_PASSWORD` rather than `--cert-password`, so it
stays out of your shell history and the process table.

Exit codes: `0` everything passed, `1` a check failed, `2` the inputs could not
be read at all.

## Security

No private key material is written to disk, and no keychain is created, imported
into, or modified.

- Inputs are held base64-encoded in shell variables and decoded onto a pipe when
  needed, so raw bytes only ever exist in a pipe.
- The private key is never stored, even transiently. Only the public key derived
  from it is kept, to compare against the certificate.
- The password is passed on file descriptor 3 from a process substitution — a
  pipe, so it never reaches disk. A bash here-string would have spilled it into a
  temporary file. It is never passed as an argument, so it never appears in `ps`.
- Profiles are decoded with `openssl smime -verify -noverify`, not
  `security cms -D`. The `security` route is macOS-only, and it imports the
  signing certificates into your default keychain as a side effect of decoding
  ([fastlane#30243](https://github.com/fastlane/fastlane/issues/30243), closed as
  not planned).

The keychain is only ever read, and only when you use `--cert-name` with no
certificate file.

## Requirements

`bash`, `openssl` and `python3`. All three are present by default on
`ubuntu-latest`, `macos-latest` and any Mac with the Xcode command line tools.
Python is used for the property list and fingerprint work; no third-party
packages are needed.

Apple exports `.p12` files with ciphers that OpenSSL 3 refuses without `-legacy`,
so the fallback is applied automatically. Set `OPENSSL=` or `PYTHON=` to override
either binary.

## A note on `certificate-name`

It is tempting to pin the certificate's common name, and the check is there if
you want it. It is usually the wrong thing to assert: the name embeds the team ID
and changes when a certificate is renewed, so pinning it turns a routine renewal
into a broken pipeline. The checks that matter — that the key pairs with the
certificate, and that the profile authorises it — do not depend on the name.

## Testing

```bash
./test/run-tests.sh
```

Generates throwaway identities and profiles covering each profile type, wildcard
and non-wildcard bundle IDs, every input encoding, expired profiles, expired
certificates, certificates with no key, profiles that predate the certificate,
and certificates from a different team. Then asserts the exit code and the
message for each. 51 cases.

CI runs the suite on `ubuntu-latest`, `ubuntu-22.04`, `macos-latest` and
`macos-14`, plus a job that builds a Keychain-Access-style legacy `.p12` and
proves it is still readable where plain `openssl` rejects it.

## Licence

MIT

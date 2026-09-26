# Distribution

**Documentation only. Nothing here has been done, and nothing here should be
done without a deliberate decision to start distributing this app.**

The project's standing instruction is local builds only: no App Store Connect,
no Transporter, no `xcrun altool`, no `xcrun notarytool`, no fastlane, no
TestFlight, and no Developer ID signing. No Apple ID or API key has been used
or requested. This file records what shipping *would* involve so that the
question can be answered without guessing — not as a runbook to execute.

## Where the build stands today

| Property | Current state | What shipping would require |
|---|---|---|
| Signature | **Ad-hoc** (`codesign --sign -`) | A Developer ID Application certificate |
| Notarization | **None** | Submission to Apple's notary service, then stapling |
| Hardened runtime | **Enabled** | Unchanged — already correct |
| App Sandbox | **Enabled** | Unchanged — already correct |
| Entitlements | Sandbox + user-selected files | Unchanged. Adding a network entitlement would break the app's central promise |
| Architecture | `arm64` only | A universal binary if Intel is to be supported |
| Deployment target | macOS 14.0 | Unchanged |
| Version | `0.1.0` / build `1` | A real version policy; the build number must increase on every upload |

Naming and versioning live in one place, `Config/AppInfo.xcconfig`.

## What an ad-hoc signature is and is not

`codesign --sign -` produces a signature with **no identity behind it**. It
does two useful things:

- it lets the App Sandbox and hardened runtime apply at all, which is why the
  local build uses it rather than going unsigned;
- it detects modification of the bundle after signing.

It does **not** establish who built the bundle, and it cannot be revoked,
because there is nothing to revoke. Every user's Mac will treat an ad-hoc
signed download as untrusted, and should.

**Consequence for users today:** the only safe way to obtain this app is to
build it from source. That is stated plainly in the [README](README.md), and it
should stay stated until a real signing identity exists.

## What notarization would actually involve

Recorded for completeness. **Do not run these.**

1. Obtain a Developer ID Application certificate from an Apple Developer
   Program membership, and install it in the login keychain.
2. Re-sign the bundle with that identity instead of `-`, keeping the hardened
   runtime and the existing entitlements file.
3. Submit a zipped bundle to the notary service and wait for the result.
4. Staple the returned ticket to the bundle, so Gatekeeper can verify it
   offline.
5. Verify with `spctl --assess` before distributing anything.

Each of those steps needs credentials that this project has deliberately never
had.

## The no-network promise, under distribution

`Scripts/verify-no-network.sh` must remain part of any release process, and
must pass on the **built bundle** rather than on the sources alone — it already
inspects the packaged entitlements with `plutil` for exactly this reason.

A release that added `com.apple.security.network.client`, for any reason,
would no longer be the same product. Auto-update, crash reporting, analytics
and licence checks all require it. If any of those is ever wanted, the honest
move is to say so in the README first, not to add the entitlement and hope
nobody reads the plist.

## If distribution is never wanted

That is a coherent end state, and largely where things already are. It needs
only two things kept true:

- **no binaries published anywhere**, so there is nothing for a user to run
  without building; and
- **the README keeps saying so**, so nobody assumes a file found elsewhere is
  genuine.

Both hold today.

## Things that would need deciding first

Not technical blockers — decisions:

1. **A licence.** None has been chosen, so default copyright applies and
   nobody has the right to redistribute anything. Distribution without a
   licence is incoherent.
2. **A security review.** The app has had none. Shipping unaudited software to
   strangers is a different proposition from running it yourself.
3. **A support position.** No network means no auto-update: a shipped build can
   never tell its user about a fix. Every update would be a manual download.
4. **Intel support**, or an explicit statement that Apple Silicon is required.

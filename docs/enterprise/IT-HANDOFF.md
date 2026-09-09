# Enterprise IT handoff

This is the vendor handoff checklist for a managed macOS deployment. It deliberately separates the
standard executable, organization policy, and optional employee portal. An MDM service is the
deployment authority; neither the website nor Mechanician attempts to discover enrollment or call
an MDM administrator API.

## Artifact set

Every release produces immutable, versioned artifacts:

| Artifact | Purpose | Verification |
|---|---|---|
| `Mechanician-<version>.pkg` | MDM/Self Service installation of the standard app | Developer ID Installer signature, notarization ticket, SHA-256 |
| `Mechanician-<version>.dmg` | Employee-managed drag installation | Developer ID Application signature, notarization ticket, SHA-256 |
| `Mechanician-<version>.zip` | Sparkle full update enclosure | Sparkle EdDSA signature in the appcast and SHA-256 |
| `Mechanician-<version>-<build>-release.json` | Machine-readable identity and artifact facts | Immutable object plus SHA-256 values for every listed artifact |
| `Mechanician-<version>-<build>-provenance.json` | Source/build/agentd-SBOM provenance | Must agree with the copy inside the signed app |
| `Mechanician-<version>-<build>-SHA256SUMS.txt` | Offline artifact verification | Compare before MDM upload |
| `Mechanician.mobileconfig` | Forced configuration and optional signed tenant profile | Stable payload IDs, `plutil`, exact app domain, inner Ed25519 signature |

The PKG payload is only `/Applications/Mechanician.app`. Never add a tenant profile, API key,
bootstrap token, script, or environment file to the installer. Configuration must remain a separate
profile so its assignment and revision can change without reapproving executable bytes.

The release script builds the package with `scripts/create-enterprise-pkg.sh`, submits it to Apple's
notary service, staples the ticket, verifies it with Gatekeeper, includes it in the checksum and
release manifests, and publishes it under an immutable versioned name. A local fixture can be built
without a distribution identity using `--unsigned`; that output is never suitable for deployment.

For an employee-managed pilot, `scripts/create-dmg.sh` accepts the signed profile as an optional
third argument. It verifies the Ed25519 envelope and creates a setup image containing the unchanged
app, the profile sidecar, and an install-order guide. Sign and notarize that outer DMG before
publishing it; the embedded app must already be the exact notarized release app.

After the release and organization artifacts are final, compose the website record with:

```sh
node scripts/generate-enterprise-deployment.mjs \
  --release-manifest /path/to/Mechanician-<version>-<build>-release.json \
  --signed-profile /path/to/Company.mechanician-profile \
  --distribution-mode manual \
  --setup-kit /path/to/Company-setup.dmg \
  --setup-kit-url https://downloads.example.com/Company-setup.dmg \
  --network-json-url /enterprise/network-allowlist.json \
  --network-csv-url /enterprise/network-allowlist.csv \
  --support-url https://support.example.com/mechanician \
  --output /path/to/Company-deployment.json
```

For `configuration-mdm`, also supply the configuration-only Managed Preferences file and URL. For
`self-service` or `automatic`, supply the MDM-owned update variant. The output cryptographically
binds the signed profile and local sidecars and carries the immutable release artifact facts.

## Identity to approve

- Bundle identifier: `ai.mechanician.app`
- TeamIdentifier: `5YPG2C4S34`
- Install path: `/Applications/Mechanician.app`
- Architecture: Apple silicon
- Minimum system: read `minimumMacOS` from the release manifest
- Background label, only when unattended work is allowed: `ai.mechanician.ambient`

Use the standard bundle identity for every organization. A renamed or retagged app has different
Keychain, TCC, preferences, Launch Services, and Application Support identities and is unsupported.

Before uploading to MDM:

```sh
pkgutil --check-signature Mechanician-<version>.pkg
xcrun stapler validate Mechanician-<version>.pkg
spctl --assess --type install --verbose=2 Mechanician-<version>.pkg
shasum -a 256 Mechanician-<version>.pkg
```

Compare the result to both the checksum text and release JSON. Reject any disagreement.

## Two supported rollout modes

### Configuration-only MDM pilot

1. Employees install the standard notarized DMG from the protected portal.
2. MDM assigns the forced Managed Preferences payload with the embedded signed organization
   profile.
3. Keep `updateAuthority=sparkle`; optionally force the stable channel and automatic-check choice.
4. The employee does not download or import a configuration file.

This is useful when policy approval is faster than executable-package approval.

### MDM-owned application

1. Upload the immutable signed/notarized PKG and its hash to the MDM distribution point.
2. Assign it to a canary smart group, either required or through Self Service.
3. Assign the Managed Preferences payload with `updateAuthority=mdm`.
4. Confirm the app build before setting `minimumAppBuild` to that build.
5. Expand scope only after the canary verifies provider identity, a real turn, extension policy,
   update behavior, and removal/replacement behavior.

Do not assign the Sparkle-owned and MDM-owned payload variants together. They retain the same outer
payload identifiers so one replaces the other in place.

## Security-review packet

Provide the following with the canary request:

- release manifest, checksums, notarization evidence, provenance, and the agent daemon's CycloneDX
  SBOM;
- [network and privacy inventory](NETWORK-PRIVACY.md), including organization-specific provider,
  catalog, and MCP hosts;
- the complete forced-policy schema and redacted effective-policy example;
- storage paths, Keychain service identifiers, bundled helper/engine identities, and log locations;
- confirmation that Mechanician is hardened-runtime but not App Sandbox constrained;
- optional TCC capabilities and the exact user-facing feature that needs each one;
- uninstall and rollback behavior below.

PPPC/TCC policy is independent of Mechanician authorization. Do not request blanket privacy grants.
Grant only capabilities the assigned workflows require, and preserve macOS user consent where the
platform requires it. Endpoint security, web filters, VPN, and DLP remain effective outside the app.

## Canary acceptance

Record these checks against the exact app build and profile revision:

1. `objectIsForced` is true for `MechanicianManagedConfiguration`.
2. Mechanician reports MDM as the policy source and the expected revision.
3. A disallowed provider cannot start a runtime, including queued and scheduled paths.
4. A real provider turn reaches only the approved tenant/project and model.
5. Permission mode, public discovery, user extensions, and unattended work match policy.
6. The app makes no automatic organization-profile request when the signed profile is manual or
   MDM-owned.
7. The chosen app-update authority is the only one active.
8. Replacing the configuration and relaunching yields the new revision without losing preserved
   user state.
9. Removing the app leaves enterprise data handling consistent with the organization's retention
   policy.

## Uninstall and rollback

Removing the app does not automatically delete the user's library, provider credentials, extension
configuration, logs, or scheduled definitions. Decide separately whether corporate offboarding
should preserve, archive, or remove those locations; never use an unscoped recursive deletion.

Before removing or relaxing the forced payload, audit preserved local profiles, overrides,
extensions, credentials, scheduled tasks, and armed waits. They may become active again when the
ceiling disappears. Before rolling the app backward, lower `minimumAppBuild` and confirm the older
binary supports the current storage schema. MDM assignment is not a database downgrade mechanism.

The first managed assignment and any unattended revocation must also follow the LaunchAgent cleanup
procedure in [MDM-DEPLOYMENT.md](MDM-DEPLOYMENT.md). A long-lived job cannot be assumed to observe a
new launch-scoped policy until it has been booted out and the app has reconciled it.

# Enterprise deployment with macOS MDM

Use this with the [enterprise IT handoff checklist](IT-HANDOFF.md) and the
[network and privacy inventory](NETWORK-PRIVACY.md).

Mechanician accepts organization policy through macOS **Managed Preferences**. An MDM service
installs a configuration profile containing a `Forced` preference for the exact application domain
named by the deployed app's `CFBundleIdentifier`. This first MDM-capable release uses the standard
`ai.mechanician.app` build; tenant routing and presentation arrive through its signed managed
profile rather than a separately branded app bundle. On an enrolled and scoped Mac, policy delivery
is automatic: the person does not download or import a `.mechanician-profile` file.

The MDM configuration profile and the Mechanician app are separate deployments. Pushing the
configuration does not install or update the app, and choosing MDM as the app-update authority does
not make that happen by itself. The MDM administrator must assign both artifacts when both should
be automatic:

1. the signed, notarized Mechanician installer package; and
2. the Managed Preferences configuration profile described here.

The release pipeline publishes an immutable versioned `.pkg` containing only the standard
`/Applications/Mechanician.app`. Tenant configuration is deliberately separate. An administrator
can therefore approve the executable package once while replacing the Managed Preferences payload
on its own schedule. Until package approval is complete, use the employee portal for the normal
DMG while MDM delivers configuration automatically.

Provider sign-in and network prerequisites are also separate. MDM can configure which provider
lanes are allowed, but a person may still need to complete Google, Anthropic, OpenAI, or AWS
authentication and connect to the corporate network or VPN.

## Trust boundaries

The app reads one preference named `MechanicianManagedConfiguration`. It honors the value only
when macOS reports it as forced. A value written with `defaults`, an ordinary per-user preference,
or another unforced mechanism is ignored.

That check establishes forced managed-preference semantics; it is not proof of device enrollment,
enterprise identity, or licensing. macOS can also install a configuration profile manually. Keep
the outer policy limited to restrictions and defaults, and continue to rely on the signed inner
profile for tenant routes and endpoints.

The forced preference transports two different kinds of data:

- The outer property-list dictionary is administrator policy. MDM supplies and enforces it.
- The optional `signedProfile` value is the exact byte sequence of an existing signed
  `.mechanician-profile` envelope. Mechanician verifies those bytes with its embedded enterprise
  profile public key before using any tenant route, endpoint, model list, or managed extension
  declaration.

MDM delivery does not replace the inner signature. Do not decode and reserialize the signed JSON.
In an XML `.mobileconfig`, put the base64 representation of the original file bytes in a `<data>`
value; the property-list decoder reconstructs the exact signed bytes.

Neither layer is a credential store. Do not include API keys, OAuth tokens, passwords, private
keys, cookies, authorization headers, or other secrets. Provider credentials continue to use their
normal Keychain, provider login, Google ADC, or AWS credential-chain path.

## Payload shape

Use a `com.apple.ManagedClient.preferences` payload whose `PayloadContent` contains the deployed
app's exact `CFBundleIdentifier`, a `Forced` array, and an `mcx_preference_settings` dictionary. The
repository includes a lintable starting point for the standard `ai.mechanician.app` build at
[`Mechanician-managed-preferences.example.mobileconfig`](Mechanician-managed-preferences.example.mobileconfig).
For a reproducible artifact, copy
[`managed-preferences-build.example.json`](managed-preferences-build.example.json), retain stable
payload identifiers and UUIDs, and run:

```sh
node scripts/generate-managed-preferences-profile.mjs \
  --config /path/to/private-managed-preferences.json \
  --signed-profile /path/to/Company.mechanician-profile \
  --output /path/to/Mechanician.mobileconfig
```

The generator verifies the inner Ed25519 signature, rejects credential-shaped fields, embeds the
exact signed bytes as property-list `Data`, and lints the result with `plutil`.

Do not retag or repackage that build under a different bundle identifier: macOS would give it a
different preference, Keychain, privacy-permission, and application-support identity, and this
release does not support that migration path.

The value under `MechanicianManagedConfiguration` has this shape:

```text
MechanicianManagedConfiguration
├── schemaVersion: 1                         required
├── signedProfile: Data                      optional, exact signed file bytes
├── policyIdentifier: String                 optional
├── revision: Int                            optional
└── policy: Dictionary                       optional
    ├── allowedProviderAccesses: [String]
    ├── maximumInteractivePermissionMode: String
    ├── allowUnattendedTasks: Bool
    ├── allowLocalProfile: Bool
    ├── allowLocalConfigurationOverrides: Bool
    ├── allowUserConfiguredExtensions: Bool
    ├── allowPublicExtensionDiscovery: Bool
    ├── updateAuthority: String
    ├── sparkleUpdateChannel: String
    ├── sparkleAutomaticChecks: Bool
    └── minimumAppBuild: Int
```

All policy fields are optional. Missing fields preserve ordinary Mechanician behavior.

| Key | Accepted values | Default and effect |
|---|---|---|
| `schemaVersion` | `1` | Required. An unsupported version fails closed. |
| `signedProfile` | Property-list `Data`, at most 1 MiB | Optional. The exact signed `.mechanician-profile` bytes; an invalid signature is launch-blocking. |
| `policyIdentifier` | Non-empty string, at most 128 characters, no control characters | Optional stable deployment identifier. |
| `revision` | Positive integer | Optional administrator-visible generation. Use increasing values operationally; the outer policy does not itself enforce monotonic revisions. |
| `allowedProviderAccesses` | Non-empty array of lane identifiers using only ASCII letters, digits, `.`, `_`, and `-` (128 characters maximum each) | Missing means all configured lanes. A policy that leaves no lane available in this app/profile combination is launch-blocking. |
| `maximumInteractivePermissionMode` | `plan`, `default`, `acceptEdits`, or `bypassPermissions` | Missing means no additional ceiling. `plan` blocks built-in file, shell, computer-control, and Apple-automation mutation and cannot be exited mid-turn, but is not a universal read-only guarantee. The app and daemon clamp stale or direct requests to the ceiling. |
| `allowUnattendedTasks` | Boolean | Defaults to `true`. `false` prevents scheduled/background work and prevents `WaitFor` from arming automatic resume or shell polling. |
| `allowLocalProfile` | Boolean | Defaults to `true`. `false` ignores local profile files and the profile-path environment override without deleting either. |
| `allowLocalConfigurationOverrides` | Boolean | Defaults to `true`. `false` prevents local configuration overrides from changing the resolved signed/default profile. |
| `allowUserConfiguredExtensions` | Boolean | Defaults to `true`. `false` ignores user MCP/plugin configuration at runtime and uses only signed managed remote servers. See the limitation below. |
| `allowPublicExtensionDiscovery` | Boolean | Defaults to `true`. `false` disables public extension discovery even if the signed tenant profile otherwise permits it. |
| `updateAuthority` | `sparkle` or `mdm` | Defaults to `sparkle`. `mdm` disables in-app Sparkle updates; the administrator must deploy app updates. |
| `sparkleUpdateChannel` | `stable` or `daily` | Optional forced Sparkle channel. Invalid when `updateAuthority` is `mdm`. |
| `sparkleAutomaticChecks` | Boolean | Optional forced automatic-check setting. Invalid when `updateAuthority` is `mdm`. |
| `minimumAppBuild` | Positive integer matching `CFBundleVersion` | Optional. A lower installed build may open for diagnosis and updating, but interactive turns, scheduled turns, and automatic `WaitFor` polling/resume are blocked until the app is updated. |

The entire managed dictionary is limited to 1 MiB. Wrong types, invalid values, or an invalid
forced dictionary fail closed and stop normal app launch with an administrator-facing recovery
message. Schema v1 also rejects unknown top-level or `policy` keys so a misspelled restriction
cannot silently take its permissive default; add fields only with a schema-version update.

Provider lane identifiers are exact persisted values:

- `claude_subscription`
- `anthropic_api`
- `codex_subscription`
- `openai_api`
- `claude_vertex` when the signed tenant profile declares the audited Vertex route
- `claude_bedrock` when the signed tenant profile declares the audited Bedrock route

Unknown future lane strings are retained for forward compatibility but do not make a lane available
to an older app. An empty allowlist is invalid.

The permission value is a ceiling, not a remembered-approval reset. `default` can still honor an
existing workspace-scoped **Always Allow** decision. A `plan` ceiling prevents built-in file,
shell, computer-control, and Apple-automation mutation, but a third-party MCP tool whose effects
Mechanician cannot classify may still be presented for approval and may mutate remote state. For
a stricter deployment, combine `plan` with `allowUserConfiguredExtensions=false` and declare no
mutating signed managed MCP endpoints.

This schema does not yet have a separately configurable unattended permission ceiling. Scheduled
turns are clamped to `maximumInteractivePermissionMode` when they execute, but their saved task
definitions are preserved unchanged. If any unattended execution is unacceptable, set
`allowUnattendedTasks=false` for this release.

The first schema also does not expose separate organization switches for Computer Control,
AppleScript/Shortcuts, or remembered approvals. A `plan` ceiling is the available built-in local
mutation control, subject to the MCP limitation above. macOS privacy policy, endpoint security,
and network policy remain separate controls and should still be deployed where required.

### Managed-extension limitation

When `allowUserConfiguredExtensions` is `false`, the current release accepts only signed managed
remote MCP declarations that resolve to HTTPS `http` or `sse` endpoints. Executable declarations
(`command`, `args`, or `env`) are rejected by signed-profile verification. The current UI does not
yet provide the complete OAuth/readiness lifecycle for those signed managed rows, so use this path
only for endpoints that do not require a person to complete interactive MCP authorization. A
deployment that declares no managed servers is unaffected by this limitation.

Managed server names must already be canonical ASCII identifiers containing only letters, digits,
`_`, and `-`. They must be unique and must not equal or extend a Mechanician built-in MCP namespace.
The signed-profile verifier rejects the complete profile when these constraints are not met.

The encoded aggregate of signed managed-server declarations is limited to 64 KiB because it is
transported to the isolated app and scheduler daemons. Exceeding that limit is launch-blocking in
managed-only mode; it never silently starts a daemon with an empty server set.

Unattended direct-SDK runs do not mount signed managed remote servers in this first release. They
still disable user extensions and provider-owned connectors and run with only Mechanician's bounded
artifact server. Keep unattended work off if a task would require a managed remote MCP endpoint.

Managed-only mode also disables Claude.ai account connectors and plugin sync, supplies no local
plugin list, suppresses connector status, and rejects connector authorization controls in the
daemon. A signed managed server that needs interactive OAuth receives an explicit
unsupported-lifecycle error instead of falling through to a provider-owned connector flow.

The same managed-only mode intentionally makes the `codex_subscription` lane unavailable in this
release. Codex keeps provider-native plugin/MCP state in a user-writable home, and Mechanician
cannot yet prove that surface absent. This is a fail-closed limitation; other provider lanes remain
subject to the explicit allowlist.

## Build a deployment profile

1. Start with the example `.mobileconfig`. Replace every `com.example` identifier, UUID, display
   name, and organization string with deployment-owned values.
2. Decide whether Mechanician should use the public/default provider routes or a tenant profile.
   For tenant routes, generate the signed `.mechanician-profile` using the private enterprise
   configuration publishing process.
3. Base64-encode the signed file bytes and add them as the top-level `signedProfile` data value:

   ```xml
   <key>signedProfile</key>
   <data>
   BASE64_OF_THE_EXACT_SIGNED_FILE_BYTES
   </data>
   ```

   On macOS, `/usr/bin/base64 < Company.mechanician-profile` produces suitable data text. Do not
   put a path, URL, JSON string, or already-decoded profile object in this field.
4. Set the policy restrictions. For a centrally controlled deployment, the usual starting point is
   `allowLocalProfile=false` and `allowLocalConfigurationOverrides=false`.
5. Validate the XML before upload:

   ```sh
   plutil -lint Mechanician.mobileconfig
   ```

6. Upload it to the MDM provider as a custom macOS configuration profile and assign it first to a
   canary device group.
7. If `updateAuthority=mdm`, separately upload and assign the release's signed/notarized versioned
   `.pkg`. Deploy the required app build before raising `minimumAppBuild` to that build. Verify its
   signature, notarization ticket, SHA-256, TeamIdentifier, and bundle identifier against the
   accompanying machine-readable release manifest before assignment.
8. Verify on a managed Mac that the profile is installed, the Mechanician Settings UI reports the
   managed configuration and expected revision, disallowed providers are unavailable, and a test
   turn uses the intended route.
9. Expand assignment only after the canary completes provider sign-in and a real turn.

Deploy and verify a policy-capable Mechanician build before assigning this preference. Older
versions do not know the key and therefore cannot enforce it. Record the first supported
`CFBundleVersion` in the private deployment runbook, and never roll a managed fleet below that
build while the payload remains assigned.

If unattended tasks are enabled, deploy a `com.apple.servicemanagement` payload whose managed
login-item rule matches the LaunchAgent label `ai.mechanician.ambient` and Mechanician's signing
TeamIdentifier `5YPG2C4S34`; verify both against the actual signed artifact before deployment.
Apple's declarative Background Task Management payload deploys MDM-owned jobs and is not approval
for this app-installed LaunchAgent.

For reproducible publishing, generate the final `.mobileconfig` from the private configuration
repository or release pipeline. The public app repository should hold only examples; the employee
site should never receive the profile-signing private key.

## Updates, replacement, and rollback

Choose exactly one app-update authority:

- `sparkle`: Mechanician retains its signed in-app updater. Administrators can force `stable` or
  `daily` and the automatic-check setting.
- `mdm`: Mechanician disables Sparkle controls. The MDM service owns app-artifact assignment,
  rollout, and rollback. Do not include either `sparkleUpdateChannel` or
  `sparkleAutomaticChecks` in this mode.

Changing policy means publishing a replacement payload through MDM. Keep one owning configuration
profile with stable outer and inner `PayloadIdentifier` and `PayloadUUID` values so the service
replaces it in place. If provider-specific behavior requires new identifiers, remove the old
profile before assigning the replacement; two profiles forcing the same application preference
have ambiguous resolution. Increment the administrator `revision` so support staff can distinguish
generations.

Schema v1 is launch-scoped: Mechanician snapshots the forced preference when the app starts. A
replacement or removal therefore requires quitting and reopening Mechanician. A persistent
scheduled-task LaunchAgent also retains the policy snapshot with which it was started. Before
assigning or replacing the payload, the MDM workflow must boot out `ai.mechanician.ambient` from
every currently loaded `gui/<uid>` launchd domain. On the first managed assignment, and whenever
unattended work is revoked, a root-managed script must also remove the exact
`Library/LaunchAgents/ai.mechanician.ambient.plist` below every in-scope local user's home—not only
homes whose users are logged in. Otherwise a logged-out user's stale job can start at their next
login before Mechanician reads the forced preference. For a replacement that continues to allow
unattended work, retain the plists but boot out every loaded job. Then quit and reopen Mechanician
for each active user so the app reads the new forced preference and, when allowed, reconciles or
installs a fresh LaunchAgent identity. Until a signed policy gate can read forced preferences
inside the long-lived scheduler itself, do not claim live policy revocation while the app is
closed. The initial managed policy should keep `allowUnattendedTasks=false`.

Canary every change. A malformed forced document, a bad inner signature, or an allowlist with no
currently available provider fails closed. The recovery action is to replace or remove the bad MDM
payload, then reopen Mechanician.

Removing the forced payload restores unmanaged resolution. Mechanician does not delete a local
profile, local overrides, user extensions/plugins, credentials, scheduled-task definitions, or
armed `WaitFor` triggers while policy tells it to ignore them. Any of that preserved state may
become active again after policy removal or relaxation. Audit and disable it before using payload
removal as a permanent rollback.

Before rolling back the app itself, lower or remove `minimumAppBuild`, deploy the compatible app,
and account for Mechanician's forward-only storage migrations. An older binary is not guaranteed
to open a library written by a newer build; use the product's documented recovery/rollback path
instead of treating MDM assignment as a database rollback mechanism.

## Managed employee flow

For a Mac enrolled in MDM and included in the Mechanician assignment, configuration becomes
automatic at device check-in:

1. MDM installs or updates the app if app deployment is assigned.
2. MDM installs the forced Managed Preferences payload.
3. Mechanician reads and verifies the embedded signed tenant profile on launch.
4. The person completes any provider authentication and VPN step still required by the configured
   route.

The person does not download a `.mechanician-profile` file and does not use **Import
Configuration…**. If MDM supplies policy but not the app, the person may still download the app;
only the configuration-import step disappears.

The employee download site should remain a portal, not become the MDM control plane. In the
MDM-first flow it should:

- present one primary **Download Mechanician** action only when app installation is still manual;
- otherwise explain that Mechanician is installed and configured by the organization's IT team;
- list the remaining provider sign-in and VPN steps;
- provide a support/contact path and troubleshooting for a missing assignment;
- keep the direct configuration download behind an explicitly labeled break-glass/manual fallback,
  if that fallback is still authorized; and
- avoid claiming that a browser can detect whether the Mac is enrolled or the payload is applied.

If the MDM provider needs a public artifact URL, the site or release CDN may host an immutable,
versioned, signed/notarized artifact and checksum in a format that provider supports. Device
inventory, enrollment, group assignment, profile upload, push status, and administrator
credentials belong in the selected MDM service (or a separately designed authenticated management
backend), not in the employee download route. Do not add an MDM admin console to the download site
until a provider and its authorization, audit, and API model have been selected.

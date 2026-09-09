# Network and privacy inventory

Mechanician has no product account, first-party usage telemetry upload, or crash-reporting service.
It does make network requests for explicitly selected providers and extensions, and it can check for
signed software or organization-configuration updates. Those categories must be described
separately: disabling vendor updates does not make a configured cloud model work offline.

## First-party-controlled destinations

| Destination | Activation | Data sent | Disable path |
|---|---|---|---|
| Sparkle feed and release CDN from `SUFeedURL` | Automatic only after the unmanaged user chooses automatic updates, or as forced by policy; explicit Check otherwise | App/Sparkle version and ordinary HTTPS metadata; Sparkle system-profile reporting is disabled | Choose manual updates, or set `updateAuthority=mdm` |
| Signed profile's `profileFeedURL` | Automatic only when the signed profile declares `profileUpdateMode=automatic`; explicit Check in manual mode | Current profile endpoint request and ordinary HTTPS metadata; no credential or portal cookie | Publish manual mode, remove the feed, or embed the profile through MDM |
| Product/help/support URLs | Explicit button or menu action | Ordinary browser request | Do not open the link |

No Mechanician or Magic & Lasers hostname is compiled as a licensing, entitlement, account,
telemetry, or MDM-discovery endpoint. A tenant-selected signed profile may name a profile feed, but
the destination is data, not an implicit trust grant: every response is verified locally before it
can replace configuration.

Two useful privacy statements are intentionally different:

- **No background request to the product website:** use a manual or MDM-owned signed profile.
- **No background request to any vendor-controlled infrastructure:** also choose manual app updates
  or make MDM the update authority.

## Provider destinations

A selected and authenticated provider lane may perform account refresh and model-catalog work at
startup, before the first user message. A turn sends the prompt and selected context directly to the
provider; Magic & Lasers is not a relay.

Known classes include:

- Google authorization, token, user-info, and regional/global Vertex AI endpoints for a managed
  Vertex lane;
- Anthropic API and Claude account services;
- OpenAI API and Codex account services; and
- AWS credential and Bedrock endpoints for a managed Bedrock lane.

Do not reduce these to a permanent hostname list in product code. Provider SDKs, regional routing,
identity systems, and an organization's private networking can change. Generate the firewall review
from the exact signed profile and canary-observed DNS/proxy traffic, and record the app/profile
revision alongside it.

## Extension destinations

- Opening the Extensions browser fetches enabled registry and marketplace indexes.
- Rendering a provider marketplace can fetch provider or third-party media.
- Enabled remote MCP servers are contacted directly when initialized or used.
- MCP OAuth discovery and token refresh contact server-declared authorization endpoints.
- A `vpnOnly` server can receive a credential-free availability probe before use.
- Installing a plugin can fetch its declared source.

`allowPublicExtensionDiscovery=false` removes public discovery sources. It does not by itself block
user-configured servers or plugins; use `allowUserConfiguredExtensions=false` when the managed-only
runtime semantics and documented limitations fit the deployment.

## Local communication

Provider and MCP sign-in can use a loopback callback on `127.0.0.1`. App-to-daemon communication is
stdio, and the local metrics harness is loopback-only with export disabled. These are not remote
telemetry destinations.

## Website and download logging

Visiting an employee portal is browser traffic, not app traffic. Authentication, access control,
downloads, Cloud hosting, and object storage necessarily create ordinary service logs such as time,
path, IP address, user agent, status, and bytes. State the actual retention and access controls on
the portal's privacy page. Do not transfer its cookie, email link, device fingerprint, or MDM state
into Mechanician.

An enterprise download event needs only aggregate artifact/version counts. Avoid a persistent or
daily visitor identifier and referrer unless a documented operational requirement justifies them.

## Firewall manifest shape

An employee portal may publish a passive JSON/CSV inventory for IT review. Each destination should
contain:

- hostname, port, and protocol;
- owner;
- purpose;
- activation: automatic, user action, feature use, or MDM;
- requirement: required, optional, or when enabled; and
- data categories.

The manifest is documentation, never an active connectivity probe. Mechanician and the website must
not contact every listed service merely to decide whether it is reachable.

# ADR-001: Paired local companion with shared protocol

**Status:** Accepted for development
**Date:** 2026-10-29
**Deciders:** Show Bar project owner; implementation follows the request to review and build the companion

## Context

The Mac application already has privileged window/screenshot functionality. iOS and iPadOS apps cannot replace the platform's window manager. The previous network prototype could be controlled by any LAN peer and confused TCP chunks with complete messages. Clipboard and screen contents require a clear opt-in boundary.

## Decision

Build a native companion that controls Mac windows. Discover hosts with Bonjour; authenticate and encrypt with Network.framework TLS-PSK using a random 128-bit host pairing code. Keep secrets in Keychain and disable hosting/history/image sharing by default. Share a versioned Codable protocol and incremental framing implementation across platforms. Require explicit target window selection for arranging and pasting.

## Options considered

| Option | Complexity | Cost | Privacy / lifecycle | Decision |
| --- | --- | --- | --- | --- |
| Plain TCP plus a token field | Low | None | Token and content exposed without another encrypted layer | Rejected |
| Bonjour + TLS-PSK | Moderate | None | OS TLS authentication, local-only discovery, manual secure pairing | Selected for first version |
| Cloud relay + user accounts | High | Hosting and operations | Remote reach but expands retention and account obligations | Revisit only for remote-access requirement |
| Per-device TLS identities / QR enrollment | Higher | None locally | Better individual revocation and TLS 1.3 migration | Follow-up transport version |

## Trade-offs and consequences

Pairing a full secret is less convenient than a short PIN; it avoids inventing an unauthenticated short-code cryptographic protocol. A shared host code makes rotation revoke every device; there is no per-device revocation list. The TLS 1.2 PSK cipher used here lacks forward secrecy, which is a documented limitation rather than an implied TLS 1.3 guarantee. Native Network.framework keeps framing, permissions, encryption, and reconnection explicit without a server dependency.

Clipboard and image streams are bounded and separately enabled. iOS does not continuously read the pasteboard or keep a socket active indefinitely in the background. The UI must make offline/demo states obvious and never report an unacknowledged command as completed.

## Action items

- Implement shared protocol, paired desktop host, native client and accessible adaptive UI.
- Test authentication failures and real client/server message exchange, not just encoding.
- Verify physical-device pairing/permissions before release.
- Evaluate TLS 1.3 per-device identities and QR onboarding as a separately versioned improvement.

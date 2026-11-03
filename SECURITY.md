# Security

Dabble syncs your to-dos directly between your devices, with no server. This document describes what that design protects against, what it doesn't, and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private reporting instead: go to the repository's **Security** tab and choose **Report a vulnerability** ([direct link](https://github.com/nearbycoder/dabble/security/advisories/new)).

Include what you found, how to reproduce it, and the versions affected. We'll acknowledge the report as soon as we can, keep you updated while we work on a fix, and credit you in the advisory unless you'd rather we didn't. Dabble is a volunteer project, so we can't offer a bug bounty.

Only the latest release is supported with security fixes.

## How sync is secured

The details are in [README → How sync works](README.md#how-sync-works) and in `Packages/DabbleKit/Sources/DabbleKit/Sync/`. In short:

- **Sync group key.** Devices that sync together share a random 256-bit key. Holding that key is what makes a device a member of the group. There are no accounts or per-device identities beyond it.
- **Channel.** Every connection starts with an ephemeral **X25519** key exchange. The shared secret and the group key are combined with **HKDF-SHA256** (salted with both sides' random hellos) into two directional **ChaCha20-Poly1305** keys. Frames use a counter nonce, so they can't be replayed, reordered or silently dropped. A device without the group key can't complete a session.
- **Forward secrecy.** Because each session uses fresh ephemeral keys, a recording of past traffic can't be decrypted later, even by someone who later obtains the group key.
- **Pairing** uses numeric comparison, as in Bluetooth Secure Simple Pairing. The two devices run the same X25519 handshake (without a group key) and then a commit/reveal exchange: the joining device sends `SHA-256(nonce_j ‖ transcript)`, the host replies with `nonce_h`, and the joiner reveals `nonce_j`. Both show a 6-digit code derived from `SHA-256(transcript ‖ nonce_h ‖ nonce_j)`, where the transcript is a hash of both handshake hellos. The host sends the group key only after the user confirms the codes match **on both devices**. The joiner accepts a key only after confirming on its own side.

## What this protects against

- **Passive eavesdroppers** on your network (or on a VPN path) can't read your data or learn your group key. That includes the pairing exchange, which is encrypted under the ephemeral X25519 secret.
- **Active attackers during pairing.** There's no secret code to brute-force, online or offline. A man in the middle ends up with a different handshake transcript on each side. Because the joiner commits to its nonce before seeing the host's, the attacker can't steer both codes to match: they get one try with a 1-in-1,000,000 chance, and you'd see the mismatch.
- **Devices outside your group** can't connect, read or inject changes. They fail at the first encrypted message.
- **Tampering in transit**: modified, replayed or reordered frames are rejected and the connection is closed.

## Known limitations

We'd rather you know these than discover them.

### Pairing relies on you comparing the codes

Pairing has no password to guess. Its security comes from you checking that both devices show the same six digits and confirming on both. If you tap **Codes Match** without looking, an attacker on the same network during the 5-minute pairing window could pair in your place. A real mismatch means something is wrong: tap **Codes Don't Match** and pair again on a network you trust.

The code is 6 digits, so an active man in the middle who gets you to compare codes has a one-in-a-million chance of making them match on a single attempt. They don't get a second try without you starting pairing again.

### Every device in the group is fully trusted

- Any member can read and change everything, and can claim any device name or id. There's no per-device signing.
- **There's no revocation yet.** Forgetting a device on another device doesn't take away its key, so a lost or stolen device that's still a member can keep syncing whenever it can reach your devices. To evict it, have every remaining device leave the sync group, then pair them again. That creates a new group key. Key rotation is on the roadmap.

### Data at rest

- Your to-dos (`dabble.json`) and the group key (`sync.json`) are stored unencrypted inside Dabble's sandboxed app container. They're protected by the operating system: the app sandbox, FileVault on the Mac, and Data Protection on iPhone and iPad (`sync.json` uses *complete until first user authentication*). The group key isn't in the Keychain.
- Anyone who can read your app container (malware running as you, an unencrypted backup of your Mac) can read your data and join your sync group.
- JSON backups you export are plain text. Store them accordingly.

### Metadata on the local network

- Each device advertises itself over Bonjour with the **device name** you chose, a random **device id**, and a short **group fingerprint**. Anyone on the same network can see that these devices run Dabble and belong to the same group, and could recognize them on other networks too. They can't see any to-do content.
- Traffic timing and sizes are visible to anyone on the network path.

### Exposing Dabble to the internet

Manual addresses are meant for private networks such as Tailscale or WireGuard. Opening the sync port (52384) on your router to the whole internet isn't recommended: the protocol keeps out anyone without your key, but it adds attack surface and lets anyone try to connect.

### Denial of service

Anyone who can reach a device's sync port can open connections and make it do some work (a key exchange, and buffering up to one large frame) before the connection fails or times out after 15 seconds. That can't expose data, but local-network denial of service is out of scope.

### Distribution

- **macOS release builds are ad-hoc signed and not notarized.** macOS can't verify who built them. Check the downloaded file against `SHA256SUMS.txt` in the release, or build from source.
- **The iOS `.ipa` is unsigned** and gets signed with your own Apple ID by Xcode, AltStore or Sideloadly.
- Release builds are produced by the public [release workflow](.github/workflows/release.yml) from the tagged commit, so you can check how each one was built.

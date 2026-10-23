# From a Phone

Any SSH app can reach the box and run `afk`, but herdr is driven by keyboard
chords, and a phone keyboard has no Ctrl, Alt or Esc to send them with.
[Whip](https://github.com/kosumic/whip) (Android and iOS) gets around that: it
reads herdr's API socket over SSH and shows spaces, tabs, panes and agents as
native screens you tap and swipe through. Each agent shows whether it is
working, blocked or done, Claude Code and Codex transcripts open as a chat, and
a pane's terminal is still there when you need it.

Nothing is installed on the box and no port is opened: Whip uses the SSH port
you already connect to, as `dev`, with its own key.

## Setup

1. Install Whip from Google Play or the App Store. Stay with one source: Play
   re-signs its builds, so switching to the APK from GitHub Releases means
   uninstalling first.
2. In Whip, generate an Ed25519 key under **More → Global SSH keychain** and
   copy its public key.
3. Add that public key as a new line in `SSH_PUBLIC_KEYS` and redeploy. The
   redeploy recreates the container, which ends running processes: herdr
   restores its layout afterwards, tmux sessions are gone. Do it between
   tasks.
4. Add the host in Whip: the server's address, port `2222` (or `SSH_PORT`),
   user `dev`, and the key from step 2.

Skip Whip's QR pairing (`whipair`), which authorizes the phone's key on the
host itself. The box reads keys only from the file the entrypoint writes from
`SSH_PUBLIC_KEYS` on every boot (see `AuthorizedKeysFile` in
[sshd_config.d](sshd_config.d)), so `SSH_PUBLIC_KEYS` is the one place a key
lasts.

## herdr upgrades

Whip speaks herdr's private client protocol and supports a fixed range of its
versions, 17 to 22 when this was written. herdr 0.9.5 speaks 22. A herdr bump
that moves the protocol past what Whip supports breaks the phone until Whip
catches up, so before merging one, compare what the box reports:

```bash
herdr status server   # private_protocol: 22
```

against the range in Whip's README.

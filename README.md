# magnus-bridge

Host [Magnus](https://github.com/hrishikeshs/magnus) agents in the
[Bridge](https://github.com/hrishikeshs/bridge) messenger.

> [!IMPORTANT]
> `magnus-bridge` is not a standalone server or phone application. It requires
> the separate `bridge` binary and a running Bridge daemon on the same machine.
> It does not install, start, expose, pair, or stop that shared daemon.

`magnus-bridge` is deliberately small. Magnus owns agent processes and Bridge
owns the phone app, identity, history, delivery, permissions, and security.
This package is the adapter between them:

```text
phone ⇄ bridge daemon ⇄ magnus-bridge ⇄ Magnus vterms
```

The daemon never reaches into Emacs. Emacs registers its live agents, attests
their readiness, drains daemon-authored messages into their terminals, and
acknowledges only deliveries it actually typed.

## Install both halves

- Emacs 28.1 or newer
- Magnus 0.5 or newer
- The `bridge` binary

First install and start the required Bridge daemon:

```sh
brew install hrishikeshs/tap/bridge
# Or, with a current Go toolchain:
# go install github.com/hrishikeshs/bridge@latest

bridge install-daemon
bridge expose
bridge pair
```

`bridge expose` and `bridge pair` are needed only for phone access. Bridge may
also remain local to `127.0.0.1`. The daemon writes `~/.bridge/daemon.json`;
`magnus-bridge-mode` reads that lockfile and fails clearly when it is absent.

Then install this Emacs package from MELPA when its recipe lands, or put this
checkout on `load-path` during development.

## Use

Enable the global adapter:

```text
M-x magnus-bridge-mode
```

Or from Emacs Lisp:

```elisp
(require 'magnus-bridge)
(magnus-bridge-mode 1)
```

Run `M-x magnus-bridge-status` to see the lease age, hosted-agent count, and
number of deliveries typed during this connection. Disable
`magnus-bridge-mode` to disconnect Emacs; the shared Bridge daemon and any
agents it hosts elsewhere keep running.

Pairing, tailnet exposure, daemon supervision, and emergency lockdown remain
Bridge responsibilities:

```sh
bridge pair
bridge expose
bridge install-daemon
bridge lockdown
```

## Safety properties

- The daemon lockfile token authenticates every localhost request.
- A generation guard makes callbacks from expired leases harmless.
- Messages are acknowledged only after successful terminal delivery.
- Delivery IDs are deduplicated between typing and acknowledgement.
- Text is never typed while Magnus reports an open permission dialog.
- Approval keys are checked against a small whitelist on both sides.
- Daemon restarts heal through lockfile re-reading and bounded backoff.
- Every string crossing `url.el` is explicitly UTF-8 unibyte.

These complement Bridge's durable mailboxes, prompt judge, identity model,
audit log, paired-device tokens, and tailnet boundary.

## Provider boundary

The current adapter hosts Claude Code agents over Bridge's terminal transport
v1. Magnus-owned Codex sessions are intentionally skipped: their rollout and
approval semantics are not Claude's, and a second semantic client would
duplicate ownership of the native Codex TUI.

Use `bridge codex` for Bridge-owned semantic Codex sessions.

## Development

```sh
make test         # focused ERT suite, no daemon or vterm required
make compile      # byte-compile with warnings as errors
make checkdoc
make integration  # scratch Bridge daemon + simulated Magnus agent
```

The integration test builds the sibling `../bridge` checkout into a temporary
directory, uses a throwaway home and random local port, and cleans up every
process it starts.

## License

MIT.

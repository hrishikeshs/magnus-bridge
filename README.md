# magnus-bridge

**Chat with your [Magnus](https://github.com/hrishikeshs/magnus) agents from your phone.**

magnus-bridge runs a small HTTP server *inside Emacs* serving a chat PWA.
Exposed over [Tailscale](https://tailscale.com), it gives you a messaging
interface to your Claude Code crew from anywhere — with no third party
between your thumb and your agents.

- 💬 **Chat** — message any agent; replies (`@you` mentions in the
  coordination Log) land on your phone, threaded per agent
- 🔔 **Attention** — when an agent hits a permission prompt, you get a card
  with the prompt text and tappable keys (1 / 2 / 3 / esc) to unblock it
- 📊 **Roster** — live agent list with health (ok / stale / stuck / dead)
- 🔒 **No intermediary** — traffic never leaves your tailnet; WireGuard is
  the perimeter

## Install

```
M-x package-install RET magnus-bridge
```

You also need [Tailscale](https://tailscale.com/download) on your Mac/PC
and your phone (free for personal use).

## Setup (once)

```
M-x magnus-bridge-start            ;; server on 127.0.0.1:8377
M-x magnus-bridge-setup-tailscale  ;; tailnet-only HTTPS via `tailscale serve`
M-x magnus-bridge-pair             ;; one-time pairing code
```

Open the printed `https://…ts.net` URL on your phone, enter the pairing
code, then **Share → Add to Home Screen**. Done — your crew is in your
pocket.

Add to `init.el` to start with Emacs:

```elisp
(with-eval-after-load 'magnus (magnus-bridge-start))
```

## Security model

Messages from this bridge become *prompts* to Claude Code agents on your
machine, so it is built with defense in depth:

1. The server binds **127.0.0.1 only** — reachable solely through
   `tailscale serve`, which stays tailnet-only (never Funnel).
2. Requests must carry the **Tailscale identity header**; restrict to
   yourself with `(setq magnus-bridge-allowed-logins '("you@example.com"))`.
3. The API requires a **per-device token**, obtained via a one-time
   pairing code that is only ever displayed inside Emacs (2-minute
   expiry, single use). Tokens persist in a `0600` file.
4. The approve endpoint delivers **only whitelisted keys** (`1 2 3 y n
   esc`), and only to agents that Magnus attention flagged as waiting.
5. Everything a phone message triggers still passes through **Claude
   Code's own permission system** — the bridge extends the
   human-in-the-loop, it never removes it.
6. Every request is **audit-logged** (`M-x magnus-bridge-audit`).
7. `M-x magnus-bridge-lockdown` kills the server and revokes every
   device token in one command.

## For transport hackers

The PWA is just the first client. The REST + SSE API
(`/api/status`, `/api/send`, `/api/approve`, `/api/events`,
`/api/history`) accepts `Authorization: Bearer <token>`, so a Telegram,
Signal, or Matrix adapter is ~100 lines against the same surface.

## Commands

| Command | |
|---|---|
| `magnus-bridge-start` / `-stop` | start/stop the server |
| `magnus-bridge-setup-tailscale` | expose on your tailnet, print URL |
| `magnus-bridge-pair` | one-time device pairing code |
| `magnus-bridge-revoke-all-devices` | de-pair everything |
| `magnus-bridge-lockdown` | emergency stop + revoke |
| `magnus-bridge-audit` | open the audit log |

## License

GPL-3.0-or-later, like Magnus.

# The server and its web view

What `mirai kai serve` (and the headless `mirai-kai serve`) runs, `kai/hub`, and how it is
deployed. Its options are `hub.SERVE_USAGE`.

## The server

- An always-on [agent](sync.md#the-agent) that is a `Node` of each org it hosts: either joined by
  `--join <invite>` (repeatable, from a `--role node` invite) or self-registered over Noise by any
  org admin (`agent_server_attach` via `Server_Info` + `Org_Register`, zero SSH required). The
  server checks the admin's signature chain and that its own key is listed as `Node`, creates
  `orgs/<org hex>` and immediately syncs all repositories and derived data of the org.
  `--max-orgs` (default `MAX_ORGS_DEFAULT` = 64; `0` disables self-registration) bounds how many
  orgs admins may register. `--public host:port` is the address the org lists for the server.
- Offline invites: admins of a hosted org can register 1-use `Invite_Grant` vouchers on the server
  (`Invite_Grant`, cleared by `Invite_Revoke`), which invitees redeem while the admin is offline
  into verified `(Invite_Grant, Invite_Claim)` admissions ([invites](org.md#invites)). The server
  still signs no org record and cannot forge membership.
- Under `--root` (`kai-server` by default; `mirai kai serve --store S` uses that store's folder):
  `server/` is its own store (its device key and web accounts) and each org lives in a store of
  its own, `orgs/<org hex>` (`kai.Tenants`), so a server that keeps the orgs of several customers
  never mixes their objects, refs or quota.
- `--ddc-quota <bytes>` bounds the derived data of each org: every `DDC_SWEEP_SECONDS` the oldest
  records past it go (`ddc_quota`) and the org's store is swept with what `store_live` names.
- The server is trusted as a Git host is: it holds the repositories in the clear and its web view
  decides what each account sees. As a `Node` it signs no record of an org.
- It does not ask a router for a port: a server has a public address, or a port forwarded to it.
  Idle HTTP client threads slice their receive timeout (`50 ms`) so `hub_stop` wakes and stops
  promptly on every OS, including Windows Winsock.

## The web view

- Plain HTTP/1.1 on `127.0.0.1:7351` (`--http`), meant to sit behind a reverse proxy that gives it
  TLS (Caddy, Cloudflare, nginx); a session cookie is `Secure` when the proxy says
  `X-Forwarded-Proto: https`.
- Pages are made on the server as HTML with no script; every answer carries a policy of no script,
  no third party and no framing (`SECURITY_HEADERS`). The routes: `/` (the account's orgs and
  every public repository), `/login` and `/logout`, `/<org>` (its repositories and, for members,
  who is in it), `/<org>/<repo>` (shared bookmarks and the history of main),
  `/<org>/<repo>/c/<rev>` (a change and the files it changed) and `/<org>/<repo>/t/<rev>/<path>` (a
  folder or a text file of a change).
- A public repository shows to anyone; a private one and the org's members only to a member. A
  page shows only a revision a shared bookmark of that repository reaches (`reaches`), so an
  address of another repository or org gets nothing.
- The request parser (`kai/hub/http.odin`) has no I/O and bounds the head, the headers, the target
  and the body; it refuses rather than guesses what two readers of one stream could read apart:
  any `Transfer-Encoding`, more than one `Content-Length`, a body on a GET, folded headers and bare
  line breaks (`hub_http_refuses_hostile_requests`).

## Web accounts

- A member sets its sign-in from its device: `mirai kai web-login <server host:port> <name>`
  (`kai.web_login` in the editor, `agent_web_login`), over the agent's authenticated connection.
  The dial expects the key of the org's server (the `Node` whose address is that, else the one
  server its orgs list), so the password reaches no other machine, and gives up after
  `WEB_LOGIN_SECONDS`.
  The server keeps the name, the Argon2id of the password (OWASP parameters) and that device's key
  under `kai-web` refs of its own store; a name belongs to the device that set it first, and
  setting it again from that device changes the password.
- A signed-in account sees what its device's role in each org lets it see. A session is a random
  token in a cookie kept in memory for `SESSION_HOURS`: a restart signs everyone out.
- Why no passkeys and no signing in the browser: the server is trusted with the repositories
  anyway, so a password set from an authenticated device gives the same guarantee with no script
  on the page.

## Deployment

- The target is a small Linux machine with a public address: a VM at a cloud provider or a
  Raspberry Pi, running one static executable under `systemd`. `mirai build kai --target
  linux_arm64` builds `bin/mirai-kai-linux-arm64` from any system that has `ld.lld` (`brew install
  lld`, `apt install lld`): Odin's objects for the target linked statically against a pinned,
  prebuilt musl and the compiler's builtins, which `mirai` downloads and checks by hash. The result
  has no dynamic loader and needs nothing installed. A release attaches the same executable.
- The [store](../../mirai-store/SKILL.md) maps its packs and holds file locks, which need a local
  ext4 or xfs volume, not overlayfs or a network filesystem.
- Ports: TCP 7350 (`--port`) open to the internet for the org's machines; the web view stays on
  loopback behind the proxy, which listens on 443.
- A unit, as an unprivileged user, and a Caddy site in front of it:

```ini
[Unit]
Description=Kai server
After=network-online.target
Wants=network-online.target

[Service]
User=kai
ExecStart=/opt/kai/mirai-kai-linux-arm64 serve --root /var/lib/kai \
  --public kai.example.com:7350 --ddc-quota 50000000000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```text
kai.example.com {
    reverse_proxy 127.0.0.1:7351
}
```

- Org admins attach straight from the editor (new orgs auto-attach to the default server; existing
  orgs offer Sync to server) or `kai.org` with `attach`. Manual joining is still available by
  running the `ExecStart` line once with `--join <invite>` added, stopping it once it prints
  `joined org`, and starting the unit.

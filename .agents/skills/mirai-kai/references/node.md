# The node and KaiHub

`mirai kai serve` is an always-on machine of an org: a relay, a seed and, optionally, a derived data
cache, with a web view of the projects it serves. The code is `kai/hub/` (`serve.odin`, `hub.odin`,
`server.odin`, `http.odin`, `auth.odin`, `api.odin`, `views.odin`, `members.odin`, `writes.odin`,
`certs.odin`, `sandbox_linux.odin`), its frontend `kai/hub/web/` and `tools/kai`. A node is
optional: an org with no node works on a LAN and between machines that can reach each other.

## The node

- A node is a Kai machine like any other (its own device keys, its own store) that runs only a
  runner and, with a web port, a hub. `mirai kai serve` and the headless `mirai-kai` run the same
  procedure (`serve_command`), so what one does the other does; `tools/kai` imports `kai/hub` alone
  so that it links without SDL, the GPU, audio or the editor.
- `--mode relay` holds the org's logs and runs rendezvous and relay only; `--mode seed` adds the
  full closures, anonymous read of public projects and the web view; `--mode seed+ddc` adds the
  derived data cache with `--ddc-quota`. A relay has no web view because it holds no projects. What
  a mode does in the mesh is in [nodes](mesh.md#nodes).
- A node serves the orgs whose log names it with `Node_Add`. A new node serves none: it prints the
  command that pairs it, an admin runs `mirai kai pair offer node --org <org> --modes ...` and the
  node runs `mirai-kai pair join <ticket> --store <folder>` while it serves, and the same eight
  digits are compared ([pairing](identity.md#pairing)). A node no address of the ticket reaches
  (the admin is behind a router) is offered `--at` its public address.
- A node signs nothing for a user, holds no org key and no scope key. Everything it keeps is what
  members and the mesh already hold, plus the keys of its own device and its web certificates, in
  its store's folder, owner-only ([confinement](#confinement)).

## Hosted orgs

- A node with a web view is open: a user born there makes orgs of its own and the node serves them
  ([making an org](#sign-in-and-writes)). Such an org is **hosted**; one the node's operator paired
  it into (`pair join` run on the node's machine) is the operator's. The node marks a hosted org in
  its machine's namespace, with the user who made it, when it keeps the org's genesis; nothing in
  the org's logs tells the two apart, so no member can turn one into the other.
- The node keeps and serves no derived data of a hosted org, whatever its `Node_Add` says: no DDC
  record is fetched or exposed, and the web view shows no previews of its assets. An operator's org
  gets derived data when the node's mode has it.
- What the node holds of a hosted org (its logs, the closures its refs reach and its overlays'
  ciphertext: the org's members' set) is bounded by `HOSTED_QUOTA`, or `serve --hosted-quota`.
  Once reached the node takes no new object of the org, only its own log and the users' logs, and
  every Welcome it answers a member's device with says so; that machine says the node's storage for
  the org is full and to move the org to a node of its own (`hosted_full_text`). The org's machines
  keep syncing among themselves and the relay goes on
  (`a_hosted_org_keeps_no_derived_data_and_stops_at_its_bound`). An operator's org has no bound.
- A user makes at most `HOSTED_ORGS` orgs on a node, or `serve --hosted-orgs`; `--hosted-orgs 0`
  makes none and the web view does not offer it. Private projects and scopes are allowed in a hosted
  org and count toward its bound.

## Deployment

- The target is a small `linux_arm64` machine: a VM at a cloud provider or a Raspberry Pi, running
  one static executable under `systemd`. `mirai build kai --target linux_arm64` builds
  `bin/mirai-kai-linux-arm64` from any system that has `ld.lld` (`brew install lld`, `apt install
  lld`). Odin's `core:os` needs a C library on Linux and Odin does not link a Linux target from
  another system, so the build compiles to objects and links them statically against a pinned,
  prebuilt musl and the compiler's builtins (compiler-rt, which musl's long-double formatting
  calls), both of which `mirai` downloads and checks by hash. The result has no dynamic loader and
  needs nothing installed on the machine.
- Why a VM and a real filesystem: rendezvous and relays need a stable public address without
  container bridge NAT overhead, and the [store](../../mirai-store/SKILL.md) maps its packs,
  flushes and keeps process leases, which need a local ext4 or xfs volume and not overlayfs or a
  network filesystem.
- A unit that runs a seed with the web view, as an unprivileged user:

```ini
[Unit]
Description=Kai node
After=network-online.target
Wants=network-online.target

[Service]
User=kai
ExecStart=/opt/kai/mirai-kai-linux-arm64 serve --mode seed+ddc --store /var/lib/kai \
  --domain kai.example.com --ddc-quota 50G
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

- Ports: UDP `--port` (47914 by default) for peers, and TCP 443 for the web view, ACME's validation
  and the relay over TCP, which share the port. `--domain` makes the hub order a certificate by
  TLS-ALPN-01 for those names on that port ([ACME](tls.md#acme)), so the port must be reachable from
  the internet and the name must point at the machine. `--https PORT` moves the web view (the relay
  over TCP then listens on 443 by itself) and `--http PORT` serves plain HTTP on loopback only, for
  tests, never for passkeys.
- On Linux the node confines itself once its sockets are open ([confinement](#confinement)) and
  refuses to start if the kernel cannot, unless it is told `--no-sandbox`: an unconfined node is a
  decision someone made, never a default.
- An OCI image is supported only as `FROM scratch`, the one binary, `--network host` and a volume
  bind-mounted from the host; there is no distribution inside it and no orchestrator around it. The
  host network is what keeps the real source addresses that hole punching needs.
- The headless build and run is `headless_arm64_server_builds_and_serves_public_and_member_views`:
  it checks the executable is static aarch64 and, where a linux/arm64 runtime exists, serves a store
  over HTTPS with a certificate of a local authority.

## The API

- The routes are one table (`kai/hub/api.odin`) that both dispatches and describes: `GET /api`
  answers with every route, its access, params and result, so this document does not list them and a
  client never reads a document instead of asking. Ids are lowercase hex and bytes in bodies are
  base64url.
- A route is `public`, `session` or `member`. A private project answers 404 to everyone but a
  session of a member of its org, the same 404 as a project that does not exist, so a name leaks
  nothing. A path a scope of the org takes is left out of every listing.
- Public reads are the projects, an overview with README, trees, files, changes, one change, the
  line diff of a file between two revisions (`std/diff`) and the evolution of a change, over what
  the shared bookmarks reach. A member also reads the bookmarks of every device and the proposals'
  revisions there. Member reads are stacks, proposals with their comments and verdicts, the org's
  roster and the derived data dashboard (hits, misses, keys with more than one output). The routes
  for the node's own state are read by any member of an org it serves.
- A route answers only what the mesh would serve the caller in its class
  ([access](mesh.md#who-reads-what)): anyone but a member of the project's org what the public
  closure holds, a member what its org's set holds. A ref or a proposal that names another org's
  change, or its address in a route, gets 404; the check reads the agent's sets and walks nothing.
- A POST is JSON from this origin only (a page of another origin cannot post a form), and reads
  carry the cookie only on this site. Every answer carries headers that allow only what the origin
  serves (no third party, no framing); a file of a repository is shown and never run, with a sandbox
  policy of its own, as text or as an attachment.
- Everything is bounded: the HTTP parser has no I/O and refuses what two readers of one stream could
  take differently (any `Transfer-Encoding`, two lengths, a body on a GET, folded or bare-line-break
  headers); connections, per-address connections, sessions, challenges, approvals and request rates
  per address have fixed tables, and the connections with their buffers and TLS are a pool made at
  start, so serving allocates nothing per connection or record; deadlines end a slow or idle
  connection. An error is `{error}` with
  what failed and how to fix it (`hub_http_refuses_hostile_requests`).
- A read takes prepared state: the hub keeps the folds of each org's proposals and the bookmarks
  of its projects, made again when the agent folds its logs (and, for refs and objects that came,
  at most once per step of the hub), so a flood of anonymous requests costs parsing and lookups.
- `hub_api_describes_every_route` checks that what `GET /api` describes is what the table
  dispatches.

## Sign in and writes

- There is no account: a person is a user log and a browser's key is a passkey the log records. A
  read session is a random token in a `__Host-` cookie (HttpOnly, Secure, SameSite=Strict); it
  reads, and a write still needs a signature of the user's own.
- A passkey signs in over a challenge the server gave and used once. A user who has no log makes one
  in the browser from its passkey alone: the passkey signs the `Passkey_Genesis` the page built,
  and the page generates no key, so the node never holds a recovery or device key of it. One
  passkey makes one user on a node.
- A user nobody admitted waits on the node that made it, under `kai-local-waiting`, which no peer
  is served: it is not among the user logs peers sync and counts against no org's logs. When a
  member adds it (`Member_Add`), or it makes an org here, its log joins the synced ones; past
  `WAITING_MAX` waiting users the oldest goes, and the create route is rate-limited per address. A
  waiting user signs in: it links its first machine, and makes an org or waits for an admin.
- A passkey-born user links its first device from the browser: the page asks a link
  (`POST /api/approvals`, kind device), `mirai kai web approve <link>` on the machine offers its
  keys and proof and waits, both show the same eight digits, and the passkey signs the
  `Device_Add` the page built from the offer. The machine then takes the user's log and becomes its
  device, sets the user's first recovery key at once, shows it there once and sends the node the
  signed entry alone (`POST /api/users/{user}/entries`); the page waits for it.
- **Making an org.** Until the user has a recovery key the page says what is missing and how to
  get it, and the node refuses an org's genesis with the same text ([keys](identity.md#keys)).
  Then the passkey signs the org's genesis and the `Node_Add` of this node (relay and seed, its
  keys and addresses as `GET /api/node` gives them: the domain's at the UDP port, or the
  interfaces'), and the node hosts the org at once ([hosted orgs](#hosted-orgs)). A project is a
  `Project_Genesis` and the org's `Project_Add`, born empty: its files always come from a machine.
- **A machine on such an org.** `mirai kai web join <origin>` on a device of the user signs it in
  to the node by its device key (`POST /api/session/device`, the signature of an approved login),
  reads the user's orgs there and takes the log of each this machine lacks; the org's `Node_Add`
  tells its agent where the node listens, with no LAN between them. Then `mirai kai init`
  makes a workspace of a project.
- A browser with no passkey, or a second passkey for an existing user, asks a device of the user to
  approve: it shows a link and `mirai kai web approve <link>` on that device shows what it would
  sign and signs it only after a yes.
- A write is a log entry. The server drafts the unsigned bytes (heads, author and org contexts,
  time) and gives **no challenge**; the page parses them as `entry.js` lays an
  entry out, checks every field against what the user asked and signs the BLAKE3 of the
  bytes with its passkey (or a device does). The server verifies it as every peer will, appends
  it and tells the peers. This is why a compromised or malicious node cannot make a user say
  something: it can refuse to relay, never forge.
- A passkey signs a write only with the user verified (PIN or biometric), and a P-256 write keeps
  the low `S` of its signature, so a signature and therefore an entry has one encoding and one
  address.
- `webauthn_login_and_signed_verdict_verify_offline` and `hub_serves_public_and_member_views` cover
  both paths. A recovery key, once more, never crosses the API.

## The frontend

- `kai/hub/web` is embedded at build time and served flat with `Cache-Control: no-cache` and a
  strong `ETag` (`304 Not Modified` on match); names starting with a dot are refused and a path with
  no dot that names no file gets `index.html`. It is ES modules with no framework, no third-party
  code and no build step, styled in Mirai's light-mode palette (`#7050f0` accent, Inter and
  JetBrains Mono, sidebar app shell and `⌘K` search).
- Views are `html` tagged templates (`web/dom.js`): values become text nodes, attributes, properties
  or listeners, never markup. `web/markdown.js` renders Markdown (http/https/relative links only),
  `web/highlight.js` tokenizes code and `web/diffs.js` renders unified/split diffs with word-level
  highlights, file trees and inline comments without `innerHTML`. Refreshes preserve loaded views
  and scroll position; large files paginate by 2,000 lines; failed actions surface via toast.
- The pure modules (`blake3.js`, `entry.js`, `preview.js`, `markdown.js`, `highlight.js`,
  `diffs.js`) are tested against the node's binary layout and safety rules by
  `hub_web_modules_agree_with_the_node` under `node` (fails if `node` is absent).
- Views: project overview, tree, file (with [previews](#previews)), changes, diff and revision
  history; for members: stacks, proposals (with inline review, verdicts and browser landing via
  signed `bookmark_move` + `proposal_land`), orgs and server status. Zero third-party requests.

## Previews

- The node never reads an asset. What the web view shows of one, its summary, its thumbnail and
  the detail of what a change did to it, is derived data a peer that reads the file published
  (`kai/preview.odin`, made in `cook/kai/preview.odin`), keyed by the file's content address, or
  the two of a change, and `PREVIEW_VERSION`. The node serves what `preview_check` takes, bounded,
  and nothing else; the frontend decodes the records in `web/preview.js`.
- The machine that publishes a bookmark of an org's project publishes them for the assets the
  changes it newly reaches touched, a bounded walk: summaries and details always, thumbnails only
  those the editor stores of exactly those bytes. Nothing renders for the web; a missing one is
  absent in the view.
- A preview route reaches its file as the file route does. A file a scope takes gets none: it is
  never published, and a record that names tainted scopes is not shown. A seed without ddc fetches
  a record's output when a browser asks for it; a ddc node mirrors it.

## Confinement

- On Linux, after its sockets are open and its secrets read, the node applies Landlock and a
  seccomp filter. It reads its store's root, where the device's keys and the ACME account key are
  files, and writes only in the folders directly in it as they are when the sandbox applies: the
  store's own and `kai-web`. It reads the files its DNS resolver reads, binds and connects TCP only
  on the ports it uses and makes only the system calls it makes.
- No key is reachable for writing once the node is confined but the certificate's key and chain in
  `kai-web`, which a renewal must keep. The control file the agent leaves at the root when it stops
  is harmless: a client takes the agent's lock before it reads the file.
- `mmap` and `mprotect` map nothing executable, signals go to the node's own threads, `clone` makes
  only a thread of the process (the flags musl's `pthread_create` gives), `clone3` fails with
  `ENOSYS` so a C library falls back to `clone`, the node makes no `ioctl`, and any other call (or
  another architecture's) fails with `EPERM`. A kernel without Landlock or seccomp makes `serve`
  refuse and say why.
- The filter is tested to refuse what the node does not do
  (`hub_seccomp_program_refuses_what_the_node_does_not_do`). Elsewhere a node runs as it is: only
  Linux confines.

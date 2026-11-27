# Sync: the handshake, the wire and the agent

How the machines of an org reach each other and pull what they lack (`kai/noise.odin`,
`kai/wire.odin`, `kai/agent.odin`, `kai/ddc.odin`, `cook/kai/mesh.odin`), and why. Everything is
Odin on `core:crypto` and `core:net`: no C library, no HTTP and no UDP transport of `mirai:net` in
a sync; `mirai:net` gives only the
[port mapping](../../mirai-networking/references/port-mapping.md).

## The handshake

- Noise NNhfs (the KEM extension for hybrid forward secrecy) with X25519 and ML-KEM-768,
  ChaChaPoly and SHA-256 (`NOISE_PROTOCOL`), prologue `kai/2`:
  `-> e, e1`; `<- e, ee, ekem1` with the responder's key and its signature of the handshake hash;
  `->` the initiator's key, its signature and an invite proof (zero when it joins by none).
- The session keys come from both the X25519 and the ML-KEM secret, so a recording of the stream
  stays closed unless both break. Each end proves its Ed25519 device key by signing the hash at
  that point: a man in the middle holds two hashes and no signature of either side over its own.
- The dialing end names the key it expects (`conn_dial`'s `expect`): a member's, or an invite's
  inviter; another key ends the connection. The answering end learns the initiator's key and
  decides by the org records what it may read.
- Why not TLS or a Noise pattern with static DH keys: the device key is the Ed25519 key that signs
  every record, so one key per device suffices and no certificate authority is involved; NN with a
  signature over the hash gives mutual authentication with that key alone.

## The wire

- One TCP stream per pair of machines, the same on a LAN and to a server, on `KAI_PORT` (7350;
  any free port when it is taken), so the kernel's congestion control runs at the link's speed.
  `socket_tune` sets no delay, large buffers and `SEND_SECONDS`: a peer that takes nothing for
  that long ends its connection. A dial gives up after `DIAL_SECONDS` or when the agent stops; the
  handshake, after `HANDSHAKE_SECONDS`. Its keys live on the stack of `conn_dial` and
  `conn_accept` and are zeroed before they return; a connection keeps only its session ciphers
  and the invite proof. A failed handshake leaves the accepted socket to its caller.
- The three handshake messages have fixed sizes, so neither end reads a length it did not
  authenticate. Every frame after them is a u32 little-endian length and one ChaChaPoly-sealed
  message of at most `FRAME_MAX`, its `Msg` kind first. A length past its bound, a frame that does
  not open or a message that does not parse ends the connection.
- Messages: `Hello` (names, listening port and the heads this end holds), `Tell` (heads that
  moved: an org record, a verified offline admission, a repository's `Repo_Refs` or a derived data
  set), `Want` (up to `WANT_MAX` chunk addresses of an org), `Chunks` (the chunks asked, in order,
  as the store keeps them, up to `FRAME_FILL`), `Lack`, `Ddc_Ask`, `Join` (with optional signed
  `Invite_Claim`) and `Welcome` (org head and optional `Admission` address,
  [invites](org.md#invites)), first-message control RPCs (`Web_Login`, `Server_Info`,
  `Org_Register`, `Invite_Grant`, `Invite_Revoke`) and `Bye` with why. A peer that keeps more than
  `REQUESTS_BYTES_MAX` of wants and asks waiting, or tells of more than `TOLD_MAX` heads, ends its
  connection.
- Of two connections between the same keys, both ends keep the one whose dialing end has the
  lower key (`peer_unique`).

## The agent

- One agent per machine, in the process that holds the store: the editor (once the machine is in
  an org), `mirai kai agent`, or `mirai kai serve`. `mirai kai join`, `pull` and `web-login` start
  one for their run that listens nowhere. The editor reads its peers, pulls and events under its
  lock, never over a socket, and reads them again only when `agent_generation` moved.
- It listens on TCP, says on the LAN where (`agent_beacon_run`), and dials every member of its
  orgs it knows an address of (`agent_dial_members`): one thread per member tries its addresses
  in turn, at most every `REDIAL_SECONDS`; a peer of the options goes by its address.
  `agent_stop` waits for every dial, and a caller that holds a peer (a join, an ask) holds it
  against the reaper (`peer_pin`).
- Each connection has three threads: the reader takes every message and stores the chunks a fetch
  asked, checked against their address before the store keeps them; the server answers `Want`s;
  the puller fetches what the other end told it holds.
- The puller takes, in order: newer org records (back to one held, [org record](org.md)), newer
  shared bookmarks, then every chunk that what they reach lacks here, for the repositories this
  machine keeps: those a workspace links, or all of them on a node. A pull walks a level of the
  trees at a time (`walk_missing`) with up to `FETCH_WINDOW` chunks in flight; a fetch with nothing
  answered for `FETCH_SECONDS` gives up on that peer.
- A pull is whole only when every chunk of every object it reaches is here (`object_whole`, with
  `whole` in the walk of `kai/reach.odin`), never when a root alone is: a pull cut midway never
  reads as complete (`a_closure_is_whole_only_when_every_chunk_is_here`).
- A head this process wrote reaches the peers at once (`agent_changed`), which also wakes dials
  for newly discovered members; one another process of the machine wrote reaches them within
  `LOOK_SECONDS`. `agent_sync_now` clears dial throttling and forces an immediate sync pass.
  `agent_join` and `agent_admit` save the peer's dialed or listening address (`team_peer_seen`)
  after membership holds so peers reconnect across restarts without beacons. Nothing else polls.

## Who reads what

- A peer is served the heads of the orgs whose member its key is (`agent_heads`) and the chunks of
  those orgs, asked by address in the org's store. A `Want` for an org it is no member of ends the
  connection.
- On a server each org has its own store ([server](server.md#the-server)), so an address of
  another org is never there to serve.
- A peer takes from another only what that one's role lets it sign: org versions by the rules of
  [the record](org.md#the-org-record), shared bookmarks and derived data from writers.

## How machines reach each other

- On a LAN: the beacon, a plain UDP datagram (`BEACON_MAGIC`, the key and the port) every
  `BEACON_SECONDS` on the broadcast of each IPv4 network, also on `KAI_PORT`. A beacon proves
  nothing: whoever it names proves its key in the handshake.
- Across networks: the addresses a peer was last reached at, the address the org lists for a
  member (a server's), and the `peers` of `Agent_Options`. The editor and `mirai kai agent` (without
  `--public`) ask the router to forward their TCP port with PCP, NAT-PMP or UPnP (`net`'s
  `Port_Mapping` with `.TCP`); `agent_addresses` then lists the router's address first, which an
  invite carries. A UPnP mapping the router already forwards to this machine serves and is never
  deleted. `agent_reach` says Local, Connecting or Online; an invite made while the router has not
  answered waits for it up to 1.5 s (`agent_reach_wait`), and the views move when it does.
- Without a router that maps and without a server, a machine on another network is reached only
  at a host:port someone forwarded (`--at` of an invite). A central server (`DEFAULT_SERVER`,
  overridden or disabled with `MIRAI_KAI_SERVER=""`) is the usual way.

## Pulls

- Measured on loopback, dev build: 113 MB in 1000 files pulled in 0.627 s, about 180 MB/s
  (`a_pull_over_loopback_runs_at_tcp_speed` with `KAI_BENCH_MB=113`), where the UDP mesh it
  replaced moved about 1.5 MB/s.
- `agent_pulls` and zero-alloc `agent_pull_of` give per repository the chunks and bytes that
  arrived, those left and whether it is whole: what `mirai kai pull`, the launcher and `kai.peers`
  show.

## Derived data

- A writer publishes what an import or a cook built as a signed `DDC_Record` under
  `kai-ddc-<org hex>/<key hex>`: the key is the hash of the cache ref, and the record names a
  `DDC_Output` that lists every object the result consists of, the cache ref's first. Kai moves,
  keeps and serves a result whole without reading what it is. Two records of one key with
  different outputs are both kept: the build is not deterministic.
- `ddc_accept` keeps only records signed by a writer of the org now. A node keeps every set a
  writer tells it (`agent_ddc_published`) and drops the oldest past `--ddc-quota`
  (`ddc_quota`).
- `cook/kai`'s `peers_open` is what a project's imports and cooks take (`cache.Peers_Open`): when
  the project is a workspace of an org's repository, an agent of the process dials the org's
  members (waiting up to `PEERS_WAIT`), a miss asks them (`agent_ddc_ask`) and takes the output
  whole, and what the cache keeps is published and told to the org's nodes. A build found here
  that the org has no record of is published too, so the builds a project came with reach the
  machines that pull it.

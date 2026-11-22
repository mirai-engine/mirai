# The mesh: runner, peers, nodes and derived data

How the machines of an org find each other and what each may read from the others. The code is
`kai/runner.odin`, `kai/mesh.odin`, `kai/control.odin`, `kai/beacon.odin`, `kai/relay.odin`,
`kai/tcp.odin`, `kai/node.odin` and `kai/refs_ddc.odin`; the transport under it is
[net](../../mirai-networking/SKILL.md) and the sync is
[exchange](../../mirai-store/references/exchange.md#what-the-owner-calls).

## The runner

- One **runner** per machine and store holds one UDP socket and one agent per org the machine
  serves. A datagram's first byte says what it is (a net datagram for an org's server or client
  host, a relay envelope, a rendezvous message, a beacon, a pairing message or a request of a local
  process), and an org's datagrams carry a route made from a hash of its id, so one socket and one
  port serve every org. A hostile datagram is dropped, never answered
  (`runner_refuses_hostile_datagrams`).
- An agent is one identity host others connect to, client hosts for the connections it makes, and
  one `exchange` over all of them. A connection presents the org's id as its claim, and `authorize`
  decides who it is from the org's logs ([access](#who-reads-what)); when the logs change it runs
  again, so a peer not admitted yet becomes a member as soon as it has the log entries that admit
  it, and a removed one is disconnected with `Revoked`. An agent that closes tells its peers, so
  they ask others at once (`a_closed_agent_leaves_its_peers_at_once`).
- One thread touches a runner and its agents: the exchange has no worker, so what it serves and
  what peers ask run on that thread too. The runner's own machine tells it of a write directly, so
  only that thread writes through it; any other thread or process writes through a machine of its
  own, which tells the runner through its control.
- The runner is owned by the editor while it is open (in a thread of its own), by `mirai kai agent`
  (which exits when idle unless told `--stay`) or by a node. A lock file held for as long as it runs
  keeps it to one runner per store. Others reach it over loopback: it writes an owner-only file with
  its port and a random token, only a user who can read it can ask, and it answers only from
  loopback. Every other process (the CLI, a cook, a second editor) talks to it through that control
  channel.
- Nothing polls. A write of this machine reaches the runner as `Machine.changed`; a ref that moved
  is told to the peers that may read its namespace; on connect each end asks the other's names per
  namespace and fetches a ref that differs. A log's ref names its index: the pages the store lacks
  are fetched in turn, and the log merges by union of verified entries; refs and derived data merge
  by their own rules.
- An agent holds loaded the logs of its org it folds: users, the org, projects, keyrings and open
  proposals, at most `AGENT_LOGS` at once. A closed or landed proposal stays in the store and loads
  when a view or a merge asks for it, until the next fold lets it go; past the bound a log is left
  in the store and counted in `logs_refused`
  (`a_settled_proposal_stays_in_the_store_until_asked_for`).
- When an agent folds a removal that a log it holds a right in lacks a witness of, while the
  affected key signed there, it writes the witness ([folding](identity.md#folding-and-revocation)).
- A seed fetches what the closure of every bookmark lacks. A machine whose peers have not delivered
  a file yet asks the mesh for it: the editor reads again on its poll, a method waits for the bytes.

## Who reads what

A connection is a class: member, node, grant, pending (an identity whose user log is not here yet)
or anonymous (an empty claim). The namespace decides who reads it:

| Namespace | Read by |
| --- | --- |
| `kai-user` | pending, member, node, grant (they prove who is a member) |
| `kai-log` | member, node, grant: org, project, proposal and keyring logs |
| `kai-refs-<project>` | member, node; a grant of read, write or check on it |
| `kai-ddc-<org>` | member, node; a grant of ddc |
| `kai-ovl-<project>-<scope>` | member, node: ciphertext only |

- Chunks are content-addressed and an address is no secret, so every peer is served from a set of
  addresses. A member or a node gets what its org reaches, as far as it is here: the user logs and
  the org's logs, the closures of what its projects' shared bookmarks, device refs and proposals'
  stacks name, the device refs, its overlays' records and ciphertext, and its derived data with
  every object an output lists. Nothing else of the store is served to it: not another org's, a
  repository in no org nor what a cook kept (`a_member_gets_only_what_its_org_reaches`). The set
  is built whole when the agent starts or the org's projects or scopes change, a walk of the
  whole history that reads every node of every object once; a ref that moves adds what it reaches
  down to what the set holds, and an object not here yet joins once it arrives.
- What a restricted peer may fetch is a smaller set made the same way: pending peers get the user
  logs, anonymous ones the closures of public projects, a grant what its scope covers
  ([grants](identity.md#grants)). An address outside the set is not served, whatever the peer asks
  (`anonymous_peer_gets_only_the_public_closure`).
- The public closure is what the shared bookmarks of a public project reach: the moves of its log a
  writer signed and its policy allowed. A device's refs and a proposal's stacks are work in progress
  and stay out of it, and an anonymous peer is listed no ref: it asks by address what the node's
  public view lists.
- A peer that is not a member or a node is restricted: it writes nothing, except a grant holder's
  refs under the write right.
- The local namespaces (`kai-local-*` for a workspace's operations and a node's waiting users, the
  machine's own for its user, orgs and projects) are never exposed to any peer.

## The connection ladder

- A device reaches a peer by rungs, best first, and raced in parallel: a LAN address a beacon gave;
  the global IPv6 and mapped addresses a node passed on; the reflexive address a node saw, with both
  ends punching at once; the node's relay over UDP; the node's relay over TCP when UDP to the node
  is blocked. A connection on a worse rung is replaced when a better one appears.
- The **LAN beacon** is a datagram sent periodically, and at once when `D` changes, on IPv4
  broadcast and the IPv6 link-local multicast of every interface. Its tags are keyed by `D` and
  rotate with time buckets, so to anyone without `D` the beacons of one device in two buckets, or of
  two orgs in one, are unrelated noise, and clocks a few minutes apart still meet. The end that does
  not dial (the higher X25519 key) answers a beacon with its own. There is no mDNS.
- A **relay** node is stateless rendezvous. It sees the reflexive address of a device's datagrams on
  two of its ports, which tells a hard (symmetric) NAT from a cone one so that punching is not tried
  where it cannot work; it tells two cone devices when to punch (the lower key starts) and forwards
  the datagrams of the rest. What it forwards is already sealed end to end: it reads the envelope's
  destination and nothing else, and each sending device draws on its own byte bucket. Rendezvous
  messages are authenticated with a key both ends derive from their X25519 keys.
- The relay over TCP carries what the UDP socket would, as length-prefixed frames after a magic, on
  the node's HTTPS port: no TLS and no HTTP, told apart by the first byte, which a TLS record never
  starts with. A device opens one only when the UDP rungs to the node failed and drops it when the
  node answers over UDP again. A node bounds connections, connections per address, the time to the
  magic and to a whole frame, and the queue per peer; a frame past it is dropped as UDP drops a
  datagram.
- A ticket advertises the loopback first, then LAN and global addresses with the socket's port, so
  two stores of one machine pair even where a firewall holds a new program's incoming traffic. A
  granted port mapping is only a candidate: the handshake confirms the real reach ([port
  mapping](../../mirai-networking/references/port-mapping.md#api-and-lifecycle)).

## Nodes

- A node is the same runner with modes: **relay** (logs and rendezvous only), **seed** (it also
  mirrors the closure of every project and the ciphertext of every overlay, and serves public
  projects to anonymous readers and the [web view](node.md#the-node)) and **ddc** (it also keeps
  derived data). It serves only the orgs whose log names it with `Node_Add`, paired like a member.
- A seed and a relay hold no scope key and never could read a private file: overlays reach them as
  ciphertext and keyrings as wrapped keys. Their disks hold what the mesh already holds.
- The store's sweep follows refs only and not the links inside Kai records, so a node prunes the
  operation logs and names as live what `store_live` names
  ([retention](model.md#operations-and-undo)) and what its agents fetch and hold back.
- A ddc node keeps every key of an org's namespace with every object its outputs list, and drops the
  least recently used keys past its quota (`a_ddc_node_drops_least_used_outputs_past_its_quota`),
  then has the sweep reclaim the bytes. A key a lookup through the node is still fetching is not
  dropped.

## Derived data

- What a cook builds can be taken from a peer. A `DDC_Record` is signed by its producer: the key, an
  `output_root` naming a `DDC_Output` object that lists every object the output consists of (the one
  the key's cache ref names first), and the scopes its inputs taint. Because the output lists its
  own objects, a node mirrors and serves a result whole without reading what it is.
- A record is accepted only from a device of a writer, a node in ddc mode or the holder of a ddc
  grant. Records of one key with different outputs are both kept and flagged nondeterministic: the
  build is not deterministic and the mesh says so instead of choosing.
- A lookup asks the store, then LAN peers, then the rest, and answers `Found` only once every object
  of the output is whole here, or `Missing` after a bounded time. Lookups at once and the uses a
  ddc node remembers have fixed tables: one lookup more is a miss, one use more replaces the
  oldest.
- An output built from private inputs inherits their scopes: it is sealed under the newest epoch of
  every one at once, so only a device that reads them all opens it ([private
  files](private.md#what-a-peer-sees)). It is sealed and opened a chunk at a time, as a private
  file is, so neither holds more than a chunk of it.
- The previews of assets the web view shows are derived data too, published with a bookmark
  ([previews](node.md#previews)).
- The cook is `cook/kai/mesh.odin`: a miss of `cook/cache` asks the machine's runner through its
  control for a record of the project's org and a build publishes its own, with the key the hash of
  the cache ref. With no runner the cook builds alone, which is the same result slower
  (`a_cook_takes_derived_data_a_peer_built`).

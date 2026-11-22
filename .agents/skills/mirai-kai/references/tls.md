# TLS and ACME

`net/tls` is what a node's browsers speak: TLS 1.3 as a state machine without I/O, and an ACME
client that obtains the certificates. It is layer 2, imports `core:` and `std` alone (the crypto and
x509 of `core:crypto`, no C library) and is used by `kai/hub`. Peer traffic between Mirai machines
does not use it: that is [net](../../mirai-networking/SKILL.md)'s own Noise transport.

## TLS 1.3

- The files are `net/tls/tls.odin` (connection, config, errors), `handshake.odin` (messages and
  their vectors), `record.odin` (the record layer and key schedule), `server.odin`, `client.odin`
  and `certificate.odin` (a certificate made and signed with ECDSA P-256, for tests and for the
  challenge of ACME).
- The caller owns every byte and every socket. A connection is handed what the peer sent (`receive`)
  and gives what to send (`pending`, then `sent`); between those it reads and writes application
  data. The same procedures run over a system socket, an in-memory pair in a test and the hub's
  connections, so the protocol is tested without a network.
- A connection takes **one block of memory at creation and allocates nothing after it**. A record is
  decrypted in place in the input buffer and its data waits there until `read` takes it, and
  `receive` takes no more bytes until then nor while the output has no room for an answer (an alert,
  a KeyUpdate). This is what makes a flood of connections a bounded cost and what lets a node serve
  under the memory its sandbox allows.
- Only TLS 1.3, with the three suites of the RFC and the X25519 and P-256 groups: no renegotiation,
  compression, resumption or early data (a server skips a client's early data without reading it),
  and no client certificate is asked. A server presents ECDSA P-256 chains; a client verifies a
  chain against the trust anchors of its config and the host it connects to. A feature that is
  absent is absent on purpose: each one is an attack surface that a node serving a handful of
  browsers does not need.
- A server picks its credential at each ClientHello by the name the client asks for (SNI) and the
  protocol it offers. A credential made for one protocol (the challenge certificate of `acme-tls/1`)
  is presented only to connections that negotiate it, and they get no other, so a validation never
  sees the real certificate and a browser never sees the challenge. The owner of the credential
  slice may replace entries while connections run, because a connection reads one only while it
  answers a ClientHello.
- A hostile peer is bounded: handshake messages and records have maximums, a run of records that
  carry no application data ends the connection, a server that negotiates TLS 1.2 or lower with a
  client that offered 1.3 is told by its `DOWNGRD` random, and a key protects a bounded number of
  records before KeyUpdate. Every failure maps to the alert the RFC names and ends the connection;
  none panics (`tls13_refuses_hostile_and_downgraded_input`).
- Conformance is checked by `tls13_known_answer_vectors` (the RFC's vectors),
  `tls13_handshake_and_records_round_trip_in_memory` and `tls13_interoperates_with_system_tools`,
  which runs a handshake against the system's TLS client and server and is skipped where they are
  absent.

## ACME

- `acme_order` runs one RFC 8555 order for a set of names to its certificate chain, proving each
  name with TLS-ALPN-01 (RFC 8737): a server that holds only its TLS port presents, to connections
  that negotiate `acme-tls/1`, a self-signed certificate of the name that carries the SHA-256 of the
  challenge's key authorization. Nothing else is opened: no port 80, no DNS record, no file.
- The caller serves the port. `acme_order` takes a `Transport` (a byte stream to a host; the
  system's TCP is `tcp_transport`) and a callback `serve` that it calls while an order waits, so the
  hub keeps answering browsers, relay frames and the directory's validation connection while the
  order is pending: ordering never stalls serving. The hub's transport looks the directory's name
  up on a thread of its own and connects without blocking, stepping the hub while either waits
  (`hub_serves_while_an_acme_order_dials`). The hub presents the challenge credential while
  ACME says so and withdraws it, wiping the copy, before ACME frees it.
- The account key is a P-256 key made once and each order makes a new certificate key; both are kept
  owner-only at the root of the store, beside the device's keys, written whole or not at all and on
  disk before the hub answers. The chain is kept as PEM and loaded again only when it serves every
  domain and is not due.
- A certificate is renewed when a third of its life is left (`renewal_due`). A failed order leaves
  the one served in place and is tried again later; a `Refused` or `Invalid` authorization carries
  the directory's problem text so the log says why (an unreachable port 443 and a name that does not
  point at the machine are the usual ones).
- The directory's own HTTPS is checked against the ISRG roots embedded in `kai/hub`, whatever the
  system trusts: a machine with a stale or tampered root store cannot be sent a forged certificate.
  Another directory (a test's) is given its own roots.
- `acme_orders_a_certificate_by_tls_alpn_from_a_fake_directory` runs a whole order against a fake
  directory; `hub_certificates_live_only_while_served_and_load_back` checks the hub keeps and wipes
  credentials as above.

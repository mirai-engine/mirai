# Automatic UDP port opening

`net/portmap*.odin` obtains a candidate external endpoint for a port the application already has
open. Order: PCP, NAT-PMP and UPnP IGD; a public local IPv4 address is returned as `Direct`. There
is no external service, relay or document transport in this package.

## API and lifecycle

`Port_Mapping` stays at the address where it started until `mapping_close`.

1. `mapping_start` starts a thread; the application keeps its socket for as long as the mapping
   lasts. Optional `gateway` and `discovery_port` set the router and its SSDP port (tests use
   local servers). Without them the IPv4 gateway is discovered with one implementation per system,
   and a UDP socket connected to it gives the local address of the route, without sending traffic
   to an Internet service.
2. `mapping_poll` copies `Port_Mapping_Status` under a mutex, without waiting for the network or
   allocating.
3. `mapping_stop` requests closing without waiting; the thread releases the mapping and publishes
   `Closed`.
4. `mapping_close` requests closing, waits for the thread and destroys its resources. Network work
   checks for cancellation often, and the UPnP release bounds its HTTP requests instead of using
   the system's blocking connection timeout.

`Mapped` means **candidate endpoint**: the router granted a mapping, or the interface had a public
address. It does not prove that a guest can reach it: the application confirms the connection only
with its handshake and treats denials and timeouts as such. `lease_seconds` is the granted
duration, not a countdown. If the router returns another port or changes the endpoint when
renewing, it shows up in the next read.

## Protocols

- **PCP**: MAP UDP v2 with a system nonce and IPv4 addresses mapped to IPv6. Only gateway responses
  that match version, opcode, nonce, protocol and internal port are accepted, with a positive
  lifetime and a non-null external port.
- **NAT-PMP**: public address and UDP mapping; both responses must come from the gateway and
  declare success, and the external port may differ from the requested one. If the mapping arrives
  but the address is lost, it is released before trying UPnP.
- **UPnP IGD**: SSDP multicast, HTTP descriptor and WANIPConnection v1/v2 or WANPPPConnection v1
  service.
  - `GetSpecificPortMappingEntry` checks that the port is free before `AddPortMapping`; if it is
    taken, a few more high ports are tried.
  - The mapping description carries a session identifier: renewing and `DeletePortMapping` only
    operate if local address, internal port and description match, to preserve a mapping another
    process has replaced. Foreign mappings are neither copied nor replaced.
  - A router that returns 725 receives the request again with zero lifetime, as it requires for
    its permanent mappings, which are checked and renewed periodically.
- It renews halfway through the granted lease; a failure retries before expiry and, on expiry, the
  candidate becomes `Unavailable`. PCP and NAT-PMP are released with zero-lifetime datagrams; UPnP,
  with `DeletePortMapping`.

## Bounded readers

The router's datagrams, HTTP and XML are untrusted: requests and responses live in fixed buffers
with size limits. HTTP admits `Content-Length`, a body ended by close and `chunked`, and rejects
other encodings and the combination of chunked and Content-Length. Only numeric HTTP URLs at the
gateway's address are followed, without resolving names or following redirects. TCP sockets are
non-blocking with a deadline per request, and no XML parser with external entities is used.

## Scope and limits

- Discovery and mapping are IPv4: the PCP codec reads an IPv6 external address, but does not
  discover an IPv6 gateway or its scopes.
- Private, loopback, link-local, multicast, CGNAT-shared and the usual reserved blocks are not
  announced as public.
- It does not traverse a second NAT or a CGNAT without router support, does not change the local
  firewall and neither identifies nor authenticates users: that belongs to the application and to
  `net.Host`.
- Loss of the UDP release is covered by retries and by lease expiry; immediate removal is not
  guaranteed. A permanent UPnP mapping whose router does not respond to the close may remain until
  the router removes it.

## Verification

- `mirai test net <test...>` with the `port_mapping_*` tests of `net/portmap_test.odin`: PCP and
  NAT-PMP codecs, UPnP parsers, bounded HTTP and the worker (renewal, release and the PCP →
  NAT-PMP → UPnP fallback), with a local UDP gateway and local SSDP/HTTP/SOAP servers over real
  sockets.
- They do not prove that a specific home router, firewall or connection between networks allows
  entry: that needs a handshake between those networks.

# nettyrpc
 Implements an RPC-like system for Nim

nettyrpc is an RPC library built on top of the netty library, and sends data over a modified UDP connection that's capped at 250kb of in-flight data.  Netty performs packet ordering and packet resending like a TCP connection.  Check the netty library for more information about how netty utilizes UDP, and it's limitations.

nettyrpc can be set up to run authoritative and non-authoritative servers by the use of `{.networked.}` or `{.relayed.}` RPCs. 

A relayed RPC is sent directly to the server, no server-side processing is done and the RPC is sent to every connected client on the server where it is processed client-side.  Relayed RPCs have a `isLocal` bool that can be used to control what the caller runs in a relayed procedure vs what the receivers runs.  Relayed procedures can be called like any other procedure.

Networked RPCs are sent to the server where the server processes the data, and depending on how you write your server code, the server can forward the data to an individual client, all clients, or process the data server-side without any forwarding.  Networked RPCs must be called through the `rpc` procedures provided by nettyrpc.

Both relayed and networked RPCs contain a netty `Connection` object that represents the RPC caller's connection.  This is accessed through the `conn` variable that is automatically added to any `{.relayed.}` or `{.networked.}` procedures.

## Uses

Mostly games, but any networked application that does not require a ton of throughput.  UDP is not designed for throughput, however this library could be used to negotiate a TCP connection for larger data transfers.

## Examples

Check the examples folder in this repo for documented examples.

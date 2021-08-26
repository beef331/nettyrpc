# nettyrpc
 Implements an RPC-like system for Nim

nettyrpc is a RPC module for game development.  nettyrpc is built on top of the netty library, and sends data over a modified UDP connection that's capped at 250k of in-flight data.  Netty performs packet ordering and packet resending like a TCP connection, but it's all done over UDP.  Check the netty library for more information about how netty utilizes UDP, and it's limitations.

https://github.com/treeform/netty

nettyrpc can be set up to run authoritative and non-authoritative servers by the use of `{.networked.}` or `{.relayed.}` procedures. 

A `{.relayed.}` RPC is sent directly to the server, no server-side processing is done and the RPC is sent to every connected client on the server where it is processed client-side.  Relayed RPCs have a `isLocal` bool that can be used to control what the caller runs in a relayed procedure vs what the receivers run.  Unlike `{.networked.}` procedures, relayed procedures can be called like any other procedure.

`{.networked.}` RPCs are sent to the server where the server processes the data, and depending on how you write your server code, the server can forward the data to an individual client, all clients, or process the data server-side without any forwarding.  Networked RPCs must be called through the `rpc` procedures provided by nettyrpc, ie. `rpc("someRemoteProc", (arg1, arg2, arg3))` or `rpc(conn, "someRemoteProc", (arg1, arg2, arg3))`.  It's important that your args are wrapped in a `tuple` when using the `rpc` procedures.  If your `networked` procedure only has 1 argument, you must use a named tuple.

`{.networked.}` RPCs contain [a netty `Connection` object](https://github.com/treeform/netty/blob/master/src/netty.nim#L52) that represents the RPC caller's connection.  This is accessed through the `conn` variable that is automatically added to any `{.networked.}` procedures.  It is important to note that the `Connection` object that is provided to the client-side script will always point back to the server.  The server's `{.networked.}` procedures must pass this information on to clients if the clients need to know which client is responsible for the original remote procedure call.

## Uses

Mostly game developement, but any networked application that does not require a ton of throughput.  UDP is not designed for throughput, however this library could be used to negotiate a TCP connection for larger data transfers.

## Examples

Here is what a typical `{.relayed.}` procedure looks like on the client-side.

```nim
proc send(name, message: string) {.relayed.} =
  if not isLocal:  # If remote client runs procedure
    eraseLine()
    echo fmt"{getClockStr()} {name} says: {message}"
  else:  # If local client runs procedure.
    eraseLine()
    echo fmt"{getClockStr()} You said: {message}"
```

Remember that `{.relayed.}` procedures do not require any server-side RPCs to be defined, so we only need to modify our client's code.

A `{.networked.}` procedure requires us to implement server-side RPCs so the server can process the request and dispatch RPCs manually.

### A Tiny Example

Here is a client with a `{.networked.}` procedure.  It attempts to run the `join` procedure located on the server, and the server then processes the message and calls the `welcome` procedure on all connected clients.

__client.nim__

```nim
import netty, nettyrpc
import std/[strutils, strformat]

# Define our client-side RPC.
proc welcome(name: string, id: int) {.networked.} =
  ## Display a welcome message.
  echo fmt"{id}:{name} has joined the server"

# Set up nettyrpc to run as a client.
let client = newReactor()
nettyrpc.client = client.connect("127.0.0.1", 1999)
nettyrpc.reactor = client

# Call the `join` procedure on the server with an argument 
# representing our name, along with an id.
rpc("join", ("Bobby Bouche", 1))

while true:
  # rpcTick handles calling/sending procedures.  This must be called to send
  # and receive RPCs.
  client.rpcTick()  
```

Here is the server code we need to handle the call to `join`, and then calling the `welcome` procedure on each connected client.  It also sends the same welcome message to the caller of the RPC (to demonstrate direct calling of a RP)

__server.nim__

```nim
import netty, nettyrpc, os

# Define server-side RPC
proc join(name: string, id: int) {.networked.} =
  # Do server side logic, maybe we log the event or something like that.
  rpc("welcome", (name, id))  # Call `welcome` procedure on all connected clients.
  rpc(conn, "welcome", (name, id))  # Call `welcome` procedure on the client that called `join`.


# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)

# Set up nettyrpc as a server.
nettyrpc.reactor = server

# main loop
while true:
  server.rpcTick(server=true)  # rpcTick handles dispatching of procedures. Must be called.
  for msg in server.messages:  # Display messages since last tick.
    echo msg
```

Check the examples folder in this repo for the full documented examples.

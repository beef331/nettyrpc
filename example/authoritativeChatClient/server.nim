import netty, nettyrpc, os

# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)

# Set nettyrpc reactor to server.
nettyrpc.reactor = server


proc join() {.networked.} =
  ## Join server and send client's server-side connection id to caller.
  ## This uses info from the `conn` variable that's added to all networked 
  ## and relayed procedures.
  rpc(conn, "set_client_id", (theClientId: conn.id))


proc send_chat(name: string, msg: string) {.networked.} =
  ## Dispatch chat messages to all connected clients regardless of who sent it.
  rpc("display_chat", (name: name, msg: msg, originId: conn.id))


# main loop
while true:
  server.rpcTick(server=true)  
  for msg in server.messages:  # Display messages since last tick.
    echo msg
  sleep(30)
  
  # rpcTick(server=true) will automatically loop through messages
  # and dispatch/relay RPCs.  It's the equivelant to the following
  # relay code:
  #
  # for msg in server.messages:
  #   for client in server.connections:
  #     if(msg.conn != client):
  #       server.send(client, msg.data)

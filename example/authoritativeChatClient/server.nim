import netty, nettyrpc, os


proc join() {.networked.} =
  ## Join server and send client's server-side connection id to caller.
  ## This uses info from the `conn` variable that's added to all networked 
  ## procedures.
  rpc(conn, "set_client_id", (theClientId: conn.id))


proc send_chat(name: string, msg: string) {.networked.} =
  ## Dispatch chat messages to all connected clients regardless of who sent it.
  rpc("display_chat", (name: name, msg: msg, originId: conn.id))


var server = newReactor("127.0.0.1", 1999)      # listen for a connection on localhost port 1999
nettyrpc.reactor = server                       # Set nettyrpc reactor to server.

while true:
  server.rpcTick(server=true)   # tick RPCs  
  for msg in server.messages:   # Display messages since last tick.
    echo msg
  sleep(30)

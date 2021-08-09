import netty, nettyrpc, os

# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)

# Set nettyrpc reactor to server.
nettyrpc.reactor = server

# main loop
while true:
  server.rpcTick(server=true)  
  for msg in server.messages:  # Display messages since last tick.
    echo msg
    
  # rpcTick(server=true) will automatically loop through messages
  # and dispatch/relay RPCs.  It's the equivelant to the following
  # relay code:
  #
  # for msg in server.messages:
  #   for client in server.connections:
  #     if(msg.conn != client):
  #       server.send(client, msg.data)
  # sleep(30)

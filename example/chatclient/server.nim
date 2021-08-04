import netty, nettyrpc, os

# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)
# main loop
while true:
  server.rpcTick(server=true)  
  # rpcTick(server=true) will automatically loop through messages
  # and dispatch/relay RPCs.  It's the equivelant to the following
  # relay code:
  #
  # for msg in server.messages:
  #   echo msg
  #   for client in server.connections:
  #     if(msg.conn != client):
  #       server.send(client, msg.data)
  sleep(30)

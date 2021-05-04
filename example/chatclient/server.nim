import netty, os

# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)
# main loop
while true:
  server.tick()
  #We be relaying
  for msg in server.messages:
    echo msg
    for client in server.connections:
      if(msg.conn != client):
        server.send(client, msg.data)
  sleep(30)

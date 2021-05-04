import netty, nettyrpc
import std/[times, parseopt, strutils, strformat, terminal]

### This is a somewhat simple chat client, very broken
### -p is Port
### -n is Name
### -i is Ip

proc getParams: (string, string, int) =
  for kind, key, val in getOpt():
    case key:
    of "p", "port":
      result[2] = parseint(val)
    of "ip", "i":
      result[1] = val
    of "name", "n":
      result[0] = val

proc send(name, message: string){.networked.} =
  if not isLocal:
    eraseLine()
    echo fmt"{getClockStr()} {name} says: {message}"

proc inputLoop(input: ptr Channel[string]) {.thread.} =
  echo "Started input loop"
  var msg = ""
  while true:
    msg.add stdin.readLine()
    input[].send(msg)
    msg.setLen(0)


let 
  (name, ip, port) = getParams()
  client = newReactor()
nettyrpc.client = client.connect(ip, port)
nettyrpc.reactor = client

var 
  worker: Thread[ptr Channel[string]]
  input: Channel[string]
input.open
worker.createThread(inputLoop, input.addr)
echo fmt"Hello {name}"

while true:
  client.rpcTick()
  let (gotInput, msg) = input.tryRecv
  if gotInput:
    name.send(msg)





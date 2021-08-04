import std/[macros, strutils, macrocache, tables, hashes, sequtils]
import netty
import nettyrpc/nettystream

export nettystream

type NettyRpcException = object of CatchableError

var
  compEventCount{.compileTime.} = 0u16
  relayedEvents*: array[uint16, proc(data: var NettyStream, conn: Connection)] ## Ugly method of holding procedures
  managedEvents*: Table[Hash, proc(data: var NettyStream, conn: Connection)] ## Uglier method of holding procedures
  reactor*: Reactor
  client*: Connection
  sendBuffer* = NettyStream()

proc send*(message: var NettyStream) =
  ## Sends the RPC message to the server to relay
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  if(not reactor.isNil and message.pos > 0):
    reactor.send(client, message.getBuffer[0..<message.pos])
    message.clear()

proc rpcTick*(client: Reactor) =
  ## Parses all packets recieved since last tick.
  ## Invokes procedures internally.
  client.tick()
  send(sendBuffer)
  var recBuff = NettyStream()
  for msg in reactor.messages:
    recBuff.addToBuffer(msg.data)
  while(not recBuff.atEnd):
    let id = block:
      var res: uint16
      recBuff.read res
      res
    if(events[id] != nil):
      events[id](recBuff)


macro networked*(toNetwork: untyped): untyped =
  ## Adds the RPC like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, isLocal: static bool = false).
  ## Use `if isLocal` to diferentiate "sender" and "reciever" logic.
  ## Will always relay to the server the passed in data.
  var
    paramNameType: seq[(NimNode, NimNode)]
    paramNames: seq[NimNode]

  #Get parameters name and type
  for x in toNetwork[3]:
    if x.kind == nnkIdentDefs:
      for ident in x[0..^3]:
        let typ = 
          if x[^2].kind != nnkEmpty:
            x[^2]
          else:
            newCall(ident"typeOf", x[^1])
        paramNameType.add (ident, typ)
        paramNames.add ident

  var
    recBody = newStmtList()
    sendBody = newStmtList().add(
      newCall(
          ident("write"),
          ident("sendBuffer"),
          newLit(compEventCount)
      )
    )
  let data = ident("data")
  # For each variable read data
  for (name, pType) in paramNameType:
    # Logic for recieving
    let sendBuffer = ident("sendBuffer")
    recBody.add quote do:
      let `name` = block:
        var temp: `pType`
        `data`.read(temp)
        temp
    sendBody.add quote do:
      write(`sendBuffer`, `name`)
  paramNames.add nnkExprEqExpr.newTree(ident"isLocal", ident"false") # Adding `isLocal = false` for the call
  recBody.add(newCall($toNetwork[0], paramNames))

  toNetwork[3].add newIdentDefs(ident"isLocal", ident"bool", ident"true")
  toNetwork[^1].add newIfStmt((ident("isLocal"), sendBody))

  var sendParams: seq[NimNode]
  for x in toNetwork[3]:
    sendParams.add(x)

  #Generated AST for entire proc
  result = newStmtList().add(
    toNetwork,
    quote do:
      events[`compEventCount`] = proc(`data`: var NettyStream) = `recBody`
  )
  inc compEventCount

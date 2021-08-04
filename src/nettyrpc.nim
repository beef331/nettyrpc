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
  ## it emits a proc(a: int, conn: Connection = Connection())
  ## The Connection is the sender of the RPC.
  ## You can use the connection to call an RPC on that
  ## connection only via `rpc(conn, "some_func", a)`
  ## or `conn.rpc("some_func", a)`
  
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

  var identDef = newIdentDefs(
      ident("conn"), ident("Connection"), newCall(ident("Connection"))
    )
  toNetwork[3].add(identDef)
  paramNames.add(ident("conn"))

  var
    recBody = newStmtList()

  let data = ident("data")
  let conn = ident("conn")
  # For each variable read data
  for (name, pType) in paramNameType:
    # Logic for recieving
    let sendBuffer = ident("sendBuffer")
    recBody.add quote do:
      let `name` = block:
        var temp: `pType`
        `data`.read(temp)
        temp

  recBody.add(newCall($toNetwork[0], paramNames))

  var sendParams: seq[NimNode]
  for x in toNetwork[3]:
    sendParams.add(x)

  let procName = hash($name(toNetwork))
  #Generated AST for entire proc
  result = newStmtList().add(
    toNetwork,
    quote do:
      managedEvents[`procName`] = proc(`data`: var NettyStream, `conn`: Connection) = `recBody`
  )

macro relayed*(toNetwork: untyped): untyped =
  ## Adds the RPC-relay like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, conn: Connection = Connection(), isLocal: static bool = false).
  ## Use `if isLocal` to diferentiate "sender" and "reciever" logic.
  ## Will always relay to the server the passed in data.
  ## A netty Connection is provided to the proc so senders
  ## can still be identified in relayed procedures.
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
  
  let procName = $name(toNetwork)
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
  let conn = ident("conn")
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
  paramNames.add ident("conn") # param for conn: Conection = Connection ()
  paramNames.add nnkExprEqExpr.newTree(ident"isLocal", ident"false") # Adding `isLocal = false` for the call
  
  recBody.add(newCall($toNetwork[0], paramNames))

  var identDef = newIdentDefs(
    ident("conn"), ident("Connection"), newCall(ident("Connection"))
  )
  toNetwork[3].add identDef
  toNetwork[3].add newIdentDefs(ident"isLocal", ident"bool", ident"true")
  toNetwork[^1].add newIfStmt((ident("isLocal"), sendBody))

  var sendParams: seq[NimNode]
  for x in toNetwork[3]:
    sendParams.add(x)

  #Generated AST for entire proc
  result = newStmtList().add(
    toNetwork,
    quote do:
      relayedEvents[`compEventCount`] = proc(`data`: var NettyStream, `conn`: Connection) = `recBody`
  )
  inc compEventCount

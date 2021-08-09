import std/[macros, macrocache, tables, hashes]
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

proc basicSend(conn: Connection, message: string) =
  ## Sends the RPC message to the server to process directly.
  ## Does not use netty stream.
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  if(not reactor.isNil):
    reactor.send(conn, message)

proc send*(conn: Connection, message: var NettyStream) =
  ## Sends the RPC message to the server to process directly.
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  if(not reactor.isNil and message.pos > 0):
    reactor.send(conn, message.getBuffer[0..<message.pos])
    message.clear()

proc sendall*(message: var NettyStream) =
  ## Sends the RPC message to the server to process
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  if(not reactor.isNil and message.pos > 0):
    var d = message.getBuffer[0..<message.pos]
    for conn in reactor.connections:
      reactor.send(conn, d)
    message.clear()

proc rpc*(conn: Connection, procName: string, vargs: tuple) =
  ## Send a rpc to a specific connection.
  sendBuffer.write(hash(procName))
  for k, v in vargs.fieldPairs:
    sendBuffer.write(v)
  send(conn, sendBuffer)

proc rpc*(procName: string, vargs: tuple) =
  ## Send a rpc to all connected clients.
  sendBuffer.write(hash(procName))
  for k, v in vargs.fieldPairs:
    sendBuffer.write(v)
  sendall(sendBuffer)

proc rpc*(conn: Connection, procName: string) =
  ## Send a rpc to a specific connection.
  sendBuffer.write(hash(procName))
  send(conn, sendBuffer)

proc rpc*(procName: string) =
  ## Send a rpc to all connected clients.
  sendBuffer.write(hash(procName))
  sendall(sendBuffer)

proc relay(ns: string, conn: Connection) =
  ## Relay the message data to the specified connection.
  ## Used when there is no server-side procedure.
  for connec in reactor.connections:
    if connec != conn:
      basicSend(connec, ns)

proc rpcTick*(sock: Reactor, server: bool = false) =
  ## Parses all packets recieved since last tick.
  ## Invokes procedures internally.  If no procedure is
  ## found it will relay the command.
  sock.tick()
  if not server:
    client.send(sendBuffer)

  var relayedBuff = NettyStream()
  var managedBuff = NettyStream()
  var conns = newSeq[Connection]()
  for msg in reactor.messages:
    relayedBuff.addToBuffer(msg.data)
    managedBuff.addToBuffer(msg.data)
    conns.add(msg.conn)

  var i = 0
  while(not relayedBuff.atEnd):
    # Check for a managed proc first.
    let managedId = block: 
      var res: int
      managedBuff.read res
      res
    if managedEvents.hasKey(managedId):
      managedEvents[managedId](managedBuff, conns[i])
      break  # buffer will be consumed so we don't need to keep looping.

    if server:  # No need to check server for relayed procs since they don't exist
      relay(relayedBuff.getBuffer, conns[i])
      break  # buffer will be consumed so we don't need to keep looping.

    # If there was no managed proc and we are client then check for relayed 
    # procs and run them.
    let relayedId = block:
      var res: uint16
      relayedBuff.read res
      res
    if(relayedEvents[relayedId] != nil):
      relayedEvents[relayedId](relayedBuff, conns[i])
      break  # buffer will be consumed so we don't need to keep looping.
    i += 1

proc mapProcParams(toNetwork: NimNode): tuple[n: seq[NimNode], t: seq[(NimNode, NimNode)]] =
  ## Create a tuple containing nim node names and types that we need to 
  ## modify the procedure.
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
  (paramNames, paramNameType)

proc patchNodes(toNetwork: NimNode, paramNames: var seq[NimNode], paramNameType: var seq[(NimNode, NimNode)], isRelayed: bool = false): tuple[recBody: NimNode, sendBody: NimNode, data: NimNode, conn: NimNode] =
  ## Patches nim nodes and adds netty Connection object.  If the procedure is relayed
  ## it will add the isLocal bool.
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
    if isRelayed:
      sendBody.add quote do:
        write(`sendBuffer`, `name`)

  paramNames.add ident("conn") # param for conn: Conection = Connection ()
  if isRelayed:
    paramNames.add nnkExprEqExpr.newTree(ident"isLocal", ident"false") # Adding `isLocal = false` for the call
  recBody.add(newCall($toNetwork[0], paramNames))
  
  var identDef = newIdentDefs(
      ident("conn"), ident("Connection"), newCall(ident("Connection"))
    )
  toNetwork[3].add(identDef)
  if isRelayed:
    toNetwork[3].add newIdentDefs(ident"isLocal", ident"bool", ident"true")
    toNetwork[^1].add newIfStmt((ident("isLocal"), sendBody))
  
  (recBody, sendBody, data, conn)

proc compileFinalStmts(toNetwork: NimNode, data: NimNode, conn: NimNode, recBody: NimNode, isRelayed: bool = false): NimNode =
  ## Create the final statement list with the finalized procedure and the proc
  ## registry.
  let procName = hash($name(toNetwork))
    
  let finalStmts = block:
    if isRelayed:
      let stm = quote do:
        relayedEvents[`compEventCount`] = proc(`data`: var NettyStream, `conn`: Connection) = `recBody`
      inc compEventCount
      stm
    else:
      quote do:
        managedEvents[`procName`] = proc(`data`: var NettyStream, `conn`: Connection) = `recBody`

  #Generated AST for entire proc
  result = newStmtList().add(
    toNetwork,
    quote do:
      `finalStmts`
  )

macro networked*(toNetwork: untyped): untyped =
  ## Adds the RPC like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, conn: Connection = Connection())
  ## The Connection is the sender of the RPC.
  ## You can use the connection to call an RPC on that
  ## connection only via `rpc(conn, "some_func", a)`
  ## or `conn.rpc("some_func", a)`
  
  var (paramNames, paramNameType) = mapProcParams(toNetwork)
  var (recBody, sendBody, data, conn) = patchNodes(toNetwork, paramNames, paramNameType)
  result = compileFinalStmts(toNetwork, data, conn, recBody)

macro relayed*(toNetwork: untyped): untyped =
  ## Adds the RPC-relay like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, conn: Connection = Connection(), isLocal: static bool = false).
  ## Use `if isLocal` to diferentiate "sender" and "reciever" logic.
  ## Will always relay to the server the passed in data.
  ## A netty Connection is provided to the proc so senders
  ## can still be identified in relayed procedures.
  
  var (paramNames, paramNameType) = mapProcParams(toNetwork)
  var (recBody, sendBody, data, conn) = patchNodes(toNetwork, paramNames, paramNameType, true)
  result = compileFinalStmts(toNetwork, data, conn, recBody, true)

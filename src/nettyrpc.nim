import std/[macros, macrocache, tables, hashes, strutils]
import netty
import nettyrpc/nettystream

export nettystream

type 
  NettyRpcException = object of CatchableError
  Strings* = string or static string
  MessageType = enum
    Networked, Relayed
var
  compEventCount{.compileTime.} = 0u16
  relayedEvents: array[uint16, proc(data: var NettyStream)] ## Ugly method of holding procedures
  managedEvents: Table[Hash, proc(data: var NettyStream, conn: Connection)] ## Uglier method of holding procedures
  reactor*: Reactor
  client*: Connection
  sendBuffer = NettyStream()
  relayBuffer = NettyStream()
  sendAllBuffer = NettyStream()
  directSends: Table[Connection, seq[NettyStream]]

proc hash(conn: Connection): Hash =
  var h: Hash = 0
  h = h !& hash(conn.id)
  h = h !& hash(conn.address.host)
  result = !$h

proc basicSend(conn: Connection, message: string) =
  ## Sends the RPC message to the server to process directly.
  ## Does not use netty stream.
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  
  reactor.send(conn, message)

proc send*(conn: Connection, message: var NettyStream) =
  ## Sends the RPC message to the server to process directly.
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  if message.pos > 0:
    reactor.send(conn, message.getBuffer)
    message.clear()

proc sendall*(message: string, exclude: Connection = nil) =
  ## Sends the RPC message to the server to process
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")

  if message.len > 0:
    for conn in reactor.connections:
      if conn != exclude:
        reactor.send(conn, message)

proc sendall*(message: var NettyStream, exclude: Connection = nil) =
  ## Sends the RPC message to the server to process
  if reactor.isNil:
    raise newException(NettyRpcException, "Reactor is not set")
  if message.pos > 0:
    var d = message.getBuffer
    for conn in reactor.connections:
      if conn != exclude:
        reactor.send(conn, d)
    message.clear()

proc writeRpcHeader(procName: Strings, ns: var NettyStream) {.inline.} =
  ## Write the MessageType and hashed procedure name to the send buffer.
  ns.write(MessageType.Networked)
  when procName.type is static string:
    const hashedName = hash(procName) # Calculate at compile time
    ns.write(hashedName)
  else:
    ns.write(hash(procName))

proc addDirectSend(conn: Connection, ns: var NettyStream) =
  if directSends.hasKey(conn):
    directSends[conn].add(ns)
  else:
    directSends[conn] = newSeq[NettyStream]()
    directSends[conn].add(ns)

proc rpc*(conn: Connection, procName: Strings, vargs: tuple) =
  ## Send a rpc to a specific connection.
  var nb = NettyStream()
  writeRpcHeader(procName, nb)
  for k, v in vargs.fieldPairs:
    nb.write(v)
  addDirectSend(conn, nb)

proc rpc*(procName: Strings, vargs: tuple) =
  ## Send a rpc to all connected clients.
  writeRpcHeader(procName, sendAllBuffer)
  for k, v in vargs.fieldPairs:
    sendAllBuffer.write(v)

proc rpc*(conn: Connection, procName: Strings) =
  ## Send a rpc to a specific connection.
  var nb = NettyStream()
  writeRpcHeader(procName, nb)
  addDirectSend(conn, nb)

proc rpc*(procName: Strings) =
  ## Send a rpc to all connected clients.
  writeRpcHeader(procName, sendAllBuffer)

proc relayServerTick(conn: Connection, data: string) =
  for connec in reactor.connections:
    if connec != conn:
      reactor.send(connec, data)

proc rpcTick*(sock: Reactor, server: bool = false) =
  sock.tick()
  if server:
    for k, s in directSends.pairs:  # Direct sends from the server.
      var directSendStream = NettyStream()
      for stream in s:
        directSendStream.addToBuffer(stream.getBuffer)
      reactor.send(k, directSendStream.getBuffer)
    directSends.clear()
  else:
    if relayBuffer.pos > 0:
      sendBuffer.write(MessageType.Relayed) # Id
      sendBuffer.write(relayBuffer.getBuffer) # Writes len, message
      echo relayBuffer.getBuffer
      relayBuffer.clear()
    client.send(sendBuffer) # Relayed client

  sendall(sendAllBuffer)  # Send to all connections

  var theBuffer = NettyStream()
  for msg in reactor.messages:
    theBuffer.clear()
    theBuffer.addToBuffer(msg.data)

    while(not theBuffer.atEnd):
      let
        start = theBuffer.pos
        messageType = theBuffer.read(MessageType)
      case messageType:
      of MessageType.Networked:
        let managedId = theBuffer.read(Hash)
        if managedEvents.hasKey(managedId):
          managedEvents[managedId](theBuffer, msg.conn)

      of MessageType.Relayed:
        let messageLength = theBuffer.read(int64)
        if server:
          let
            theEnd = theBuffer.pos + messageLength # len doesnt count header info so offset it
            str = theBuffer.getBuffer[start..<theEnd]
          echo str
          sendAll(str, msg.conn)
          theBuffer.pos = theEnd.int
          continue
        else:
          let theEnd = theBuffer.pos + messageLength - 1
          while theBuffer.pos < theEnd:
            let relayedId = theBuffer.read(uint16)
            if relayedEvents[relayedId] != nil and relayedId in 0u16..compEventCount:
              relayedEvents[relayedId](theBuffer)

proc mapProcParams(toNetwork: NimNode, isRelayed: bool = false): tuple[n: seq[NimNode], t: seq[(NimNode, NimNode)]] =
  ## Create a tuple containing nim node names and types that we need to 
  ## modify the procedure.
  var
    paramNameType: seq[(NimNode, NimNode)]
    paramNames: seq[NimNode]

  #Get parameters name and type
  for x in toNetwork[3]:
    if x.kind == nnkIdentDefs:
      for idn in x[0..^3]:
        var typ = 
          if x[^2].kind != nnkEmpty:
            x[^2]
          else:
            newCall(ident"typeOf", x[^1])
        paramNameType.add (idn, typ)
        paramNames.add idn
  (paramNames, paramNameType)

proc patchNodes(toNetwork: NimNode, paramNames: var seq[NimNode], paramNameType: var seq[(NimNode, NimNode)], isRelayed: bool = false): tuple[recBody: NimNode, sendBody: NimNode, data: NimNode, conn: NimNode] =
  ## Patches nim nodes and adds netty Connection object.  If the procedure is relayed
  ## it will add the isLocal bool.
  var 
    recBody = newStmtList()
    sendBody = newStmtList()
  let 
    sendBuffer = 
      if isRelayed:
        bindSym"relayBuffer"
      else:
        bindSym"sendBuffer"

  let
    data = ident("data")
    conn = ident("conn")

  # For each variable read data
  for (name, pType) in paramNameType:
    # Logic for recieving
    recBody.add quote do:
      let `name` = block:
        var temp: `pType`
        `data`.read(temp)
        temp
    if isRelayed:
      sendBody.add quote do:
        write(`sendBuffer`, `name`)

  let
    messageKind =
      if isRelayed:
        Relayed
      else:
        Networked
    eventId = 
      if isRelayed:
        newLit(compEventCount)
      else:
        newLit(hash($toNetwork[0].baseName))

  if isRelayed:
    sendBody.insert 0, quote do:
      write(`sendBuffer`, `eventId`)
    paramNames.add nnkExprEqExpr.newTree(ident"isLocal", ident"false") # Adding `isLocal = false` for the call
    toNetwork[3].add newIdentDefs(ident"isLocal", ident"bool", ident"true")
    toNetwork[^1].add newIfStmt((ident("isLocal"), newStmtList(sendBody)))
  else:
    sendBody.insert 0, quote do:
      write(`sendBuffer`, `messageKind`)
      write(`sendBuffer`, `eventId`)
    paramNames.add ident("conn") # param for conn: Conection = Connection ()

    let identDef = newIdentDefs(
      ident("conn"), ident("Connection"), newCall(ident("Connection"))
    )

    toNetwork[3].add(identDef)

  recBody.add(newCall($toNetwork[0], paramNames))

  (recBody, sendBody, data, conn)

proc compileFinalStmts(toNetwork: NimNode, data: NimNode, conn: NimNode, recBody: NimNode, isRelayed: bool = false): NimNode =
  ## Create the final statement list with the finalized procedure and the proc
  ## registry.
  let procName = hash($name(toNetwork))
  let finalStmts = block:
    if isRelayed:
      let
        relayEvents = bindSym"relayedEvents"
        stm = quote do:
          `relayEvents`[`compEventCount`] = proc(`data`: var NettyStream) = `recBody`
      inc compEventCount
      stm
    else:
      let manageEvents = bindsym"managedEvents"
      quote do:
        `manageEvents`[`procName`] = proc(`data`: var NettyStream, `conn`: Connection) = `recBody`

  #Generated AST for entire proc
  result = newStmtList().add(
    toNetwork,
    finalStmts
  )

macro networked*(toNetwork: untyped): untyped =
  ## Adds the RPC like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, conn: Connection = Connection())
  ## The Connection is the sender of the RPC.
  ## You can use the connection to call an RPC on that
  ## connection only via `rpc(conn, "some_func", a)`
  ## or `conn.rpc("some_func", a)`.  The Connection object
  ## on the client-side will always represent the connection to the server.
  
  var (paramNames, paramNameType) = mapProcParams(toNetwork)
  var (recBody, sendBody, data, conn) = patchNodes(toNetwork, paramNames, paramNameType)
  result = compileFinalStmts(toNetwork, data, conn, recBody)
  echo result.repr

macro relayed*(toNetwork: untyped): untyped =
  ## Adds the RPC-relay like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, conn: Connection = Connection(), isLocal: static bool = false).
  ## Use `if isLocal` to diferentiate "sender" and "reciever" logic.
  ## Will always relay to the server the passed in data.
  ## Netty Connection object will always represent connection to server.
  
  var (paramNames, paramNameType) = mapProcParams(toNetwork, true)
  var (recBody, sendBody, data, conn) = patchNodes(toNetwork, paramNames, paramNameType, true)
  result = compileFinalStmts(toNetwork, data, conn, recBody, true)
  echo result.repr

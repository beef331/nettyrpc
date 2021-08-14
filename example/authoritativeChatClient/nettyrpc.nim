import std/[macros, macrocache, tables, hashes]
import netty
import nettyrpc/nettystream

export nettystream

type 
  NettyRpcException = object of CatchableError
  Strings* = string or static string
  MessageType* {.pure.} = enum
    Relayed, Networked
  DataType* = ref object of RootObj
    datatype: MessageType

var
  compEventCount{.compileTime.} = 0u16
  relayedEvents*: array[uint16, proc(data: var NettyStream)] ## Ugly method of holding procedures
  managedEvents*: Table[Hash, proc(data: var NettyStream, conn: Connection)] ## Uglier method of holding procedures
  reactor*: Reactor
  client*: Connection
  sendBuffer* = NettyStream()
  sendAllBuffer* = NettyStream()
  directSends*: Table[Connection, seq[NettyStream]]
  theConnections: Table[uint32, Connection]
  connectionMap: Table[uint32, uint32] # SenderID / ServersLocalID

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
    echo "Reactor is nil"
    raise newException(NettyRpcException, "Reactor is not set")
  if(not reactor.isNil and message.pos > 0):
    var d = message.getBuffer[0..<message.pos]
    for conn in reactor.connections:
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
  # send(conn, sendBuffer)
  addDirectSend(conn, nb)

proc rpc*(procName: Strings, vargs: tuple) =
  ## Send a rpc to all connected clients.
  writeRpcHeader(procName, sendAllBuffer)
  for k, v in vargs.fieldPairs:
    sendAllBuffer.write(v)
  # sendall(sendBuffer)

proc rpc*(conn: Connection, procName: Strings) =
  ## Send a rpc to a specific connection.
  var nb = NettyStream()
  writeRpcHeader(procName, nb)
  # send(conn, sendBuffer)
  addDirectSend(conn, nb)

proc rpc*(procName: Strings) =
  ## Send a rpc to all connected clients.
  writeRpcHeader(procName, sendAllBuffer)
  # sendall(sendBuffer)

proc relay(ns: string, conn: Connection) =
  ## Relay the message data to the specified connection.
  ## Used when there is no server-side procedure.
  for connec in reactor.connections:
    if connec != conn:
      # send(connec, ns)
      basicSend(connec, ns)

proc relayServerTick() =
  for msg in reactor.messages:
    for connec in reactor.connections:
      if connec != msg.conn:
        reactor.send(connec, msg.data)

proc networkTick*(sock: Reactor, server: bool = false) =
  sock.tick()
  if server:
    for k, s in directSends.pairs:
      echo "direct sending"
      var directSendStream = NettyStream()
      for stream in s:
        directSendStream.write(stream.getBuffer)
      send(k, directSendStream)
  sendall(sendAllBuffer)

  var theBuffer = NettyStream()
  var theBufferPos = theBuffer.pos
  for msg in reactor.messages:
    echo "got message"
    theBuffer.addToBuffer(msg.data)

    while(not theBuffer.atEnd):
      # theBufferPos = theBuffer.pos
      let messageType = block:  # Read the message type
        var res: MessageType
        try:
          theBuffer.read res
        except RangeDefect:
          echo "Range defect"
          # theBuffer.pos = theBufferPos
          break
        res

      case messageType:
      of MessageType.Networked:
        let managedId = block: 
          var res: int
          theBuffer.read res
          res
        if managedEvents.hasKey(managedId):
          managedEvents[managedId](theBuffer, msg.conn)
      of MessageType.Relayed:
        raise newException(NettyRpcException, "Relayed messages mixed with networked messages.  Don't mix relayed and networked pragmas.")

proc rpcTick*(sock: Reactor, server: bool = false) =
  ## Parses all packets recieved since last tick.
  ## Invokes procedures internally.  If no procedure is
  ## found it will relay the command.
  sock.tick()
  if not server:
    client.send(sendBuffer)

  var theBuffer = NettyStream()
  var conn: Connection # CLIENT-SIDE IS ALWAYS RECEIVING FROM THE SERVER!
  for msg in reactor.messages:
    theBuffer.addToBuffer(msg.data)
    echo msg.conn.id
    conn = msg.conn  # Since the connection is always the server this is safe for client.  Used for relay

  while(not theBuffer.atEnd):
    let messageType = block:  # Read the message type
      var res: MessageType
      theBuffer.read res
      res

    case messageType:
    of MessageType.Relayed:
      if server:
        relayServerTick()
        return
      let relayedId = block:
        var res: uint16
        theBuffer.read res
        res
      if(relayedEvents[relayedId] != nil):
        # echo "Calling relayed: " & $relayedId
        relayedEvents[relayedId](theBuffer)
    of MessageType.Networked:
      raise newException(NettyRpcException, "Networked messages mixed with relayed messages.  Don't mix relayed and networked pragmas.")
      let managedId = block: 
        var res: int
        theBuffer.read res
        res
      if managedEvents.hasKey(managedId):
        managedEvents[managedId](theBuffer, conn)


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
    sendBody = newStmtList()

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

  if isRelayed:
    sendBody.insert(
      0,
      newStmtList(
        newCall(
          ident("write"),
          ident("sendBuffer"),
          newDotExpr(ident("MessageType"), ident("Relayed"))
        ),
        # newCall(
        #   ident("write"),
        #   ident("sendBuffer"),
        #   newDotExpr(
        #     newDotExpr(ident("nettyrpc"), ident("reactor")),
        #     ident("id")
        #   )
        # ),
        newCall(
          ident("write"),
          ident("sendBuffer"),
          newLit(compEventCount)
        )      
      )
    )

  if not isRelayed:
    paramNames.add ident("conn") # param for conn: Conection = Connection ()
  if isRelayed:
    paramNames.add nnkExprEqExpr.newTree(ident"isLocal", ident"false") # Adding `isLocal = false` for the call
  recBody.add(newCall($toNetwork[0], paramNames))
  
  var identDef = newIdentDefs(
      ident("conn"), ident("Connection"), newCall(ident("Connection"))
    )
  if not isRelayed:
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
        relayedEvents[`compEventCount`] = proc(`data`: var NettyStream) = `recBody`
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
  ## or `conn.rpc("some_func", a)`.  The Connection object
  ## on the client-side will always represent the connection to the server.
  
  var (paramNames, paramNameType) = mapProcParams(toNetwork)
  var (recBody, sendBody, data, conn) = patchNodes(toNetwork, paramNames, paramNameType)
  result = compileFinalStmts(toNetwork, data, conn, recBody)

macro relayed*(toNetwork: untyped): untyped =
  ## Adds the RPC-relay like behaviour,
  ## for proc(a: int),
  ## it emits a proc(a: int, conn: Connection = Connection(), isLocal: static bool = false).
  ## Use `if isLocal` to diferentiate "sender" and "reciever" logic.
  ## Will always relay to the server the passed in data.
  ## Netty Connection object will always represent connection to server.
  
  var (paramNames, paramNameType) = mapProcParams(toNetwork)
  var (recBody, sendBody, data, conn) = patchNodes(toNetwork, paramNames, paramNameType, true)
  result = compileFinalStmts(toNetwork, data, conn, recBody, true)
  echo result.repr

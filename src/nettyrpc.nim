import macros, strutils, netty
import nettyrpc/nettystream

export nettystream

var compEventCount{.compileTime.} = 0u16
var events*: array[uint16, proc(data: var NettyStream)]
var
  isLocalMessage* = true
  reactor*: Reactor
  client*: Connection
  sendBuffer* = NettyStream()

proc sendNetworked*(packet: var NettyStream) =
  if(not reactor.isNil and packet.pos > 0):
    reactor.send(client, packet.getBuffer[0..<packet.pos])
    packet.clear()

proc rpcTick*(client: Reactor) =
  sendNetworked(sendBuffer)
  var recBuff = NettyStream()
  for msg in reactor.messages:
    recBuff.addToBuffer(msg.data)
  while(not recBuff.atEnd):
    let id = block:
      var res: uint16
      recBuff.read res
      res
    if(events[id] != nil):
      isLocalMessage = false
      events[id](recBuff)
      isLocalMessage = true

macro networked*(toNetwork: untyped): untyped =
  ##[
      Adds the RPC like behaviour, only works with stack allocated types, so no strings as of yet.
  ]##
  var
    paramNameType: seq[(NimNode, NimNode)]
    paramNames: seq[NimNode]

  #Get parameters name and type
  for x in toNetwork[3]:
    if(x.kind == nnkIdentDefs):
      for ident in x[0..^3]:
        paramNameType.add (ident, x[^2])
        paramNames.add ident

  let
    recName = ident("recieve" & capitalizeAscii($toNetwork[0]))
    sendName = ident("send" & capitalizeAscii($toNetwork[0]))
    recParams = [newEmptyNode(), newIdentDefs(ident("data"), newNimNode(nnkVarTy).add ident(
            "NettyStream"))]
  var
    recBody = newStmtList()
    sendBody = newStmtList().add(
            newCall(
                ident("write"),
                ident("sendBuffer"),
                newLit(compEventCount)
      )
    )
  #For each variable read data
  for (name, pType) in paramNameType:
    #Logic for recieving
    let
      data = ident("data")
      sendBuffer = ident("sendBuffer")
    recBody.add quote do:
      let `name` = block:
        var t: `pType`
        `data`.read(t)
        t
    sendBody.add quote do:
      `sendBuffer`.write(`name`)

  recBody.add(newCall($toNetwork[0], paramNames))

  #Append If logic
  var ifBody = newStmtList(newCall(sendName, paramNames))

  toNetwork[toNetwork.len-1].add(newIfStmt((ident("isLocalMessage"), ifBody)))

  var sendParams: seq[NimNode]
  for x in toNetwork[3]:
    sendParams.add(x)

  #Generated AST for entire proc
  result = newStmtList().add(
      newProc(sendName, sendParams, sendBody),
      toNetwork,
      newProc(recName, recParams, recBody),
      quote do:
    events[`compEventCount`] = `recName`
  )
  inc compEventCount
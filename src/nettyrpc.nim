import macros, tables, strutils, streams, netty

export streams, tables
var compEventCount{.compileTime.} = 0u16
var events*: array[uint16, proc(data: StringStream)]

var
  isLocalMessage* = true
  reactor*: Reactor
  client*: Connection
  recieveBuffer* = newStringStream()
  sendBuffer* = newStringStream()

type
  Collection[T] = concept c
    for v in c:
      v is T

proc writeReferences*[T](ss: Stream, a: T) =
  when(T is object):
    for x in a.fields:
      ss.writeReferences(x)
  elif(T is Collection):
    ss.write(a.len.uint32)
    for x in a:
      ss.writeReferences(x)
  elif(T is ref):
    ss.writeReferences(a[])
  else:
    ss.write(a)


proc readReferences*[T](ss: Stream): T =
  when(T is object):
    result = T()
    for val in result.fields:
      val = readReferences[val.type](ss)
  elif(T is ref):
    result = T()
    for val in result[].fields:
      val = readReferences[val.type](ss)
  elif(T is Collection):
    var temp: typeOf(result[0])
    let count = ss.readUint32
    for x in 0..<count:
      result.add(readReferences[temp.type](ss))
  else:
    var temp: T
    ss.read(temp)
    result = temp

proc sendNetworked*(packet: StringStream) =
  if(not reactor.isNil and packet.getPosition() > 0):
    let pos = packet.getPosition
    packet.setPosition(0)
    let message = packet.readStr(pos)
    reactor.send(client, message)
    packet.setPosition(0)

proc rpcTick*(client: Reactor) =
  sendNetworked(sendBuffer)
  for msg in reactor.messages:
    recieveBuffer.write(msg.data)
    recieveBuffer.setPosition(0)
    while(not recieveBuffer.atEnd()):
      let id = recieveBuffer.readUint16
      if(events[id] != nil):
        isLocalMessage = false
        events[id](recieveBuffer)
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
    recParams = [newEmptyNode(), newIdentDefs(ident("data"), ident(
            "StringStream"))]
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
      let `name` = `data`.readReferences[: `pType`]()
    sendBody.add quote do:
      `sendBuffer`.writeReferences(`name`)

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

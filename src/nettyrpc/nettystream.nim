type NettyStream* = object
  buffer: string
  pos*: int

proc write*[T: enum or bool](ns: var NettyStream, i: T)

proc read*[T: enum or bool](ns: var NettyStream, e: var T)
proc read*[T: SomeInteger](ns: var NettyStream, v: var T)

proc write*[T: enum or bool](ns: var NettyStream, i: T) =
  ns.write i.ord

proc write*[T: SomeInteger](ns: var NettyStream, i: T) =
  for `byte` in 0..<T.sizeof:
    ns.buffer.add ((i shr (byte * 8)) and 0xff).char
    inc ns.pos

proc write*[T: float32](ns: var NettyStream, f: T) =
  let i = cast[int32](f)
  ns.write(i)

proc write*[T: float64](ns: var NettyStream, f: T) =
  let i = cast[int64](f)
  ns.write(i)

proc write*[T: char](ns: var NettyStream, c: T) =
  ns.buffer.add c
  inc ns.pos

proc write*[T: array](ns: var NettyStream, a: T) =
  for ele in a:
    ns.write ele

proc write*[T: seq or string](ns: var NettyStream, s: T) =
  ns.write(s.len)
  for x in s:
    ns.write(x)

proc write*[T: object or tuple](ns: var NettyStream, obj: T)=
  for field in obj.fields:
    ns.write(field)

proc write*[T: ref object](ns: var NettyStream, obj: T) =
  ns.write(obj.isNil)
  if obj != nil:
    ns.write(obj[])

proc read*[T: enum or bool](ns: var NettyStream, e: var T) =
  var val = 0
  ns.read(val)
  e = val.T

proc read*[T: char](ns: var NettyStream, c: var T) =
  c = ns.buffer[ns.pos]
  inc ns.pos

proc read*[T: SomeInteger](ns: var NettyStream, v: var T) =
  v = default(T)
  for `byte` in 0..<T.sizeof:
    v = v or (ns.buffer[ns.pos].ord shl (byte * 8)).T
    inc ns.pos

proc read*[T: float32](ns: var NettyStream, v: var T) =
  var i32: uint32
  ns.read(i32)
  v = cast[T](i32)

proc read*[T: float64](ns: var NettyStream, v: var T) =
  var i64: uint64
  ns.read(i64)
  v = cast[T](i64)

proc read*[T: array](ns: var NettyStream, a: var T) =
  for i in 0..a.high:
    ns.read(a[i])

proc read*[T: seq or string](ns: var NettyStream, s: var T) =
  var newLength = 0
  ns.read(newLength)
  s.setLen(newLength)
  for x in 0..s.high:
    ns.read(s[x])

proc read*[T: object](ns: var NettyStream, o: var T) =
  for field in o.fields:
    ns.read(field)

proc read*[T: ref object](ns: var NettyStream, o: var T) =
  var isNil: bool
  ns.read(isNil)
  if not isNil:
    o = T()
    for x in o[].fields:
      ns.read(x)

proc getBuffer*(ns: NettyStream): string = ns.buffer
proc addToBuffer*(ns: var NettyStream, str: string) = ns.buffer.add str
proc atEnd*(ns: NettyStream): bool = ns.pos >= ns.buffer.len
proc size*(ns: NettyStream): int = ns.buffer.len
proc clear*(ns: var NettyStream) =
  ns.pos = 0
  ns.buffer = ""
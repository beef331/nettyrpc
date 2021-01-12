import std/[unittest]
import nettyrpc/nettystream

suite "nettystream":
  test "object":
    type Test = object
      a: int
      b: string
      c: seq[int]
    let t = Test(a: 42, b: "Hello", c: @[10, 30, 40])
    var ns = NettyStream()
    ns.write(t)
    ns.pos = 0
    var test: Test
    ns.read(test)
    assert t == test
  
  test "ref object":
    type Test = ref object
      a: int
      b: string
      c: seq[int]
    let t = Test(a: 42, b: "Hello", c: @[10, 30, 40])
    var ns = NettyStream()
    ns.write(t)
    ns.pos = 0
    var test: Test
    ns.read(test)
    assert t[] == test[]

  test "enum":
    type Colour = enum
      red, green, yellow, indigo, violet
    var ns = NettyStream()
    for x in Colour.low..Colour.high:
      ns.write(x)
    ns.pos = 0
    var c: Colour
    for x in Colour.low..Colour.high:
      ns.read(c)
      assert c == x

  test "array":
    var ns = Nettystream()
    let data = [1, 2, 3, 4, 10, 50]
    ns.write(data)
    ns.pos = 0
    var test: data.type
    ns.read(test)
    assert test == data

  test "ints":
    var ns = Nettystream()
    ns.write(3170893824)
    ns.write(-13333333)
    ns.write(32132132132)
    ns.pos = 0
    var t: int
    ns.read t
    assert t == 3170893824
    ns.read t
    assert t == -13333333
    ns.read t
    assert t == 32132132132
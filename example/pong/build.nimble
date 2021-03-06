version       = "0.1.0"
author        = "Jason"
description   = "TestProject"
license       = "MIT"

requires "nico"
requires "netty"
requires "nettyrpc"

task make, "Makes client and server":
  exec "nim c -d:release ./server"
  exec "nim c -d:release ./client"
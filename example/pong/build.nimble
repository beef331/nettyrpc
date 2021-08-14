version       = "0.1.0"
author        = "Jason"
description   = "TestProject"
license       = "MIT"

requires "nico"
requires "netty"
requires "nettyrpc"

task make, "Makes client and server":
  exec "nim c -d:debug ./server"
  exec "nim c -d:debug ./client"

task tBuild, "tests":
  makeTask()
  try:
    exec "killall server"
  except: discard
  exec "sleep 1; ./server & sleep 1; ./client & sleep 1; ./client"
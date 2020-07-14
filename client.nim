import netty, nettyrpc, nico, random, times
import nico/vec

randomize(now().nanosecond)
let id = rand(1..10000000) 

var 
    client = newReactor()
    c2s = client.connect("127.0.0.1", 1999)
    otherID = 0
    shouldHandshake = false
    otherLeft = false

type
    GameState = enum
        gsWaiting, gsReady, gsPlaying
    Paddle = object
        y,color: int
        local: bool
    Ball = object
        owner: int32
        dirX, dirY: float32
        x,y, vel: float32

# send message on the connection
nettyhelper.reactor = client
nettyhelper.client = c2s

var 
    currentState = gsWaiting
    otherState = gsWaiting
    paddles: array[2,Paddle]
    ball: Ball
    leftScore, rightScore = 0

proc lobbyFull:bool = otherID != 0 

proc join(a : int, isLeft: bool = false){.networked.}=
    if(not isLocalMessage):
        #Attempt to handshake
        if(a != otherID): shouldHandshake = true
        otherID = a
        otherLeft = isLeft

proc changeState(gs : GameState){.networked.}=
    if(not isLocalMessage):
        otherState = gs
    else:
        currentState = gs

proc updatePaddle(p: Paddle){.networked.}=
    if(not isLocalMessage):
        for x in paddles.mitems:
            if(not x.local):
                x.y = p.y

proc updateBall(inBall: Ball){.networked.}=
    ball = inBall

proc ballScored(leftScr: int, rightScr: int){.networked.}=
    leftScore = leftScr
    rightScore = rightScr

proc init= 
    loadFont(0,"font.png")
    join(id)

proc generateBallDirection(b : var Ball)=
    ##Generates a random vector for the ball to travel
    let 
        x = rand(0..1) * 2 - 1
        vect = vec2f(x, rand(-0.8..0.8)).normalized()
    ball.dirX = vect.x
    ball.dirY = vect.y
    ball.vel = 50

proc update(dt: float32)=
    client.rpcTick()
    client.tick()

    if(currentState == gsWaiting and otherID != 0 and keypr(K_RETURN)):
        changeState(gsReady)
    elif(currentState == gsReady and otherID != 0 and keypr(K_RETURN)):
        changeState(gsWaiting)

    if(currentState == gsReady and otherState in {gsReady, gsPlaying}):
        paddles[0] = Paddle(y: screenHeight.div(2) - 10, local: not otherLeft, color: 3)
        paddles[1] = Paddle(y: screenHeight.div(2) - 10, local: otherLeft, color: 4)
        ball = Ball(x: screenWidth.div(2).float32, y: screenHeight.div(2).float32)
        #Easy way to decide who is the "server"
        if(id > otherID):
            ball.generateBallDirection
            ball.owner = id
        changeState(gsPlaying)

    if(currentState == gsPlaying):
        if(ball.owner == id):
            #Ball collision
            if(ball.y + 2 >= paddles[0].y and ball.y - 2 <= paddles[0].y + 20 and ball.x - 2 <= 10):
                ball.dirX *= -1

            if(ball.y + 2 >= paddles[1].y and ball.y - 2 <= paddles[1].y + 20 and ball.x + 2 >= screenWidth - 10):
                ball.dirX *= -1

            if(ball.y - 2 <= 0):
                ball.dirY *= -1
        
            if(ball.y + 2 >= screenHeight):
                ball.dirY *= -1

            ball.x += ball.dirX * ball.vel * dt
            ball.y += ball.dirY * ball.vel * dt
            updateBall(ball)
            if(ball.x >= screenWidth or ball.x <= 0):
                let
                    newLeftScore = if(ball.x >= screenWidth): leftScore + 1 else: leftScore
                    newRightScore = if(ball.x <= 0): rightScore + 1 else: rightScore
                ballScored(newLeftScore, newRightScore)
                ball.x = screenWidth / 2
                ball.y = screenHeight / 2
                ball.generateBallDirection
                ball.updateBall

        for x in paddles.mitems:
            if(x.local):
                if(key(K_UP)):
                    x.y -= 1
                if(key(K_DOWN)):
                    x.y += 1
                x.y = clamp(x.y,0,screenHeight-20)
                updatePaddle(x)

    #If we joined first we're left cause yes
    if(shouldHandshake): 
        join(id, not otherLeft)
        shouldHandshake = false

proc draw()=
    cls()
    setColor(5)

    if(currentState == gsWaiting and lobbyFull()):
        printc("Press enter when ready",screenWidth.div(2),0)
    if(currentState == gsReady):
        printc("Waiting for other player",screenWidth.div(2),0)

    if(currentState == gsPlaying):
        print($leftScore,10,10,3)
        print($rightScore, screenWidth - 22,10, 3)

        print($(id == ball.owner),0,screenHeight - 10)
        setColor(paddles[0].color)
        rectfill(1,paddles[0].y, 6,paddles[0].y + 20)
        setColor(paddles[1].color)
        rectfill(screenWidth - 6,paddles[1].y,screenHeight - 1, paddles[1].y + 20)
        setColor(10)
        circfill(ball.x,ball.y, 2)

nico.init("Blah", "blah")
nico.createWindow("myApp", 128, 128, 4, false)
nico.run(init,update,draw)
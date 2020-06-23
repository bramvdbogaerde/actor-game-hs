module Actors where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.State

newtype Mailbox m = Mailbox [m]
data MailboxSTM m = MailboxSTM (TVar (Mailbox m))

isEmpty :: [a] -> Bool
isEmpty [] = True
isEmpty _ = False

--- Reads the first message of the mailbox, fails
--- if the mailbox does not contain any messages
readMessage :: MailboxSTM m -> STM m
readMessage (MailboxSTM mailbox) = do
   messages <- readTVar mailbox 
   case messages of
        Mailbox messageList -> do {
           writeTVar mailbox $ Mailbox (tail messageList) ;
           return $ head messageList
        }

--- Returns true if the mailbox contains at least one message
mailboxNotEmpty :: MailboxSTM m -> STM Bool
mailboxNotEmpty (MailboxSTM mailbox) = do
   messages <- readTVar mailbox
   case messages of 
        Mailbox messageList -> return (not $ isEmpty messageList)

--- Deliver a new message in the given mailbox
deliverMessage :: MailboxSTM m -> m -> STM ()
deliverMessage (MailboxSTM mailbox) message = do 
   messages <- readTVar mailbox
   case messages of
        Mailbox messageList -> writeTVar mailbox $ Mailbox (message : messageList)

--- Block until a message has arrived
waitMessage :: MailboxSTM m -> STM m
waitMessage mailbox = do
   mailboxIsNotEmpty <- mailboxNotEmpty mailbox
   if mailboxIsNotEmpty
      then readMessage mailbox
      else retry

--- Actor is a tuple consisting of a mailbox, a synchronisation variable to 
--- sync on in order to wait for it to be killed, and a thread id that represents
--- the physical thread of the actor.
data Actor m = Actor {
   mailbox  :: MailboxSTM m,
   killSync :: MVar Bool
}

type Behaviour r = (r -> ActorReceive r (ActorReply r))
type BehaviourResult r = ActorReceive r (ActorReply r)

--- An actor can reply in four differente ways:
--- DropMessage: ignores and removes the message from the mailbox
--- IgnoreMessage: ignores the message, but queues it for later delivery
--- Terminate: terminates the actor
data ActorReply r = DropMessage | IgnoreMessage | Become (Behaviour r) | Terminate


--- Alias for `Become` data constructor
become :: Behaviour r -> ActorReceive r (ActorReply r)
become = return . Become

--- Alias for `IgnoreMessage` data constructor
ignore :: ActorReceive r (ActorReply m)
ignore = return $ IgnoreMessage

--- Alies for 'DropMessage' data constructor
drop :: ActorReceive r (ActorReply m)
drop = return $ DropMessage

--- Wait until the actor has terminated, only do this in the main thread
--- as it is blocking, and only one thread will be unblocked when killSync
--- contains a value.
join :: Actor m -> IO ()
join actor = do { _ <- takeMVar $ killSync actor ; return () }

data ActorReceiveState m = ActorReceiveState { ioActions :: [ActorAction], selfActor :: Actor m }
emptyActorReceiveState :: Actor m -> ActorReceiveState m
emptyActorReceiveState m = ActorReceiveState { ioActions = [], selfActor = m }

type ActorAction = IO ()
type ActorReceive m = State (ActorReceiveState m)

schedule :: IO () -> ActorReceive m ()
schedule act = do
   state <- get
   put (state { ioActions = act : ioActions state } )

self :: ActorReceive m (Actor m)
self = do { state <- get ; return $ selfActor state }

--- IO variant of send, can be used in context where impure actions are allowed
sendIO :: Actor m -> m -> IO ()
sendIO actor message = atomically ( deliverMessage (mailbox actor) message )

--- Log a message
log :: (Show a) => a -> ActorReceive m ()
log m = schedule $ putStrLn (show m)

--- Send a message to the given actor
send :: Actor m -> m -> ActorReceive a ()
send actor message = schedule $ sendIO actor message

--- The message loop of an actor with the given mailbox
messageLoop :: Actor m -> Behaviour m -> IO ()
messageLoop actor receive = do
   message <- atomically ( waitMessage $ mailbox actor )
   let response  = receive message
   let (reply, state) = runState response $ emptyActorReceiveState actor
   _ <- sequence $ ioActions state
   case reply of
        Terminate -> putMVar (killSync actor) True
        Become receive' -> messageLoop actor receive'
        _ -> messageLoop actor receive

--- Creates and starts an actor in a seperate thread with the given receive function
actor :: Behaviour m -> IO (Actor m)
actor receive = do
   mailbox <- fmap MailboxSTM $ newTVarIO (Mailbox [])
   killSync <- newEmptyMVar
   let actor = Actor { mailbox = mailbox, killSync = killSync }
   threadID <- forkIO $ messageLoop actor receive
   return actor
      
--- An example actor that receives the value of the counter
data CounterResultMessage = CounterResultMessage Integer | StartCounter
senderActor :: Actor CounterMessage -> Behaviour CounterResultMessage
senderActor counterActor StartCounter = do
   send counterActor Inc
   sender <- self
   send counterActor (GetResult sender)
   ignore

senderActor counterActor (CounterResultMessage ctr) = do
   Actors.log ctr
   send counterActor Inc
   sender <- self
   send counterActor (GetResult sender)
   ignore

--- An example counter actor
data CounterMessage = Inc | Dec | GetResult (Actor CounterResultMessage)
counterActor :: Integer -> Behaviour CounterMessage
counterActor ctr Inc = become $ counterActor (ctr+1)
counterActor ctr Dec = become $ counterActor (ctr-1)
counterActor ctr (GetResult sender) = do
   send sender (CounterResultMessage ctr)
   ignore

--- An example program to run the actors
runActors :: IO ()
runActors = do
   counter <- actor (counterActor 0)
   sender  <- actor (senderActor counter)
   sendIO sender StartCounter
   return ()

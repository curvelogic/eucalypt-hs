{-# LANGUAGE FlexibleContexts, LambdaCase #-}

{-|
Module      : Eucalypt.Stg.Machine
Description : Spineless tagless G-machine
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental

-}
module Eucalypt.Stg.Machine where

import Control.Applicative
import Control.Exception.Safe
import Data.Foldable (toList)
import qualified Data.HashMap.Strict as HM
import Data.HashMap.Strict (HashMap)
import Data.IORef
import Data.Vector (Vector, (!?))
import qualified Data.Vector as Vector
import Data.Word
import Eucalypt.Stg.Event
import Eucalypt.Stg.Error
import Eucalypt.Stg.Globals
import Eucalypt.Stg.Syn
import Prelude hiding (log)
import qualified Text.PrettyPrint as P

-- | A mutable refence to a heap object
newtype Address =
  Address (IORef HeapObject)
  deriving (Eq)

instance Show Address where
  show _ = "0x?"

-- | Allocate a new heap object, return address
allocate :: HeapObject -> IO Address
allocate obj = Address <$> newIORef obj

-- | Replace the heap object at this address
poke :: Address -> HeapObject -> IO ()
poke (Address r) = writeIORef r

-- | Retrieve the heap object at this address
peek :: Address -> IO HeapObject
peek (Address r) = readIORef r

-- | Values on the stack or in environments can be addresses or
-- primitives. All 'Ref's are resolved to 'StgValues' within the
-- machine.
data StgValue
  = StgAddr Address
  | StgNat Native
  deriving (Eq, Show)

instance StgPretty StgValue where
  prettify (StgAddr _) = P.text "<addr>"
  prettify (StgNat n) = prettify n

-- | Anything storable in an 'Address'.
data HeapObject
  = Closure { closureCode :: !LambdaForm
            , closureEnv :: !ValVec }
  | PartialApplication { papCode :: !LambdaForm
                       , papEnv :: !ValVec
                       , papArgs :: !ValVec
                       , papArity :: !Word64 }
  | BlackHole
  deriving (Eq, Show)

instance StgPretty HeapObject where
  prettify (Closure lf env) = prettify env <> P.space <> prettify lf
  prettify (PartialApplication lf env args arity) =
    prettify env <> P.space <>
    P.parens (prettify args <> P.text "..." <> P.int (fromIntegral arity)) <>
    prettify lf
  prettify BlackHole = P.text "•"

-- | Vector of values, used for both local environment and arrays of
-- resolved arguments.
newtype ValVec =
  ValVec (Vector StgValue)
  deriving (Eq, Show)

toValVec :: [StgValue] -> ValVec
toValVec = ValVec . Vector.fromList

envSize :: ValVec -> Word64
envSize (ValVec v) = fromIntegral $ Vector.length v

singleton :: StgValue -> ValVec
singleton = ValVec . Vector.singleton

extendEnv :: ValVec -> ValVec -> (ValVec, RefVec)
extendEnv env args = (env', refs)
  where
    envlen = envSize env
    arglen = envSize args
    env' = env <> args
    refs = locals envlen (arglen + envlen)

instance Semigroup ValVec where
  (<>) (ValVec l) (ValVec r) = ValVec $ l Vector.++ r

instance Monoid ValVec where
  mempty = ValVec mempty
  mappend = (<>)

instance StgPretty ValVec where
  prettify (ValVec vs) =
    P.braces $ P.hcat $ P.punctuate P.comma (map prettify (toList vs))

-- | Entry on the frame stack, encoding processing to be done later
-- when a value is available
data Continuation
  = Branch !BranchTable
           !ValVec
  | NativeBranch !NativeBranchTable
                 !ValVec
  | Update !Address
  | ApplyToArgs !ValVec
  deriving (Eq, Show)

instance StgPretty Continuation where
  prettify (Branch _ _) = P.text "Br"
  prettify (NativeBranch _ _) = P.text "NBr"
  prettify (Update _) = P.text "Up"
  prettify (ApplyToArgs _) = P.text "Ap"

-- | Currently executing code
data Code
  = Eval !StgSyn
         !ValVec
  | ReturnCon !Tag
              !ValVec
  | ReturnLit !Native
  deriving (Eq, Show)

instance StgPretty Code where
  prettify (Eval e le) =
    P.text "EVAL" <> P.space <> prettify le <> P.space <> prettify e
  prettify (ReturnCon t binds) =
    P.text "RETURNCON" <> P.space <> P.int (fromIntegral t) <> P.space <>
    prettify binds
  prettify (ReturnLit n) = P.text "RETURNLIT" <> P.space <> prettify n

-- | Machine state.
--
data MachineState = MachineState
  { machineCode :: Code
    -- ^ Next instruction to execute
  , machineGlobals :: HashMap String StgValue
    -- ^ Global (heap allocated) objects
  , machineStack :: Vector Continuation
    -- ^ stack of continuations
  , machineCounter :: Int
    -- ^ count of steps executed so far
  , machineTerminated :: Bool
    -- ^ whether the machine has terminated
  , machineTrace :: MachineState -> IO ()
    -- ^ debug action to run prior to each step
  , machineEmit :: MachineState -> Event -> IO MachineState
    -- ^ emit function to send out events
  , machineDebugEmitLog :: [Event]
    -- ^ log of emitted events for debug / testing
  }

allocGlobal :: String -> LambdaForm -> IO StgValue
allocGlobal _name impl =
  StgAddr <$> allocate (Closure {closureCode = impl, closureEnv = mempty})

-- | Initialise machine state.
initMachineState :: StgSyn -> HashMap String LambdaForm -> IO MachineState
initMachineState stg ge = do
  genv <- HM.traverseWithKey allocGlobal ge
  return $
    MachineState
      { machineCode = Eval stg mempty
      , machineGlobals = genv
      , machineStack = mempty
      , machineCounter = 0
      , machineTerminated = False
      , machineTrace = \_ -> return ()
      , machineEmit = \s _ -> return s
      , machineDebugEmitLog = []
      }

-- | Initialise machine state with the standard global defs.
initStandardMachineState :: StgSyn -> IO MachineState
initStandardMachineState s = initMachineState s standardGlobals

-- | A debug dump to use as machine's trace function
dump :: MachineState -> IO ()
dump ms = putStrLn $ P.render $ prettify ms

-- | An emit function to use for debugging
dumpEmission :: MachineState -> Event -> IO MachineState
dumpEmission ms@MachineState {machineDebugEmitLog = es} e =
  return ms {machineDebugEmitLog = es ++ [e]}

-- | Initialise machine state with a trace function that dumps state
-- every step
initDebugMachineState :: StgSyn -> IO MachineState
initDebugMachineState stg = do
  ms <- initStandardMachineState stg
  return $ ms {machineTrace = dump, machineEmit = dumpEmission}

-- | Dump machine state for debugging.
instance StgPretty MachineState where
  prettify MachineState { machineCode = code
                        , machineGlobals = _globals
                        , machineStack = stack
                        , machineCounter = counter
                        , machineDebugEmitLog = events
                        } =
    P.nest 10 $
    P.vcat
      [ P.int counter <> P.colon <> P.space <>
        P.parens (P.hcat (P.punctuate P.colon (map prettify (toList stack)))) <>
        P.space <>
        prettify code
      , if null events
          then P.empty
          else P.nest 2 (P.text ">>> " <> P.text (show events))
      ]

-- | Resolve environment references against local and global
-- environments. If a ref is still a BoundArg at the point it is
-- resolved, AttemptToResolveBoundArg will be thrown. Args are
-- resolved and recorded in environment for use.
val :: MonadThrow m => ValVec -> MachineState -> Ref -> m StgValue
val (ValVec le) _ (Local l) =
  case le !? fromIntegral l of
    Just v -> return v
    _ -> throwM EnvironmentIndexOutOfRange
val _ _ (BoundArg _) = throwM AttemptToResolveBoundArg
val _ MachineState {machineGlobals = g} (Global nm) = return $ g HM.! nm
val _ _ (Literal n) = return $ StgNat n

-- | Resolve a vector of refs against an environment to create
-- environment
vals :: MonadThrow m => ValVec -> MachineState -> Vector Ref -> m ValVec
vals le ms refs = ValVec <$> traverse (val le ms) refs

-- | Resolve a ref against env and machine to get address of
-- HeapObject
resolveHeapObject :: MonadThrow m => ValVec -> MachineState -> Ref -> m Address
resolveHeapObject env st ref =
  val env st ref >>= \case
    StgAddr r -> return r
    StgNat _ -> throwM NonAddressStgValue

resolveNative :: MonadThrow m => ValVec -> MachineState -> Ref -> m Native
resolveNative env st ref =
  val env st ref >>= \case
    StgAddr _ -> throwM NonNativeStgValue
    StgNat n -> return n

-- | Increase counters
tick :: MachineState -> MachineState
tick ms@MachineState {machineCounter = n} = ms {machineCounter = n + 1}


-- | Set the next instruction
setCode :: MachineState -> Code -> MachineState
setCode ms@MachineState {} c = ms {machineCode = c}

-- | Build a closure from a STG PreClosure
buildClosure ::
     MonadThrow m => ValVec -> MachineState -> PreClosure -> m HeapObject
buildClosure le ms (PreClosure captures code) =
  Closure code <$> vals le ms captures

-- | Allocate new closure.
allocClosure :: ValVec -> MachineState -> PreClosure -> IO Address
allocClosure le ms cc = buildClosure le ms cc >>= allocate
{-|
Module      : Eucalypt.Stg.Eval
Description : STG evaluation steps
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental

-}
module Eucalypt.Stg.Eval where

import Control.Applicative
import Control.Exception.Safe
import Control.Monad (zipWithM_)
import Control.Monad.Loops (iterateUntilM)
import Control.Monad.State
import Data.Foldable (toList)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import qualified Data.Vector as Vector
import Eucalypt.Stg.Error
import Eucalypt.Stg.Intrinsics
import Eucalypt.Stg.Machine
import Eucalypt.Stg.Syn
import Prelude hiding (log)

-- | Allocate a PAP to record args provided so far and the function
-- info already discovered
allocPartial :: ValVec -> MachineState -> LambdaForm -> ValVec -> IO Address
allocPartial le _ms lf xs = allocate pap
  where
    pap =
      PartialApplication {papCode = lf, papEnv = le, papArgs = xs, papArity = a}
    a = fromIntegral (_bound lf) - envSize xs

-- | Push a continuation onto the stack
push :: MachineState -> Continuation -> MachineState
push ms@MachineState {machineStack = st} v =
  ms {machineStack = Vector.snoc st v}

-- | Pop a continuation off the stack
pop :: MonadThrow m => MachineState -> m (Maybe Continuation, MachineState)
pop ms@MachineState {machineStack = st} =
  if Vector.null st
    then return (Nothing, ms)
    else return (Just $ Vector.last st, ms {machineStack = Vector.init st})

-- | Push an ApplyToArgs continuation on the stack
pushApplyToArgs :: MonadThrow m => MachineState -> ValVec -> m MachineState
pushApplyToArgs ms@MachineState {machineStack = stack} xs =
  return $ ms {machineStack = stack `Vector.snoc` ApplyToArgs xs}

-- | Branch expressions expect to find their args as the top entries
-- in the environment (and right now the compiler needs to work out
-- where...)
selectBranch :: BranchTable -> Tag -> Maybe StgSyn
selectBranch (BranchTable bs _ _) t = snd <$> Map.lookup t bs

-- | Match a native branch table alternative, return the next
-- expression to eval
selectNativeBranch :: BranchTable -> Native -> Maybe StgSyn
selectNativeBranch (BranchTable _ bs _) n = HM.lookup n bs

-- | Halt the machine
terminate :: MachineState -> MachineState
terminate ms@MachineState{} = ms {machineTerminated = True}

-- | Call a lambda form by putting args in environment and rewiring
-- refs then evaluating.
call :: MonadThrow m => ValVec -> MachineState -> LambdaForm -> ValVec -> m Code
call env _ms code addrs = do
  let env' = env <> addrs
  let code' = argsAt (fromIntegral (envSize env)) (_body code)
  return (Eval code' env')



-- | Main machine step function
step :: (MonadIO m, MonadThrow m) => MachineState -> m MachineState
step ms@MachineState {machineTerminated = True} =
  prepareStep "TERM" ms >> throwM SteppingTerminated
step ms0@MachineState {machineCode = (Eval (App f xs) env)} = do
  ms <- prepareStep "EVAL APP" ms0
  let len = length xs
  case f of
    Ref r -> do
      addr <- resolveHeapObject env ms r
      obj <- liftIO $ peek addr
      case obj of
        Closure lf@LambdaForm {_bound = ar} le ->
          case compare (fromIntegral len) ar
            -- EXACT
                of
            EQ ->
              setRule "EXACT" . setCode ms <$>
              (vals env ms xs >>= call le ms lf)
            -- CALLK
            GT ->
              let (enough, over) = Vector.splitAt (fromIntegral ar) xs
               in vals env ms over >>= pushApplyToArgs ms >>= \s ->
                    setRule "CALLK" . setCode s <$>
                    (vals env ms enough >>= call le ms lf)
            -- PAP2
            LT ->
              if len == 0
                then return $ (setRule "PAP2-0" . setCode ms) (ReturnFun addr)
                else liftIO $
                     vals env ms xs >>= allocPartial le ms lf >>= \a ->
                       return $ (setRule "PAP2" . setCode ms) (ReturnFun a)
        -- PCALL
        PartialApplication code le args ar ->
          case compare (fromIntegral len) ar of
            EQ ->
              vals env ms xs >>= \as ->
                setRule "PCALL EXACT" . setCode ms <$>
                call le ms code (args <> as)
            GT ->
              let (enough, over) = Vector.splitAt (fromIntegral ar) xs
               in vals env ms over >>= pushApplyToArgs ms >>= \s ->
                    vals env ms enough >>= \as ->
                      setRule "PCALLK" . setCode s <$>
                      call le ms code (args <> as)
            LT ->
              if len == 0
                then return $ -- return fun?
                     (setRule "PCALL PAP2-0" . setCode ms) (ReturnFun addr)
                else liftIO $
                     vals env ms xs >>= allocPartial le ms code >>= \a ->
                       return $
                       (setRule "PCALL PAP2" . setCode ms) (ReturnFun a)
        BlackHole -> throwM EnteredBlackHole
    -- must be saturated
    Con t -> do
      env' <- vals env ms xs
      return $ setCode ms (ReturnCon t env')
    -- must be saturated
    Intrinsic i ->
      let mf = intrinsicFunction i
       in liftIO $ vals env ms xs >>= mf ms



-- | LET
step ms0@MachineState {machineCode = (Eval (Let pcs body) env)} = do
  ms <- prepareStep "EVAL LET" ms0
  addrs <- liftIO $ traverse (allocClosure env ms) pcs
  let env' = env <> (ValVec . Vector.map StgAddr) addrs
  return $ setCode ms (Eval body env')



-- | LET (recursive)
step ms0@MachineState {machineCode = (Eval (LetRec pcs body) env)} = do
  ms <- prepareStep "EVAL LETREC" ms0
  addrs <- liftIO $ sequenceA $ replicate (length pcs) (allocate BlackHole)
  let env' = env <> (toValVec . map StgAddr) addrs
  closures <- traverse (buildClosure env' ms) pcs
  liftIO $ zipWithM_ poke addrs (toList closures)
  return $ setCode ms (Eval body env')



-- | CASE
step ms0@MachineState {machineCode = (Eval (Case syn k) env)} = do
  ms <- prepareStep "EVAL CASE" ms0
  return $ setCode (push ms (Branch k env)) (Eval syn env)



-- | ReturnCon - returns a data structure into a BranchTable branch
step ms0@MachineState {machineCode = (ReturnCon t xs)} = do
  ms <- prepareStep "RETURNCON" ms0
  (entry, ms') <- pop ms
  case entry of
    (Just (Branch k le)) ->
      case selectBranch k t
        -- | CASECON
            of
        (Just expr) -> return $ setCode ms' (Eval expr (le <> xs))
        -- | CASEANY
        Nothing -> do
          addr <-
            liftIO $
            allocate
              (Closure
                 (LambdaForm 0 0 False (App (Con t) (locals 0 (envSize xs))))
                 xs)
          case defaultBranch k of
            (Just expr) ->
              return $
               setCode ms' (Eval expr (le <> singleton (StgAddr addr)))
            Nothing -> throwM NoBranchFound
    (Just (Update a)) -> do
      liftIO $ poke a (Closure (standardConstructor (envSize xs) t) xs)
      return ms'
    (Just (ApplyToArgs _)) -> throwM ArgInsteadOfBranchTable
    Nothing -> return $ terminate ms'



-- | ReturnLit - returns a native value to a NativeBranchTable or
-- terminates if none.
step ms0@MachineState {machineCode = (ReturnLit nat)} = do
  ms <- prepareStep "RETURNLIT" ms0
  (entry, ms') <- pop ms
  case entry of
    (Just (Branch k le)) ->
      case selectNativeBranch k nat of
        -- CASECON
        (Just expr) -> return $ setCode ms' (Eval expr le)
        -- CASEANY (lit)
        Nothing ->
          case defaultBranch k of
            (Just expr) ->
              return $ setCode ms' (Eval expr (le <> singleton (StgNat nat)))
            Nothing -> throwM NoBranchFound
    (Just (Update _)) -> throwM LiteralUpdate
    (Just (ApplyToArgs _)) -> throwM ArgInsteadOfNativeBranchTable
    Nothing -> return $ terminate ms'



-- | ReturnFun - returns a callable into either a continuation that
-- will apply it or a case expressions that can inspect it (closed?)
step ms0@MachineState {machineCode = (ReturnFun r)} = do
  ms <- prepareStep "RETURNFUN" ms0
  (entry, ms') <- pop ms
  case entry of
    (Just (ApplyToArgs addrs)) ->
      let (env', args') = extendEnv mempty $ singleton (StgAddr r) <> addrs
       in return $ setCode ms' (Eval (App (Ref $ Local 0) args') env')
    -- RETFUN into case default... (for forcing lambda-valued exprs)
    (Just (Branch (BranchTable _ _ (Just expr)) le)) ->
      return $ setCode ms' (Eval expr (le <> singleton (StgAddr r)))
    -- (Just (Update a)) -> do  -- update with indirect?
    --   liftIO $ poke a (Closure (standardConstructor (envSize xs) t) xs)
    --   return ms'
    _ ->
      return $
      setCode ms' (Eval (App (Ref $ Local 0) mempty) (singleton (StgAddr r)))



-- | In most cases, we punt on to Eval App which should cause
-- ReturnCon or ReturnLit when we reach a value
step ms0@MachineState {machineCode = (Eval (Atom ref) env)} = do
  ms <- prepareStep "EVAL ATOM" ms0
  v <- val env ms ref
  case v of
    StgAddr _ ->
      return $ setCode ms (Eval (App (Ref $ Local 0) mempty) (singleton v)) -- (ReturnFun a) -- what if it's a thunk?
    StgNat n -> return $ setCode ms (ReturnLit n)



-- | Step repeatedly until the terminated flag is set
run :: (MonadIO m, MonadThrow m) => MachineState -> m MachineState
run = iterateUntilM machineTerminated step

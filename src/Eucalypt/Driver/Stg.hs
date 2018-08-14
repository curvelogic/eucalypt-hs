{-|
Module      : Eucalypt.Driver.Stg
Description : Drive compilation, evaluation and render using STG
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}

module Eucalypt.Driver.Stg
  ( render
  , dumpStg
  ) where

import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Eucalypt.Core.Syn (CoreExpr)
import Eucalypt.Driver.Options (EucalyptOptions(..))
import qualified Eucalypt.Stg.Compiler as C
import Eucalypt.Stg.Eval (run)
import Eucalypt.Stg.Event (Event(..))
import Eucalypt.Stg.Machine
  ( MachineState(..)
  , dumpEmission
  , initStandardMachineState
  )
import Eucalypt.Stg.Syn (StgPretty(..), StgSyn)
import qualified Text.PrettyPrint as P

-- | Compile, install a render sink and run
render :: EucalyptOptions -> CoreExpr -> IO ()
render opts expr = do
  syn <- compile expr
  ms <- machine syn
  void $ run ms {machineEmit = emit}
  where
    format = fromMaybe "yaml" (optionExportFormat opts)
    emit = selectRenderSink format

-- | Dump STG expression to stdout
dumpStg :: EucalyptOptions -> CoreExpr -> IO ()
dumpStg _opts expr = compile expr >>= putStrLn . P.render . prettify

-- | Compile Core to STG
compile :: CoreExpr -> IO StgSyn
compile expr = return $ C.compile 0 C.emptyContext expr

-- | Instantiate the STG machine
machine :: StgSyn -> IO MachineState
machine = initStandardMachineState

-- | Select an emit function appropriate to the render format
selectRenderSink :: String -> MachineState -> Event -> IO MachineState
selectRenderSink _format = dumpEmission
{-|
Module      : Eucalypt.Stg.Intrinsics.Dict
Description : Basic dict built-ins for the STG evaluator
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}

module Eucalypt.Stg.Intrinsics.Dict
  ( intrinsics
  ) where

import Eucalypt.Stg.Intrinsics.Common
import Eucalypt.Stg.IntrinsicInfo
import Eucalypt.Stg.Error
import Eucalypt.Stg.Syn
import Eucalypt.Stg.Machine
import qualified Data.Map.Strict as MS
import Data.Sequence ((!?))

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}

intrinsics :: [IntrinsicInfo]
intrinsics =
  [ IntrinsicInfo "EMPTYDICT" 0 emptyDict
  , IntrinsicInfo "DICTCONTAINSKEY" 2 dictContainsKey
  , IntrinsicInfo "DICTGET" 2 dictGet
  , IntrinsicInfo "DICTPUT" 2 dictPut
  , IntrinsicInfo "DICTDEL" 2 dictDel
  , IntrinsicInfo "DICTENTRIES" 2 dictEntries
  ]

getDictAndKey
  :: MachineState -> ValVec -> IO (MS.Map Native Native, Native)
getDictAndKey ms args = do
  ns <- getNatives ms args
  let (Just (NativeDict d)) = ns !? 0
  let (Just k) = ns !? 1
  return (d, k)

getDictKeyAndValue
  :: MachineState
     -> ValVec -> IO (MS.Map Native Native, Native, Native)
getDictKeyAndValue ms args= do
  ns <- getNatives ms args
  let (Just (NativeDict d)) = ns !? 0
  let (Just k) = ns !? 1
  let (Just v) = ns !? 2
  return (d, k, v)

-- | __EMPTYDICT
emptyDict :: MachineState -> ValVec -> IO MachineState
emptyDict ms _ = return $ setCode ms (ReturnLit (NativeDict MS.empty) Nothing)

-- | __DICTCONTAINSKEY(d, k)
dictContainsKey :: MachineState -> ValVec -> IO MachineState
dictContainsKey ms args = do
  (d, k) <- getDictAndKey ms args
  return $ setCode ms (ReturnLit (NativeBool $ k `MS.member` d) Nothing)

-- | __DICTGET(d, k)
dictGet :: MachineState -> ValVec -> IO MachineState
dictGet ms args = do
  (d, k) <- getDictAndKey ms args
  case MS.lookup k d of
    Just n -> return $ setCode ms (ReturnLit n Nothing)
    Nothing -> throwIn ms $ DictKeyNotFound k

-- | __DICTPUT(d, k, v)
dictPut :: MachineState -> ValVec -> IO MachineState
dictPut ms args = do
  (d, k, v) <- getDictKeyAndValue ms args
  return $ setCode ms (ReturnLit (NativeDict $ MS.insert k v d) Nothing)

-- | __DICTDEL(d, k)
dictDel :: MachineState -> ValVec -> IO MachineState
dictDel ms args = do
  (d, k) <- getDictAndKey ms args
  return $ setCode ms (ReturnLit (NativeDict $ MS.delete k d) Nothing)

-- | __DICTENTRIES(d)
dictEntries :: MachineState -> ValVec -> IO MachineState
dictEntries ms (ValVec args) = do
  let (Just (StgNat (NativeDict d) _)) = args !? 0
  returnNatPairList ms (MS.assocs d)

{-|
Module      : Eucalypt.Stg.Globals.Str
Description : String and regex globals for STG implementation
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}

module Eucalypt.Stg.Globals.Str
  ( euMatch
  , euMatches
  , euJoin
  , euSplit
  , euStr
  , euSym
  ) where

import Eucalypt.Stg.Syn
import Eucalypt.Stg.Intrinsics (intrinsicIndex)



euMatch :: LambdaForm
euMatch =
  lam_ 0 2 $
  ann_ "__MATCH" $
  force_ (Atom (BoundArg 0)) $
  force_ (Atom (BoundArg 1)) $
  appbif_ (intrinsicIndex "MATCH") [Local 2, Local 3]



euMatches :: LambdaForm
euMatches =
  lam_ 0 2 $
  ann_ "__MATCHES" $
  force_ (Atom (BoundArg 0)) $
  force_ (Atom (BoundArg 1)) $
  appbif_ (intrinsicIndex "MATCHES") [Local 2, Local 3]



euJoin :: LambdaForm
euJoin =
  lam_ 0 2 $
  ann_ "__JOIN" $
  let_
    [pc_ [BoundArg 0] $ thunkn_ 1 $ appfn_ (Global "seqNatList") [Local 0]]
    (force_
       (Atom (BoundArg 1))
       (force_ (Atom (Local 2)) $
        appbif_ (intrinsicIndex "JOIN") [Local 4, Local 3]))


-- | SPLIT(s, re)
euSplit :: LambdaForm
euSplit =
  let s = BoundArg 0
      re = BoundArg 1
      es = Local 2
      ere = Local 3
   in lam_ 0 2 $
      ann_ "__SPLIT" $
      force_
        (Atom s)
        (force_ (Atom re) $ appbif_ (intrinsicIndex "SPLIT") [es, ere])


-- | __STR(n) - only supports natives for now
euStr :: LambdaForm
euStr =
  lam_ 0 1 $
  ann_ "__STR" $
  force_ (Atom (BoundArg 0)) (appbif_ (intrinsicIndex "STRNAT") [Local 1])


-- | __SYM(n)
euSym :: LambdaForm
euSym =
  lam_ 0 1 $
  ann_ "__SYM" $
  force_ (Atom (BoundArg 0)) (appbif_ (intrinsicIndex "STRSYM") [Local 1])

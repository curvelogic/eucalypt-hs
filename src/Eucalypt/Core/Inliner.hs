{-|
Module      : Eucalypt.Core.Inliner
Description : Pass for inlining definitions
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}
module Eucalypt.Core.Inliner where

import Data.Bifunctor
import Bound
import Eucalypt.Core.Syn


inline :: CoreExp a -> CoreExp a
inline = betaReduce . distribute . tagInlinables



distribute :: CoreExp a -> CoreExp a
distribute (CoreLet smid bs b) =
  CoreLet smid bindings body
  where
    bindingsToInline = map (selectScopeForInline . snd) bs
    body = instantiateSome bindingsToInline b
    bindings = map (second $ instantiateSome bindingsToInline) bs
distribute (CoreMeta smid m e) = CoreMeta smid (distribute m) $ distribute e
distribute (CoreLookup smid b e) = CoreLookup smid (distribute b) e
distribute (CoreList smid xs) = CoreList smid (map distribute xs)
distribute (CoreBlock smid l) = CoreBlock smid $ distribute l
distribute (CoreApply smid f xs) =
  CoreApply smid (distribute f) (map distribute xs)
distribute (CoreOperator _ _ _ e) = e
distribute e = e



instantiateSome ::
     [Maybe (Scope Int CoreExp a)]
  -> Scope Int CoreExp a
  -> Scope Int CoreExp a
instantiateSome bs e = Scope $ unscope e >>= k
  where
    k v =
      case v of
        B b -> case bs !! b of
                 Nothing -> CoreVar 0 $ B b
                 Just sub -> distribute $ unscope sub
        F a -> CoreVar 0 $ F a




selectScopeForInline :: Scope Int CoreExp a -> Maybe (Scope Int CoreExp a)
selectScopeForInline (Scope e) = Scope <$> selectForInline e



selectForInline :: CoreExp a -> Maybe (CoreExp a)
selectForInline e =
  if isSynonym e || isInlinable e
    then Just e
    else Nothing



isSynonym :: CoreExp a -> Bool
isSynonym CoreBuiltin{} = True
isSynonym CoreVar{} = True
isSynonym _ = False



isInlinable :: CoreExp a -> Bool
isInlinable (CoreLambda _ True _ _ ) = True
isInlinable _ = False



isTransposition :: Scope Int CoreExp a -> Bool
isTransposition s = case unscope s of
  (CoreApply _ f xs) -> all isVar xs && isSimple f
  _ -> False
  where
    isVar CoreVar{} = True
    isVar _ = False
    isSimple CoreBuiltin{} = True
    isSimple CoreVar{} = True
    isSimple _ = False



tagInlinables :: CoreExp a -> CoreExp a
tagInlinables e@(CoreLambda smid False ns body) =
  if isTransposition body
  then
    CoreLambda smid True ns body
  else
    e
tagInlinables (CoreLet smid bs b) = CoreLet smid bs' b'
  where
    b' = tagInlinablesScope b
    bs' = map (second tagInlinablesScope) bs
    tagInlinablesScope = Scope . tagInlinables . unscope
tagInlinables (CoreMeta smid m e) = CoreMeta smid (tagInlinables m) $ tagInlinables e
tagInlinables (CoreLookup smid b e) = CoreLookup smid (tagInlinables b) e
tagInlinables (CoreList smid xs) = CoreList smid (map tagInlinables xs)
tagInlinables (CoreBlock smid l) = CoreBlock smid $ tagInlinables l
tagInlinables (CoreApply smid f xs) =
  CoreApply smid (tagInlinables f) (map tagInlinables xs)
tagInlinables (CoreOperator _ _ _ e) = e
tagInlinables e = e



betaReduce :: CoreExp a -> CoreExp a
betaReduce (CoreApply _ (CoreLambda _ True _ body) xs) =
  instantiate (xs !!) body
betaReduce (CoreLambda smid i ns body) =
  CoreLambda smid i ns $ (Scope . betaReduce . unscope) body
betaReduce (CoreLet smid bs b) =
  CoreLet smid bs' b'
  where
    b' = betaReduceScope b
    bs' = map (second betaReduceScope) bs
    betaReduceScope = Scope . betaReduce . unscope
betaReduce (CoreMeta smid m e) = CoreMeta smid (betaReduce m) $ betaReduce e
betaReduce (CoreLookup smid b e) = CoreLookup smid (betaReduce b) e
betaReduce (CoreList smid xs) = CoreList smid (map betaReduce xs)
betaReduce (CoreBlock smid l) = CoreBlock smid $ betaReduce l
betaReduce e = e

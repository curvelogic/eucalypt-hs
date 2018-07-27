{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE LambdaCase, TemplateHaskell, DeriveFunctor,
  DeriveFoldable, DeriveTraversable, FlexibleContexts,
  FlexibleInstances, TupleSections #-}
{-# OPTIONS_GHC -fno-warn-missing-methods #-}
{-|
Module      : Eucalypt.Core.Syn
Description : Core expression forms for the Eucalypt language
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}

module Eucalypt.Core.Syn
where

import Bound
import Bound.Scope
import Control.Monad.State.Strict
import Data.Char (isDigit)
import Data.Deriving (deriveEq1, deriveOrd1, deriveRead1, deriveShow1)
import Data.Functor.Classes
import Data.List (elemIndex)
import Data.Maybe
import Data.Traversable (for)
import Data.Bifunctor (second)
import Eucalypt.Core.Anaphora
import Safe (maximumMay)

-- | Primitive types (literals are available in the eucalypt syntax)
data Primitive
  = CoreInt Integer
  | CoreFloat Double
  | CoreString String
  | CoreSymbol String
  | CoreBoolean Bool
  | CoreNull
  deriving (Eq, Show, Read, Ord)



-- | A name in a block namespace, used in lookups
type CoreRelativeName = String



-- | A name used for a (free) binding
type CoreBindingName = String


-- | Type used to name intrinsics
type CoreBuiltinName = String


-- | Fixity of operator
data Fixity = UnaryPrefix | UnaryPostfix | InfixLeft | InfixRight
  deriving (Eq, Show, Read, Ord)

fixityArity :: Fixity -> Int
fixityArity UnaryPostfix = 1
fixityArity UnaryPrefix = 1
fixityArity _ = 2

-- | Precedence of operator
type Precedence = Int


-- | A new bound-based implementation, with multi-arity to allow STG
-- later.
--
data CoreExp a
  = CoreVar a
  | CoreLet [(CoreBindingName, Scope Int CoreExp a)] (Scope Int CoreExp a)
  | CoreBuiltin CoreBuiltinName
  | CorePrim Primitive
  | CoreLookup (CoreExp a) CoreRelativeName
  | CoreName CoreRelativeName -- ^ new parser - relative lookup name
  | CoreList [CoreExp a]
  | CoreBlock (CoreExp a)
  | CoreMeta (CoreExp a) (CoreExp a)
  | CoreArgTuple [CoreExp a] -- ^ new parser
  | CoreLambda Int (Scope Int CoreExp a)
  | CoreApply (CoreExp a) [CoreExp a]
  | CoreOpSoup [CoreExp a]
  | CoreOperator Fixity Precedence (CoreExp a) -- ^ new parser
  | CorePAp Int (CoreExp a) [CoreExp a] -- ^ during evaluation only
  | CoreTraced (CoreExp a) -- ^ during evaluation only
  | CoreChecked (CoreExp a) (CoreExp a) -- ^ during evaluation only
  deriving (Functor,Foldable,Traversable)


-- | Core expression using a simple string binding name
type CoreExpr = CoreExp CoreBindingName

-- | True if expression is a block
isBlock :: CoreExp a -> Bool
isBlock (CoreBlock _) = True
isBlock _ = False


-- | True if expression is a list
isList :: CoreExp a -> Bool
isList (CoreList _) = True
isList _ = False


-- | Return the name of a symbol if the expression is a symbol.
symbolName :: CoreExp a -> Maybe String
symbolName (CorePrim (CoreSymbol s)) = Just s
symbolName _ = Nothing



-- | String content of string literal if the expression is a string.
stringContent :: CoreExp a -> Maybe String
stringContent (CorePrim (CoreString s)) = Just s
stringContent _ = Nothing



deriveEq1   ''CoreExp
deriveOrd1  ''CoreExp
deriveRead1 ''CoreExp
deriveShow1 ''CoreExp
instance Eq a => Eq (CoreExp a) where (==) = eq1
instance Ord a => Ord (CoreExp a) where compare = compare1
instance Show a => Show (CoreExp a) where showsPrec = showsPrec1
instance Read a => Read (CoreExp a) where readsPrec = readsPrec1



instance Applicative CoreExp where
  pure = CoreVar
  (<*>) = ap



instance Monad CoreExp where
  return = CoreVar
  CoreVar a >>= f = f a
  CoreLet bs b >>= f = CoreLet (map (second (>>>= f)) bs) (b >>>= f)
  CoreBuiltin n >>= _ = CoreBuiltin n
  CorePAp a e as >>= f = CorePAp a (e >>= f) (map (>>= f) as)
  CorePrim p >>= _ = CorePrim p
  CoreLookup e n >>= f = CoreLookup (e >>= f) n
  CoreList es >>= f = CoreList (map (>>= f) es)
  CoreBlock e >>= f = CoreBlock (e >>= f)
  CoreMeta m e >>= f = CoreMeta (m >>= f) (e >>= f) -- TODO: separate meta?
  CoreTraced e >>= f = CoreTraced (e >>= f)
  CoreChecked check e >>= f = CoreChecked (check >>= f) (e >>= f)
  CoreOpSoup es >>= f = CoreOpSoup (map (>>= f) es)
  CoreLambda n e >>= f = CoreLambda n (e >>>= f)
  CoreOperator x p e >>= f = CoreOperator x p (e >>= f)
  CoreArgTuple es >>= f = CoreArgTuple (map (>>= f) es)
  CoreApply g es >>= f = CoreApply (g >>= f) (map (>>= f) es)
  CoreName n >>= _ = CoreName n

-- | Construct a var
var :: a -> CoreExp a
var = CoreVar



-- | Construct a name (maybe be a relative name, not a var)
corename :: CoreRelativeName -> CoreExp a
corename = CoreName



-- | Abstract lambda of several args
lam :: [CoreBindingName] -> CoreExpr -> CoreExpr
lam as expr = CoreLambda (length as) scope
  where
    scope = abstract (`elemIndex` as) expr



--- | Construct a function application
app :: CoreExp a -> [CoreExp a] -> CoreExp a
app = CoreApply



-- | Construct recursive let of several bindings
letexp :: [(CoreBindingName, CoreExpr)] -> CoreExpr -> CoreExpr
letexp [] b = b
letexp bs b = CoreLet (map (second abstr) bs) (abstr b)
  where abstr = abstract (`elemIndex` map fst bs)



-- | Construct boolean expression
corebool :: Bool -> CoreExp a
corebool = CorePrim . CoreBoolean



-- | Construct null expression
corenull :: CoreExp a
corenull = CorePrim CoreNull



-- | CoreList
corelist :: [CoreExp a] -> CoreExp a
corelist = CoreList



-- | Construct symbol expression
sym :: String -> CoreExp a
sym = CorePrim . CoreSymbol



-- | Construct builtin expression
bif :: String -> CoreExp a
bif = CoreBuiltin



-- | Construct an integer expression
int :: Integer -> CoreExp a
int = CorePrim . CoreInt



-- | Construct an integer expression
float :: Double -> CoreExp a
float = CorePrim . CoreFloat



-- | Construct a string expression
str :: String -> CoreExp a
str = CorePrim . CoreString



-- | A block element from string key and expr value
element :: String -> CoreExp a -> CoreExp a
element k v = CoreList [sym k, v]



-- | A block from its items
block :: [CoreExp a] -> CoreExp a
block items = CoreBlock $ CoreList items



-- | Apply metadata to another expression
withMeta :: CoreExp a -> CoreExp a -> CoreExp a
withMeta = CoreMeta



-- | A left-associative infix operation
infixl_ :: Precedence -> CoreExp a -> CoreExp a
infixl_ = CoreOperator InfixLeft



-- | A right-associative infix operation
infixr_ :: Precedence -> CoreExp a -> CoreExp a
infixr_ = CoreOperator InfixRight



-- | A unary prefix operator
prefix_ :: Precedence -> CoreExpr -> CoreExpr
prefix_ = CoreOperator UnaryPrefix



-- | A unary postfix operat
postfix_ :: Precedence -> CoreExpr -> CoreExpr
postfix_ = CoreOperator UnaryPostfix



-- | Operator soup without explicit brackets
soup :: [CoreExpr] -> CoreExpr
soup = CoreOpSoup



-- | Arg tuple constructor
args :: [CoreExpr] -> CoreExpr
args = CoreArgTuple

-- $ special operators
--


-- | Catenation operator
catOp :: CoreExp a
catOp = infixl_ 20 (CoreBuiltin "CAT")



-- | Function calls using arg tuple are treated as operator during the
-- fixity / precedence resolution phases but formed into core syntax
-- after that.
callOp :: CoreExp a
callOp = infixl_ 90 (CoreBuiltin "*CALL*")



-- | Name lookup is treated as operator during the fixity / precedence
-- resolution phases but formed into core syntax after that.
lookupOp :: CoreExpr
lookupOp = infixl_ 95 (CoreBuiltin "*DOT*")

-- ? anaphora
--
-- These are instances and functions for handling expression anaphora
-- (e.g '_', '_0', '_1',...) which implicitly define lambdas by
-- referring to automatic parameters

instance Anaphora String where
  unnumberedAnaphor = "_"

  isAnaphor s
    | s == "_" = True
    | (isJust . anaphorIndex) s = True
  isAnaphor _ = False

  toNumber = anaphorIndex

  fromNumber n = "_" ++ show n

  toName = id

instance (Anaphora a, Eq b, Show b) => Anaphora (Var b a) where
  unnumberedAnaphor = F unnumberedAnaphor

  isAnaphor (F s)
    | isAnaphor s = True
    | (isJust . anaphorIndex . toName) s = True
  isAnaphor _ = False

  toNumber (F s) = anaphorIndex (toName s)
  toNumber _ = Nothing

  fromNumber n = F $ fromNumber n

  toName (F s) = toName s
  toName (B _) = ""


expressionAnaphor :: (Anaphora a) => CoreExp a
expressionAnaphor = var unnumberedAnaphor

isAnaphoricVar :: (Anaphora a) => CoreExp a -> Bool
isAnaphoricVar (CoreVar s) = isAnaphor s
isAnaphoricVar _ = False

applyNumber :: (Anaphora a, Eq a) => a -> State Int a
applyNumber s | s == unnumberedAnaphor = do
  n <- get
  put (n + 1)
  return $ fromNumber n
applyNumber x = return x


-- | Is it the name of an anahoric parameter? @_@ doesn't count as it
-- should have been substituted for a numbered version by cooking.
anaphorIndex :: String -> Maybe Int
anaphorIndex ('_':s:_) | isDigit s  = Just (read [s] :: Int)
anaphorIndex _ = Nothing


-- | Add numbers to numberless anaphora
numberAnaphora :: Anaphora a => CoreExp a -> CoreExp a
numberAnaphora expr = flip evalState (0 :: Int) $ for expr applyNumber



-- | Bind anaphora
--
-- Wrap a lambda around the expression, binding all anaphoric
-- parameters unless there are none in which case return the
-- expression unchanged
bindAnaphora :: Anaphora a => CoreExp a -> CoreExp a
bindAnaphora expr =
  case maxAnaphor of
    Just n -> CoreLambda (n + 1) $ abstract toNumber expr
    Nothing -> expr
  where
    freeVars = foldr (:) [] expr
    freeAnaphora = mapMaybe toNumber freeVars
    maxAnaphor = maximumMay freeAnaphora


-- $ substitutions
--
-- The crude bootstrap interpreter just manipulates core expressions.
-- We keep the abstraction and instantiation workings (using the Bound
-- library) in here.
--

-- | Instantiate arguments into lambda body (new multi-arg lambda)
--
instantiateBody :: [CoreExpr] -> Scope Int CoreExp CoreBindingName -> CoreExpr
instantiateBody vals = instantiate (vals !!)

-- | Use Bound to wire the bindings into the appropriate places in the
-- expressions (lazily...)
instantiateLet :: CoreExpr -> CoreExpr
instantiateLet (CoreLet bs b) = inst b
  where
    es = map (inst . snd) bs
    inst = instantiate (es !!)
instantiateLet _ = error "instantiateLet called on non-let"


-- ? rebodying

-- | Allows us to retrieve the CoreBindingName of a variable even when
-- it is wrapped in several layers of 'Var'
class ToCoreBindingName c where
  toCoreBindingName :: c -> Maybe CoreBindingName

instance ToCoreBindingName String where
  toCoreBindingName = Just

instance ToCoreBindingName a => ToCoreBindingName (Var b a) where
  toCoreBindingName v = case v of
    F a -> toCoreBindingName a
    B _ -> Nothing


-- | Navigates down through lets and transparent expressions (like
-- metadata and traces) and replaces the innermost body, binding free
-- expressions in that body according to the bindings of the
-- containing lets.
rebody :: (ToCoreBindingName a, Show a) => CoreExp a -> CoreExp a -> CoreExp a
rebody (CoreLet bs body) payload =
  let payload' = rebody (fromScope body) (fmap return payload)
   in CoreLet bs (bindMore'' toNameAndBinding (toScope payload'))
  where
    toNameAndBinding :: ToCoreBindingName a => a -> Maybe (CoreBindingName, Int)
    toNameAndBinding nm =
      case toCoreBindingName nm of
        (Just b) -> (b, ) <$> (b `elemIndex` map fst bs)
        Nothing -> Nothing
rebody (CoreMeta m e) payload = CoreMeta m (rebody e payload)
rebody (CoreTraced e) payload = CoreTraced (rebody e payload)
rebody (CoreChecked _ e) payload = rebody e payload
rebody _ payload = payload


-- | For binding further free variables in an expression that has
-- already been abstracted once and is therefore a Scope.
bindMore'' ::
     Monad f
  => (a -> Maybe (CoreBindingName, b))
  -> Scope b f a
  -> Scope b f a
bindMore'' k = toScope . bindFree . fromScope
  where
    bindFree e =
      e >>= \v ->
        return $
        case v of
          F a -> bind a
          B b -> B b
    bind a =
      case k a of
        (Just (_, z)) -> B z
        Nothing -> F a



-- | For binding further free variables in an expression that has
-- already been abstracted once and is therefore a Scope.
bindMore ::
     Monad f => (a -> Maybe b) -> Scope b f a -> Scope b f a
bindMore k = toScope . bindFree . fromScope
  where
    bindFree e =
      e >>= \v ->
        return $
        case v of
          F a -> bind a
          B b -> B b
    bind a =
      case k a of
        Just z -> B  z
        Nothing -> F a



-- | Modify (e.g. wrap) bound variables as specified by the
-- transformation function 'k'.
modifyBoundVars ::
     Monad f
  => (b -> f (Var b (f a)) -> f (Var b (f a)))
  -> Scope b f a
  -> Scope b f a
modifyBoundVars k e =
  Scope $
  unscope e >>= \case
      B b ->
        let f = k b
         in f (pure (B b))
      F a -> pure $ F a


-- | Replace bound variables in let and lambda bodies with
-- appropriately named free variables. Handy for inspecting
-- expression in tests.
unbind :: CoreExpr -> CoreExpr
unbind (CoreLambda _ e) = instantiate (CoreVar . show) e
unbind (CoreLet bs body) = inst body
  where
    names = map fst bs
    inst = instantiate (\n -> CoreVar (names !! n))
unbind e = e


-- | Pull a unit (let or block) apart into bindings and body
unitBindingsAndBody ::
  CoreExpr
  -> ([(CoreBindingName, Scope Int CoreExp CoreBindingName)],
      Scope Int CoreExp CoreBindingName)
unitBindingsAndBody (CoreLet bs b) = (bs, b)
unitBindingsAndBody e@CoreBlock{} = ([], abstract (const Nothing) e)
unitBindingsAndBody CoreList{} = error "Input is a sequence and must be named."
unitBindingsAndBody _ = error "Unsupported unit type (not block or sequence)"


-- | Merge bindings from core units, using body of final unit as
-- default body.
--
mergeUnits :: [CoreExpr] -> CoreExpr
mergeUnits lets = last newLets
  where
    (bindLists, bodies) = unzip (map unitBindingsAndBody lets)
    bindLists' = scanl1 rebindBindings bindLists
    bodies' = zipWith rebindBody bodies bindLists'
    rebindBindings establishedBindings nextBindings =
      let abstr =
            bindMore
              (\n ->
                 (length nextBindings +) <$>
                 (n `elemIndex` map fst establishedBindings))
          shift = mapBound (\i -> i + length nextBindings)
          reboundNextBindings = map (second abstr) nextBindings
          shiftedEstablishedBindings = map (second shift) establishedBindings
      in reboundNextBindings ++ shiftedEstablishedBindings
    rebindBody oldBody newBindList =
      let abstr = bindMore (`elemIndex` map fst newBindList)
       in abstr oldBody
    newLets = zipWith CoreLet bindLists' bodies'

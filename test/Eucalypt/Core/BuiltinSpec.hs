module Eucalypt.Core.BuiltinSpec
  ( main
  , spec
  ) where

import Eucalypt.Core.Builtin
import Eucalypt.Core.Error
import Eucalypt.Core.EvalByName
import Eucalypt.Core.Interpreter
import Eucalypt.Core.Syn
import Test.Hspec
import Test.QuickCheck

main :: IO ()
main = hspec spec


-- | Evaluate a zero arity builtin
shallowEvalBuiltin :: CoreBuiltinName -> Either EvaluationError CoreExpr
shallowEvalBuiltin name =
  runInterpreter
    (case lookupBuiltin name of
       Just (_, f) -> f return []
       Nothing -> throwEvalError (BuiltinNotFound name (bif ("__" ++ name))))


-- | A panic to use in contexts which should not be evaluated
abort :: CoreExpr
abort = CoreApp (bif "PANIC") (str "Should not have been evaluated")


spec :: Spec
spec = do
  describe "Builtin lookup" $ do
    it "has null" $ shallowEvalBuiltin "NULL" `shouldBe` Right corenull
    it "has true" $ shallowEvalBuiltin "TRUE" `shouldBe` Right (corebool True)
    it "has false" $
      shallowEvalBuiltin "FALSE" `shouldBe` Right (corebool False)
    it "fails sensibly" $
      shallowEvalBuiltin "NONESUCH" `shouldBe`
      Left (BuiltinNotFound "NONESUCH" (bif "__NONESUCH"))
  describe "Boolean operators" $ -- TODO: quickcheck properties
   do
    it "calculates and" $
      runInterpreter (euAnd return [corebool True, corebool False]) `shouldBe`
      Right (corebool False)
    it "calculates or" $
      runInterpreter (euOr return [corebool True, corebool False]) `shouldBe`
      Right (corebool True)
    it "calculates not(true)" $
      runInterpreter (euNot return [corebool True]) `shouldBe`
      Right (corebool False)
    it "calculates not(false)" $
      runInterpreter (euNot return [corebool False]) `shouldBe`
      Right (corebool True)
  describe "If builtin" $ do
    it "evaluates false branch lazily" $
      runInterpreter (euIf whnfM [corebool True, bif "TRUE", abort]) `shouldBe`
      Right (bif "TRUE")
    it "evaluates true branch lazily" $
      runInterpreter (euIf whnfM [corebool False, abort, bif "FALSE"]) `shouldBe`
      Right (bif "FALSE")
    -- it "ingnores recursion traps in unevaluated branch" $
    --   runInterpreter
    --     (whnfM
    --        (letexp
    --           [ ( "a"
    --             , (appexp (bif "IF") [corebool False, var "a", bif "FALSE"]))
    --           ]
    --           (block [element "a" (var "a")]))) `shouldBe`
    --   Right (bif "FALSE")
  describe "List builtins" $ do
    it "extracts head" $
      runInterpreter
        (euHead whnfM [CoreList [bif "TRUE", bif "FALSE", bif "FALSE"]]) `shouldBe`
      Right (bif "TRUE")
    it "extracts tail" $
      runInterpreter
        (euTail whnfM [CoreList [bif "TRUE", bif "FALSE", bif "FALSE"]]) `shouldBe`
      Right (CoreList [bif "FALSE", bif "FALSE"])
    it "throws when head-ing []" $
      runInterpreter (euHead whnfM [CoreList []]) `shouldBe`
      Left (EmptyList (CoreList []))
    it "throws when tail-ing []" $
      runInterpreter (euTail whnfM [CoreList []]) `shouldBe`
      Left (EmptyList (CoreList []))
    it "conses" $
      runInterpreter (euCons whnfM [int 0, CoreList [int 1, int 2, int 3]]) `shouldBe`
      Right (CoreList [int 0, int 1, int 2, int 3])
    it "conses with empty" $
      runInterpreter (euCons whnfM [int 0, CoreList []]) `shouldBe`
      Right (CoreList [int 0])
    it "throws consing a non-list tail" $
      runInterpreter (euCons whnfM [int 0, int 1]) `shouldBe`
      Left (NotList (int 1))
    it "conses with list-valued call" $
      runInterpreter
        (euCons
           whnfM
           [int 0, CoreApp (bif "TAIL") (CoreList [int 1, int 2, int 3])]) `shouldBe`
      Right (CoreList [int 0, int 2, int 3])
    it "judges head([1,2,3])=1" $
      runInterpreter
        (whnfM (appexp (bif "HEAD") [CoreList [int 1, int 2, int 3]])) `shouldBe`
      Right (int 1)
    it "judges head(cons(h,t))=h" $
      runInterpreter
        (whnfM
           (appexp
              (bif "EQ")
              [ appexp
                  (bif "HEAD")
                  [appexp (bif "CONS") [int 1, CoreList [int 2, int 3]]]
              , int 1
              ])) `shouldBe`
      Right (corebool True)
    it "judges head(cons(head(l), tail(l)))=head(l)" $
      runInterpreter
        (whnfM
           (appexp
              (bif "HEAD")
              [ appexp
                  (bif "CONS")
                  [ appexp (bif "HEAD") [CoreList [int 1, int 2, int 3]]
                  , appexp (bif "TAIL") [CoreList [int 1, int 2, int 3]]
                  ]
              ])) `shouldBe`
      Right (int 1)
    it "judges cons(head(l), tail(l))=l" $
      runInterpreter
        (forceDataStructures
           whnfM
           (appexp
              (bif "CONS")
              [ appexp (bif "HEAD") [CoreList [int 1, int 2, int 3]]
              , appexp (bif "TAIL") [CoreList [int 1, int 2, int 3]]
              ])) `shouldBe`
      Right (CoreList [int 1, int 2, int 3])
    it "judges eq(l,(cons(head(l), tail(l))))=true" $
      runInterpreter
        (whnfM
           (appexp
              (bif "EQ")
              [ CoreList [int 1, int 2, int 3]
              , appexp
                  (bif "CONS")
                  [ appexp (bif "HEAD") [CoreList [int 1, int 2, int 3]]
                  , appexp (bif "TAIL") [CoreList [int 1, int 2, int 3]]
                  ]
              ])) `shouldBe`
      Right (corebool True)
  arithSpec


addsIntegers :: Integer -> Integer -> Bool
addsIntegers l r = runInterpreter (euAdd whnfM [int l, int r]) == (Right $ int (l + r))

addsFloats :: Double -> Double -> Bool
addsFloats l r = runInterpreter (euAdd whnfM [float l, float r]) == (Right $ float (l + r))

subtractsIntegers :: Integer -> Integer -> Bool
subtractsIntegers l r = runInterpreter (euSub whnfM [int l, int r]) == (Right $ int (l - r))

subtractsFloats :: Double -> Double -> Bool
subtractsFloats l r = runInterpreter (euSub whnfM [float l, float r]) == (Right $ float (l - r))

multipliesIntegers :: Integer -> Integer -> Bool
multipliesIntegers l r = runInterpreter (euMul whnfM [int l, int r]) == (Right $ int (l * r))

multipliesFloats :: Double -> Double -> Bool
multipliesFloats l r = runInterpreter (euMul whnfM [float l, float r]) == (Right $ float (l * r))

dividesIntegers :: Integer -> NonZero Integer -> Bool
dividesIntegers l (NonZero r) = runInterpreter (euDiv whnfM [int l, int r]) == (Right $ float (fromInteger l / fromInteger r))

dividesFloats :: Double -> NonZero Double -> Bool
dividesFloats l (NonZero r) = runInterpreter (euDiv whnfM [float l, float r]) == (Right $ float (l / r))

ordersIntegersWithLt :: Integer -> Integer -> Bool
ordersIntegersWithLt l r = runInterpreter (euLt whnfM [int l, int r]) == (Right $ corebool True)
  || runInterpreter (euGte whnfM [int l, int r]) == (Right $ corebool True)

ordersIntegersWithGt :: Integer -> Integer -> Bool
ordersIntegersWithGt l r = runInterpreter (euLte whnfM [int l, int r]) == (Right $ corebool True)
  || runInterpreter (euGt whnfM [int l, int r]) == (Right $ corebool True)

ordersFloatsWithLt :: Double -> Double -> Bool
ordersFloatsWithLt l r = runInterpreter (euLt whnfM [float l, float r]) == (Right $ corebool True)
  || runInterpreter (euGte whnfM [float l, float r]) == (Right $ corebool True)

ordersFloatsWithGt :: Double -> Double -> Bool
ordersFloatsWithGt l r = runInterpreter (euLte whnfM [float l, float r]) == (Right $ corebool True)
  || runInterpreter (euGt whnfM [float l, float r]) == (Right $ corebool True)

equatesEqualInts :: Integer -> Bool
equatesEqualInts n = runInterpreter (euEq whnfM [int n, int n]) == (Right $ corebool True)

equatesEqualFloats :: Double -> Bool
equatesEqualFloats n = runInterpreter (euEq whnfM [float n, float n]) == (Right $ corebool True)


arithSpec :: Spec
arithSpec =
  describe "Arithmetic operations" $ do
    it "adds ints" $ property addsIntegers
    it "subtracts ints" $ property subtractsIntegers
    it "multiplies ints" $ property multipliesIntegers
    it "adds floats" $ property addsFloats
    it "subtracts floats" $ property subtractsFloats
    it "multiplies floats" $ property multipliesFloats
    it "divides integers" $ property dividesIntegers
    it "divides floats" $ property dividesFloats
    it "orders ints with < / >=" $ property ordersIntegersWithLt
    it "orders ints with <= / >" $ property ordersIntegersWithGt
    it "orders floats with < / >=" $ property ordersFloatsWithLt
    it "orders floats with <= / >" $ property ordersFloatsWithGt
    it "equates equal ints" $ property equatesEqualInts
    it "equates equal floats" $ property equatesEqualFloats

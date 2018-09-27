module Eucalypt.Core.ImportSpec
  ( main
  , spec
  ) where

import qualified Data.Map as M
import Data.Maybe (fromJust)
import qualified Data.Set as S
import Eucalypt.Core.Import
import Eucalypt.Core.Syn
import Eucalypt.Core.Unit
import Eucalypt.Syntax.Input
import Test.Hspec

main :: IO ()
main = hspec spec

unitAInput :: Input
unitAInput = fromJust $ parseInputFromString "unitA"

unitACore :: CoreExpr
unitACore =
  letexp [("foo", sym "foo"), ("bar", sym "bar")] $
  block [element "foo" $ var "foo", element "bar" $ var "bar"]

unitA :: TranslationUnit
unitA =
  TranslationUnit
    { truCore = unitACore
    , truImports = mempty
    , truTargets = mempty
    }

unitBInput :: Input
unitBInput = fromJust $ parseInputFromString "unitB"

unitBCore :: CoreExpr
unitBCore =
  letexp
    [ ( "z"
      , withMeta (block [element "import" $ str "unitA"]) $
        block [element "foo" $ var "foo"])
    ] $
  block [element "z" $ var "z"]

unitBCoreResult :: CoreExpr
unitBCoreResult =
  letexp
    [ ( "z"
      , withMeta (block []) $
        letexp [("foo", sym "foo"), ("bar", sym "bar")] $
        block [element "foo" $ var "foo"])
    ] $
  block [element "z" $ var "z"]

unitB :: TranslationUnit
unitB =
  TranslationUnit
    { truCore = unitBCore
    , truImports = S.fromList [unitAInput]
    , truTargets = mempty
    }

unitsAB :: M.Map Input TranslationUnit
unitsAB = M.fromList [(unitAInput, unitA), (unitBInput, unitB)]

unitCInput :: Input
unitCInput = fromJust $ parseInputFromString "unitC"

unitCCore :: CoreExpr
unitCCore =
  letexp
    [ ( "quux"
      , withMeta (block [element "import" $ str "unitB"]) $
        block [element "z" $ var "z"])
    ] $
  block [element "quux" $ var "quux"]

unitCCoreResult :: CoreExpr
unitCCoreResult =
  letexp
    [ ( "quux"
      , withMeta (block []) $
        letexp
          [ ( "z"
            , withMeta (block []) $
              letexp [("foo", sym "foo"), ("bar", sym "bar")] $
              block [element "foo" $ var "foo"])
          ] $
        block [element "z" $ var "z"])
    ] $
  block [element "quux" $ var "quux"]

unitC :: TranslationUnit
unitC =
  TranslationUnit
    { truCore = unitCCore
    , truImports = S.fromList [unitBInput]
    , truTargets = mempty
    }

unitsABC :: M.Map Input TranslationUnit
unitsABC =
  M.fromList [(unitAInput, unitA), (unitBInput, unitB), (unitCInput, unitC)]

namedInput :: Input
namedInput = fromJust $ parseInputFromString "namedInput"

namedUnit :: TranslationUnit
namedUnit = applyName "name"
  TranslationUnit
    { truCore = unitACore
    , truImports = mempty
    , truTargets = mempty
    }

unitDInput :: Input
unitDInput = fromJust $ parseInputFromString "unitD"

unitDCore :: CoreExpr
unitDCore =
  letexp
    [ ( "nest"
      , withMeta (block [element "import" $ str "namedInput"]) $
        block [element "name" $ var "name"])
    ] $
  block [element "quux" $ var "quux"]

unitDCoreResult :: CoreExpr
unitDCoreResult =
  letexp
    [ ( "nest"
      , withMeta (block []) $
        letexp
          [ ( "name"
            , letexp [("foo", sym "foo"), ("bar", sym "bar")] $
              block [element "foo" $ var "foo", element "bar" $ var "bar"])
          ] $
        block [element "name" $ var "name"])
    ] $
  block [element "quux" $ var "quux"]

unitD :: TranslationUnit
unitD =
  TranslationUnit
    { truCore = unitDCore
    , truImports = S.fromList [namedInput]
    , truTargets = mempty
    }

unitsNamedAndD :: M.Map Input TranslationUnit
unitsNamedAndD =
  M.fromList [(namedInput, namedUnit), (unitDInput, unitD)]


spec :: Spec
spec =
  describe "Import processing" $ do
    context "single imports" $ do
      it "processes a single import" $
        processImports (const unitACore) unitBCore `shouldBe` unitBCoreResult
      it "processes single import from unit map" $
        truCore <$> M.lookup unitBInput (applyAllImports unitsAB) `shouldBe` Just unitBCoreResult
      it "processes single named import from unit map" $
        truCore <$> M.lookup unitDInput (applyAllImports unitsNamedAndD) `shouldBe` Just unitDCoreResult
    context "transitive imports" $ do
      it "intermediates are correct" $
        truCore <$> M.lookup unitBInput (applyAllImports unitsABC) `shouldBe` Just unitBCoreResult
      it "end result is correct" $
        truCore <$> M.lookup unitCInput (applyAllImports unitsABC) `shouldBe` Just unitCCoreResult

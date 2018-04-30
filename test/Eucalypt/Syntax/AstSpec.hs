module Eucalypt.Syntax.AstSpec (main, spec)
where

import Eucalypt.Reporting.Location
import Eucalypt.Syntax.Ast
import Test.Hspec

main :: IO ()
main = hspec spec

spec :: Spec
spec = do

  describe "ident smart constructor" $ do

    it "creates qualified names" $
      locatee (ident "x.y.z") `shouldBe` EIdentifier [NormalName "x", NormalName "y", NormalName "z"]

    it "creates simple names" $
      locatee (ident "x") `shouldBe` EIdentifier [NormalName "x"]

  describe "op smart constructor" $

    it "creates operator calls" $
      locatee (op "<*>" (ident "x") (ident "y")) `shouldBe` EOperation (OperatorName "<*>") (ident "x") (ident "y")

  describe "cat smart constructor" $

    it "creates catenations" $
      locatee (cat (ident "x") (ident "y")) `shouldBe` ECatenation (ident "x") (ident "y")

  describe "invoke smart constructor" $

    it "creates invocations" $
      locatee (invoke (ident "x.y.fn") (map ident ["a", "b", "c"])) `shouldBe` EInvocation (ident "x.y.fn") [ident "a", ident "b", ident "c"]

  describe "int literals" $
    it "represents integers" $ do
      locatee (int 5) `shouldBe` (ELiteral . VInt) 5
      locatee (int (-5)) `shouldBe` (ELiteral . VInt) (-5)

  describe "string literals" $
    it "represents strings" $
      locatee (str "1234") `shouldBe` (ELiteral . VStr) "1234"

  describe "list literals" $
    it "represents lists" $
      locatee (list ( map ident ["x", "y", "z"])) `shouldBe` (EList $ map ident ["x", "y", "z"])

  describe "property declaration" $
    it "represents a property declaration" $
      locatee (prop "x" (ident "some.expr")) `shouldBe` PropertyDecl
                                                (NormalName "x")
                                                (ident "some.expr")

  describe "function declaration" $
    it "represents function declarations" $
      locatee (func "x" ["a", "b", "c"] (ident "body")) `shouldBe` FunctionDecl (NormalName "x")
                                                                      ["a", "b", "c"]
                                                                      (ident "body")

  describe "oper smart constructor" $
    it "represents operator declarations" $
      locatee (oper "<<&&>>" "lhs" "rhs" (ident "body")) `shouldBe` OperatorDecl
                                                           (OperatorName "<<&&>>")
                                                           "lhs"
                                                           "rhs"
                                                           (ident "body")

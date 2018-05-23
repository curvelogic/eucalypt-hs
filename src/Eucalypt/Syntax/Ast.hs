{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
{-|
Module      : Eucalypt.Syntax.Ast
Description : Abstract syntax for the Eucalypt language
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}
module Eucalypt.Syntax.Ast
where

import GHC.Generics
import Data.Aeson
import Data.List.Split (splitOn)
import Eucalypt.Reporting.Location


-- | Eucalypt literals: numbers, strings or symbols.
data PrimitiveLiteral = VInt Integer   -- ^ integer (decimal representation)
                      | VFloat Double  -- ^ floating point (TODO: inf, nan?)
                      | VStr String    -- ^ double quoted string
                      | VSym String    -- ^ symbol (colon prefixed)
  deriving (Eq, Show, Generic, ToJSON)


-- | Basic unqualified identifier components, name or operator.
data AtomicName
  = NormalName String    -- ^ a name component, simple or single quoted
  | OperatorName String  -- ^ an operator name
  deriving (Eq, Show, Generic, ToJSON)


-- | A parameter name is lexically a normal name but just an alias to
-- a string
type ParameterName = String


-- | In a while we may allow configurable bracket types ("idiot
-- brackets") which will affect the interpretation of catenation
-- within them, so we record the bracket set with the op soup.
data BracketSet = Explicit Char Char | Implicit
  deriving (Eq, Show, Generic, ToJSON)


-- | For now though it's just parentheses.
parentheses :: BracketSet
parentheses = Explicit '(' ')'



implicit :: BracketSet
implicit = Implicit



type Expression = Located Expression_

-- | An Expression is anything that can appear to the right of a colon
-- in a declaration.
data Expression_

  = EIdentifier [AtomicName]
    -- ^ a (possibly complex) identifier

  | EOperation AtomicName Expression Expression
    -- ^ a binary operator

  | ELiteral PrimitiveLiteral
    -- ^ a primitive literal value

  | EInvocation Expression [Expression]
    -- ^ a function-style invocation @f(a,b,c)@

  | ECatenation Expression Expression
    -- ^ invocation by catenation: @x f@

  | EBlock Block
    -- ^ a block literal { decls }

  | EList [Expression]
    -- ^ a list literal: [x, y, z]

  | EOpSoup BracketSet [Expression]
    -- ^ a sequence of expressions and operators

  | EName AtomicName
    -- ^ simple identifier

  deriving (Eq, Show, Generic, ToJSON)


-- | Strip location from a located expression; useful for testing.
-- TODO: generalise
instance HasLocation Expression_ where
  stripLocation (EOperation n l r) =
    EOperation n (stripLocation l) (stripLocation r)
  stripLocation (EInvocation f xs) =
    EInvocation (stripLocation f) (map stripLocation xs)
  stripLocation (ECatenation a b) =
    ECatenation (stripLocation a) (stripLocation b)
  stripLocation (EBlock b) = EBlock (stripLocation b)
  stripLocation (EList es) = EList (map stripLocation es)
  stripLocation (EOpSoup bs es) = EOpSoup bs (map stripLocation es)
  stripLocation e = e


-- | A syntax element could be annotated with another expression
data Annotated a
  = Annotated { annotation :: Maybe Expression,
                -- ^ arbitrary expression used to annotated the declaration
                declaration :: a
                -- ^ the declaration itself
              }
  deriving (Eq, Show, Generic, ToJSON)

-- | A declaration form has source location metadata
type DeclarationForm = Located DeclarationForm_

-- | Declaration forms permissible within a block.
--
-- This may be any of
-- * a property declaration
-- * a function declaration
-- * an operator declaration
data DeclarationForm_

  = PropertyDecl AtomicName Expression |
    -- ^ A simple property declaration: @key: value-expression@

    FunctionDecl AtomicName [ParameterName] Expression |
    -- ^ A function declaration @f(x, y, z): value-expression@

    OperatorDecl AtomicName ParameterName ParameterName Expression
    -- ^ A binary operator declaration @(x ** y): value-expression@

  deriving (Eq, Show, Generic, ToJSON)


instance HasLocation DeclarationForm_ where
  stripLocation (PropertyDecl n e) = PropertyDecl n (stripLocation e)
  stripLocation (FunctionDecl f ps e) = FunctionDecl f ps (stripLocation e)
  stripLocation (OperatorDecl n l r e) = OperatorDecl n l r (stripLocation e)

type BlockElement = Located BlockElement_

-- | Block elements may be annotated declarations or splice forms
-- which will evaluate to alists mapping symbols to values and be
-- merged into the block at evaluation time.
data BlockElement_ = Declaration (Annotated DeclarationForm)
                   | Splice Expression
  deriving (Eq, Show, Generic, ToJSON)

instance HasLocation BlockElement_ where
  stripLocation (Declaration Annotated {annotation = a, declaration = d}) =
    Declaration Annotated{annotation = stripLocation <$> a, declaration = stripLocation d}
  stripLocation (Splice e) = Splice $ stripLocation e

-- | A Block is a block with location metadata
type Block = Located Block_

-- | A block is a sequence of block elements, with later keys
-- overriding earlier.
newtype Block_ = Block [BlockElement]
  deriving (Eq, Show, Generic, ToJSON)


instance HasLocation Block_ where
  stripLocation (Block elts) = Block (map stripLocation elts)

-- | Strip single quotes from single-quoted string
unquote :: String -> String
unquote ('\'' : xs) = (reverse . unquote . reverse) xs
unquote xs = xs

-- | Turn dotted string into complex identifier
ident :: String -> Expression
ident = at nowhere . EIdentifier . map (NormalName . unquote) . splitOn "."

-- | Form an operation from name and operands
op :: String -> Expression -> Expression -> Expression
op o l r = at nowhere $ EOperation (OperatorName o) l r

-- | Form a catenation of two expressions
cat :: Expression -> Expression -> Expression
cat l r = at nowhere $ ECatenation l r

-- | Form a multi-argument invocation
invoke :: Expression -> [Expression] -> Expression
invoke f params = at nowhere $ EInvocation f params

-- | Form a literal int
int :: Integer -> Expression
int = at nowhere . ELiteral . VInt

-- | Form a literal string
str :: String -> Expression
str = at nowhere . ELiteral . VStr

-- | Form a literal symbol
sym :: String -> Expression
sym = at nowhere . ELiteral . VSym

-- | Form a list literal from a list of expressions
list :: [Expression] -> Expression
list = at nowhere . EList

-- | Create a property declaration
prop :: String -> Expression -> DeclarationForm
prop k = at nowhere . PropertyDecl (NormalName k)

-- | Create a function declaration
func :: String -> [String] -> Expression -> DeclarationForm
func f params e = at nowhere $ FunctionDecl (NormalName f) params e

-- | Create an operator declaration
oper :: String -> String -> String -> Expression -> DeclarationForm
oper o l r e = at nowhere $ OperatorDecl (OperatorName o) l r e

-- | Create an annotated block element
ann :: Expression -> DeclarationForm -> BlockElement
ann a decl = at nowhere $ Declaration Annotated { annotation = Just a, declaration = decl }

-- | Create an unannotated block element
bare :: DeclarationForm -> BlockElement
bare decl = at nowhere $ Declaration Annotated { annotation = Nothing, declaration = decl }

-- | Create a block expression
block :: [BlockElement] -> Expression
block = at nowhere . EBlock . at nowhere . Block

-- | Create an op soup expression with implicit bracketset
opsoup :: [Expression] -> Expression
opsoup = at nowhere . EOpSoup implicit

-- | Create an op soup expression with bracket set parentheses
opsoupParens :: [Expression] -> Expression
opsoupParens = at nowhere . EOpSoup parentheses

-- | A normal name as expression
normalName :: String -> Expression
normalName = at nowhere . EName . NormalName

-- | An operator name as expression
operatorName :: String -> Expression
operatorName = at nowhere . EName . OperatorName

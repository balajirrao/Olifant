{-# LANGUAGE PatternSynonyms #-}
{-|
Module      : Olifant.Parser
Description : First phase of the compilation
-}
--
-- It's ok to throw away results of do notation in a parser. Disable the warning
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

module Olifant.Parser where

import Olifant.Core hiding (lambda)

import Prelude   (Char, String)
import Protolude hiding (bool, handle, many, try, (<|>))

import Data.Char   (isAlpha)

import Control.Monad (fail)
import Text.Megaparsec hiding (parse)
import Text.Megaparsec.Char hiding (space1)
import qualified Text.Megaparsec.Char.Lexer as L

-- | Parser type alias
type Parser = Parsec Void String

-- | Pattern match a constant without repeating it.
pattern Eql :: Calculus
pattern Eql = CVar TUnit "__EQUAL__"

-- | Handle a single space.
--
-- Megaparsec version consumes new line as well and that is *NOT* what I want
space1 :: Parser ()
space1 = void $ char ' '

-- | Space consumer
sc :: Parser ()
sc = L.space space1 empty empty

-- | Lexeme; consume the spaces after a token, but not before it
lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

-- | Parse a constant string literal
symbol :: String -> Parser String
symbol = L.symbol sc

-- | Term separator
sep :: Parser Char
sep = char ';' <|> newline <|> (eof *> return ';')

-- | 'parens' parses something between parenthesis.
parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

-- | Parse a signed integer
--
-- The `signed` combinator from Megaparsec accepts spaces b/w the sign and
-- number; so that is not what I want.
number :: Parser Calculus
number = CLit . Number <$> ps
  where
    ps :: Parser Int
    ps = try $ do
      sign <- optional (char '-')
      d    <- lexeme L.decimal
      return $ if sign == Just '-' then negate d else d

-- | Parse scheme style boolean
--
-- Try is required on the left side of <|> to prevent eagerly consuming #
bool :: Parser Calculus
bool = CLit . Bool . (== "#t") <$> (try (symbol "#t") <|> symbol "#f")

-- | Parse an identifier
identifier :: Parser Text
identifier = toS <$> some (satisfy ok)
  where
    ok :: Char -> Bool
    ok c = (isAlpha c || c `elem` allowed) && (c `notElem` specials)

    -- | Special symbols
    specials :: String
    specials = [':', 'λ', '#', '\\', '/', ';', '\n']

    -- | Special symbols allowed in identifiers
    allowed :: String
    allowed = ['?', '!', '_', '+', '-', '/', '*', '^', '<', '>', '$']

-- | Parse a word as an identifier
var :: Parser Calculus
var = do
    n <- identifier
    t <- try ty
    return $ CVar t n
  where
    -- | Parse a type
    ty :: Parser Ty
    ty = do
        t <- optional $ try (char ':') *> (char 'i' <|> char 'b')
        return $ case t of
          Just 'b' -> TBool
          Just 'i' -> TInt
          Just _   -> TUnit
          Nothing  -> TUnit

-- [TODO] - Add support for Haskell style type declaration
-- [TODO] - Treat type declarations without body as extern

-- | Parse an assignment; @literal = symbol@
--
-- Using magic constants kind of suck; find some other approach
equals :: Parser Calculus
equals = CVar TUnit . toS <$> symbol "=" *> return Eql

-- | A single term
term1 :: Parser Calculus
term1 = lexeme $ bool <|> number <|> var <|> equals

-- | A sequence of terms, optionally parenthesized
term :: Parser Calculus
term = parens term <|> (many term1 >>= handle)

calculus :: Parser Calculus
calculus = manyTill term sep >>= handle

-- | Parse the whole program; split by new line
parser :: Parser [Calculus]
parser = many (space *> calculus) <* eof

parse' :: Parser [Calculus] -> Text -> Either Error [Calculus]
parse' _ "" = Right []
parse' p' input =
    case runParser p' "" (toS input) of
        Left err  -> Left $ ParseError err
        Right val -> Right val

-- | Parse source and return AST
parse :: Text -> Either Error [Calculus]
parse = parse' parser

-- | Parse source and return AST with tracing output
debug :: Text -> Either Error [Calculus]
debug = parse' $ dbg "TEST" parser

-- | Convert a series of terms into a Calculus expression
handle :: [Calculus] -> Parser Calculus
handle []  = fail "Oops!"
handle [x] = return x
handle ts  = case break (Eql ==) ts of
    -- Assignment; `a = 42`
    ([CVar t variable], [Eql, val]) -> return $ CLet t variable val

    -- Assignment to non text value; `3 = 4`
    ([_], [Eql, _])          -> fail "Illegal Assignment"

    -- Function definition
    (CVar _ f: as, Eql: body) -> do

        -- Ensure all arguments are typed
        args <- mapM mkArgs as
        body' <- handle body
        return $ CLam f args body'
      where
        mkArgs :: Calculus -> Parser (Ty, Text)
        mkArgs (CVar t val) = return (t, val)
        mkArgs _ = fail "Expected typed variable as argument"

     -- A sequence without a = should be an application
    (f:args, []) -> return $ CApp f args

    _ -> fail $ "Unable to parse\n" <> show ts

{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright   : (c) 2010, 2011 Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
-- 
--
-- Pretty printing and parsing of Maude terms and replies.
module Term.Maude.Parser (
  -- * pretty printing of terms for Maude
    ppMaude
  , ppTheory

  -- * parsing of Maude replies
  , parseUnifyReply
  , parseMatchReply
  , parseVariantsReply
  , parseReduceReply
  ) where

import Term.LTerm
import Term.Maude.Types
import Term.Maude.Signature
import Term.Rewriting.Definitions

import Control.Monad.Bind

import Control.Basics

import qualified Data.Set as S

import qualified Data.ByteString as B
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC

import Data.Attoparsec.ByteString.Char8

-- import Extension.Data.Monoid

------------------------------------------------------------------------------
-- Pretty printing of Maude terms.
------------------------------------------------------------------------

-- | Pretty print an 'LSort'.
ppLSort :: LSort -> ByteString
ppLSort s = case s of
    LSortPub       -> "Pub"
    LSortFresh     -> "Fresh"
    LSortMsg       -> "Msg"
    LSortNat       -> "TamNat"
    LSortNode      -> "Node"

ppLSortSym :: LSort -> ByteString
ppLSortSym lsort = case lsort of
    LSortFresh     -> "f"
    LSortPub       -> "p"
    LSortMsg       -> "c"
    LSortNode      -> "n"
    LSortNat       -> "t"

parseLSortSym :: ByteString -> Maybe LSort
parseLSortSym s = case s of
    "f"  -> Just LSortFresh
    "p"  -> Just LSortPub
    "c"  -> Just LSortMsg
    "n"  -> Just LSortNode
    "t"  -> Just LSortNat
    _    -> Nothing

-- | Used to prevent clashes with predefined Maude function symbols
--   like @true@
funSymPrefix :: ByteString
funSymPrefix = "tam"

-- | Encode attributes in additional prefix
funSymEncodeAttr :: Privacy -> Constructability -> ByteString
funSymEncodeAttr priv constr  = f priv <> g constr
    where
        f Private = "P"
        f Public  = "X"
        g Constructor = "C"
        g Destructor = "D"

-- | Decode string @funSymPrefix || funSymEncodeAttr p c || ident@ into
--   @(ident,p,c)@
funSymDecode :: ByteString -> (ByteString, Privacy, Constructability)
funSymDecode s = (ident,priv,constr)
    where
        prefixLen      = BC.length funSymPrefix
        (eAttr,ident)  = BC.splitAt 2 (BC.drop prefixLen s) 
        (priv,constr)  = case eAttr of
                            "PD" -> (Private,Destructor)
                            "PC" -> (Private,Constructor)
                            "XD" -> (Public,Destructor)
                            _    -> (Public,Constructor)

         

-- | Replace underscores "_" with minus "-" for Maude.
replaceUnderscore :: ByteString -> ByteString
replaceUnderscore s = BC.map f s
    where
       f x | x == '_'  = '-'
       f x | otherwise = x

-- | Replace underscores "_" with minus "-" for Maude.
replaceUnderscoreFun :: NoEqSym -> NoEqSym
replaceUnderscoreFun (s, p) = (replaceUnderscore s, p)

-- | Replace minus "-" with underscores "_" when parsing back from Maude.
replaceMinus :: ByteString -> ByteString
replaceMinus s = BC.map f s
    where
       f x | x == '-'  = '_'
       f x | otherwise = x

-- | Replace minus "-" with underscores "_" when parsing back from Maude.
replaceMinusFun :: NoEqSym -> NoEqSym
replaceMinusFun (s, p) = (replaceMinus s, p)


-- | Pretty print an AC symbol for Maude.
ppMaudeACSym :: ACSym -> ByteString
ppMaudeACSym o =
    funSymPrefix <> case o of
                      Mult    -> multSymString 
                      Union   -> munSymString
                      Xor     -> xorSymString
                      NatPlus -> natPlusSymString

-- | Pretty print a non-AC symbol for Maude.
ppMaudeNoEqSym :: NoEqSym -> ByteString
ppMaudeNoEqSym (o,(_,prv,cnstr))  = funSymPrefix <> funSymEncodeAttr prv cnstr <> replaceUnderscore o

-- | Pretty print a C symbol for Maude.
ppMaudeCSym :: CSym -> ByteString
ppMaudeCSym EMap = funSymPrefix <> emapSymString


-- | @ppMaude t@ pretty prints the term @t@ for Maude.
ppMaude :: Term MaudeLit -> ByteString
ppMaude t = case viewTerm t of
    Lit (MaudeVar i lsort)   -> "x" <> ppInt i <> ":" <> ppLSort lsort
    Lit (MaudeConst i lsort) -> ppLSortSym lsort <> "(" <> ppInt i <> ")"
    Lit (FreshVar _ _)       -> error "Term.Maude.Types.ppMaude: FreshVar not allowed"
    FApp (NoEq fsym) []      -> ppMaudeNoEqSym fsym
    FApp (NoEq fsym) as      -> ppMaudeNoEqSym fsym <> ppArgs as
    FApp (C fsym) as         -> ppMaudeCSym fsym    <> ppArgs as
    FApp (AC op) as          -> ppMaudeACSym op     <> ppArgs as
    FApp List as             -> "list(" <> ppList as <> ")"
  where
    ppArgs as     = "(" <> (B.intercalate "," (map ppMaude as)) <> ")"
    ppInt         = BC.pack . show
    ppList []     = "nil"
    ppList (x:xs) = "cons(" <> ppMaude x <> "," <> ppList xs <> ")"

------------------------------------------------------------------------------
-- Pretty printing a 'MaudeSig' as a Maude functional module.
------------------------------------------------------------------------------

-- | The term algebra and rewriting rules as a functional module in Maude.
ppTheory :: MaudeSig -> ByteString
ppTheory msig = BC.unlines $
    [ "fmod MSG is"
    , "  protecting NAT ." ]
    ++
    (if enableNat msig
      then
        [ "  sort Pub Fresh Msg Node TamNat TOP ." ]
      else
        [ "  sort Pub Fresh Msg Node TOP ." ]
    )
    ++
    [ "  subsort Pub < Msg ."
    , "  subsort Fresh < Msg ." ]
    ++
    (if enableNat msig
      then
        ["  subsort TamNat < Msg ."]
      else [])
    ++
    [  "  subsort Msg < TOP ."
    , "  subsort Node < TOP ."
    -- constants
    , "  op f : Nat -> Fresh ."
    , "  op p : Nat -> Pub ."
    , "  op c : Nat -> Msg ."
    , "  op n : Nat -> Node ." ]
    ++
    (if enableNat msig
      then
        ["  op t : Nat -> TamNat ."]
      else [])
    ++
    -- used for encoding FApp List [t1,..,tk]
    -- list(cons(t1,cons(t2,..,cons(tk,nil)..)))
    [ "  op list : TOP -> TOP ."
    , "  op cons : TOP TOP -> TOP ."
    , "  op nil  : -> TOP ." ]
    ++
    (if enableMSet msig
       then
       [ theoryOpAC "mun : Msg Msg -> Msg [comm assoc]" ]
       else [])
    ++
    (if enableDH msig
       then
       [ theoryOpEq "one : -> Msg"
       , theoryOpEq "DH-neutral  : -> Msg"       
       , theoryOpEq "exp : Msg Msg -> Msg"
       , theoryOpAC "mult : Msg Msg -> Msg [comm assoc]"
       , theoryOpEq "inv : Msg -> Msg" ]
       else [])
    ++
    (if enableBP msig
       then
       [ theoryOpEq "pmult : Msg Msg -> Msg"
       , theoryOpC "em : Msg Msg -> Msg [comm]" ]
       else [])
    ++
    (if enableXor msig
       then
       [ theoryOpEq "zero : -> Msg"
       , theoryOpAC "xor : Msg Msg -> Msg [comm assoc]" ]
       else [])
    ++    
    (if enableNat msig
       then
       [ theoryOpEq "tone : -> TamNat"
       , theoryOpAC "tplus : TamNat TamNat -> TamNat [comm assoc]" ]
       else [])
    ++
    map theoryFunSym (S.toList $ stFunSyms msig)
    ++
    map theoryRule (S.toList $ rrulesForMaudeSig msig)
    ++
    [ "endfm" ]
  where
    maybeEncode (Just (priv,cnstr)) = funSymEncodeAttr priv cnstr
    maybeEncode Nothing             = ""
    theoryOp attr fsort =
        "  op " <> funSymPrefix <> maybeEncode attr <> fsort <>" ."
    theoryOpEq = theoryOp (Just (Public,Constructor))
    theoryOpAC = theoryOp Nothing
    theoryOpC  = theoryOp Nothing
    theoryFunSym (s,(ar,priv,cnstr)) =
        theoryOp  (Just(priv,cnstr)) (replaceUnderscore s <> " : " <> (B.concat $ replicate ar "Msg ") <> " -> Msg")
    theoryRule (l `RRule` r) =
        "  eq " <> ppMaude lm <> " = " <> ppMaude rm <> " [variant] ."
      where (lm,rm) = evalBindT ((,) <$>  lTermToMTerm' l <*> lTermToMTerm' r) noBindings
                        `evalFresh` nothingUsed

-- Parser for Maude output
------------------------------------------------------------------------

-- | @parseUnifyReply reply@ takes a @reply@ to a unification query
--   returned by Maude and extracts the unifiers.
parseUnifyReply :: MaudeSig -> ByteString -> Either String [MSubst]
parseUnifyReply msig reply = flip parseOnly reply $
    choice [ string "No unifier." *> endOfLine *> pure []
           , many1 (parseSubstitution msig) ]
        <* endOfInput

-- | @parseMatchReply reply@ takes a @reply@ to a match query
--   returned by Maude and extracts the unifiers.
parseMatchReply :: MaudeSig -> ByteString -> Either String [MSubst]
parseMatchReply msig reply = flip parseOnly reply $
    choice [ string "No match." *> endOfLine *> pure []
           , many1 (parseSubstitution msig) ]
        <* endOfInput

-- | @parseVariantsReply reply@ takes a @reply@ to a variants query
--   returned by Maude and extracts the unifiers.
parseVariantsReply :: MaudeSig -> ByteString -> Either String [MSubst]
parseVariantsReply msig reply = flip parseOnly reply $ do
    endOfLine *> many1 parseVariant <* (string "No more variants.")
    <* endOfLine <* string "rewrites: "
    <* takeWhile1 isDigit <* endOfLine <* endOfInput
  where
    parseVariant = string "Variant " *> optional (char '#') *> takeWhile1 isDigit *> endOfLine *>
                   string "rewrites: " *> takeWhile1 isDigit *> endOfLine *>
                   parseReprintedTerm *> manyTill parseEntry endOfLine
    parseReprintedTerm = choice [ string "TOP" *> pure LSortMsg, parseSort ]
                         *> string ": " *> parseTerm msig <* endOfLine
    parseEntry = (,) <$> (flip (,) <$> (string "x" *> decimal <* string ":") <*> parseSort)
                     <*> (string " --> " *> parseTerm msig <* endOfLine)

-- | @parseSubstitution l@ parses a single substitution returned by Maude.
parseSubstitution :: MaudeSig -> Parser MSubst
parseSubstitution msig = do
    endOfLine *> choice [string "Solution ", string "Unifier ", string "Matcher "] *> takeWhile1 isDigit *> endOfLine
    choice [ string "empty substitution" *> endOfLine *> pure []
           , many1 parseEntry]
  where 
    parseEntry = (,) <$> (flip (,) <$> (string "x" *> decimal <* string ":") <*> parseSort)
                     <*> (string " --> " *> parseTerm msig <* endOfLine)

-- | @parseReduceReply l@ parses a single solution returned by Maude.
parseReduceReply :: MaudeSig -> ByteString -> Either String MTerm
parseReduceReply msig reply = flip parseOnly reply $ do
    string "result " *> choice [ string "TOP" *> pure LSortMsg, parseSort ] -- we ignore the sort
        *> string ": " *> parseTerm msig <* endOfLine <* endOfInput

-- | Parse an 'MSort'.
parseSort :: Parser LSort
parseSort =  string "Pub"      *> return LSortPub
         <|> string "Fresh"    *> return LSortFresh
         <|> string "Node"     *> return LSortNode
         <|> string "TamNat"   *> return LSortNat
         <|> string "M"        *> -- FIXME: why?
               (    string "sg"  *> return LSortMsg )

-- | @parseTerm@ is a parser for Maude terms.
parseTerm :: MaudeSig -> Parser MTerm
parseTerm msig = choice
   [ string "#" *> (lit <$> (FreshVar <$> (decimal <* string ":") <*> parseSort))
   , string "%" *> (lit <$> (FreshVar <$> (decimal <* string ":") <*> parseSort))
   , do ident <- takeWhile1 (`BC.notElem` (":(,)\n " :: B.ByteString))
        choice [ do _ <- string "("
                    case parseLSortSym ident of
                      Just s  -> parseConst s
                      Nothing -> parseFApp ident
               , string ":" *> parseMaudeVariable ident
               , parseFAppConst ident
               ]
   ]
  where
    consSym = ("cons",(2,Public,Constructor))
    nilSym  = ("nil",(0,Public,Constructor))

    parseFunSym ident args
      | op `elem` allowedfunSyms = replaceMinusFun op
      | otherwise                =
          error $ "Maude.Parser.parseTerm: unknown function "
                  ++ "symbol `"++ show op ++"', not in "
                  ++ show allowedfunSyms
      where 
            special             = ident `elem` ["list", "cons", "nil" ]
            (ident',priv,cnstr) = funSymDecode ident
            op                  = if special then 
                                        (ident , (length args,Public,Constructor))
                                  else  (ident', (length args, priv, cnstr))
            allowedfunSyms = [consSym, nilSym, natOneSym]
                ++ (map replaceUnderscoreFun $ S.toList $ noEqFunSyms msig)

    parseConst s = lit <$> (flip MaudeConst s <$> decimal) <* string ")"

    parseFApp ident =
        appIdent <$> sepBy1 (parseTerm msig) (string ", ") <* string ")"
      where
        appIdent args  | ident == ppMaudeACSym Mult       = fAppAC Mult    args
                       | ident == ppMaudeACSym Union      = fAppAC Union   args
                       | ident == ppMaudeACSym NatPlus    = fAppAC NatPlus args
                       | ident == ppMaudeACSym Xor        = fAppAC Xor   args
                       | ident == ppMaudeCSym  EMap       = fAppC  EMap  args
        appIdent [arg] | ident == "list"                  = fAppList (flattenCons arg)
        appIdent args                                     = fAppNoEq op args
          where op = parseFunSym ident args

        flattenCons (viewTerm -> FApp (NoEq s) [x,xs]) | s == consSym = x:flattenCons xs
        flattenCons (viewTerm -> FApp (NoEq s)  [])    | s == nilSym  = []
        flattenCons t                                                 = [t]

    parseFAppConst ident = return $ fAppNoEq (parseFunSym ident []) []

    parseMaudeVariable ident =
        case BC.uncons ident of
            Just ('x', num) -> lit <$> (MaudeVar (read (BC.unpack num)) <$> parseSort)
            _               -> fail "invalid variable"

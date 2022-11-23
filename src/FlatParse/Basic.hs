{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}

{-|
This module implements a `Parser` supporting custom error types.  If you need efficient indentation
parsing, use "FlatParse.Stateful" instead.

Many internals are exposed for hacking on and extending. These are generally
denoted by a @#@ hash suffix.
-}

module FlatParse.Basic (

  -- * Parser types and constructors
    type Parser
  , type Res#
  , pattern OK#
  , pattern Fail#
  , pattern Err#
  , Result(..)
  , ParserT(..)

  -- * Running parsers
  , runParser
  , runParserS
  , runParserIO
  , runParserST

  -- * Embedding parser types
  , unsafeEmbedIOinST
  , unsafeEmbedSTinIO
  , embedSTinPure
  , unsafeEmbedIOinPure
  , unsafeDupableEmbedIOinPure

  -- * Errors and failures
  , failed
  , Base.empty
  , err
  , lookahead
  , fails
  , try
  , optional
  , optional_
  , withOption
  , cut
  , cutting

  -- * Basic lexing and parsing
  , eof
  , takeBs
  , takeRestBs
  , skip
  , char
  , byte
  , bytes
  , byteString
  , string
  , switch
  , switchWithPost
  , rawSwitchWithPost
  , satisfy
  , satisfy_
  , satisfyASCII
  , satisfyASCII_
  , fusedSatisfy
  , fusedSatisfy_
  , anyWord8
  , anyWord8_
  , anyWord16
  , anyWord16_
  , anyWord32
  , anyWord32_
  , anyWord64
  , anyWord64_
  , anyWord
  , anyWord_
  , anyInt8
  , anyInt16
  , anyInt32
  , anyInt64
  , anyInt
  , anyChar
  , anyChar_
  , anyCharASCII
  , anyCharASCII_
  , FlatParse.Internal.isDigit
  , FlatParse.Internal.isGreekLetter
  , FlatParse.Internal.isLatinLetter
  , FlatParse.Basic.readInt
  , FlatParse.Basic.readIntHex
  , FlatParse.Basic.readWord
  , FlatParse.Basic.readWordHex
  , FlatParse.Basic.readInteger
  , readVarintProtobuf
  , anyCString

  -- ** Explicit-endianness machine integers
  , anyWord16le
  , anyWord16be
  , anyWord32le
  , anyWord32be
  , anyWord64le
  , anyWord64be
  , anyInt16le
  , anyInt16be
  , anyInt32le
  , anyInt32be
  , anyInt64le
  , anyInt64be

  -- * Combinators
  , (<|>)
  , branch
  , chainl
  , chainr
  , many
  , many_
  , some
  , some_
  , notFollowedBy
  , isolate

  -- * Positions and spans
  , Pos(..)
  , Span(..)
  , getPos
  , setPos
  , endPos
  , spanOf
  , withSpan
  , byteStringOf
  , withByteString
  , inSpan

  -- ** Position and span conversions
  , validPos
  , posLineCols
  , unsafeSpanToByteString
  , unsafeSlice
  , mkPos
  , FlatParse.Basic.lines

  -- * Getting the rest of the input as a 'String'
  , takeLine
  , traceLine
  , takeRest
  , traceRest

  -- * `String` conversions
  , packUTF8
  , unpackUTF8

  -- * Internal functions
  , ensureBytes#

  -- ** Unboxed arguments
  , takeBs#
  , atSkip#

  -- *** Machine integer continuation parsers
  , withAnyWord8#
  , withAnyWord16#
  , withAnyWord32#
  , withAnyWord64#
  , withAnyInt8#
  , withAnyInt16#
  , withAnyInt32#
  , withAnyInt64#

  -- ** Location & address primitives
  , setBack#
  , withAddr#
  , takeBsOffAddr#
  , lookaheadFromAddr#
  , atAddr#

  -- ** Unsafe
  , anyCStringUnsafe
  , scan8#
  , scan16#
  , scan32#
  , scan64#
  , scanAny8#
  , scanBytes#

  ) where

import qualified Control.Applicative as Base
import Control.Monad
import Control.Monad.IO.Class (MonadIO(..))
import Data.Foldable
import Data.List (sortBy)
import Data.Map (Map)
import Data.Ord (comparing)
import Data.Word
import GHC.IO (noDuplicate, IO(..))
import GHC.Exts
import GHC.Word
import GHC.Int
import GHC.ForeignPtr
import Language.Haskell.TH
import System.IO.Unsafe
import Unsafe.Coerce (unsafeCoerce)

import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Internal as B
import qualified Data.Map.Strict as M

import FlatParse.Internal
import FlatParse.Internal.UnboxedNumerics

--------------------------------------------------------------------------------

-- | Primitive result of a parser. Possible results are given by `OK#`, `Err#` and `Fail#`
--   pattern synonyms. The actual parser results will still be wrapped by `Res#` to accomodate for state tokens.
type ResI# e a =
  (#
    (# a, Addr# #)
  | (# #)
  | (# e #)
  #)

type Res# (st :: ZeroBitType) e a =
  (# st, ResI# e a #)

-- | Contains return value and a pointer to the rest of the input buffer.
pattern OK# :: (st :: ZeroBitType) -> a -> Addr# -> Res# st e a
pattern OK# st a s = (# st, (# (# a, s #) | | #) #)

-- | Constructor for errors which are by default non-recoverable.
pattern Err# :: (st :: ZeroBitType) -> e -> Res# st e a
pattern Err# st e = (# st, (# | | (# e #) #) #)

-- | Constructor for recoverable failure.
pattern Fail# :: (st :: ZeroBitType) -> Res# st e a
pattern Fail# st = (# st, (# | (# #) | #) #)
{-# complete OK#, Err#, Fail# #-}

-- | @ParserT st e a@ has an error type @e@ and a return type @a@.
newtype ParserT (st :: ZeroBitType) e a = ParserT {runParserT# :: ForeignPtrContents -> Addr# -> Addr# -> st -> Res# st e a}

type Parser = ParserT PureMode
type ParserIO = ParserT IOMode
type ParserST s = ParserT (STMode s)


instance Functor (ParserT st e) where
  fmap f (ParserT g) = ParserT \fp eob s st -> case g fp eob s st of
    OK# st' a s -> OK# st' (f $! a) s
    x       -> unsafeCoerce# x
  {-# inline fmap #-}

  (<$) a' (ParserT g) = ParserT \fp eob s st -> case g fp eob s st of
    OK# st' a s -> OK# st' a' s
    x       -> unsafeCoerce# x
  {-# inline (<$) #-}

instance Applicative (ParserT st e) where
  pure a = ParserT \fp eob s st -> OK# st a s
  {-# inline pure #-}
  ParserT ff <*> ParserT fa = ParserT \fp eob s st -> case ff fp eob s st of
    OK# st' f s -> case fa fp eob s st' of
      OK# st'' a s  -> OK# st'' (f $! a) s
      x        -> unsafeCoerce# x
    x -> unsafeCoerce# x
  {-# inline (<*>) #-}
  ParserT fa <* ParserT fb = ParserT \fp eob s st -> case fa fp eob s st of
    OK# st' a s   -> case fb fp eob s st' of
      OK# st'' b s -> OK# st'' a s
      x -> unsafeCoerce# x
    x -> unsafeCoerce# x
  {-# inline (<*) #-}
  ParserT fa *> ParserT fb = ParserT \fp eob s st -> case fa fp eob s st of
    OK# st' a s -> fb fp eob s st'
    x       -> unsafeCoerce# x
  {-# inline (*>) #-}

instance Monad (ParserT st e) where
  return = pure
  {-# inline return #-}
  ParserT fa >>= f = ParserT \fp eob s st -> case fa fp eob s st of
    OK# st' a s -> runParserT# (f a) fp eob s st'
    x       -> unsafeCoerce# x
  {-# inline (>>=) #-}
  (>>) = (*>)
  {-# inline (>>) #-}

instance MonadIO (ParserT IOMode e) where
  liftIO (IO a) = ParserT \fp eob s rw ->
    case a rw of
      (# rw', a #) -> OK# rw' a s


-- | Higher-level boxed data type for parsing results.
data Result e a =
    OK a !(B.ByteString)  -- ^ Contains return value and unconsumed input.
  | Fail                  -- ^ Recoverable-by-default failure.
  | Err !e                -- ^ Unrecoverble-by-default error.
  deriving Show

instance Functor (Result e) where
  fmap f (OK a s) = let !b = f a in OK b s
  fmap f r        = unsafeCoerce# r
  {-# inline fmap #-}
  (<$) a (OK _ s) = OK a s
  (<$) _ r        = unsafeCoerce# r
  {-# inline (<$) #-}

-- | Switch out the underlying state token type. This is a notoriously unsafe
-- thing to do and should not be exposed to users.
reallyUnsafeStateCoerce :: ParserT st e a -> ParserT su e a
reallyUnsafeStateCoerce (ParserT p) = ParserT (unsafeCoerce p)

-- | Equivalent of 'unsafeIOToST'. Same caveats apply
unsafeEmbedIOinST :: ParserIO e a -> ParserT s e a
unsafeEmbedIOinST = reallyUnsafeStateCoerce

-- | Equivalent of 'unsafeSTToIO'. Same caveats apply
unsafeEmbedSTinIO :: ParserT s e a -> ParserIO e a
unsafeEmbedSTinIO = reallyUnsafeStateCoerce

-- | Equivalent of 'runST'
embedSTinPure :: (forall s. ParserT s e a) -> Parser e a
embedSTinPure p = p

-- | Equivalent of 'unsafePerformIO'. Same caveats apply.
unsafeEmbedIOinPure :: ParserIO e a -> Parser e a
unsafeEmbedIOinPure p = unsafeDupableEmbedIOinPure (liftIO noDuplicate >> p)

-- | Equivalent of 'unsafeDupablePerformIO'. Same caveats apply.
unsafeDupableEmbedIOinPure :: ParserIO e a -> Parser e a
unsafeDupableEmbedIOinPure = reallyUnsafeStateCoerce


--------------------------------------------------------------------------------

-- | Run a parser.
runParser :: Parser e a -> B.ByteString -> Result e a
runParser (ParserT f) b@(B.PS (ForeignPtr _ fp) _ (I# len)) = unsafePerformIO $
  B.unsafeUseAsCString b \(Ptr buf) -> do
    let end = plusAddr# buf len
    pure case f fp end buf proxy# of
      OK# _ a s ->  let offset = minusAddr# s buf
                      in OK a (B.drop (I# offset) b)

      Err# _ e ->  Err e
      Fail# _  ->  Fail
{-# inlinable runParser #-}

-- | Run an ST based parser
runParserST :: (forall s. ParserST s e a) -> B.ByteString -> Result e a
runParserST pst buf = unsafeDupablePerformIO (runParserIO pst buf)
{-# inlinable runParserST #-}

-- | Run an IO based parser
runParserIO :: ParserIO e a -> B.ByteString -> IO (Result e a)
runParserIO (ParserT f) b@(B.PS (ForeignPtr _ fp) _ (I# len)) = do
  B.unsafeUseAsCString b \(Ptr buf) -> do
    let end = plusAddr# buf len
    IO \st -> case f fp end buf st of
      OK# rw' a s ->  let offset = minusAddr# s buf
                      in (# rw', OK a (B.drop (I# offset) b) #)

      Err# rw' e ->  (# rw', Err e #)
      Fail# rw'  ->  (# rw', Fail #)
{-# inlinable runParserIO #-}


-- | Run a parser on a `String` input. Reminder: @OverloadedStrings@ for `B.ByteString` does not
--   yield a valid UTF-8 encoding! For non-ASCII `B.ByteString` literal input, use `runParserS` or
--   `packUTF8` for testing.
runParserS :: Parser e a -> String -> Result e a
runParserS pa s = runParser pa (packUTF8 s)


--------------------------------------------------------------------------------

-- | The failing parser. By default, parser choice `(<|>)` arbitrarily backtracks
--   on parser failure.
failed :: ParserT st e a
failed = ParserT \fp eob s st -> Fail# st
{-# inline failed #-}

-- | Throw a parsing error. By default, parser choice `(<|>)` can't backtrack
--   on parser error. Use `try` to convert an error to a recoverable failure.
err :: e -> ParserT st e a
err e = ParserT \fp eob s st -> Err# st e
{-# inline err #-}

-- | Save the parsing state, then run a parser, then restore the state.
lookahead :: ParserT st e a -> ParserT st e a
lookahead (ParserT f) = ParserT \fp eob s st ->
  case f fp eob s st of
    OK# st' a _ -> OK# st' a s
    x           -> x
{-# inline lookahead #-}

-- | Convert a parsing failure to a success.
fails :: ParserT st e a -> ParserT st e ()
fails (ParserT f) = ParserT \fp eob s st ->
  case f fp eob s st of
    OK# st' _ _ -> Fail# st'
    Fail# st'   -> OK# st' () s
    Err# st' e  -> Err# st' e
{-# inline fails #-}

-- | Convert a parsing error into failure.
try :: ParserT st e a -> ParserT st e a
try (ParserT f) = ParserT \fp eob s st -> case f fp eob s st of
  Err# st' _ -> Fail# st'
  x          -> x
{-# inline try #-}

-- | Convert a parsing failure to a `Maybe`. If possible, use `withOption` instead.
optional :: ParserT st e a -> ParserT st e (Maybe a)
optional p = (Just <$> p) <|> pure Nothing
{-# inline optional #-}

-- | Convert a parsing failure to a `()`.
optional_ :: ParserT st e a -> ParserT st e ()
optional_ p = (() <$ p) <|> pure ()
{-# inline optional_ #-}

-- | CPS'd version of `optional`. This is usually more efficient, since it gets rid of the
--   extra `Maybe` allocation.
withOption :: ParserT st e a -> (a -> ParserT st e b) -> ParserT st e b -> ParserT st e b
withOption (ParserT f) just (ParserT nothing) = ParserT \fp eob s st -> case f fp eob s st of
  OK# st' a s -> runParserT# (just a) fp eob s st'
  Fail# st'   -> nothing fp eob s st'
  Err# st' e  -> Err# st' e
{-# inline withOption #-}

-- | Convert a parsing failure to an error.
cut :: ParserT st e a -> e -> ParserT st e a
cut (ParserT f) e = ParserT \fp eob s st -> case f fp eob s st of
  Fail# st' -> Err# st' e
  x         -> x
{-# inline cut #-}

-- | Run the parser, if we get a failure, throw the given error, but if we get an error, merge the
--   inner and the newly given errors using the @e -> e -> e@ function. This can be useful for
--   implementing parsing errors which may propagate hints or accummulate contextual information.
cutting :: ParserT st e a -> e -> (e -> e -> e) -> ParserT st e a
cutting (ParserT f) e merge = ParserT \fp eob s st -> case f fp eob s st of
  Fail# st'   -> Err# st' e
  Err# st' e' -> Err# st' $! merge e' e
  x           -> x
{-# inline cutting #-}

--------------------------------------------------------------------------------


-- | Succeed if the input is empty.
eof :: ParserT st e ()
eof = ParserT \fp eob s st -> case eqAddr# eob s of
  1# -> OK# st () s
  _  -> Fail# st
{-# inline eof #-}

-- | Read the given number of bytes as a 'ByteString'.
--
-- Throws a runtime error if given a negative integer.
takeBs :: Int -> ParserT st e B.ByteString
takeBs (I# n#) = takeBs# n#
{-# inline takeBs #-}

-- | Consume the rest of the input. May return the empty bytestring.
takeRestBs :: ParserT st e B.ByteString
takeRestBs = ParserT \fp eob s st ->
  let n# = minusAddr# eob s
  in  OK# st (B.PS (ForeignPtr s fp) 0 (I# n#)) eob
{-# inline takeRestBs #-}

-- | Skip forward @n@ bytes. Fails if fewer than @n@ bytes are available.
--
-- Throws a runtime error if given a negative integer.
skip :: Int -> ParserT st e ()
skip (I# os#) = atSkip# os# (pure ())
{-# inline skip #-}

-- | Parse a UTF-8 character literal. This is a template function, you can use it as
--   @$(char \'x\')@, for example, and the splice in this case has type @Parser e ()@.
char :: Char -> Q Exp
char c = string [c]

-- | Read a `Word8`.
byte :: Word8 -> ParserT st e ()
byte w = ensureBytes# 1 >> scan8# w
{-# inline byte #-}

-- | Read a sequence of bytes. This is a template function, you can use it as @$(bytes [3, 4, 5])@,
--   for example, and the splice has type @Parser e ()@. For a non-TH variant see 'byteString'.
bytes :: [Word] -> Q Exp
bytes bytes = do
  let !len = length bytes
  [| ensureBytes# len >> $(scanBytes# bytes) |]

-- | Parse a given `B.ByteString`. If the bytestring is statically known, consider using 'bytes' instead.
byteString :: B.ByteString -> ParserT st e ()
byteString (B.PS (ForeignPtr bs fcontent) _ (I# len)) =

  let go64 :: Addr# -> Addr# -> Addr# -> State# RealWorld -> Res# (State# RealWorld) e ()
      go64 bs bsend s rw =
        let bs' = plusAddr# bs 8# in
        case gtAddr# bs' bsend of
          1# -> go8 bs bsend s rw
          _  -> case eqWord# (indexWord64OffAddr# bs 0#) (indexWord64OffAddr# s 0#) of
            1# -> go64 bs' bsend (plusAddr# s 8#) rw
            _  -> Fail# rw

      go8 :: Addr# -> Addr# -> Addr# -> State# RealWorld -> Res# (State# RealWorld) e ()
      go8 bs bsend s rw = case ltAddr# bs bsend of
        1# -> case eqWord8'# (indexWord8OffAddr# bs 0#) (indexWord8OffAddr# s 0#) of
          1# -> go8 (plusAddr# bs 1#) bsend (plusAddr# s 1#) rw
          _  -> Fail# rw
        _  -> OK# rw () s

  -- We roundtrip through ParserIO in order to use touch#
  in reallyUnsafeStateCoerce $
       ParserT \fp eob s rw -> case len <=# minusAddr# eob s of
         1# -> case go64 bs (plusAddr# bs len) s rw of
                 (# rw', res #) -> case touch# fcontent rw' of
                   rw'' -> (# rw'', res #)
         _  -> Fail# rw
{-# inline byteString #-}

-- | Parse a UTF-8 string literal. This is a template function, you can use it as @$(string "foo")@,
--   for example, and the splice has type @Parser e ()@.
string :: String -> Q Exp
string str = bytes (strToBytes str)

{-|
This is a template function which makes it possible to branch on a collection of string literals in
an efficient way. By using `switch`, such branching is compiled to a trie of primitive parsing
operations, which has optimized control flow, vectorized reads and grouped checking for needed input
bytes.

The syntax is slightly magical, it overloads the usual @case@ expression. An example:

@
    $(switch [| case _ of
        "foo" -> pure True
        "bar" -> pure False |])
@

The underscore is mandatory in @case _ of@. Each branch must be a string literal, but optionally
we may have a default case, like in

@
    $(switch [| case _ of
        "foo" -> pure 10
        "bar" -> pure 20
        _     -> pure 30 |])
@

All case right hand sides must be parsers with the same type. That type is also the type
of the whole `switch` expression.

A `switch` has longest match semantics, and the order of cases does not matter, except for
the default case, which may only appear as the last case.

If a `switch` does not have a default case, and no case matches the input, then it returns with
failure, \without\ having consumed any input. A fallthrough to the default case also does not
consume any input.
-}
switch :: Q Exp -> Q Exp
switch = switchWithPost Nothing

{-|
Switch expression with an optional first argument for performing a post-processing action after
every successful branch matching, not including the default branch. For example, if we have
@ws :: ParserT st e ()@ for a whitespace parser, we might want to consume whitespace after matching
on any of the switch cases. For that case, we can define a "lexeme" version of `switch` as
follows.

@
  switch' :: Q Exp -> Q Exp
  switch' = switchWithPost (Just [| ws |])
@

Note that this @switch'@ function cannot be used in the same module it's defined in, because of the
stage restriction of Template Haskell.
-}
switchWithPost :: Maybe (Q Exp) -> Q Exp -> Q Exp
switchWithPost postAction exp = do
  !postAction <- sequence postAction
  (!cases, !fallback) <- parseSwitch exp
  genTrie $! genSwitchTrie' postAction cases fallback

-- | Version of `switchWithPost` without syntactic sugar. The second argument is the
--   list of cases, the third is the default case.
rawSwitchWithPost :: Maybe (Q Exp) -> [(String, Q Exp)] -> Maybe (Q Exp) -> Q Exp
rawSwitchWithPost postAction cases fallback = do
  !postAction <- sequence postAction
  !cases <- forM cases \(str, rhs) -> (str,) <$> rhs
  !fallback <- sequence fallback
  genTrie $! genSwitchTrie' postAction cases fallback

-- | Parse a UTF-8 `Char` for which a predicate holds.
satisfy :: (Char -> Bool) -> ParserT st e Char
satisfy f = ParserT \fp eob s st -> case runParserT# anyChar fp eob s st of
  OK# st' c s | f c -> OK# st' c s
  (# st', _ #)      -> Fail# st'
{-#  inline satisfy #-}

-- | Skip a UTF-8 `Char` for which a predicate holds.
satisfy_ :: (Char -> Bool) -> ParserT st e ()
satisfy_ f = ParserT \fp eob s st -> case runParserT# anyChar fp eob s st of
  OK# st' c s | f c -> OK# st' () s
  (# st', _ #)      -> Fail# st'
{-#  inline satisfy_ #-}

-- | Parse an ASCII `Char` for which a predicate holds. Assumption: the predicate must only return
--   `True` for ASCII-range characters. Otherwise this function might read a 128-255 range byte,
--   thereby breaking UTF-8 decoding.
satisfyASCII :: (Char -> Bool) -> ParserT st e Char
satisfyASCII f = ParserT \fp eob s st -> case eqAddr# eob s of
  1# -> Fail# st
  _  -> case derefChar8# s of
    c1 | f (C# c1) -> OK# st (C# c1) (plusAddr# s 1#)
       | otherwise -> Fail# st
{-#  inline satisfyASCII #-}

-- | Skip an ASCII `Char` for which a predicate holds. Assumption: the predicate
--   must only return `True` for ASCII-range characters.
satisfyASCII_ :: (Char -> Bool) -> ParserT st e ()
satisfyASCII_ f = ParserT \fp eob s st -> case eqAddr# eob s of
  1# -> Fail# st
  _  -> case derefChar8# s of
    c1 | f (C# c1) -> OK# st () (plusAddr# s 1#)
       | otherwise -> Fail# st
{-#  inline satisfyASCII_ #-}

-- | This is a variant of `satisfy` which allows more optimization. We can pick four testing
--   functions for the four cases for the possible number of bytes in the UTF-8 character. So in
--   @fusedSatisfy f1 f2 f3 f4@, if we read a one-byte character, the result is scrutinized with
--   @f1@, for two-bytes, with @f2@, and so on. This can result in dramatic lexing speedups.
--
--   For example, if we want to accept any letter, the naive solution would be to use
--   `Data.Char.isLetter`, but this accesses a large lookup table of Unicode character classes. We
--   can do better with @fusedSatisfy isLatinLetter isLetter isLetter isLetter@, since here the
--   `isLatinLetter` is inlined into the UTF-8 decoding, and it probably handles a great majority of
--   all cases without accessing the character table.
fusedSatisfy :: (Char -> Bool) -> (Char -> Bool) -> (Char -> Bool) -> (Char -> Bool) -> ParserT st e Char
fusedSatisfy f1 f2 f3 f4 = ParserT \fp eob buf st -> case eqAddr# eob buf of
  1# -> Fail# st
  _  -> case derefChar8# buf of
    c1 -> case c1 `leChar#` '\x7F'# of
      1# | f1 (C# c1) -> OK# st (C# c1) (plusAddr# buf 1#)
         | otherwise  -> Fail# st
      _  -> case eqAddr# eob (plusAddr# buf 1#) of
        1# -> Fail# st
        _ -> case indexCharOffAddr# buf 1# of
          c2 -> case c1 `leChar#` '\xDF'# of
            1# ->
              let resc = C# (chr# (((ord# c1 -# 0xC0#) `uncheckedIShiftL#` 6#) `orI#`
                                   (ord# c2 -# 0x80#)))
              in case f2 resc of
                   True -> OK# st resc (plusAddr# buf 2#)
                   _    -> Fail# st
            _ -> case eqAddr# eob (plusAddr# buf 2#) of
              1# -> Fail# st
              _  -> case indexCharOffAddr# buf 2# of
                c3 -> case c1 `leChar#` '\xEF'# of
                  1# ->
                    let resc = C# (chr# (((ord# c1 -# 0xE0#) `uncheckedIShiftL#` 12#) `orI#`
                                         ((ord# c2 -# 0x80#) `uncheckedIShiftL#`  6#) `orI#`
                                         (ord# c3 -# 0x80#)))
                    in case f3 resc of
                         True -> OK# st resc (plusAddr# buf 3#)
                         _    -> Fail# st
                  _ -> case eqAddr# eob (plusAddr# buf 3#) of
                    1# -> Fail# st
                    _  -> case indexCharOffAddr# buf 3# of
                      c4 ->
                        let resc = C# (chr# (((ord# c1 -# 0xF0#) `uncheckedIShiftL#` 18#) `orI#`
                                             ((ord# c2 -# 0x80#) `uncheckedIShiftL#` 12#) `orI#`
                                             ((ord# c3 -# 0x80#) `uncheckedIShiftL#`  6#) `orI#`
                                              (ord# c4 -# 0x80#)))
                        in case f4 resc of
                             True -> OK# st resc (plusAddr# buf 4#)
                             _    -> Fail# st
{-# inline fusedSatisfy #-}

-- | Skipping variant of `fusedSatisfy`.
fusedSatisfy_ :: (Char -> Bool) -> (Char -> Bool) -> (Char -> Bool) -> (Char -> Bool) -> ParserT st e ()
fusedSatisfy_ f1 f2 f3 f4 = () <$ fusedSatisfy f1 f2 f3 f4
{-# inline fusedSatisfy_ #-}

-- | Parse any UTF-8-encoded `Char`.
anyChar :: ParserT st e Char
anyChar = ParserT \fp eob buf st -> case eqAddr# eob buf of
  1# -> Fail# st
  _  -> case derefChar8# buf of
    c1 -> case c1 `leChar#` '\x7F'# of
      1# -> OK# st (C# c1) (plusAddr# buf 1#)
      _  -> case eqAddr# eob (plusAddr# buf 1#) of
        1# -> Fail# st
        _ -> case indexCharOffAddr# buf 1# of
          c2 -> case c1 `leChar#` '\xDF'# of
            1# ->
              let resc = ((ord# c1 -# 0xC0#) `uncheckedIShiftL#` 6#) `orI#`
                          (ord# c2 -# 0x80#)
              in OK# st (C# (chr# resc)) (plusAddr# buf 2#)
            _ -> case eqAddr# eob (plusAddr# buf 2#) of
              1# -> Fail# st
              _  -> case indexCharOffAddr# buf 2# of
                c3 -> case c1 `leChar#` '\xEF'# of
                  1# ->
                    let resc = ((ord# c1 -# 0xE0#) `uncheckedIShiftL#` 12#) `orI#`
                               ((ord# c2 -# 0x80#) `uncheckedIShiftL#`  6#) `orI#`
                                (ord# c3 -# 0x80#)
                    in OK# st (C# (chr# resc)) (plusAddr# buf 3#)
                  _ -> case eqAddr# eob (plusAddr# buf 3#) of
                    1# -> Fail# st
                    _  -> case indexCharOffAddr# buf 3# of
                      c4 ->
                        let resc = ((ord# c1 -# 0xF0#) `uncheckedIShiftL#` 18#) `orI#`
                                   ((ord# c2 -# 0x80#) `uncheckedIShiftL#` 12#) `orI#`
                                   ((ord# c3 -# 0x80#) `uncheckedIShiftL#`  6#) `orI#`
                                    (ord# c4 -# 0x80#)
                        in OK# st (C# (chr# resc)) (plusAddr# buf 4#)
{-# inline anyChar #-}

-- | Skip any UTF-8-encoded `Char`.
anyChar_ :: ParserT st e ()
anyChar_ = ParserT \fp eob buf st -> case eqAddr# eob buf of
  1# -> Fail# st
  _  -> case derefChar8# buf of
    c1 -> case c1 `leChar#` '\x7F'# of
      1# -> OK# st () (plusAddr# buf 1#)
      _  ->
        let buf' =
              case c1 `leChar#` '\xDF'# of
                1# -> plusAddr# buf 2#
                _  -> case c1 `leChar#` '\xEF'# of
                    1# -> plusAddr# buf 3#
                    _ ->  plusAddr# buf 4#
        in case leAddr# buf' eob of
             1# -> OK# st () buf'
             _  -> Fail# st
{-# inline anyChar_ #-}


-- | Parse any `Char` in the ASCII range, fail if the next input character is not in the range.
--   This is more efficient than `anyChar` if we are only working with ASCII.
anyCharASCII :: ParserT st e Char
anyCharASCII = ParserT \fp eob buf st -> case eqAddr# eob buf of
  1# -> Fail# st
  _  -> case derefChar8# buf of
    c1 -> case c1 `leChar#` '\x7F'# of
      1# -> OK# st (C# c1) (plusAddr# buf 1#)
      _  -> Fail# st
{-# inline anyCharASCII #-}

-- | Skip any `Char` in the ASCII range. More efficient than `anyChar_` if we're working only with
--   ASCII.
anyCharASCII_ :: ParserT st e ()
anyCharASCII_ = () <$ anyCharASCII
{-# inline anyCharASCII_ #-}

-- | Read a non-negative `Int` from the input, as a non-empty digit sequence.
-- Fails on overflow.
readInt :: ParserT st e Int
readInt = ParserT \fp eob s st -> case FlatParse.Internal.readInt eob s of
  (# (##) | #)        -> Fail# st
  (# | (# n, s' #) #) -> OK# st (I# n) s'
{-# inline readInt #-}

-- | Read an `Int` from the input, as a non-empty case-insensitive ASCII
--   hexadecimal digit sequence.
-- Fails on overflow.
readIntHex :: ParserT st e Int
readIntHex = ParserT $ \fp eob s st ->
  case FlatParse.Internal.readIntHex eob s of
    (# | (# i, s' #) #) -> OK# st (I# i) s'
    (# (# #) | #)       -> Fail# st
{-# inline readIntHex #-}

-- | Read a `Word` from the input, as a non-empty digit sequence.
-- Fails on overflow.
readWord :: ParserT st e Int
readWord = ParserT \fp eob s st -> case FlatParse.Internal.readInt eob s of
  (# (##) | #)        -> Fail# st
  (# | (# n, s' #) #) -> OK# st (I# n) s'
{-# inline readWord #-}

readWordHex :: ParserT st e Word
readWordHex = ParserT $ \_fp eob s st ->
  case FlatParse.Internal.readWordHex eob s of
    (# | (# n, s' #) #) -> OK# st (W# n) s'
    (# (# #) | #)       -> Fail# st
{-# inline readWordHex #-}

-- | Read a non-negative `Integer` from the input, as a non-empty digit
-- sequence.
readInteger :: ParserT st e Integer
readInteger = ParserT \fp eob s st -> case FlatParse.Internal.readInteger fp eob s of
  (# (##) | #)        -> Fail# st
  (# | (# i, s' #) #) -> OK# st i s'
{-# inline readInteger #-}

-- | Read a protobuf-style varint into an `Word`.
--
-- protobuf-style varints are byte-aligned. For each byte, the lower 7 bits are
-- data and the MSB indicates if there are further bytes. Once fully parsed, the
-- 7-bit payloads are concatenated and interpreted as a little-endian unsigned
-- integer.
--
-- Really, these are varnats. They also match with the LEB128 varint encoding.
--
-- protobuf encodes negatives in unsigned integers using zigzag encoding. See
-- the @fromZigzag@ family of functions for this functionality.
--
-- Further reading:
-- https://developers.google.com/protocol-buffers/docs/encoding#varints
readVarintProtobuf :: ParserT st e Word
readVarintProtobuf = ParserT \fp eob s st ->
    case readVarintProtobuf# eob s of
      (# (##) | #) -> Fail# st
      (# | (# w#, s#, n# #) #) ->
        case n# ># 64# of
          1# -> Fail# st -- overflow
          _  -> OK# st (W# w#) s#
{-# inline readVarintProtobuf #-}

--------------------------------------------------------------------------------

-- | Choose between two parsers. If the first parser fails, try the second one, but if the first one
--   throws an error, propagate the error.
infixr 6 <|>
(<|>) :: ParserT st e a -> ParserT st e a -> ParserT st e a
(<|>) (ParserT f) (ParserT g) = ParserT \fp eob s st ->
  case f fp eob s st of
    Fail# st' -> g fp eob s st'
    x         -> x
{-# inline[1] (<|>) #-}

instance Base.Alternative (ParserT st e) where
  empty = failed
  {-# inline empty #-}
  (<|>) = (<|>)
  {-# inline (Base.<|>) #-}

instance MonadPlus (ParserT st e) where
  mzero = failed
  {-# inline mzero #-}
  mplus = (<|>)
  {-# inline mplus #-}

{-# RULES

"flatparse/reassoc-alt" forall l m r. (l <|> m) <|> r = l <|> (m <|> r)

#-}

-- | Branch on a parser: if the first argument succeeds, continue with the second, else with the third.
--   This can produce slightly more efficient code than `(<|>)`. Moreover, `ḃranch` does not
--   backtrack from the true/false cases.
branch :: ParserT st e a -> ParserT st e b -> ParserT st e b -> ParserT st e b
branch pa pt pf = ParserT \fp eob s st -> case runParserT# pa fp eob s st of
  OK# st' _ s -> runParserT# pt fp eob s st'
  Fail# st'  -> runParserT# pf fp eob s st'
  Err# st' e  -> Err# st' e
{-# inline branch #-}

-- | An analogue of the list `foldl` function: first parse a @b@, then parse zero or more @a@-s,
--   and combine the results in a left-nested way by the @b -> a -> b@ function. Note: this is not
--   the usual `chainl` function from the parsec libraries!
chainl :: (b -> a -> b) -> ParserT st e b -> ParserT st e a -> ParserT st e b
chainl f start elem = start >>= go where
  go b = do {!a <- elem; go $! f b a} <|> pure b
{-# inline chainl #-}

-- | An analogue of the list `foldr` function: parse zero or more @a@-s, terminated by a @b@, and
--   combine the results in a right-nested way using the @a -> b -> b@ function. Note: this is not
--   the usual `chainr` function from the parsec libraries!
chainr :: (a -> b -> b) -> ParserT st e a -> ParserT st e b -> ParserT st e b
chainr f (ParserT elem) (ParserT end) = ParserT go where
  go fp eob s st = case elem fp eob s st of
    OK# st' a s -> case go fp eob s st' of
      OK# st'' b s -> let !b' = f a b in OK# st'' b' s
      x       -> x
    Fail# st' -> end fp eob s st'
    Err# st' e -> Err# st' e
{-# inline chainr #-}

-- | Run a parser zero or more times, collect the results in a list. Note: for optimal performance,
--   try to avoid this. Often it is possible to get rid of the intermediate list by using a
--   combinator or a custom parser.
many :: ParserT st e a -> ParserT st e [a]
many (ParserT f) = ParserT go where
  go fp eob s st = case f fp eob s st of
    OK# st' a s -> case go fp eob s st' of
                    OK# st'' as s -> OK# st'' (a:as) s
                    x        -> x
    Fail# st'  -> OK# st' [] s
    Err# st' e -> Err# st' e
{-# inline many #-}

-- | Skip a parser zero or more times.
many_ :: ParserT st e a -> ParserT st e ()
many_ (ParserT f) = ParserT go where
  go fp eob s st = case f fp eob s st of
    OK# st' a s -> go fp eob s st'
    Fail# st'   -> OK# st' () s
    Err# st' e  -> Err# st' e
{-# inline many_ #-}

-- | Run a parser one or more times, collect the results in a list. Note: for optimal performance,
--   try to avoid this. Often it is possible to get rid of the intermediate list by using a
--   combinator or a custom parser.
some :: ParserT st e a -> ParserT st e [a]
some p = (:) <$> p <*> many p
{-# inline some #-}

-- | Skip a parser one or more times.
some_ :: ParserT st e a -> ParserT st e ()
some_ pa = pa >> many_ pa
{-# inline some_ #-}

-- | Succeed if the first parser succeeds and the second one fails.
notFollowedBy :: ParserT st e a -> ParserT st e b -> ParserT st e a
notFollowedBy p1 p2 = p1 <* fails p2
{-# inline notFollowedBy #-}

-- | @isolate n p@ runs the parser @p@ isolated to the next @n@ bytes. All
--   isolated bytes must be consumed.
--
-- Throws a runtime error if given a negative integer.
isolate :: Int -> ParserT st e a -> ParserT st e a
isolate (I# n#) p = ParserT \fp eob s st ->
  let s' = plusAddr# s n#
  in  case n# <=# minusAddr# eob s of
        1# -> case n# >=# 0# of
          1# -> case runParserT# p fp s' s st of
            OK# st' a s'' -> case eqAddr# s' s'' of
              1# -> OK# st' a s''
              _  -> Fail# st' -- isolated segment wasn't fully consumed
            Fail# st' -> Fail# st'
            Err# st' e -> Err# st' e
          _  -> error "FlatParse.Basic.isolate: negative integer"
        _  -> Fail# st -- you tried to isolate more than we have left
{-# inline isolate #-}


--------------------------------------------------------------------------------

-- | Get the current position in the input.
getPos :: ParserT st e Pos
getPos = ParserT \fp eob s st -> OK# st (addrToPos# eob s) s
{-# inline getPos #-}

-- | Set the input position. Warning: this can result in crashes if the position points outside the
--   current buffer. It is always safe to `setPos` values which came from `getPos` with the current
--   input.
setPos :: Pos -> ParserT st e ()
setPos s = ParserT \fp eob _ st -> OK# st () (posToAddr# eob s)
{-# inline setPos #-}

-- | The end of the input.
endPos :: Pos
endPos = Pos 0
{-# inline endPos #-}

-- | Return the consumed span of a parser.
spanOf :: ParserT st e a -> ParserT st e Span
spanOf (ParserT f) = ParserT \fp eob s st -> case f fp eob s st of
  OK# st' a s' -> OK# st' (Span (addrToPos# eob s) (addrToPos# eob s')) s'
  x        -> unsafeCoerce# x
{-# inline spanOf #-}

-- | Bind the result together with the span of the result. CPS'd version of `spanOf`
--   for better unboxing.
withSpan :: ParserT st e a -> (a -> Span -> ParserT st e b) -> ParserT st e b
withSpan (ParserT f) g = ParserT \fp eob s st -> case f fp eob s st of
  OK# st' a s' -> runParserT# (g a (Span (addrToPos# eob s) (addrToPos# eob s'))) fp eob s' st'
  x        -> unsafeCoerce# x
{-# inline withSpan #-}

-- | Return the `B.ByteString` consumed by a parser. Note: it's more efficient to use `spanOf` and
--   `withSpan` instead.
byteStringOf :: ParserT st e a -> ParserT st e B.ByteString
byteStringOf (ParserT f) = ParserT \fp eob s st -> case f fp eob s st of
  OK# st' a s' -> OK# st' (B.PS (ForeignPtr s fp) 0 (I# (minusAddr# s' s))) s'
  x        -> unsafeCoerce# x
{-# inline byteStringOf #-}

-- | CPS'd version of `byteStringOf`. Can be more efficient, because the result is more eagerly unboxed
--   by GHC. It's more efficient to use `spanOf` or `withSpan` instead.
withByteString :: ParserT st e a -> (a -> B.ByteString -> ParserT st e b) -> ParserT st e b
withByteString (ParserT f) g = ParserT \fp eob s st -> case f fp eob s st of
  OK# st' a s' -> runParserT# (g a (B.PS (ForeignPtr s fp) 0 (I# (minusAddr# s' s)))) fp eob s' st'
  x        -> unsafeCoerce# x
{-# inline withByteString #-}

-- | Run a parser in a given input span. The input position and the `Int` state is restored after
--   the parser is finished, so `inSpan` does not consume input and has no side effect.  Warning:
--   this operation may crash if the given span points outside the current parsing buffer. It's
--   always safe to use `inSpan` if the span comes from a previous `withSpan` or `spanOf` call on
--   the current input.
inSpan :: Span -> ParserT st e a -> ParserT st e a
inSpan (Span s eob) (ParserT f) = ParserT \fp eob' s' st ->
  case f fp (posToAddr# eob' eob) (posToAddr# eob' s) st of
    OK# st' a _ -> OK# st' a s'
    x       -> unsafeCoerce# x
{-# inline inSpan #-}

--------------------------------------------------------------------------------

-- | Check whether a `Pos` points into a `B.ByteString`.
validPos :: B.ByteString -> Pos -> Bool
validPos str pos =
  let go = do
        start <- getPos
        pure (start <= pos && pos <= endPos)
  in case runParser go str of
    OK b _ -> b
    _      -> error "impossible"
{-# inline validPos #-}

-- | Compute corresponding line and column numbers for each `Pos` in a list. Throw an error
--   on invalid positions. Note: computing lines and columns may traverse the `B.ByteString`,
--   but it traverses it only once regardless of the length of the position list.
posLineCols :: B.ByteString -> [Pos] -> [(Int, Int)]
posLineCols str poss =
  let go !line !col [] = pure []
      go line col ((i, pos):poss) = do
        p <- getPos
        if pos == p then
          ((i, (line, col)):) <$> go line col poss
        else do
          c <- anyChar
          if '\n' == c then
            go (line + 1) 0 ((i, pos):poss)
          else
            go line (col + 1) ((i, pos):poss)

      sorted :: [(Int, Pos)]
      sorted = sortBy (comparing snd) (zip [0..] poss)

  in case runParser (go 0 0 sorted) str of
       OK res _ -> snd <$> sortBy (comparing fst) res
       _        -> error "invalid position"

-- | Create a `B.ByteString` from a `Span`. The result is invalid if the `Span` points
--   outside the current buffer, or if the `Span` start is greater than the end position.
unsafeSpanToByteString :: Span -> ParserT st e B.ByteString
unsafeSpanToByteString (Span l r) =
  lookahead (setPos l >> byteStringOf (setPos r))
{-# inline unsafeSpanToByteString #-}

-- | Create a `Pos` from a line and column number. Throws an error on out-of-bounds
--   line and column numbers.
mkPos :: B.ByteString -> (Int, Int) -> Pos
mkPos str (line', col') =
  let go line col | line == line' && col == col' = getPos
      go line col = (do
        c <- anyChar
        if c == '\n' then go (line + 1) 0
                     else go line (col + 1)) <|> error "mkPos: invalid position"
  in case runParser (go 0 0) str of
    OK res _ -> res
    _        -> error "impossible"

-- | Break an UTF-8-coded `B.ByteString` to lines. Throws an error on invalid input.
--   This is mostly useful for grabbing specific source lines for displaying error
--   messages.
lines :: B.ByteString -> [String]
lines str =
  let go = ([] <$ eof) <|> ((:) <$> takeLine <*> go)
  in case runParser go str of
    OK ls _ -> ls
    _       -> error "linesUTF8: invalid input"

--------------------------------------------------------------------------------

-- | Parse the rest of the current line as a `String`. Assumes UTF-8 encoding,
--   throws an error if the encoding is invalid.
takeLine :: ParserT st e String
takeLine = branch eof (pure "") do
  c <- anyChar
  case c of
    '\n' -> pure ""
    _    -> (c:) <$> takeLine

-- | Parse the rest of the current line as a `String`, but restore the parsing state.
--   Assumes UTF-8 encoding. This can be used for debugging.
traceLine :: ParserT st e String
traceLine = lookahead takeLine

-- | Take the rest of the input as a `String`. Assumes UTF-8 encoding.
takeRest :: ParserT st e String
takeRest = branch eof (pure "") do
  c <- anyChar
  cs <- takeRest
  pure (c:cs)

-- | Get the rest of the input as a `String`, but restore the parsing state. Assumes UTF-8 encoding.
--   This can be used for debugging.
traceRest :: ParserT st e String
traceRest = lookahead takeRest

--------------------------------------------------------------------------------

-- | Convert an UTF-8-coded `B.ByteString` to a `String`.
unpackUTF8 :: B.ByteString -> String
unpackUTF8 str = case runParser takeRest str of
  OK a _ -> a
  _      -> error "unpackUTF8: invalid encoding"

-- | Check that the input has at least the given number of bytes.
ensureBytes# :: Int -> ParserT st e ()
ensureBytes# (I# len) = ParserT \fp eob s st ->
  case len  <=# minusAddr# eob s of
    1# -> OK# st () s
    _  -> Fail# st
{-# inline ensureBytes# #-}

-- | Unsafely read a concrete byte from the input. It's not checked that the input has
--   enough bytes.
scan8# :: Word8 -> ParserT st e ()
scan8# (W8# c) = ParserT \fp eob s st ->
  case indexWord8OffAddr# s 0# of
    c' -> case eqWord8'# c c' of
      1# -> OK# st () (plusAddr# s 1#)
      _  -> Fail# st
{-# inline scan8# #-}

-- | Unsafely read two concrete bytes from the input. It's not checked that the input has
--   enough bytes.
scan16# :: Word16 -> ParserT st e ()
scan16# (W16# c) = ParserT \fp eob s st ->
  case indexWord16OffAddr# s 0# of
    c' -> case eqWord16'# c c' of
      1# -> OK# st () (plusAddr# s 2#)
      _  -> Fail# st
{-# inline scan16# #-}

-- | Unsafely read four concrete bytes from the input. It's not checked that the input has
--   enough bytes.
scan32# :: Word32 -> ParserT st e ()
scan32# (W32# c) = ParserT \fp eob s st ->
  case indexWord32OffAddr# s 0# of
    c' -> case eqWord32'# c c' of
      1# -> OK# st () (plusAddr# s 4#)
      _  -> Fail# st
{-# inline scan32# #-}

-- | Unsafely read eight concrete bytes from the input. It's not checked that the input has
--   enough bytes.
scan64# :: Word -> ParserT st e ()
scan64# (W# c) = ParserT \fp eob s st ->
  case indexWord64OffAddr# s 0# of
    c' -> case eqWord# c c' of
      1# -> OK# st () (plusAddr# s 8#)
      _  -> Fail# st
{-# inline scan64# #-}

-- | Unsafely read and return a byte from the input. It's not checked that the input is non-empty.
scanAny8# :: ParserT st e Word8
scanAny8# = ParserT \fp eob s st -> OK# st (W8# (indexWord8OffAddr# s 0#)) (plusAddr# s 1#)
{-# inline scanAny8# #-}

scanPartial64# :: Int -> Word -> ParserT st e ()
scanPartial64# (I# len) (W# w) = ParserT \fp eob s st ->
  case indexWordOffAddr# s 0# of
    w' -> case uncheckedIShiftL# (8# -# len) 3# of
      sh -> case uncheckedShiftL# w' sh of
        w' -> case uncheckedShiftRL# w' sh of
          w' -> case eqWord# w w' of
            1# -> OK# st () (plusAddr# s len)
            _  -> Fail# st
{-# inline scanPartial64# #-}

-- | Decrease the current input position by the given number of bytes.
setBack# :: Int -> ParserT st e ()
setBack# (I# i) = ParserT \fp eob s st ->
  OK# st () (plusAddr# s (negateInt# i))
{-# inline setBack# #-}

-- | Template function, creates a @Parser e ()@ which unsafely scans a given
--   sequence of bytes.
scanBytes# :: [Word] -> Q Exp
scanBytes# bytes = do
  let !(leading, w8s) = splitBytes bytes
      !scanw8s        = go w8s where
                         go (w8:[] ) = [| scan64# w8 |]
                         go (w8:w8s) = [| scan64# w8 >> $(go w8s) |]
                         go []       = [| pure () |]
  case w8s of
    [] -> go leading
          where
            go (a:b:c:d:[]) = let !w = packBytes [a, b, c, d] in [| scan32# w |]
            go (a:b:c:d:ws) = let !w = packBytes [a, b, c, d] in [| scan32# w >> $(go ws) |]
            go (a:b:[])     = let !w = packBytes [a, b]       in [| scan16# w |]
            go (a:b:ws)     = let !w = packBytes [a, b]       in [| scan16# w >> $(go ws) |]
            go (a:[])       = [| scan8# a |]
            go []           = [| pure () |]
    _  -> case leading of

      []              -> scanw8s
      [a]             -> [| scan8# a >> $scanw8s |]
      ws@[a, b]       -> let !w = packBytes ws in [| scan16# w >> $scanw8s |]
      ws@[a, b, c, d] -> let !w = packBytes ws in [| scan32# w >> $scanw8s |]
      ws              -> let !w = packBytes ws
                             !l = length ws
                         in [| scanPartial64# l w >> $scanw8s |]


-- Switching code generation
--------------------------------------------------------------------------------

#if MIN_VERSION_base(4,15,0)
mkDoE = DoE Nothing
{-# inline mkDoE #-}
#else
mkDoE = DoE
{-# inline mkDoE #-}
#endif

genTrie :: (Map (Maybe Int) Exp, Trie' (Rule, Int, Maybe Int)) -> Q Exp
genTrie (rules, t) = do
  branches <- traverse (\e -> (,) <$> (newName "rule") <*> pure e) rules

  let ix m k = case M.lookup k m of
        Nothing -> error ("key not in map: " ++ show k)
        Just a  -> a

  let ensure :: Maybe Int -> Maybe (Q Exp)
      ensure = fmap (\n -> [| ensureBytes# n |])

      fallback :: Rule -> Int ->  Q Exp
      fallback rule 0 = pure $ VarE $ fst $ ix branches rule
      fallback rule n = [| setBack# n >> $(pure $ VarE $ fst $ ix branches rule) |]

  let go :: Trie' (Rule, Int, Maybe Int) -> Q Exp
      go = \case
        Branch' (r, n, alloc) ts
          | M.null ts -> pure $ VarE $ fst $ branches M.! r
          | otherwise -> do
              !next         <- (traverse . traverse) go (M.toList ts)
              !defaultCase  <- fallback r (n + 1)

              let cases = mkDoE $
                    [BindS (VarP (mkName "c")) (VarE 'scanAny8#),
                      NoBindS (CaseE (VarE (mkName "c"))
                         (map (\(w, t) ->
                                 Match (LitP (IntegerL (fromIntegral w)))
                                       (NormalB t)
                                       [])
                              next
                          ++ [Match WildP (NormalB defaultCase) []]))]

              case ensure alloc of
                Nothing    -> pure cases
                Just alloc -> [| branch $alloc $(pure cases) $(fallback r n) |]

        Path (r, n, alloc) ws t ->
          case ensure alloc of
            Nothing    -> [| branch $(scanBytes# ws) $(go t) $(fallback r n)|]
            Just alloc -> [| branch ($alloc >> $(scanBytes# ws)) $(go t) $(fallback r n) |]

  letE
    (map (\(x, rhs) -> valD (varP x) (normalB (pure rhs)) []) (Data.Foldable.toList branches))
    (go t)

parseSwitch :: Q Exp -> Q ([(String, Exp)], Maybe Exp)
parseSwitch exp = exp >>= \case
  CaseE (UnboundVarE _) []    -> error "switch: empty clause list"
  CaseE (UnboundVarE _) cases -> do
    (!cases, !last) <- pure (init cases, last cases)
    !cases <- forM cases \case
      Match (LitP (StringL str)) (NormalB rhs) [] -> pure (str, rhs)
      _ -> error "switch: expected a match clause on a string literal"
    (!cases, !last) <- case last of
      Match (LitP (StringL str)) (NormalB rhs) [] -> pure (cases ++ [(str, rhs)], Nothing)
      Match WildP                (NormalB rhs) [] -> pure (cases, Just rhs)
      _ -> error "switch: expected a match clause on a string literal or a wildcard"
    pure (cases, last)
  _ -> error "switch: expected a \"case _ of\" expression"

genSwitchTrie' :: Maybe Exp -> [(String, Exp)] -> Maybe Exp
              -> (Map (Maybe Int) Exp, Trie' (Rule, Int, Maybe Int))
genSwitchTrie' postAction cases fallback =

  let (!branches, !strings) = unzip do
        (!i, (!str, !rhs)) <- zip [0..] cases
        case postAction of
          Nothing    -> pure ((Just i, rhs), (i, str))
          Just !post -> pure ((Just i, (VarE '(>>)) `AppE` post `AppE` rhs), (i, str))

      !m    = M.fromList ((Nothing, maybe (VarE 'failed) id fallback) : branches)
      !trie = compileTrie strings
  in (m , trie)

--------------------------------------------------------------------------------

withAnyWord8# :: (Word8'# -> ParserT st e a) -> ParserT st e a
withAnyWord8# p = ParserT \fp eob buf -> case eqAddr# eob buf of
  1# -> Fail#
  _  -> case indexWord8OffAddr# buf 0# of
    w# -> runParserT# (p w#) fp eob (plusAddr# buf 1#)
{-# inline withAnyWord8# #-}

withAnyWord16# :: (Word16'# -> ParserT st e a) -> ParserT st e a
withAnyWord16# p = ParserT \fp eob buf -> case 2# <=# minusAddr# eob buf of
  0# -> Fail#
  _  -> case indexWord16OffAddr# buf 0# of
    w# -> runParserT# (p w#) fp eob (plusAddr# buf 2#)
{-# inline withAnyWord16# #-}

withAnyWord32# :: (Word32'# -> ParserT st e a) -> ParserT st e a
withAnyWord32# p = ParserT \fp eob buf -> case 4# <=# minusAddr# eob buf of
  0# -> Fail#
  _  -> case indexWord32OffAddr# buf 0# of
    w# -> runParserT# (p w#) fp eob (plusAddr# buf 4#)
{-# inline withAnyWord32# #-}

withAnyWord64# :: (Word# -> ParserT st e a) -> ParserT st e a
withAnyWord64# p = ParserT \fp eob buf -> case 8# <=# minusAddr# eob buf of
  0# -> Fail#
  _  -> case indexWordOffAddr# buf 0# of
    w# -> runParserT# (p w#) fp eob (plusAddr# buf 8#)
{-# inline withAnyWord64# #-}

withAnyInt8# :: (Int8'# -> ParserT st e a) -> ParserT st e a
withAnyInt8# p = ParserT \fp eob buf -> case eqAddr# eob buf of
  1# -> Fail#
  _  -> case indexInt8OffAddr# buf 0# of
    i# -> runParserT# (p i#) fp eob (plusAddr# buf 1#)
{-# inline withAnyInt8# #-}

withAnyInt16# :: (Int16'# -> ParserT st e a) -> ParserT st e a
withAnyInt16# p = ParserT \fp eob buf -> case 2# <=# minusAddr# eob buf of
  0# -> Fail#
  _  -> case indexInt16OffAddr# buf 0# of
    i# -> runParserT# (p i#) fp eob (plusAddr# buf 2#)
{-# inline withAnyInt16# #-}

withAnyInt32# :: (Int32'# -> ParserT st e a) -> ParserT st e a
withAnyInt32# p = ParserT \fp eob buf -> case 4# <=# minusAddr# eob buf of
  0# -> Fail#
  _  -> case indexInt32OffAddr# buf 0# of
    i# -> runParserT# (p i#) fp eob (plusAddr# buf 4#)
{-# inline withAnyInt32# #-}

withAnyInt64# :: (Int# -> ParserT st e a) -> ParserT st e a
withAnyInt64# p = ParserT \fp eob buf -> case 8# <=# minusAddr# eob buf of
  0# -> Fail#
  _  -> case indexInt64OffAddr# buf 0# of
    i# -> runParserT# (p i#) fp eob (plusAddr# buf 8#)
{-# inline withAnyInt64# #-}

--------------------------------------------------------------------------------

-- | Parse any 'Word8' (byte).
anyWord8 :: ParserT st e Word8
anyWord8 = withAnyWord8# (\w# -> pure (W8# w#))
{-# inline anyWord8 #-}

-- | Skip any 'Word8' (byte).
anyWord8_ :: ParserT st e ()
anyWord8_ = () <$ anyWord8
{-# inline anyWord8_ #-}

-- | Parse any 'Word16'.
anyWord16 :: ParserT st e Word16
anyWord16 = withAnyWord16# (\w# -> pure (W16# w#))
{-# inline anyWord16 #-}

-- | Skip any 'Word16'.
anyWord16_ :: ParserT st e ()
anyWord16_ = () <$ anyWord16
{-# inline anyWord16_ #-}

-- | Parse any 'Word32'.
anyWord32 :: ParserT st e Word32
anyWord32 = withAnyWord32# (\w# -> pure (W32# w#))
{-# inline anyWord32 #-}

-- | Skip any 'Word32'.
anyWord32_ :: ParserT st e ()
anyWord32_ = () <$ anyWord32
{-# inline anyWord32_ #-}

-- | Parse any 'Word64'.
anyWord64 :: ParserT st e Word64
anyWord64 = withAnyWord64# (\w# -> pure (W64# w#))
{-# inline anyWord64 #-}

-- | Skip any 'Word64'.
anyWord64_ :: ParserT st e ()
anyWord64_ = () <$ anyWord64
{-# inline anyWord64_ #-}

-- | Parse any 'Word'.
anyWord :: ParserT st e Word
anyWord = withAnyWord64# (\w# -> pure (W# w#))
{-# inline anyWord #-}

-- | Skip any 'Word'.
anyWord_ :: ParserT st e ()
anyWord_ = () <$ anyWord
{-# inline anyWord_ #-}

--------------------------------------------------------------------------------

-- | Parse any 'Int8'.
anyInt8 :: ParserT st e Int8
anyInt8 = withAnyInt8# (\i# -> pure (I8# i#))
{-# inline anyInt8 #-}

-- | Parse any 'Int16'.
anyInt16 :: ParserT st e Int16
anyInt16 = withAnyInt16# (\i# -> pure (I16# i#))
{-# inline anyInt16 #-}

-- | Parse any 'Int32'.
anyInt32 :: ParserT st e Int32
anyInt32 = withAnyInt32# (\i# -> pure (I32# i#))
{-# inline anyInt32 #-}

-- | Parse any 'Int64'.
anyInt64 :: ParserT st e Int64
anyInt64 = withAnyInt64# (\i# -> pure (I64# i#))
{-# inline anyInt64 #-}

-- | Parse any 'Int'.
anyInt :: ParserT st e Int
anyInt = withAnyInt64# (\i# -> pure (I# i#))
{-# inline anyInt #-}

--------------------------------------------------------------------------------

-- | Parse any 'Word16' (little-endian).
anyWord16le :: ParserT st e Word16
anyWord16le = anyWord16
{-# inline anyWord16le #-}

-- | Parse any 'Word16' (big-endian).
anyWord16be :: ParserT st e Word16
anyWord16be = withAnyWord16# (\w# -> pure (W16# (byteSwap16'# w#)))
{-# inline anyWord16be #-}

-- | Parse any 'Word32' (little-endian).
anyWord32le :: ParserT st e Word32
anyWord32le = anyWord32
{-# inline anyWord32le #-}

-- | Parse any 'Word32' (big-endian).
anyWord32be :: ParserT st e Word32
anyWord32be = withAnyWord32# (\w# -> pure (W32# (byteSwap32'# w#)))
{-# inline anyWord32be #-}

-- | Parse any 'Word64' (little-endian).
anyWord64le :: ParserT st e Word64
anyWord64le = anyWord64
{-# inline anyWord64le #-}

-- | Parse any 'Word64' (big-endian).
anyWord64be :: ParserT st e Word64
anyWord64be = withAnyWord64# (\w# -> pure (W64# (byteSwap# w#)))
{-# inline anyWord64be #-}

--------------------------------------------------------------------------------

-- | Parse any 'Int16' (little-endian).
anyInt16le :: ParserT st e Int16
anyInt16le = anyInt16
{-# inline anyInt16le #-}

-- | Parse any 'Int16' (big-endian).
anyInt16be :: ParserT st e Int16
anyInt16be = withAnyWord16# (\w# -> pure (I16# (word16ToInt16# (byteSwap16'# w#))))
{-# inline anyInt16be #-}

-- | Parse any 'Int32' (little-endian).
anyInt32le :: ParserT st e Int32
anyInt32le = anyInt32
{-# inline anyInt32le #-}

-- | Parse any 'Int32' (big-endian).
anyInt32be :: ParserT st e Int32
anyInt32be = withAnyWord32# (\w# -> pure (I32# (word32ToInt32# (byteSwap32'# w#))))
{-# inline anyInt32be #-}

-- | Parse any 'Int64' (little-endian).
anyInt64le :: ParserT st e Int64
anyInt64le = anyInt64
{-# inline anyInt64le #-}

-- | Parse any 'Int64' (big-endian).
anyInt64be :: ParserT st e Int64
anyInt64be = withAnyWord64# (\w# -> pure (I64# (word2Int# (byteSwap# w#))))
{-# inline anyInt64be #-}

--------------------------------------------------------------------------------

-- | Skip forward @n@ bytes and run the given parser. Fails if fewer than @n@
--   bytes are available.
--
-- Throws a runtime error if given a negative integer.
atSkip# :: Int# -> ParserT st e a -> ParserT st e a
atSkip# os# (ParserT p) = ParserT \fp eob s -> case os# <=# minusAddr# eob s of
  1# -> case os# >=# 0# of
    1# -> p fp eob (plusAddr# s os#)
    _  -> error "FlatParse.Basic.atSkip#: negative integer"
  _  -> Fail#
{-# inline atSkip# #-}

-- | Read the given number of bytes as a 'ByteString'.
--
-- Throws a runtime error if given a negative integer.
takeBs# :: Int# -> ParserT st e B.ByteString
takeBs# n# = ParserT \fp eob s st -> case n# <=# minusAddr# eob s of
  1# -> -- have to runtime check for negative values, because they cause a hang
    case n# >=# 0# of
      1# -> OK# st (B.PS (ForeignPtr s fp) 0 (I# n#)) (plusAddr# s n#)
      _  -> error "FlatParse.Basic.takeBs: negative integer"
  _  -> Fail# st
{-# inline takeBs# #-}

--------------------------------------------------------------------------------

-- | Run a parser, passing it the current address the parser is at.
--
-- Useful for parsing offset-based data tables. For example, you may use this to
-- save the base address to use together with various 0-indexed offsets.
withAddr# :: (Addr# -> ParserT st e a) -> ParserT st e a
withAddr# p = ParserT \fp eob s -> runParserT# (p s) fp eob s
{-# inline withAddr# #-}

-- | @takeBsOffAddr# addr# offset# len#@ moves to @addr#@, skips @offset#@
--   bytes, reads @len#@ bytes into a 'ByteString', and restores the original
--   address.
--
-- The 'Addr#' should be from 'withAddr#'.
--
-- Useful for parsing offset-based data tables. For example, you may use this
-- together with 'withAddr#' to jump to an offset in your input and read some
-- data.
takeBsOffAddr# :: Addr# -> Int# -> Int# -> ParserT st e B.ByteString
takeBsOffAddr# addr# offset# len# =
    lookaheadFromAddr# addr# $ atSkip# offset# $ takeBs# len#
{-# inline takeBsOffAddr# #-}

-- | 'lookahead', but specify the address to lookahead from.
--
-- The 'Addr#' should be from 'withAddr#'.
lookaheadFromAddr# :: Addr# -> ParserT st e a -> ParserT st e a
lookaheadFromAddr# s = lookahead . atAddr# s
{-# inline lookaheadFromAddr# #-}

-- | Run a parser at the given address.
--
-- The 'Addr#' should be from 'withAddr#'.
--
-- This is a highly internal function -- you likely want 'lookaheadFromAddr#',
-- which will reset the address after running the parser.
atAddr# :: Addr# -> ParserT st e a -> ParserT st e a
atAddr# s (ParserT p) = ParserT \fp eob _ -> p fp eob s
{-# inline atAddr# #-}

--------------------------------------------------------------------------------

-- | Read a null-terminated bytestring (a C-style string).
--
-- Consumes the null terminator.
anyCString :: ParserT st e B.ByteString
anyCString = ParserT go'
  where
    go' fp eob s0 st = go 0# s0
      where
        go n# s = case eqAddr# eob s of
          1# -> Fail# st
          _  ->
            let s' = plusAddr# s 1#
            -- TODO below is a candidate for improving with ExtendedLiterals!
            in  case eqWord8# (indexWord8OffAddr''# s 0#) (wordToWord8''# 0##) of
                  1# -> OK# st (B.PS (ForeignPtr s0 fp) 0 (I# n#)) s'
                  _  -> go (n# +# 1#) s'
{-# inline anyCString #-}

-- | Read a null-terminated bytestring (a C-style string), where the bytestring
--   is known to be null-terminated somewhere in the input.
--
-- Highly unsafe. Unless you have a guarantee that the string will be null
-- terminated before the input ends, use 'anyCString' instead. Honestly, I'm not
-- sure if this is a good function to define. But here it is.
--
-- Fails on GHC versions older than 9.0, since we make use of the
-- 'cstringLength#' primop introduced in GHC 9.0, and we aren't very useful
-- without it.
--
-- Consumes the null terminator.
anyCStringUnsafe :: ParserT st e B.ByteString
{-# inline anyCStringUnsafe #-}
#if MIN_VERSION_base(4,15,0)
anyCStringUnsafe = ParserT \fp eob s st ->
  case eqAddr# eob s of
    1# -> Fail# st
    _  -> let n#  = cstringLength# s
              s'# = plusAddr# s (n# +# 1#)
           in OK# st (B.PS (ForeignPtr s fp) 0 (I# n#)) s'#
#else
anyCStringUnsafe = error "Flatparse.Basic.anyCStringUnsafe: requires GHC 9.0 / base-4.15, not available on this compiler"
#endif

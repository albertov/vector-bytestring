{-# LANGUAGE CPP, DeriveDataTypeable #-}

#if __GLASGOW_HASKELL__ >= 704
{-# LANGUAGE Unsafe #-}
#endif

-- |
-- Module      : Data.Vector.Storable.ByteString.Lazy.Internal
-- License     : BSD-style
-- Maintainer  : Bas van Dijk <v.dijk.bas@gmail.com>
-- Stability   : experimental
-- Portability : portable
--
-- A module containing semi-public 'ByteString' internals. This exposes
-- the 'ByteString' representation and low level construction functions.
-- Modules which extend the 'ByteString' system will need to use this module
-- while ideally most users will be able to make do with the public interface
-- modules.
--
module Data.Vector.Storable.ByteString.Lazy.Internal (

        -- * The lazy @ByteString@ type and representation
        ByteString(..),     -- instances: Eq, Ord, Show, Read, Data, Typeable
        chunk,
        foldrChunks,
        foldlChunks,

        -- * Data type invariant and abstraction function
        invariant,
        checkInvariant,

        -- * Chunk allocation sizes
        defaultChunkSize,
        smallChunkSize,
        chunkOverhead,

        -- * Conversion with lists: packing and unpacking
        packBytes, packChars,
        unpackBytes, unpackChars,

  ) where

import Prelude hiding (concat)

import qualified Data.Vector.Storable as VS

import qualified Data.Vector.Storable.ByteString.Internal as S
import qualified Data.Vector.Storable.ByteString          as S (length, take, drop)

import Data.Word        (Word8)
import Foreign.Storable (Storable(sizeOf))

import Data.Monoid      (Monoid(..))
import Control.DeepSeq  (NFData, rnf)
import Data.String      (IsString(..))

import Data.Typeable    (Typeable)
import Data.Data        (Data)

-- | A space-efficient representation of a Word8 vector, supporting many
-- efficient operations.  A 'ByteString' contains 8-bit characters only.
--
-- Instances of Eq, Ord, Read, Show, Data, Typeable
--
data ByteString = Empty | Chunk {-# UNPACK #-} !S.ByteString ByteString
    deriving (Data, Typeable)

instance Eq  ByteString
    where (==)    = eq

instance Ord ByteString
    where compare = cmp

instance Monoid ByteString where
    mempty  = Empty
    mappend = append
    mconcat = concat

instance NFData ByteString where
    rnf Empty = ()
    rnf (Chunk _ cs) = rnf cs

instance Show ByteString where
    showsPrec p ps r = showsPrec p (unpackChars ps) r

instance Read ByteString where
    readsPrec p str = [ (packChars x, y) | (x, y) <- readsPrec p str ]

instance IsString ByteString where
    fromString = packChars

------------------------------------------------------------------------
-- Packing and unpacking from lists

packBytes :: [Word8] -> ByteString
packBytes cs0 =
    packChunks 32 cs0
  where
    packChunks n cs = case S.packUptoLenBytes n cs of
      (bs, [])  -> chunk bs Empty
      (bs, cs') -> Chunk bs (packChunks (min (n * 2) smallChunkSize) cs')

packChars :: [Char] -> ByteString
packChars cs0 =
    packChunks 32 cs0
  where
    packChunks n cs = case S.packUptoLenChars n cs of
      (bs, [])  -> chunk bs Empty
      (bs, cs') -> Chunk bs (packChunks (min (n * 2) smallChunkSize) cs')

unpackBytes :: ByteString -> [Word8]
unpackBytes Empty        = []
unpackBytes (Chunk c cs) = S.unpackAppendBytesLazy c (unpackBytes cs)

unpackChars :: ByteString -> [Char]
unpackChars Empty        = []
unpackChars (Chunk c cs) = S.unpackAppendCharsLazy c (unpackChars cs)

------------------------------------------------------------------------

-- | The data type invariant:
-- Every ByteString is either 'Empty' or consists of non-null 'S.ByteString's.
-- All functions must preserve this, and the QC properties must check this.
--
invariant :: ByteString -> Bool
invariant Empty        = True
invariant (Chunk v cs) = VS.length v > 0 && invariant cs

-- | In a form that checks the invariant lazily.
checkInvariant :: ByteString -> ByteString
checkInvariant Empty = Empty
checkInvariant (Chunk c cs)
    | VS.length c > 0 = Chunk c (checkInvariant cs)
    | otherwise = error $ "Data.Vector.Storable.ByteString.Lazy: " ++
                          "invariant violation:" ++ show (Chunk c cs)

------------------------------------------------------------------------

-- | Smart constructor for 'Chunk'. Guarantees the data type invariant.
chunk :: S.ByteString -> ByteString -> ByteString
chunk c cs | VS.length c == 0  = cs
           | otherwise = Chunk c cs
{-# INLINE chunk #-}

-- | Consume the chunks of a lazy ByteString with a natural right fold.
foldrChunks :: (S.ByteString -> a -> a) -> a -> ByteString -> a
foldrChunks f z = go
  where go Empty        = z
        go (Chunk c cs) = f c (go cs)
{-# INLINE foldrChunks #-}

-- | Consume the chunks of a lazy ByteString with a strict, tail-recursive,
-- accumulating left fold.
foldlChunks :: (a -> S.ByteString -> a) -> a -> ByteString -> a
foldlChunks f z = go z
  where go a _ | a `seq` False = undefined
        go a Empty        = a
        go a (Chunk c cs) = go (f a c) cs
{-# INLINE foldlChunks #-}

------------------------------------------------------------------------

-- The representation uses lists of packed chunks. When we have to convert from
-- a lazy list to the chunked representation, then by default we use this
-- chunk size. Some functions give you more control over the chunk size.
--
-- Measurements here:
--  http://www.cse.unsw.edu.au/~dons/tmp/chunksize_v_cache.png
--
-- indicate that a value around 0.5 to 1 x your L2 cache is best.
-- The following value assumes people have something greater than 128k,
-- and need to share the cache with other programs.

-- | Currently set to 32k, less the memory management overhead
defaultChunkSize :: Int
defaultChunkSize = 32 * k - chunkOverhead
   where k = 1024

-- | Currently set to 4k, less the memory management overhead
smallChunkSize :: Int
smallChunkSize = 4 * k - chunkOverhead
   where k = 1024

-- | The memory management overhead. Currently this is tuned for GHC only.
chunkOverhead :: Int
chunkOverhead = 2 * sizeOf (undefined :: Int)

------------------------------------------------------------------------
-- Implementations for Eq, Ord and Monoid instances

eq :: ByteString -> ByteString -> Bool
eq Empty Empty = True
eq Empty _     = False
eq _     Empty = False
eq (Chunk a as) (Chunk b bs) =
  case compare (S.length a) (S.length b) of
    LT -> a == (S.take (S.length a) b) && eq as (Chunk (S.drop (S.length a) b) bs)
    EQ -> a == b                       && eq as bs
    GT -> (S.take (S.length b) a) == b && eq (Chunk (S.drop (S.length b) a) as) bs

cmp :: ByteString -> ByteString -> Ordering
cmp Empty Empty = EQ
cmp Empty _     = LT
cmp _     Empty = GT
cmp (Chunk a as) (Chunk b bs) =
  case compare (S.length a) (S.length b) of
    LT -> case compare a (S.take (S.length a) b) of
            EQ     -> cmp as (Chunk (S.drop (S.length a) b) bs)
            result -> result
    EQ -> case compare a b of
            EQ     -> cmp as bs
            result -> result
    GT -> case compare (S.take (S.length b) a) b of
            EQ     -> cmp (Chunk (S.drop (S.length b) a) as) bs
            result -> result

append :: ByteString -> ByteString -> ByteString
append xs ys = foldrChunks Chunk ys xs

concat :: [ByteString] -> ByteString
concat css0 = to css0
  where
    go Empty        css = to css
    go (Chunk c cs) css = Chunk c (go cs css)
    to []               = Empty
    to (cs:css)         = go cs css

{-# LANGUAGE DeriveGeneric #-}
module Compression.Huffman
(
  huffmanAlg
) where

import Control.Monad
import qualified Data.ByteString.Lazy as L
import Data.Bits(setBit, testBit)
import Data.Int(Int64)
import qualified Data.Binary as Binary
import Data.Binary.Get
import Data.Array
import Data.Array.MArray
import Data.Array.IO
import Data.List
import Compression.Base
import LazyByteStringPatterns
import Data.ByteString.Builder
import GHC.Generics

huffmanAlg :: CompressionAlgorithm
huffmanAlg = CompAlg {
  caCompress = compressHuffman,
  caExtract  = extractHuffman
}

data HuffTree = Leaf !Int !Byte
              | Branch !Int HuffTree HuffTree
              deriving (Show, Generic)

instance Binary.Binary HuffTree

data Bit = Zero | One deriving (Show)
type Bits = [Bit]


getCount :: HuffTree -> Int
getCount (Leaf c _)     = c
getCount (Branch c _ _) = c

-- Mutable array used for optimization purpose
-- making a time complicity O(n) with small const
-- DiffArray is too slow for whis task

countBytes   :: Stream -> IO [(Byte, Int)]
countBytes s = do
    arr <- counts
    forM_ (L.unpack s) (\ b -> succ <$> readArray arr b >>= writeArray arr b)
    getAssocs arr
    where counts = newArray (0, 255) 0 :: IO (IOUArray Byte Int)

-- obtains a pair of smallest node and the rest, that
-- are greater
getHuffTree        :: [HuffTree] -> Maybe (HuffTree, [HuffTree])
getHuffTree (t:ts) = pure $ work t [] ts
    where work x xs []                  = (x, xs)
          work x xs (y:ys)
              | getCount y < getCount x = work y (x:xs) ys
              | otherwise               = work x (y:xs) ys
getHuffTree [] = Nothing

type CodeBook = Array Byte Bits

createCodebook   :: HuffTree -> CodeBook
createCodebook t = array (0, 255) (work [] t)
    where work bs (Leaf _ x)       = [(x, bs)]
          work bs (Branch _ t0 t1) = work (bs ++ [Zero]) t0 ++ work (bs ++ [One]) t1

encodedBits      :: CodeBook -> Stream -> Bits
encodedBits cb s = concatMap (cb !) (L.unpack s)

-- convert bit stream to byte stream
bitsToStream    :: Bits -> Stream
bitsToStream [] = L.empty
bitsToStream stream = toLazyByteString $ work 0 stream 7
    where work          :: Byte -> Bits ->Int -> Builder
          work a [] _   = word8 a
          work a (b:bs) i
            | i == 0    = word8 (case b of One -> setBit a i; _ -> a) <> work 0 bs 7
            | Zero <- b = work a bs (i - 1)
            | otherwise = work (setBit a i) bs (i - 1)

-- compression with specified codebook
encode    :: CodeBook -> Stream -> Stream
encode cb = bitsToStream . encodedBits cb

-- convert byte stream to bit stream
streamToBits :: Stream -> Bits
streamToBits (x :> xs) = getBits x ++ streamToBits xs where
          getBits b = foldl' (\ a i -> (if testBit b i then One else Zero) : a) [] [0..7]
streamToBits _ = []

-- extraction with specified tree
decode :: HuffTree -> Stream -> Stream
decode t = toLazyByteString . bitDecode t . streamToBits
    where bitDecode :: HuffTree -> Bits -> Builder
          bitDecode (Branch _ t0 t1) (b:bs)
              | Zero <- b = bitDecode t0 bs
              | One  <- b = bitDecode t1 bs
          -- TODO: This should be an error signaling situation, but Builder is strict by chunk-size
          -- meanwhile explicit counter var reduces performance by 30%
          bitDecode Branch{}  [] = mempty--error "Corrupted archive"
          -- on one-Leaf degenerate tree this one leads to infinite loop
          bitDecode (Leaf _ b) bs = word8 b <> bitDecode t bs

combineBranches :: HuffTree -> HuffTree -> HuffTree
combineBranches b1 b2 = Branch (getCount b1 + getCount b2) b1 b2

-- create tree from statistics list (pairs of (byte, count))
buildHuffTree :: [(Byte, Int)] -> Maybe HuffTree
buildHuffTree stats = build [Leaf c b | (b, c) <- stats, c > 0]
    where
      build []  = Nothing
      build [t] = pure t -- it's final tree
      build ts  = do
        (t0, ts0) <- getHuffTree ts  -- first smallest and rest that greater
        (t1, ts1) <- getHuffTree ts0 -- second smallest and rest that greater
        build $ combineBranches t0 t1 : ts1

-- TODO: Two passes through input should be enough, but here it does it trice
compressHuffman           :: IO Stream -> IO Stream
compressHuffman makeInput = do
    len  <- L.length <$> makeInput
    mayHuffTree <- buildHuffTree <$> (countBytes  =<< makeInput)
    if not (null mayHuffTree) then do -- HACK !!!
      let Just t = mayHuffTree
      code <- encode (createCodebook t) <$> makeInput
      return $ Binary.encode (t, len) `L.append` code
    else return L.empty

deserialize :: Get (HuffTree, Int64, Stream)
deserialize = liftM3 (,,) Binary.get Binary.get getRemainingLazyByteString

extractHuffman   :: IO Stream -> IO Stream
extractHuffman inAction = do
  stream <- inAction
  if not (L.null stream) then do -- HACK !!!
    let (t, l, bs) = runGet deserialize stream
    return . L.take l . decode t $ bs
  else return L.empty

{-

Copyright (C) 2010 Scott R Parish <srp@srparish.net>

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-}

module Database.MongoDB.BSON
    (
     BsonValue(..),
     BsonDoc(..),
     toBsonDoc,
     BinarySubType(..)
    )
where
import Control.Monad
import Data.Binary
import Data.Binary.Get
import Data.Binary.IEEE754
import Data.Binary.Put
import Data.ByteString.Char8
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.UTF8 as L8
import Data.Int
import qualified Data.Map as Map
import qualified Data.List as List
import Data.Time.Clock.POSIX
import Database.MongoDB.Util

data BsonValue
    = BsonDouble Double
    | BsonString L8.ByteString
    | BsonObject BsonDoc
    | BsonArray [BsonValue]
    | BsonUndefined
    | BsonBinary BinarySubType L.ByteString
    | BsonObjectId L.ByteString
    | BsonBool !Bool
    | BsonDate POSIXTime
    | BsonNull
    | BsonRegex L8.ByteString String
    | BsonSymbol L8.ByteString
    | BsonInt32 Int32
    | BsonInt64 Int64
    | BsonMinKey
    | BsonMaxKey
    deriving (Show, Eq, Ord)

newtype BsonDoc = BsonDoc {
      fromBsonDoc :: Map.Map L8.ByteString BsonValue
    }
    deriving (Eq, Ord, Show)

toBsonDoc :: [(L8.ByteString, BsonValue)] -> BsonDoc
toBsonDoc = BsonDoc . Map.fromList

data DataType =
    Data_min_key        | -- -1
    Data_number         | -- 1
    Data_string         | -- 2
    Data_object	        | -- 3
    Data_array          | -- 4
    Data_binary         | -- 5
    Data_undefined      | -- 6
    Data_oid            | -- 7
    Data_boolean        | -- 8
    Data_date           | -- 9
    Data_null           | -- 10
    Data_regex          | -- 11
    Data_ref            | -- 12
    Data_code           | -- 13
    Data_symbol	        | -- 14
    Data_code_w_scope   | -- 15
    Data_int            | -- 16
    Data_timestamp      | -- 17
    Data_long           | -- 18
    Data_max_key          -- 127
    deriving (Show, Read, Enum, Eq, Ord)

toDataType :: Int -> DataType
toDataType (-1) = Data_min_key
toDataType 127 = Data_max_key
toDataType d = toEnum d

fromDataType :: DataType -> Int
fromDataType Data_min_key = (-1)
fromDataType Data_max_key = 127
fromDataType d = fromEnum d


data BinarySubType =
    BSTUNDEFINED_1     |
    BSTFunction        | -- 1
    BSTByteArray       | -- 2
    BSTUUID            | -- 3
    BSTUNDEFINED_2     |
    BSTMD5             | -- 5
    BSTUserDefined
    deriving (Show, Read, Enum, Eq, Ord)

toBinarySubType :: Int -> BinarySubType
toBinarySubType 0x80 = BSTUserDefined
toBinarySubType d = toEnum d

fromBinarySubType :: BinarySubType -> Int
fromBinarySubType BSTUserDefined = 0x80
fromBinarySubType d = fromEnum d

instance Binary BsonDoc where
    get = liftM snd getDoc
    put = putObj

getVal :: DataType -> Get (Integer, BsonValue)
getVal Data_number = getFloat64le >>= return . (,) 8 . BsonDouble
getVal Data_string = do
  sLen1 <- getI32
  (_sLen2, s) <- getS
  return (fromIntegral $ 4 + sLen1, BsonString s)
getVal Data_object = getDoc >>= \(len, obj) -> return (len, BsonObject obj)
getVal Data_array = do
  (len, arr) <- getRawObj
  let arr2 = Map.fold (:) [] arr -- reverse and remove key
  return (len, BsonArray arr2)
getVal Data_binary = do
  skip 4
  st   <- getI8
  len2 <- getI32
  bs   <- getLazyByteString $ fromIntegral len2
  return (4 + 1 + 4 + fromIntegral len2, BsonBinary (toBinarySubType st) bs)
getVal Data_undefined = return (1, BsonUndefined)
getVal Data_oid = getLazyByteString 12 >>= return . (,) 12 . BsonObjectId
getVal Data_boolean =
    getI8 >>= return . (,) (1::Integer) . BsonBool . (/= (0::Int))
getVal Data_date =
    getI64 >>= return . (,) 8 . BsonDate . flip (/) 1000 . realToFrac
getVal Data_null = return (1, BsonNull)
getVal Data_regex = fail "Data_code not yet supported" -- TODO
getVal Data_ref = fail "Data_ref is deprecated"
getVal Data_code = fail "Data_code not yet supported" -- TODO
getVal Data_symbol = do
  sLen1 <- getI32
  (_sLen2, s) <- getS
  return (fromIntegral $ 4 + sLen1, BsonString s)
getVal Data_code_w_scope = fail "Data_code_w_scope not yet supported" -- TODO
getVal Data_int = getI32 >>= return . (,) 4 . BsonInt32 . fromIntegral
getVal Data_timestamp = fail "Data_timestamp not yet supported" -- TODO

getVal Data_long = getI64 >>= return . (,) 8 . BsonInt64
getVal Data_min_key = return (0, BsonMinKey)
getVal Data_max_key = return (0, BsonMaxKey)

getInnerObj :: Int32 -> Get (Map.Map L8.ByteString BsonValue)
            -> Get (Map.Map L8.ByteString BsonValue)
getInnerObj 1 obj = obj
getInnerObj bytesLeft obj = do
  typ <- getDataType
  (keySz, key) <- getS
  (valSz, val) <- getVal typ
  getInnerObj (bytesLeft - 1 - fromIntegral keySz - fromIntegral valSz) $
              liftM (Map.insert key val) obj

getRawObj :: Get (Integer, Map.Map L8.ByteString BsonValue)
getRawObj = do
  bytes <- getI32
  obj <- getInnerObj (bytes - 4) $ return Map.empty
  getNull
  return (fromIntegral bytes, obj)

getDoc :: Get (Integer, BsonDoc)
getDoc = getRawObj >>= \(len, obj) ->  return (len, BsonDoc obj)

getDataType :: Get DataType
getDataType = liftM toDataType getI8

putType :: BsonValue -> Put
putType BsonDouble{}   = putDataType Data_number
putType BsonString{}   = putDataType Data_string
putType BsonObject{}   = putDataType Data_object
putType BsonArray{}    = putDataType Data_array
putType BsonBinary{}   = putDataType Data_binary
putType BsonUndefined  = putDataType Data_undefined
putType BsonObjectId{} = putDataType Data_oid
putType BsonBool{}     = putDataType Data_boolean
putType BsonDate{}     = putDataType Data_date
putType BsonNull       = putDataType Data_null
putType BsonRegex{}    = putDataType Data_regex
-- putType = putDataType Data_ref
-- putType = putDataType Data_code
putType BsonSymbol{}   = putDataType Data_symbol
-- putType = putDataType Data_code_w_scope
putType BsonInt32 {}   = putDataType Data_int
putType BsonInt64 {}   = putDataType Data_long
-- putType = putDataType Data_timestamp
putType BsonMinKey     = putDataType Data_min_key
putType BsonMaxKey     = putDataType Data_max_key

putVal :: BsonValue -> Put
putVal (BsonDouble d)   = putFloat64le d
putVal (BsonString s)   = putI32 (fromIntegral $ 1 + L8.length s) >> putS s
putVal (BsonObject o)   = putObj o
putVal (BsonArray es)   = putOutterObj bs
    where bs = runPut $ forM_ (List.zip [(0::Int) .. ] es) $ \(i, e) ->
               putType e >> (putS $ L8.fromString $ show i) >> putVal e
putVal (BsonBinary t bs)= do putI32 $ fromIntegral $ 4 + L.length bs
                             putI8 $ fromBinarySubType t
                             putI32 $ fromIntegral $ L.length bs
                             putLazyByteString bs
putVal BsonUndefined    = putNothing
putVal (BsonObjectId o) = putLazyByteString o
putVal (BsonBool False) = putI8 (0::Int)
putVal (BsonBool True)  = putI8 (1::Int)
putVal (BsonDate pt)    = putI64 $ round $ 1000 * (realToFrac pt :: Double)
putVal BsonNull         = putNothing
putVal (BsonRegex r opt)= do putS r
                             putByteString $ pack $ List.sort opt
                             putNull
putVal (BsonSymbol s)   = putI32 (fromIntegral $ 1 + L8.length s) >> putS s
putVal (BsonInt32 i)    = putI32 i
putVal (BsonInt64 i)    = putI64 i
putVal BsonMinKey       = putNothing
putVal BsonMaxKey       = putNothing

putObj :: BsonDoc -> Put
putObj obj   = putOutterObj bs
    where bs = runPut $ forM_ (Map.toList (fromBsonDoc obj)) $ \(k, v) ->
               putType v >> putS k >> putVal v

putOutterObj :: L.ByteString -> Put
putOutterObj bytes = do
  -- the length prefix and null term are included in the length
  putI32 $ fromIntegral $ 4 + 1 + L.length bytes
  putLazyByteString bytes
  putNull

putDataType :: DataType -> Put
putDataType = putI8 . fromDataType

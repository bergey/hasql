module Hasql.Private.Decoders.Row where

import Hasql.Private.Prelude
import Hasql.Private.Errors
import qualified Database.PostgreSQL.LibPQ as LibPQ
import qualified PostgreSQL.Binary.Decoding as A
import qualified Hasql.Private.Decoders.Value as Value


data Row a =
  Row ![ByteString] !(ReaderT Env (ExceptT RowError IO) a)
  deriving (Functor)

instance Applicative Row where
    pure = Row [] . pure
    Row ft f <*> Row bt b = Row (ft <> bt) (f b)

instance Monad Row where
    Row at a >>= f = let Row bt b = f a in Row (at <> bt) b

data Env =
  Env !LibPQ.Result !LibPQ.Row !LibPQ.Column !Bool !(IORef LibPQ.Column)


-- * Functions
-------------------------

{-# INLINE run #-}
run :: Row a -> (LibPQ.Result, LibPQ.Row, LibPQ.Column, Bool) -> IO (Either RowError a)
run (Row impl) (result, row, columnsAmount, integerDatetimes) =
  do
    columnRef <- newIORef 0
    runExceptT (runReaderT impl (Env result row columnsAmount integerDatetimes columnRef))

{-# INLINE error #-}
error :: RowError -> Row a
error x =
  Row (ReaderT (const (ExceptT (pure (Left x)))))

-- |
-- Next value, decoded using the provided value decoder.
{-# INLINE value #-}
value :: Value.Value a -> Row (Maybe a)
value valueDec =
  {-# SCC "value" #-}
  Row $ ReaderT $ \(Env result row columnsAmount integerDatetimes columnRef) -> ExceptT $ do
    col <- readIORef columnRef
    writeIORef columnRef (succ col)
    if col < columnsAmount
      then do
        valueMaybe <- {-# SCC "getvalue'" #-} LibPQ.getvalue' result row col
        pure $
          case valueMaybe of
            Nothing ->
              Right Nothing
            Just value ->
              fmap Just $ mapLeft ValueError $
              {-# SCC "decode" #-} A.valueParser (Value.run valueDec integerDatetimes) value
      else pure (Left EndOfInput)

-- |
-- Next value, decoded using the provided value decoder.
{-# INLINE nonNullValue #-}
nonNullValue :: Value.Value a -> Row a
nonNullValue valueDec =
  {-# SCC "nonNullValue" #-}
  value valueDec >>= maybe (error UnexpectedNull) pure

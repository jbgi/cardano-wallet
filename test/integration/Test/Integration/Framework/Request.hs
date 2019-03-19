{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Test.Integration.Framework.Request
    ( unsafeRequest
    , ($-)
    , RequestException(..)
    ) where

import Prelude

import Control.Exception
    ( try )
import Control.Lens
    ( Lens', view )
import Control.Monad.Catch
    ( Exception (..) )
import Control.Monad.IO.Class
    ( MonadIO, liftIO )
import Control.Monad.Trans.Reader
    ( ReaderT (..) )
import Data.Aeson
    ( FromJSON )
import Data.Bifunctor
    ( first )
import Data.ByteString.Lazy
    ( ByteString )
import Data.Functor
    ( ($>) )
import Data.Generics.Product.Typed
    ( HasType, typed )
import Data.Text
    ( Text )
import Network.HTTP.Client
    ( HttpException (..)
    , HttpExceptionContent (..)
    , Manager
    , RequestBody (..)
    , httpLbs
    , method
    , parseRequest
    , requestBody
    , requestHeaders
    , responseBody
    , responseStatus
    )
import Network.HTTP.Types.Method
    ( Method )
import Network.HTTP.Types.Status
    ( status200, status300, status404 )

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Text as T
import qualified Network.HTTP.Client as HTTP


class (HasType (Text, Manager) ctx) => HasManager ctx where
    manager :: Lens' ctx (Text, Manager)
    manager = typed @(Text, Manager)
instance (HasType (Text, Manager) ctx) => HasManager ctx

data RequestException
    = HttpException HttpException
    | DecodeFailure ByteString
    | ClientError Aeson.Value
    deriving (Show)

instance Exception RequestException

unsafeRequest
    :: forall a m ctx.
        ( FromJSON a
        , MonadIO m
        , HasManager ctx
        )
    => (Method, Text)
    -> Maybe Aeson.Value
    -> ReaderT ctx m (Either RequestException a)
unsafeRequest (verb, path) body = do
    (base, man) <- view manager
    http <- tryHttp $ do
        req <- parseRequest $ T.unpack $ base <> path
        res <- httpLbs (prepare req) man
        pure (req, res)
    return (handleResponse =<< http)

  where
    prepare :: HTTP.Request -> HTTP.Request
    prepare req = req
        { method = verb
        , requestBody = maybe mempty (RequestBodyLBS . Aeson.encode) body
        , requestHeaders =
            [ ("Content-Type", "application/json")
            , ("Accept", "application/json")
            ]
        }

    -- Catch HttpExceptions and turn them into
    -- Either RequestExceptions.
    tryHttp :: IO r -> ReaderT ctx m (Either RequestException r)
    tryHttp = liftIO . fmap (first HttpException) . try

    -- Either decode response body, or provide a RequestException.
    handleResponse (req, res) = case responseStatus res of
        s
            | s >= status200 && s <= status300 ->
                maybe
                    (Left $ decodeFailure res)
                    Right
                    (Aeson.decode $ responseBody res)
            | s == status404 ->
                Left
                    $ HttpException
                    $ HttpExceptionRequest req
                    $ StatusCodeException (res $> ())
                    $ L8.toStrict $ responseBody res

        _ -> Left $ decodeFailure res
             -- TODO: decode API error responses into ClientError

    decodeFailure :: HTTP.Response ByteString -> RequestException
    decodeFailure res = DecodeFailure $ responseBody res


-- | Provide "next" arguments to a function, leaving the first one untouched.
--
-- e.g.
--    myFunction  :: Ctx -> Int -> String -> Result
--    myFunction' :: Ctx -> Result
--    myFunction' = myFunction $- 14 $- "patate"
infixl 1 $-
($-) :: (a -> b -> c) -> b -> a -> c
($-) = flip

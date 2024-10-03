{-# LANGUAGE OverloadedStrings, CPP #-}

module Network.Wai.Logger.Apache (
    IPAddrSource(..)
  , apacheLogStr
  , serverpushLogStr
  ) where

#ifndef MIN_VERSION_base
#define MIN_VERSION_base(x,y,z) 1
#endif
#ifndef MIN_VERSION_wai
#define MIN_VERSION_wai(x,y,z) 1
#endif

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.List (find)
import Data.Maybe (fromMaybe)
#if MIN_VERSION_base(4,5,0)
import Data.Monoid ((<>))
#else
import Data.Monoid (mappend)
#endif
import Network.HTTP.Types (Status, statusCode)
import Network.HTTP.Types.Header (HeaderName)
import Network.Wai (Request(..))
import Network.Wai.Logger.IP
import System.Log.FastLogger

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Network.Wai (defaultRequest)

-- | Source from which the IP source address of the client is obtained.
data IPAddrSource =
  -- | From the peer address of the HTTP connection.
    FromSocket
  -- | From X-Real-IP: or X-Forwarded-For: in the HTTP header.
  | FromHeader
  -- | From a custom HTTP header, useful in proxied environment.
  | FromHeaderCustom [HeaderName]
  -- | From the peer address if header is not found.
  | FromFallback

-- | Apache style log format.
apacheLogStr :: ToLogStr user => IPAddrSource -> (Request -> Maybe user) -> FormattedTime -> Request -> Status -> Maybe Integer -> LogStr
apacheLogStr ipsrc userget tmstr req status msize =
      toLogStr (getSourceIP ipsrc req)
  <> " - "
  <> maybe "-" toLogStr (userget req)
  <> " ["
  <> toLogStr tmstr
  <> "] \""
  <> toLogStr (requestMethod req)
  <> " "
  <> toLogStr path
  <> " "
  <> toLogStr (show (httpVersion req))
  <> "\" "
  <> toLogStr (show (statusCode status))
  <> " "
  <> toLogStr (maybe "-" show msize)
  <> " \""
  <> toLogStr (fromMaybe "" mr)
  <> "\" \""
  <> toLogStr (fromMaybe "" mua)
  <> "\"\n"
  where
    path = rawPathInfo req <> rawQueryString req
#if !MIN_VERSION_base(4,5,0)
    (<>) = mappend
#endif
#if MIN_VERSION_wai(3,2,0)
    mr  = requestHeaderReferer req
    mua = requestHeaderUserAgent req
#else
    mr  = lookup "referer" $ requestHeaders req
    mua = lookup "user-agent" $ requestHeaders req
#endif

-- | HTTP/2 Push log format in the Apache style.
serverpushLogStr :: ToLogStr user => IPAddrSource -> (Request -> Maybe user) -> FormattedTime -> Request -> ByteString -> Integer -> LogStr
serverpushLogStr ipsrc userget tmstr req path size =
      toLogStr (getSourceIP ipsrc req)
  <> " - "
  <> maybe "-" toLogStr (userget req)
  <> " ["
  <> toLogStr tmstr
  <> "] \"PUSH "
  <> toLogStr path
  <> " HTTP/2\" 200 "
  <> toLogStr (show size)
  <> " \""
  <> toLogStr ref
  <> "\" \""
  <> toLogStr (fromMaybe "" mua)
  <> "\"\n"
  where
    ref  = rawPathInfo req
#if !MIN_VERSION_base(4,5,0)
    (<>) = mappend
#endif
#if MIN_VERSION_wai(3,2,0)
    mua = requestHeaderUserAgent req
#else
    mua = lookup "user-agent" $ requestHeaders req
#endif

-- getSourceIP = getSourceIP fromString fromByteString

getSourceIP :: IPAddrSource -> Request -> ByteString
getSourceIP FromSocket = getSourceFromSocket
getSourceIP FromHeader = getSourceFromHeader
getSourceIP FromFallback = getSourceFromFallback
getSourceIP (FromHeaderCustom hs) = fromMaybe "-" . getSourceFromHeaderCustom hs

-- |
-- >>> getSourceFromSocket defaultRequest
-- "0.0.0.0"
getSourceFromSocket :: Request -> ByteString
getSourceFromSocket = BS.pack . showSockAddr . remoteHost

-- |
-- >>> getSourceFromHeader defaultRequest { requestHeaders = [ ("X-Real-IP", "127.0.0.1") ] }
-- "127.0.0.1"
-- >>> getSourceFromHeader defaultRequest { requestHeaders = [ ("X-Forwarded-For", "127.0.0.1") ] }
-- "127.0.0.1"
-- >>> getSourceFromHeader defaultRequest { requestHeaders = [ ("Something", "127.0.0.1") ] }
-- "-"
-- >>> getSourceFromHeader defaultRequest { requestHeaders = [] }
-- "-"
--
-- 'getSourceFromHeader' uses the first instance of either @"X-Real-IP"@ or
-- @"X-Forwarded-For"@ that it finds in the header list:
--
-- >>> getSourceFromHeader defaultRequest { requestHeaders = [ ("X-Real-IP", "1.2.3.4"), ("X-Forwarded-For", "5.6.7.8") ] }
-- "1.2.3.4"
-- >>> getSourceFromHeader defaultRequest { requestHeaders = [ ("X-Forwarded-For", "5.6.7.8"), ("X-Real-IP", "1.2.3.4") ] }
-- "5.6.7.8"
getSourceFromHeader :: Request -> ByteString
getSourceFromHeader = fromMaybe "-" . getSource

-- |
-- >>> getSourceFromFallback defaultRequest { requestHeaders = [ ("X-Real-IP", "127.0.0.1") ] }
-- "127.0.0.1"
-- >>> getSourceFromFallback defaultRequest { requestHeaders = [ ("X-Forwarded-For", "127.0.0.1") ] }
-- "127.0.0.1"
-- >>> getSourceFromFallback defaultRequest { requestHeaders = [ ("Something", "127.0.0.1") ] }
-- "0.0.0.0"
-- >>> getSourceFromFallback defaultRequest { requestHeaders = [] }
-- "0.0.0.0"
--
-- 'getSourceFromFallback' uses the first instance of either @"X-Real-IP"@ or
-- @"X-Forwarded-For"@ that it finds in the header list:
--
-- >>> getSourceFromFallback defaultRequest { requestHeaders = [ ("X-Real-IP", "1.2.3.4"), ("X-Forwarded-For", "5.6.7.8") ] }
-- "1.2.3.4"
-- >>> getSourceFromFallback defaultRequest { requestHeaders = [ ("X-Forwarded-For", "5.6.7.8"), ("X-Real-IP", "1.2.3.4") ] }
-- "5.6.7.8"
getSourceFromFallback :: Request -> ByteString
getSourceFromFallback req = fromMaybe (getSourceFromSocket req) $ getSource req

-- |
-- >>> getSource defaultRequest { requestHeaders = [ ("X-Real-IP", "127.0.0.1") ] }
-- Just "127.0.0.1"
-- >>> getSource defaultRequest { requestHeaders = [ ("X-Forwarded-For", "127.0.0.1") ] }
-- Just "127.0.0.1"
-- >>> getSource defaultRequest { requestHeaders = [ ("Something", "127.0.0.1") ] }
-- Nothing
-- >>> getSource defaultRequest
-- Nothing
--
-- 'getSource' uses the first instance of either @"X-Real-IP"@ or
-- @"X-Forwarded-For"@ that it finds in the header list:
--
-- >>> getSource defaultRequest { requestHeaders = [ ("X-Real-IP", "1.2.3.4"), ("X-Forwarded-For", "5.6.7.8") ] }
-- Just "1.2.3.4"
-- >>> getSource defaultRequest { requestHeaders = [ ("X-Forwarded-For", "5.6.7.8"), ("X-Real-IP", "1.2.3.4") ] }
-- Just "5.6.7.8"
getSource :: Request -> Maybe ByteString
getSource = getSourceFromHeaders ["x-real-ip", "x-forwarded-for"]

getSourceFromHeaders :: [HeaderName] -> Request -> Maybe ByteString
getSourceFromHeaders headerNames req = addr
  where
    maddr = find (\(name,_) -> name `elem` headerNames) hdrs
    addr = fmap snd maddr
    hdrs = requestHeaders req

getSourceFromHeaderCustom :: [HeaderName] -> Request -> Maybe ByteString
getSourceFromHeaderCustom hs = getSourceFromHeaders hs

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
module Yesod.Internal.Request
    ( parseWaiRequest
    , Request (..)
    , RequestBodyContents
    , FileInfo
    , fileName
    , fileContentType
    , fileSource
    , fileMove
    , mkFileInfoLBS
    , mkFileInfoFile
    , mkFileInfoSource
    , FileUpload (..)
    -- The below are exported for testing.
    , randomString
    , parseWaiRequest'
    ) where

import Control.Applicative ((<$>))
import Control.Arrow (second)
import qualified Network.Wai.Parse as NWP
import Yesod.Internal
import qualified Network.Wai as W
import System.Random (RandomGen, newStdGen, randomRs)
import Web.Cookie (parseCookiesText)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S8
import Data.Text (Text, pack)
import Network.HTTP.Types (queryToQueryText)
import Control.Monad (join)
import Data.Maybe (fromMaybe, catMaybes)
import qualified Data.ByteString.Lazy as L
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Conduit
import Data.Conduit.List (sourceList)
import Data.Conduit.Binary (sourceFile, sinkFile)
import Data.Word (Word64)

-- | The parsed request information.
data Request = Request
    { reqGetParams :: [(Text, Text)]
    , reqCookies :: [(Text, Text)]
    , reqWaiRequest :: W.Request
      -- | Languages which the client supports.
    , reqLangs :: [Text]
      -- | A random, session-specific token used to prevent CSRF attacks.
    , reqToken :: Maybe Text
      -- | Size of the request body.
    , reqBodySize :: Word64
    }

parseWaiRequest :: W.Request
                -> [(Text, ByteString)] -- ^ session
                -> Bool
                -> Word64
                -> IO Request
parseWaiRequest env session' useToken bodySize =
    parseWaiRequest' env session' useToken bodySize <$> newStdGen

parseWaiRequest' :: RandomGen g
                 => W.Request
                 -> [(Text, ByteString)] -- ^ session
                 -> Bool
                 -> Word64
                 -> g
                 -> Request
parseWaiRequest' env session' useToken bodySize gen =
    Request gets'' cookies' env langs'' token bodySize
  where
    gets' = queryToQueryText $ W.queryString env
    gets'' = map (second $ fromMaybe "") gets'
    reqCookie = lookup "Cookie" $ W.requestHeaders env
    cookies' = maybe [] parseCookiesText reqCookie
    acceptLang = lookup "Accept-Language" $ W.requestHeaders env
    langs = map (pack . S8.unpack) $ maybe [] NWP.parseHttpAccept acceptLang

    lookupText k = fmap (decodeUtf8With lenientDecode) . lookup k

    -- The language preferences are prioritized as follows:
    langs' = catMaybes [ join $ lookup langKey gets' -- Query _LANG
                       , lookup langKey cookies'     -- Cookie _LANG
                       , lookupText langKey session' -- Session _LANG
                       ] ++ langs                    -- Accept-Language(s)

    -- Github issue #195. We want to add an extra two-letter version of any
    -- language in the list.
    langs'' = addTwoLetters (id, Set.empty) langs'

    -- If sessions are disabled tokens should not be used (any
    -- tokenKey present in the session is ignored). If sessions
    -- are enabled and a session has no tokenKey a new one is
    -- generated.
    token = if not useToken
              then Nothing
              else Just $ maybe
                            (pack $ randomString 10 gen)
                            (decodeUtf8With lenientDecode)
                            (lookup tokenKey session')

addTwoLetters :: ([Text] -> [Text], Set.Set Text) -> [Text] -> [Text]
addTwoLetters (toAdd, exist) [] =
    filter (flip Set.notMember exist) $ toAdd []
addTwoLetters (toAdd, exist) (l:ls) =
    l : addTwoLetters (toAdd', exist') ls
  where
    (toAdd', exist')
        | T.length l > 2 = (toAdd . (T.take 2 l:), exist)
        | otherwise = (toAdd, Set.insert l exist)

-- | Generate a random String of alphanumerical characters
-- (a-z, A-Z, and 0-9) of the given length using the given
-- random number generator.
randomString :: RandomGen g => Int -> g -> String
randomString len = take len . map toChar . randomRs (0, 61)
  where
    toChar i
        | i < 26 = toEnum $ i + fromEnum 'A'
        | i < 52 = toEnum $ i + fromEnum 'a' - 26
        | otherwise = toEnum $ i + fromEnum '0' - 52

-- | A tuple containing both the POST parameters and submitted files.
type RequestBodyContents =
    ( [(Text, Text)]
    , [(Text, FileInfo)]
    )

data FileInfo = FileInfo
    { fileName :: Text
    , fileContentType :: Text
    , fileSource :: Source (ResourceT IO) ByteString
    , fileMove :: FilePath -> IO ()
    }

mkFileInfoLBS :: Text -> Text -> L.ByteString -> FileInfo
mkFileInfoLBS name ct lbs = FileInfo name ct (sourceList $ L.toChunks lbs) (\fp -> L.writeFile fp lbs)

mkFileInfoFile :: Text -> Text -> FilePath -> FileInfo
mkFileInfoFile name ct fp = FileInfo name ct (sourceFile fp) (\dst -> runResourceT $ sourceFile fp $$ sinkFile dst)

mkFileInfoSource :: Text -> Text -> Source (ResourceT IO) ByteString -> FileInfo
mkFileInfoSource name ct src = FileInfo name ct src (\dst -> runResourceT $ src $$ sinkFile dst)

data FileUpload = FileUploadMemory (NWP.BackEnd L.ByteString)
                | FileUploadDisk (NWP.BackEnd FilePath)
                | FileUploadSource (NWP.BackEnd (Source (ResourceT IO) ByteString))

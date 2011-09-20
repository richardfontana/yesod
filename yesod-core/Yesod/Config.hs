{-# OPTIONS -fno-warn-missing-signatures #-}
{-# LANGUAGE QuasiQuotes                 #-}
module Yesod.Config
    ( AppConfig(..)
    , loadConfig
    , loadPostgresqlConnStr
    , loadSqliteConnStr
    , loadMongoConnParams
    ) where

import Control.Monad (join)
import Data.Object
import Data.Text (Text)
import Text.Shakespeare.Text (st)

import qualified Data.Object.Yaml as YAML
import qualified Data.Text        as T

-- | Dynamic per-environment configuration which can be loaded at
--   run-time negating the need to recompile between environments.
data AppConfig e = AppConfig
    { appEnv  :: e
    , appPort :: Int

    -- TODO: put this in db configs
    , connectionPoolSize :: Int

    -- | The base URL for your application. This will usually be
    --   different for development and production. Yesod automatically
    --   constructs URLs for you, so this value must be accurate to
    --   create valid links.
    --
    --   If your domain name was "yesod.com", you would probably want it
    --   to be:
    --
    --   > "http://yesod.com"
    --
    , appRoot :: Text
    } deriving (Show)


-- | Load an @'AppConfig'@ from a YAML-formatted file located at
--   @config\/settings.yml@.
loadConfig :: Show e => e -> IO (AppConfig e)
loadConfig env = do
    allSettings         <- (join $ YAML.decodeFile ("config/settings.yml" :: String)) >>= fromMapping
    settings            <- lookupMapping (show env) allSettings
    approot             <- lookupScalar "approot" settings
    portS               <- lookupScalar "port" settings
    port                <- readInt "port" portS
    connectionPoolSizeS <- lookupScalar "connectionPoolSize" settings
    connectionPoolSize' <- readInt "connection pool size" connectionPoolSizeS

    return $ AppConfig
        { appEnv  = env
        , appPort = port
        , appRoot = T.pack approot
        , connectionPoolSize = connectionPoolSize'
        }

    where
        readInt desc s =
            case reads s of
                (i, _):_ -> return i
                [] -> error $ concat ["Invalid ", desc, ": ", s]

-- | Load Postgresql settings from a YAML-formatted file located at
--   @config\/postgresql.yml@.
loadPostgresqlConnStr :: Show e => e -> IO Text
loadPostgresqlConnStr env = do
    allSettings <- (join $ YAML.decodeFile ("config/postgresql.yml" :: String)) >>= fromMapping
    settings    <- lookupMapping (show env) allSettings
    database    <- lookupScalar "database" settings :: IO Text

    connPart <- fmap T.concat $ (flip mapM) ["user", "password", "host", "port"] $ \key -> do
      value <- lookupScalar key settings
      return $ [st| #{key}=#{value} |]
    return $ [st|#{connPart} dbname=#{database}|]

-- | Load Sqlite settings from a YAML-formatted file located at
--   @config\/sqlite.yml@.
loadSqliteConnStr :: Show e => e -> IO Text
loadSqliteConnStr env = do
    allSettings <- (join $ YAML.decodeFile ("config/sqlite.yml" :: String)) >>= fromMapping
    settings    <- lookupMapping (show env) allSettings
    lookupScalar "database" settings

-- note: no type signature to avoid an extra Persistent.MongoDB dep for
-- those that don't need it
--loadMongoConnParams :: AppEnvironment -> IO (Database, HostName)
loadMongoConnParams env = do
    allSettings <- (join $ YAML.decodeFile ("config/mongoDB.yml" :: String)) >>= fromMapping
    settings    <- lookupMapping (show env) allSettings
    database    <- lookupScalar "database" settings
    host        <- lookupScalar "host" settings
    return (database, host)

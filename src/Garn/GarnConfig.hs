{-# LANGUAGE QuasiQuotes #-}

module Garn.GarnConfig where

import Control.Exception (IOException, catch)
import Control.Monad
import Data.Aeson (FromJSON, eitherDecode)
import Data.Map (Map)
import Data.String.Interpolate (i)
import Data.String.Interpolate.Util
import Development.Shake (CmdOption (EchoStderr, EchoStdout), Stdout (Stdout), cmd, cmd_)
import GHC.Generics (Generic)
import Garn.Common (nixArgs, nixpkgsInput)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hClose, hPutStr, stderr)
import System.IO.Temp (withSystemTempFile)

-- This needs to be in sync with `GarnConfig` in runner.ts
data GarnConfig = GarnConfig
  { targets :: Targets,
    flakeFile :: String
  }
  deriving (Eq, Show, Generic, FromJSON)

type Targets = Map String TargetConfig

data TargetConfig = TargetConfig
  { description :: String,
    packages :: [String],
    checks :: [String]
  }
  deriving (Generic, FromJSON, Eq, Show)

readGarnConfig :: IO GarnConfig
readGarnConfig = do
  checkGarnFileExists
  dir <- getCurrentDirectory
  withSystemTempFile "garn-main.js" $ \mainPath mainHandle -> do
    hPutStr
      mainHandle
      [i|
        import * as garnExports from "#{dir}/garn.ts"

        if (window.__garnGetInternalLib == null) {
          console.log("null");
        } else {
          const internalLib = window.__garnGetInternalLib();
          const { toGarnConfig } = internalLib;
          console.log(JSON.stringify(toGarnConfig("#{nixpkgsInput}", garnExports)));
        }
      |]
    hClose mainHandle
    Stdout out <- cmd "deno run --quiet --check --allow-write --allow-run --allow-read" mainPath
    case eitherDecode out :: Either String (Maybe GarnConfig) of
      Left err -> error $ "Unexpected package export from garn.ts:\n" <> err
      Right Nothing -> error $ "No garn library imported in garn.ts"
      Right (Just writtenConfig) -> return writtenConfig

writeGarnConfig :: GarnConfig -> IO ()
writeGarnConfig garnConfig = do
  writeFile "flake.nix" $ flakeFile garnConfig
  cmd_ [EchoStderr False, EchoStdout False] "nix" nixArgs "run" (nixpkgsInput <> "#nixpkgs-fmt") "./flake.nix"
  void (cmd [EchoStderr False, EchoStdout False] "git add --intent-to-add flake.nix" :: IO ExitCode) `catch` \(_ :: IOException) -> pure ()

checkGarnFileExists :: IO ()
checkGarnFileExists = do
  exists <- doesFileExist "garn.ts"
  when (not exists) $ do
    hPutStr stderr $
      unindent
        [i|
          No `garn.ts` file found in the current directory.

          Here's an example `garn.ts` file for npm frontends:

            import * as garn from "http://localhost:8777/mod.ts";

            export const frontend = garn.typescript.mkNpmProject({
              src: "./.",
              description: "An NPM frontend",
            });

        |]
    exitWith $ ExitFailure 1

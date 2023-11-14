{-# LANGUAGE DuplicateRecordFields #-}

module Garn.Optparse
  ( getOpts,
    Options (..),
    OptionType (..),
    WithGarnTsCommand (..),
    WithoutGarnTsCommand (..),
    CommandOptions (..),
    CheckCommandOptions (..),
  )
where

import qualified Data.Map as Map
import Garn.Env (Env (..))
import Garn.GarnConfig
import Garn.Utils (garnCliVersion)
import Options.Applicative hiding (command)
import qualified Options.Applicative as OA
import qualified Options.Applicative.Help.Pretty as OA
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn)
import qualified Text.PrettyPrint.ANSI.Leijen as PP

getOpts :: Env -> OptionType -> IO Options
getOpts env oType = do
  args <- getArgs
  let result = execParserPure (prefs $ showHelpOnError <> showHelpOnEmpty) opts args
  case result of
    OA.Failure failure -> do
      programName <- getProgName
      let (msg, exit) = renderFailure failure programName
      case exit of
        ExitSuccess -> hPutStrLn (stdout env) msg
        ExitFailure _ -> hPutStrLn (stderr env) msg
      exitWith exit
    _ ->
      handleParseResult result
  where
    unavailable :: OA.Doc
    unavailable =
      let formatCommands cmdInfo = [PP.string cmd | (cmd, _, _) <- cmdInfo]
       in PP.nest
            2
            $ PP.vsep
              ( PP.string "Unavailable commands:"
                  : case oType of
                    WithGarnTs _ -> formatCommands withouGarnTsCommandInfo
                    WithoutGarnTs -> formatCommands withGarnTsCommandInfo
              )
    parser :: Parser Options
    parser = case oType of
      WithGarnTs garnConfig -> WithGarnTsOpts garnConfig <$> withGarnTsParser (targets garnConfig)
      WithoutGarnTs -> WithoutGarnTsOpts <$> withoutGarnTsParser
    version =
      infoOption garnCliVersion $
        mconcat [long "version", help ("Show garn version (" <> garnCliVersion <> ")")]
    opts =
      info
        (parser <**> helper <**> version)
        ( fullDesc
            <> progDesc "Develop, build, and test your projects reliably and easily"
            <> header "garn - the project manager"
            <> footerDoc (Just unavailable)
        )

data OptionType
  = WithGarnTs GarnConfig
  | WithoutGarnTs
  deriving stock (Eq, Show)

data Options
  = WithGarnTsOpts GarnConfig WithGarnTsCommand
  | WithoutGarnTsOpts WithoutGarnTsCommand

data WithoutGarnTsCommand
  = Init

data WithGarnTsCommand
  = Gen
  | Build CommandOptions
  | Run CommandOptions [String]
  | Enter CommandOptions
  | Check CheckCommandOptions
  deriving stock (Eq, Show)

withGarnTsCommandInfo :: [(String, String, Targets -> Parser WithGarnTsCommand)]
withGarnTsCommandInfo =
  [ ("build", "Build the default executable of a project", buildCommand),
    ("run", "Build and run the default executable of a project", runCommand),
    ("enter", "Enter the default devshell for a project", enterCommand),
    ("generate", "Generate the flake.nix file and exit", const $ pure Gen),
    ("check", "Run the checks of a project", checkCommand)
  ]

buildCommand :: Targets -> Parser WithGarnTsCommand
buildCommand targets =
  Build <$> commandOptionsParser (Map.filter isBuildable targets)
  where
    isBuildable = \case
      TargetConfigProject _ -> True
      TargetConfigPackage _ -> True
      TargetConfigExecutable _ -> False

runCommand :: Targets -> Parser WithGarnTsCommand
runCommand targets =
  Run <$> commandOptionsParser (Map.filter isRunnable targets) <*> argvParser
  where
    argvParser :: Parser [String]
    argvParser = many $ strArgument $ metavar "...args"

    isRunnable :: TargetConfig -> Bool
    isRunnable = \case
      TargetConfigProject projectTarget -> runnable projectTarget
      TargetConfigPackage _ -> False
      TargetConfigExecutable _ -> True

enterCommand :: Targets -> Parser WithGarnTsCommand
enterCommand targets =
  Enter <$> commandOptionsParser (Map.filter isProject targets)

checkCommand :: Targets -> Parser WithGarnTsCommand
checkCommand targets =
  let checkCommandOptions =
        Qualified
          <$> commandOptionsParser (Map.filter isProject targets)
            <|> pure Unqualified
   in Check <$> checkCommandOptions

isProject :: TargetConfig -> Bool
isProject = \case
  TargetConfigProject _ -> True
  TargetConfigPackage _ -> False
  TargetConfigExecutable _ -> False

withGarnTsParser :: Targets -> Parser WithGarnTsCommand
withGarnTsParser targets =
  subparser $
    mconcat
      [ OA.command cmd (info (runner targets) (progDesc desc))
        | (cmd, desc, runner) <- withGarnTsCommandInfo
      ]

withouGarnTsCommandInfo :: [(String, String, Parser WithoutGarnTsCommand)]
withouGarnTsCommandInfo =
  [("init", "Infer a garn.ts file from the project layout", pure Init)]

withoutGarnTsParser :: Parser WithoutGarnTsCommand
withoutGarnTsParser =
  subparser $
    mconcat
      [ OA.command cmd (info runner (progDesc desc))
        | (cmd, desc, runner) <- withouGarnTsCommandInfo
      ]

data CommandOptions = CommandOptions
  { target :: TargetName,
    targetConfig :: TargetConfig
  }
  deriving stock (Eq, Show)

commandOptionsParser :: Targets -> Parser CommandOptions
commandOptionsParser targets =
  subparser
    ( foldMap
        ( \(target, targetConfig) ->
            OA.command
              (asUserFacing target)
              ( info
                  (pure (CommandOptions target targetConfig))
                  (progDesc $ getDescription targetConfig)
              )
        )
        $ Map.assocs targets
    )
    <**> helper

data CheckCommandOptions
  = Qualified CommandOptions
  | Unqualified
  deriving stock (Eq, Show)

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-|
Module      : Eucalypt.Driver.Core
Description : Facilities for loading core from inputs
Copyright   : (c) Greg Hawkins, 2018
License     :
Maintainer  : greg@curvelogic.co.uk
Stability   : experimental
-}

module Eucalypt.Driver.Core
  ( parseInputsAndImports
  , parseAndDumpASTs
  , loadInput
  , loader
  , CoreLoader
  ) where

import Control.Exception.Safe (throwM, try)
import Control.Monad (forM_)
import Control.Monad.Loops (iterateUntilM)
import Control.Monad.State.Strict
import qualified Data.ByteString as BS
import Data.Either (partitionEithers)
import Data.Foldable (toList)
import qualified Data.Map as M
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Yaml as Y
import Eucalypt.Core.Desugar (translateToCore)
import Eucalypt.Core.Error
import Eucalypt.Core.Import
import Eucalypt.Core.SourceMap
import Eucalypt.Core.Syn
import Eucalypt.Core.Unit
import Eucalypt.Driver.Error (CommandError(..))
import Eucalypt.Driver.Lib (getResource)
import Eucalypt.Driver.Options (EucalyptOptions(..))
import Eucalypt.Reporting.Error (EucalyptError(..))
import Eucalypt.Source.Error (DataParseException(..))
import Eucalypt.Source.TextSource
import Eucalypt.Source.TomlSource
import Eucalypt.Source.YamlSource
import Eucalypt.Syntax.Ast (Unit)
import Eucalypt.Syntax.Error (SyntaxError(..))
import Eucalypt.Syntax.Input (Input(..), Locator(..))
import qualified Eucalypt.Syntax.ParseExpr as PE
import Network.URI
import System.Exit
import System.IO


-- | Options relating to the loading of core from various inputs
data CoreLoaderOptions = CoreLoaderOptions
  { loadPath :: [FilePath] -- ^ search directories for relative paths
  , loadEvaluand :: Maybe String -- ^ maybe a command line evaluand
  }



-- | A loader with options and cache
data CoreLoader = CoreLoader
  { clOptions :: CoreLoaderOptions
  , clCache :: M.Map Input BS.ByteString
  , clNextSMID :: SMID
  }



-- | Create a new core loader from command line options, this tracks
-- state during the load of all inputs
loader :: EucalyptOptions -> CoreLoader
loader EucalyptOptions {..} =
  CoreLoader
    { clOptions =
        CoreLoaderOptions {loadPath = [], loadEvaluand = optionEvaluand}
    , clCache = mempty
    , clNextSMID = 1
    }



-- | Get the next source map identifier to stamp on syntax item
getNextSMID :: CoreLoad SMID
getNextSMID = gets clNextSMID



-- | Update the next source map identifier
setNextSMID :: SMID -> CoreLoad ()
setNextSMID smid = modify (\s -> s { clNextSMID = smid })



-- | Load an input, using cached version in CoreLoader if appropriate.
-- This is an external function used to leverage already cached
-- content if possible, it does not update the cache. ('CoreLoad' is
-- internal to this module)
loadInput :: CoreLoader -> Input -> IO BS.ByteString
loadInput CoreLoader {..} input =
  case inputLocator input of
    CLIEvaluand ->
      case loadEvaluand clOptions of
        Just s -> return . T.encodeUtf8 . T.pack $ s
        Nothing -> throwM $ Command MissingEvaluand
    _ ->
      case clCache M.!? input of
        Just bs -> return bs
        Nothing -> throwM $ Core NoSource



-- | A state wrapping monad for tracking SMID between different
-- translations - we need to ensure unique souce map IDs in all trees
type CoreLoad a = StateT CoreLoader IO a



-- | Read bytestring content for an Input and cache in the 'CoreLoader'
readInput :: Input -> CoreLoad BS.ByteString
readInput i@Input {..} = do
  bs <-
    case inputLocator of
      (URLInput u) -> liftIO $ readURLInput u
      (ResourceInput nm) ->
        case getResource nm of
          Just content -> return content
          Nothing -> throwM $ Command $ UnknownResource nm
      StdInput -> liftIO $ BS.hGetContents stdin
      CLIEvaluand ->
        gets (loadEvaluand . clOptions) >>= \case
          Just text -> (return . T.encodeUtf8 . T.pack) text
          Nothing -> throwM $ Command MissingEvaluand
  state $ \s@CoreLoader {..} -> (bs, s {clCache = M.insert i bs clCache})
  where
    readURLInput u =
      case uriScheme u of
        "file:" -> BS.readFile (uriPath u)
        _ -> throwM $ Command $ UnsupportedURLScheme $ uriScheme u



-- | Parse a byteString as eucalypt
parseEucalypt :: BS.ByteString -> String -> Either SyntaxError Unit
parseEucalypt source = PE.parseUnit text
  where text = (T.unpack . T.decodeUtf8) source



-- | Dump ASTs
dumpASTs :: EucalyptOptions -> [Unit] -> IO ()
dumpASTs _ exprs = forM_ exprs $ \e ->
  putStrLn "---" >>  (T.putStrLn . T.decodeUtf8 . Y.encode) e



-- | Parse and dump ASTs
parseAndDumpASTs :: EucalyptOptions -> IO ExitCode
parseAndDumpASTs opts@EucalyptOptions {..} = do
  texts <- evalStateT (traverse readInput euInputs) (loader opts)
  let filenames = map show euInputs
  let (errs, units) = partitionEithers (zipWith parseEucalypt texts filenames)
  if null errs
    then dumpASTs opts units >> return ExitSuccess
    else throwM $ Multiple (map Syntax errs)
  where
    euInputs = filter (\i -> inputFormat i == "eu") optionInputs



-- | Resolve a unit, read source and parse and desugar the content
-- into CoreExpr, converting all error types into EucalyptErrors.
--
-- Named inputs are automatically set to suppress export as it is
-- assumed that they will be referenced by name in subsequent source.
loadUnit :: Input -> CoreLoad (Either EucalyptError TranslationUnit)
loadUnit i@(Input locator name format) = do
  firstSMID <- getNextSMID
  source <- readInput i
  coreUnit <-
    liftIO $
    case format of
      "text" -> textDataToCore i source
      "toml" -> tomlDataToCore i source
      "yaml" -> activeYamlToCore i source
      "json" -> yamlDataToCore i source
      "eu" -> eucalyptToCore i firstSMID source
      _ -> (return . Left . Command . InvalidInput) i
  case coreUnit of
    Right u -> setNextSMID $ (nextSMID firstSMID . truSourceMap) u
    Left _ -> return ()
  return coreUnit
  where
    maybeApplyName = maybe id applyName name
    eucalyptToCore input smid text =
      case parseEucalypt text (show locator) of
        Left e -> (return . Left . Syntax) e
        Right expr ->
          (return . Right . maybeApplyName . translateToCore input smid) expr
    yamlDataToCore input text = do
      r <- try (parseYamlData text) :: IO (Either DataParseException CoreExpr)
      case r of
        Left e -> (return . Left . Source) e
        Right core -> (return . Right . maybeApplyName . dataUnit input) core
    textDataToCore input text =
      parseTextLines text >>=
      (return . Right . maybeApplyName <$> dataUnit input)
    tomlDataToCore input text =
      parseTomlData text >>=
      (return . Right . maybeApplyName <$> dataUnit input)
    activeYamlToCore input text = do
      r <- try (parseYamlExpr text) :: IO (Either DataParseException CoreExpr)
      case r of
        Left e -> (return . Left . Source) e
        Right core -> (return . Right . maybeApplyName . dataUnit input) core



-- | Parse units, reporting and exiting on error
loadUnits :: (Traversable t, Foldable t) => t Input -> CoreLoad [TranslationUnit]
loadUnits inputs = do
  asts <- traverse loadUnit inputs
  case partitionEithers (toList asts) of
    ([e], _) -> throwM e
    (es@(_:_), _) -> throwM $ Multiple es
    ([], []) -> throwM $ Core NoSource
    ([], units) -> return units



-- | Parse all units in the graph of imports.
--
loadAllUnits :: [Input] -> CoreLoad (M.Map Input TranslationUnit)
loadAllUnits inputs = do
  unitMap <- readImportsToMap inputs mempty
  iterateUntilM (null . pendingImports) step unitMap
  where
    readImportsToMap ins m = do
      units <- loadUnits ins
      return $ foldl (\m' (k, v) -> M.insert k v m') m $ zip ins units
    step m = readImportsToMap (toList $ pendingImports m) m
    collectImports = foldMap truImports . M.elems
    collectInputs = M.keysSet
    pendingImports m = S.difference (collectImports m) (collectInputs m)



-- | Parse all units specified on command line (or inferred) to core
-- syntax, processing imports on the way to arrive at a map of all
-- units specified directly or indirectly, each with fully realised
-- core expression with values bound by imported lets.
--
-- SourceMap ids are unique across all the units, starting at 1
parseInputsAndImports ::
     EucalyptOptions -> IO ([TranslationUnit], CoreLoader)
parseInputsAndImports opts = do
  (unitMap, populatedLoader) <- runStateT (loadAllUnits inputs) (loader opts)
  case applyAllImports unitMap of
    Right processedUnitMap ->
      return (mapMaybe (`M.lookup` processedUnitMap) inputs, populatedLoader)
    Left cyclicInputs -> throwM $ Command $ CyclicInputs cyclicInputs
  where
    inputs = optionInputs opts

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
module CabalBundler.Main (main) where

import Peura
import Prelude ()

import Control.Applicative ((<**>))
import Data.Version        (showVersion)
import Distribution.Parsec (eitherParsec)

import qualified Cabal.Plan                             as P
import qualified Data.Map.Strict                        as M
import qualified Data.Set                               as S
import qualified Distribution.Types.UnqualComponentName as C
import qualified Distribution.Version                   as C
import qualified Options.Applicative                    as O

import Paths_cabal_bundler (version)

import CabalBundler.Curl
import CabalBundler.ExeOption
import CabalBundler.NixSingle
import CabalBundler.OpenBSD

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

main :: IO ()
main = do
    opts <- O.execParser optsP'
    tracer <- makeTracerPeu @Void (optTracer opts defaultTracerOptions)
    runPeu tracer () $ do
        meta <- cachedHackageMetadata tracer

        -- Solve

        let pid@(PackageIdentifier pn ver) = optPackageId opts

        let exeName :: ExeOption C.UnqualComponentName
            exeName = C.packageNameToUnqualComponentName pn <$ optExeOption opts

        -- Read plan
        plan <- case optPlan opts of
            Just planPath -> do
                planPath' <- makeAbsolute planPath
                liftIO $ P.decodePlanJson (toFilePath planPath')

            Nothing -> do
                exeName' <- case exeName of
                    ExeOptionPkg x -> return $ C.unUnqualComponentName x
                    ExeOption x    -> return $ C.unUnqualComponentName x
                    ExeOptionAll   -> die tracer "--exe-all isn't supported without explicit plan.json"

                -- TODO: check that package is in metadata, if plan is not given!

                mplan <- ephemeralPlanJson tracer $ emptyPlanInput
                    { piExecutables = M.singleton pn (C.thisVersion ver, S.singleton exeName')
                    , piCompiler = Just (optCompiler opts)
                    }

                case mplan of
                    Nothing   -> die tracer $ "Cannot find an install plan for " ++ prettyShow pid
                    Just plan -> return plan

        -- Generate derivation

        rendered <- case optFormat opts of
            NixSingle -> generateDerivationNix tracer pn exeName plan meta
            Curl      -> generateCurl          tracer pn exeName plan meta
            OpenBSD   -> generateOpenBSD       tracer pn exeName plan meta

        case optOutput opts of
            Nothing -> output tracer rendered
            Just fp -> do
                fp' <- makeAbsolute fp
                writeByteString fp' (toUTF8BS rendered)

  where
    optsP' = O.info (optsP <**> O.helper <**> versionP) $ mconcat
        [ O.fullDesc
        , O.progDesc "Create bundles using cabal-install solver"
        , O.header "cabal-bundler - for offline development"
        ]

    versionP = O.infoOption (showVersion version)
        $ O.long "version" <> O.help "Show version"

-------------------------------------------------------------------------------
-- Opts
-------------------------------------------------------------------------------

data Opts = Opts
    { optFormat     :: Format
    , optPackageId  :: PackageIdentifier
    , optExeOption  :: ExeOption ()
    , optCompiler   :: FilePath
    , optOutput     :: Maybe FsPath
    , optPlan       :: Maybe FsPath
    , optTracer     :: TracerOptions Void -> TracerOptions Void
    }

data Format = NixSingle | Curl | OpenBSD

optsP :: O.Parser Opts
optsP = Opts
    <$> formatP
    <*> O.argument (O.eitherReader eitherParsec) (O.metavar "PKG" <> O.help "package to install")
    <*> exeOptionP
    <*> O.strOption (O.short 'w' <> O.long "with-compiler" <> O.value "ghc" <> O.showDefault <> O.help "Specify compiler to use")
    <*> optional (O.option (O.eitherReader $ return . fromFilePath) (O.short 'o' <> O.long "output" <> O.metavar "PATH" <> O.help "Output location"))
    <*> optional (O.option (O.eitherReader $ return . fromFilePath) (O.short 'p' <> O.long "plan" <> O.metavar "PATH" <> O.help "Use plan.json provided"))
    <*> tracerOptionsParser

formatP :: O.Parser Format
formatP = nixSingle <|> curl <|> openbsd <|> pure Curl where
    nixSingle = O.flag' NixSingle $ O.long "nix-single" <> O.help "Single nix derivation"
    curl      = O.flag' Curl      $ O.long "curl"       <> O.help "Curl script to download dependencies"
    openbsd   = O.flag' OpenBSD   $ O.long "openbsd"    <> O.help "OpenBSD port manifest (MODCABAL_MANIFEST variable)"

exeOptionP :: O.Parser (ExeOption ())
exeOptionP = exeOptionPkg <|> exeOption <|> exeOptionAll <|> pure (ExeOptionPkg ())
  where
    exeOptionPkg = O.flag' (ExeOptionPkg ()) $ O.long "exe-from-pkg" <> O.help "Derive executable name from package name (default)"
    exeOptionAll = O.flag' ExeOptionAll      $ O.long "exe-all" <> O.help "All executables"
    exeOption    = O.option (ExeOption <$> O.eitherReader eitherParsec) $ O.long "executable" <> O.help "Build this executable"

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}

import           Control.Applicative
import           Control.Arrow
import           Control.Concurrent.Async
import           Control.Exception
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Resource
import qualified Data.ByteString.Lazy         as L
import           Data.Char
import           Data.Conduit
import           Data.Conduit.Binary          (sinkLbs)
import           Data.Conduit.Filesystem      (sourceDirectoryDeep)
import qualified Data.Conduit.List            as CL
import           Data.Conduit.Process
import           Data.List                    (isSuffixOf, stripPrefix, sort)
import qualified Data.Map                     as Map
import           Data.Maybe                   (fromMaybe)
import           Data.Text.Encoding.Error     (lenientDecode)
import qualified Data.Text.Lazy               as TL
import qualified Data.Text.Lazy.Encoding      as TL
import           Data.Typeable
import           Prelude -- Fix redundant import warnings
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO.Temp
import           System.PosixCompat.Files
import           Test.Hspec

main :: IO ()
main = do
    srcDir  <- canonicalizePath ""
    currDir <- canonicalizePath "test/integration"

    let findExe name = do
            mexe <- findExecutable name
            case mexe of
                Nothing -> error $ name ++ " not found on PATH"
                Just exe -> return exe
    runghc <- findExe "runghc"
    stack <- findExe "stack"

    let testDir = currDir </> "tests"
    tests <- getDirectoryContents testDir >>= filterM (hasTest testDir) . sort

    envOrig <- getEnvironment

    withSystemTempDirectory "stackhome" $ \newHome -> do
        defaultStackRoot <- getAppUserDataDirectory "stack"
        let newStackRoot = newHome </> takeFileName defaultStackRoot
            env' = Map.toList
                 $ Map.insert "STACK_EXE" stack
                 $ Map.insert "HOME" newHome
                 $ Map.insert "APPDATA" newHome
                 $ Map.insert "STACK_ROOT" newStackRoot
                 $ Map.insert "SRC_DIR" srcDir
                 $ Map.delete "GHC_PACKAGE_PATH"
                 $ Map.fromList
                 $ map (first (map toUpper)) envOrig
            origStackRoot = fromMaybe defaultStackRoot (lookup "STACK_ROOT" envOrig)

        hspec $ mapM_ (test runghc env' currDir origStackRoot newHome newStackRoot) tests

hasTest :: FilePath -> FilePath -> IO Bool
hasTest root dir = doesFileExist $ root </> dir </> "Main.hs"

test :: FilePath -- ^ runghc
     -> [(String, String)] -- ^ env
     -> FilePath -- ^ currdir
     -> FilePath -- ^ origStackRoot
     -> FilePath -- ^ newHome
     -> FilePath -- ^ newStackRoot
     -> String
     -> Spec
test runghc env' currDir origStackRoot newHome newStackRoot name = it name $ withDir $ \dir -> do
    newHomeExists <- doesDirectoryExist newHome
    when newHomeExists (removeDirectoryRecursive newHome)
    createDirectoryIfMissing True newStackRoot
    copyTree toCopyRoot origStackRoot newStackRoot
    writeFile (newStackRoot </> "config.yaml") "system-ghc: true\ninstall-ghc: false\n"
    let testDir = currDir </> "tests" </> name
        mainFile = testDir </> "Main.hs"
        libDir = currDir </> "lib"
        cp = (proc runghc
                [ "-clear-package-db"
                , "-global-package-db"
                , "-i" ++ libDir
                , mainFile
                ])
                { cwd = Just dir
                , env = Just (Map.toList
                            $ Map.insert "TEST_DIR" testDir
                            $ Map.fromList env')
                }

    copyTree (const True) (testDir </> "files") dir

    (ClosedStream, outSrc, errSrc, sph) <- streamingProcess cp
    (out, err, ec) <- runConcurrently $ (,,)
        <$> Concurrently (outSrc `connect` sinkLbs)
        <*> Concurrently (errSrc `connect` sinkLbs)
        <*> Concurrently (waitForStreamingProcess sph)
    when (ec /= ExitSuccess) $ throwIO $ TestFailure out err ec
  where
    withDir = withSystemTempDirectory ("stack-integration-" ++ name)

data TestFailure = TestFailure L.ByteString L.ByteString ExitCode
    deriving Typeable
instance Show TestFailure where
    show (TestFailure out err ec) = concat
        [ "Exited with " ++ show ec
        , "\n\nstdout:\n"
        , toStr out
        , "\n\nstderr:\n"
        , toStr err
        ]
      where
        toStr = TL.unpack . TL.decodeUtf8With lenientDecode
instance Exception TestFailure

copyTree :: (FilePath -> Bool) -> FilePath -> FilePath -> IO ()
copyTree toCopy src dst =
    runResourceT (sourceDirectoryDeep False src `connect` CL.mapM_ go)
        `catch` \(_ :: IOException) -> return ()
  where
    go srcfp = when (toCopy srcfp) $ liftIO $ do
        Just suffix <- return $ stripPrefix src srcfp
        let dstfp = dst </> stripHeadSeparator suffix
        createDirectoryIfMissing True $ takeDirectory dstfp
        createSymbolicLink srcfp dstfp `catch` \(_ :: IOException) ->
            copyFile srcfp dstfp -- for Windows

    stripHeadSeparator :: FilePath -> FilePath
    stripHeadSeparator [] = []
    stripHeadSeparator fp@(x:xs) = if isPathSeparator x
                                   then xs
                                   else fp


toCopyRoot :: FilePath -> Bool
toCopyRoot srcfp = any (`isSuffixOf` srcfp)
    -- FIXME command line parameters to control how many of these get
    -- copied, trade-off of runtime/bandwidth vs isolation of tests
    [ ".tar"
    , ".tar.gz"
    , ".xz"
    -- , ".gz"
    , ".7z.exe"
    , "00-index.cache"
    ]

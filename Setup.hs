import Distribution.System
import Distribution.Verbosity
import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.Program
import Distribution.Simple.Setup
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Utils

import Distribution.Simple.PackageIndex
import qualified Distribution.InstalledPackageInfo as Installed

import System.IO
import System.Exit
import System.Directory
import Control.Exception.Extensible

main :: IO ()
main = defaultMainWithHooks myHooks

myHooks :: UserHooks
myHooks
    | buildOS == Windows    = simpleUserHooks
    | otherwise = simpleUserHooks {
            confHook = \genericDescript flags -> do
                        lbi <- confHook simpleUserHooks genericDescript flags
                        let pkgDescr = localPkgDescr lbi
                        let Just lib = library pkgDescr
                        let bi = libBuildInfo lib
                        bi' <- maybeSetLibiconv flags bi lbi
                        return lbi {localPkgDescr = pkgDescr {
                                                library = Just lib {
                                                    libBuildInfo = bi'}}}
            }

-- Test whether compiling a c program that links against libiconv needs -liconv.
maybeSetLibiconv :: ConfigFlags -> BuildInfo -> LocalBuildInfo -> IO BuildInfo
maybeSetLibiconv flags bi lbi = do
    let biWithIconv = addIconv bi
    let verb = fromFlag (configVerbosity flags)
    if hasFlagSet flags (FlagName "libiconv")
        then do
            putStrLn "Using -liconv."
            return biWithIconv
        else do
    putStr "checking whether to use -liconv... "
    hFlush stdout
    worksWithout <- tryCompile iconv_prog bi lbi verb
    if worksWithout
        then do
            putStrLn "not needed."
            return bi
        else do
    worksWith <- tryCompile iconv_prog biWithIconv lbi verb
    if worksWith
        then do
            putStrLn "using -liconv."
            return biWithIconv
        else error "Unable to link against the iconv library."

hasFlagSet :: ConfigFlags -> FlagName -> Bool
hasFlagSet cflags flag = Just True == lookup flag (configConfigurationsFlags cflags)

tryCompile :: String -> BuildInfo -> LocalBuildInfo -> Verbosity -> IO Bool
tryCompile program bi lbi verb = handle processExit $ handle processException $ do
    tempDir <- getTemporaryDirectory
    withTempFile tempDir ".c" $ \fname cH ->
      withTempFile tempDir "" $ \execName oH -> do
        hPutStr cH program
        hClose cH
        hClose oH
        -- TODO take verbosity from the args.
        rawSystemProgramStdoutConf verb gccProgram (withPrograms lbi)
                        (fname : "-o" : execName : args)
        return True
  where
    processException :: IOException -> IO Bool
    processException e = return False
    processExit = return . (==ExitSuccess)
    -- Mimicing Distribution.Simple.Configure
    deps = topologicalOrder (installedPkgs lbi)
    args = concat
                  [ ccOptions bi
                  , cppOptions bi
                  , ldOptions bi
                  -- --extra-include-dirs and --extra-lib-dirs are included
                  -- in the below fields.
                  -- Also sometimes a dependency like rts points to a nonstandard
                  -- include/lib directory where iconv can be found. 
                  , map ("-I" ++) (includeDirs bi ++ concatMap Installed.includeDirs deps)
                  , map ("-L" ++) (extraLibDirs bi ++ concatMap Installed.libraryDirs deps)
                  , map ("-l" ++) (extraLibs bi)
                  ]

addIconv :: BuildInfo -> BuildInfo
addIconv bi = bi {extraLibs = "iconv" : extraLibs bi}

iconv_prog :: String
iconv_prog = unlines $
    [ "#include <iconv.h>"
    , "int main(void) {"
    , "    iconv_t t = iconv_open(\"UTF-8\", \"UTF-8\");"
    , "    return 0;"
    , "}"
    ]
    

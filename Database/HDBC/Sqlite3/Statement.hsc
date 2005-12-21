{- -*- mode:haskell; -*-
Copyright (C) 2005 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and\/or modify
it under the terms of the GNU Lesser General Public License as published by
the Free Software Foundation; either version 2.1 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

-}
module Database.HDBC.Sqlite3.Statement where
import Database.HDBC.Types
import Database.HDBC
import Database.HDBC.Sqlite3.Types
import Database.HDBC.Sqlite3.Utils
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Ptr
import Control.Concurrent.MVar
import Foreign.C.String
import Foreign.Marshal
import Foreign.Storable
import Control.Monad
import Data.List
import Control.Exception

#include <sqlite3.h>

data StoState = Empty           -- ^ Not initialized or last execute/fetchrow had no results
              | Prepared Stmt   -- ^ Prepared but not executed
              | Executed Stmt   -- ^ Executed and more rows are expected
     deriving (Eq, Show, Read)

data SState = {dbo :: Sqlite3,
               stomv :: MVar StoState,
               query :: String}
     deriving (Eq, Show)

newSth :: Sqlite3 -> String -> IO Statement               
newSth indbo str = 
    do newstomv <- newMVar Empty
       newmorerowsmv <- newMVar False
       let sstate = {dbo = indbo,
                     stomv = newstomv,
                     morerowsmv = newmorerowsmv
                     query = str}
       fprepare sstate
       return $ Statement {sExecute = fexecute sstate,
                           sExecuteMany = fexecutemany sstate,
                           finish = ffinish sstate,
                           fetchRow = ffetchrow sstate}

{- The deal with adding the \0 below is in response to an apparent bug in
sqlite3.  See debign bug #343736. 

This function assumes that any existing query in the state has already
been terminated.
-}
fprepare :: SState -> IO ()
fprepare sstate = withForeignPtr (dbo sstate)
  (\p -> withCStringLen ((query sstate) ++ "\0")
   (\(cs, cslen) -> alloca
    (\(newp::Ptr (Ptr CStmt)) -> modifyMVar_ (stomv sstate) (\_ ->
     (do res <- sqlite3_prepare p cs (fromIntegral cslen) newp nullPtr
         checkError ("prepare " ++ (show cslen) ++ ": " ++ str) dbo res
         newo <- peek newp
         fptr <- newForeignPtr sqlite3_finalizeptr newo
         return (Prepared fptr,
                 Statement {sExecute = fexecute sstate,
                            sExecuteMany = fexecutemany sstate,
                            finish = ffinish sstate,
                            fetchRow = ffetchrow sstate})
         )
     )
     )
   )
   )
                 

{- General algorithm: find out how many columns we have, check the type
of each to see if it's NULL.  If it's not, fetch it as text and return that. -}
ffetchrow sstate = modifyMVar (stomv sstate) 
    where dofetchrow Empty = return (Empty, Nothing)
          dofetchrow (Prepared _) = 
              throwDyn $ SqlError {seState = "HDBC Sqlite3 fetchrow",
                                   seNativeError = 0,
                                   seErrorMsg = "Attempt to fetch row from Statement that has not been executed.  Query was: " ++ (query sstate)}
          dofetchrow (Executed sto) = withForeignPtr sto (\p ->
              do ccount <- sqlite3_column_count p
                 -- fetch the data
                 res <- mapM (getCol p) [0..(ccount - 1)]
                 r <- fstep o p
                 --when (not r)
                 --     (ffinish sto)
                 return (if r then Just sto else Nothing, Just res)
                                                     )
 
          getCol p icol = 
             do t <- sqlite3_column_type p icol
                if t == #{const SQLITE_NULL}
                   then return Nothing
                   else do t <- sqlite3_column_text p icol
                           len <- sqlite3_column_bytes p icol
                           s <- peekCStringLen (t, fromIntegral len)
                           return (Just s)

fstep dbo p =
    do r <- sqlite3_step p
       case r of
         #{const SQLITE_ROW} -> return True
         #{const SQLITE_DONE} -> return False
         #{const SQLITE_ERROR} -> checkError "step" dbo #{const SQLITE_ERROR}
                                   >> (throwDyn $ SqlError 
                                          {seState = "",
                                           seNativeError = 0,
                                           seErrorMsg = "In HDBC step, internal processing error (got SQLITE_ERROR with no error)"})
         x -> throwDyn $ SqlError {seState = "",
                                   seNativeError = fromIntegral x,
                                   seErrorMsg = "In HDBC step, unexpected result from sqlite3_step"}

fexecute sstate args = 
    -- First, finish up any existing stuff.
    do 
withForeignPtr o
  (\p -> do c <- sqlite3_bind_parameter_count p
            when (c /= genericLength args)
                 (throwDyn $ SqlError {seState = "",
                                       seNativeError = (-1),
                                       seErrorMsg = "In HDBC execute, received " ++ (show args) ++ " but expected " ++ (show c) ++ " args."})
            modifyMVar_ mv (\_ -> return False)
            sqlite3_reset p >>= checkError "execute (reset)" dbo
            zipWithM_ (bindArgs p) [1..c] args
            newmv <- fstep dbo p
            modifyMVar_ mv (\_ -> return newmv)
            when (not newmv)    -- Clean up the sth now, if there are no rows.
                 (ffinish o)
            return (-1)
  )
  where bindArgs p i Nothing =
            sqlite3_bind_null p i >>= 
              checkError ("execute (binding NULL column " ++ (show i) ++ ")") dbo
        bindArgs p i (Just str) = withCStringLen str 
             (\(cs, len) -> do r <- sqlite3_bind_text2 p i cs 
                                    (fromIntegral len)
                               checkError ("execute (binding column " ++ 
                                           (show i) ++ ")") dbo r
             )

fexecutemany mv dbo o arglist =
    mapM (fexecute mv dbo o) arglist >>= return . genericLength

--ffinish o = withForeignPtr o (\p -> sqlite3_finalize p >>= checkError "finish")
ffinish = finalizeForeignPtr

foreign import ccall unsafe "sqlite3.h &sqlite3_finalize"
  sqlite3_finalizeptr :: FunPtr ((Ptr CStmt) -> IO ())

foreign import ccall unsafe "sqlite3.h sqlite3_finalize"
  sqlite3_finalize :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_prepare"
  sqlite3_prepare :: (Ptr CSqlite3) -> CString -> CInt -> Ptr (Ptr CStmt) -> Ptr (Ptr CString) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_bind_parameter_count"
  sqlite3_bind_parameter_count :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_step"
  sqlite3_step :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_reset"
  sqlite3_reset :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_count"
  sqlite3_column_count :: (Ptr CStmt) -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_type"
  sqlite3_column_type :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_column_text"
  sqlite3_column_text :: (Ptr CStmt) -> CInt -> IO CString

foreign import ccall unsafe "sqlite3.h sqlite3_column_bytes"
  sqlite3_column_bytes :: (Ptr CStmt) -> CInt -> IO CInt

foreign import ccall unsafe "hdbc-sqlite3-helper.h sqlite3_bind_text2"
  sqlite3_bind_text2 :: (Ptr CStmt) -> CInt -> CString -> CInt -> IO CInt

foreign import ccall unsafe "sqlite3.h sqlite3_bind_null"
  sqlite3_bind_null :: (Ptr CStmt) -> CInt -> IO CInt
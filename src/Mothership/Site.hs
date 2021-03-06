{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Mothership.Site
    ( site
    ) where

import           Control.Applicative ((<|>), (<$>))
import           Control.Monad
import           Control.Monad.Trans (lift, liftIO)
import qualified Data.ByteString.Char8 as B
import           Data.ByteString.Char8 (ByteString)
import qualified Data.Map as M
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding (decodeUtf8)
import           Snap.Auth
import           Snap.Auth.Handlers
import           Snap.Extension.DB.MongoDB (MonadMongoDB)
import           Snap.Extension.Heist
import           Snap.Extension.Session.CookieSession
import           Snap.Types hiding (path, dir)
import           Snap.Util.FileServe
import           System.Directory
import           System.FilePath
import           Text.Templating.Heist
import qualified Text.XmlHtml as X
import           Prelude hiding (span, lookup)

import           Git
import           Heist.Future
import           Mothership.Application
import           Mothership.Types
import           Snap.Util
import           Snap.Util.BasicAuth
import           Snap.Util.Git

------------------------------------------------------------------------

site :: Application ()
site = routes <|> serveDirectory "resources/static"
  where
    routes = withSplices $ route
      [ ("/", home)

      , ("/login",  method GET  newLogin)
      , ("/login",  method POST login)
      , ("/logout", method GET  logout)

      , ("/signup", method GET  newSignup)
      , ("/signup", method POST signup)

      , ("/repositories/new", method GET  newRepo)
      , ("/repositories",     method POST createRepo)

      , ("/:repo", git)
      ]

------------------------------------------------------------------------

home :: Application ()
home = do
    ifTop $ renderWithSplices "home"
          [ ("repositories", repoSplice) ]

------------------------------------------------------------------------

newLogin :: Application ()
newLogin = renderWithSplices "login" [("ifLoginFailure", ignore)]

loginFailed :: Application ()
loginFailed = renderWithSplices "login" [("ifLoginFailure", include)]

login :: Application ()
login = loginHandler "password" Nothing loginFailed (redirect "/")

logout :: Application ()
logout = logoutHandler (redirect "/")

------------------------------------------------------------------------

newSignup :: Application ()
newSignup = render "signup"

signup :: Application ()
signup = do
    (authUser, user) <- createUser <$> getParams
    au <- saveAuthUser (authUser, toDoc user)
    case au of
        Nothing  -> newSignup
        Just au' -> do
            setSessionUserId (userId au')
            redirect "/"

createUser :: Params -> (AuthUser, User)
createUser ps =
    ( emptyAuthUser
        { userEmail    = Just $ lookupBS "email" ps
        , userPassword = Just $ ClearText $ lookupBS "password" ps }
    , User
        { userUsername = lookupT "username" ps
        , userFullName = lookupT "full_name" ps }
    )

currentUser :: (MonadAuth m, MonadMongoDB m) => m (Maybe User)
currentUser = toUser <$> currentAuthUser
  where
    toUser x = fmap snd x >>= fromDoc

lookupBS :: ByteString -> Params -> ByteString
lookupBS k ps = case M.lookup k ps of
    Just (x:_) -> x
    _          -> error $ "lookupBS: missing required parameter '"
                          ++ B.unpack k ++ "'"

lookupT :: ByteString -> Params -> Text
lookupT k = decodeUtf8 . lookupBS k

------------------------------------------------------------------------

newRepo :: Application ()
newRepo = render "newrepo"

createRepo :: Application ()
createRepo = do
    repo <- mkRepo <$> getParams
    insert repo

    dir <- getDir repo
    liftIO $ createDirectoryIfMissing True dir
    liftIO $ gitExec_ dir ["init", "--bare"]

    redirect "/"
  where
    mkRepo ps = Repository
        { repoName = lookupT "name" ps
        , repoDescription = lookupT "description" ps }

getDir :: Repository -> Application FilePath
getDir repo = (</> name ++ ".git") <$> getRepositoriesDir
  where
    name = T.unpack $ repoName repo

------------------------------------------------------------------------

withSplices :: Application a -> Application a
withSplices = heistLocal (bindSplices splices)

splices :: [(Text, Splice Application)]
splices =
    [ ("ifLoggedIn",   ifLoggedIn)
    , ("ifGuest",      ifGuest)
    , ("requireAuth",  requireAuth)
    , ("userFullName", userFullNameSplice)
    ]

ifLoggedIn :: Splice Application
ifLoggedIn = requireUser' ignore include

ifGuest :: Splice Application
ifGuest = requireUser' include ignore

requireAuth :: Splice Application
requireAuth = requireUser' (lift pass) include

requireUser' :: Splice Application -> Splice Application -> Splice Application
requireUser' bad good = join $ lift $ requireUser (return bad) (return good)

userFullNameSplice :: Splice Application
userFullNameSplice = lift currentUser >>= return . maybe [] name
  where
    name = return . X.TextNode . userFullName

include :: Monad m => Splice m
include = getParamNode >>= return . X.childNodes

ignore :: Monad m => Splice m
ignore = return []

------------------------------------------------------------------------

git :: Application ()
git = do
    repo <- getParamStr "repo"
    guard (isRepo repo)

    basicAuth "Mothership" attemptLogin

    dir <- getRepositoriesDir
    serveRepo (dir </> repo)
  where
    attemptLogin username password = do
        user <- performLogin euid password False
        return (user /= Nothing)
      where
        euid = EUId $ M.fromList [("username", [username])]

isRepo :: FilePath -> Bool
isRepo = (== ".git") . takeExtension

------------------------------------------------------------------------

repoSplice :: Splice Application
repoSplice = do
    repos <- lift findAll
    mapSplices (viewWith . fromRepo) repos
  where
    fromRepo :: Repository -> [(Text, Splice Application)]
    fromRepo r = [ ("name", text $ repoName r)
                 , ("description", text $ repoDescription r) ]
    text = return . return . X.TextNode

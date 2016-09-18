{-|
Module      : DiskMap
Description : Persistent STM Map
Copyright   : (c) Rune K. Svendsen, 2016
License     : PublicDomain
Maintainer  : runesvend@gmail.com
Stability   : experimental
Portability : POSIX

An STM 'STMContainers.Map' which syncs each map operation to disk,
 from which the map can be restored later. Each key is stored as a
 file with the content being the serialized map item. So this is optimized
 for access to relatively large state objects, where storing a file on disk for
 each item in the map is not an issue.
Optionally, writing to disk can be deferred, such that each map update
 doesn't touch the disk immediately, but instead only when the 'DiskSync'
 IO action, returned by 'newDiskMap', is evaluated.
This database is ACID-compliant, although the durability property is lost
 if deferred disk write is enabled.
-}

module Data.DiskMap
(
DiskMap,
newDiskMap, addItem, getItem, updateStoredItem,
CreateResult(..),
mapGetItem, mapGetItems, MapItemResult(..),
updateIfRight,getResult,
getAllItems, getItemCount,
getFilteredItems, getFilteredKeys, getFilteredKV,
collectSortedItemsWhile,
SyncAction,isSynced,makeReadOnly,
Serializable(..),
ToFileName(..),

-- re-export
Hashable(..)
)
where

import Data.DiskMap.Types
import Data.DiskMap.Internal.Helpers
import Data.DiskMap.Sync.Sync
import Data.DiskMap.Sync.Deferred (syncToDiskNow)
import Data.DiskMap.Internal.Update (updateMapItem)

import qualified ListT as LT
import Data.Hashable
import Data.Maybe (isJust, isNothing, fromJust)
import Control.Monad.STM
import Control.Monad (forM, filterM, when)
import qualified  STMContainers.Map as Map
import Control.Concurrent.STM.TVar (newTVarIO, writeTVar)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar, tryTakeMVar)
import Data.List
import Data.Ord



-- |
newDiskMap :: (ToFileName k, Serializable v) =>
    FilePath -- ^ Directory where state files will be kept. The map is restored from this directory as well.
    -> Bool  -- ^ Don't sync to disk immediately on each map update, but instead return a sync IO action
             -- which, when evaluated, performs the sync.
             -- Any updates written to the map after evaluating the sync action are lost, unless the
             --  sync action is executed again, before destroying the map. The 'isSynced' function
             --  returns a boolean indicating whether the map in question is synced to disk, or contains
             --  unsyned updates.
    -> IO (DiskMap k v, Maybe SyncAction)  -- ^New map and, optionally, a sync IO action
newDiskMap syncDir deferSync = do
    -- Restore STMMap from disk files
    m <- channelMapFromStateFiles =<< diskGetStateFiles syncDir
    -- read-only TVar
    readOnly <- newTVarIO False
    -- Deferred sync map+busyVar (Note: work in progress)
    deferredSyncMap <- Map.newIO
    syncInProgress <- newMVar ()
    let syncState = SyncState deferredSyncMap syncInProgress
    let diskMap = DiskMap (MapConfig syncDir deferSync) m syncState readOnly
    -- Sync IO action
    let maybeSyncFunc =
            if deferSync then
                Just $ syncToDiskNow diskMap
            else
                Nothing
    return (diskMap, maybeSyncFunc)


-- |
getItem :: ToFileName k =>
    DiskMap k v -> k -> IO (Maybe v)
getItem m = atomically . getItem' m

-- |
addItem :: (ToFileName k, Serializable v) =>
    DiskMap k v -> k -> v -> IO CreateResult
addItem dm@(DiskMap _ m _ _) k v = do
    res <- fmap head $ updateMapItem dm $
        getItem' dm k >>= updateIfNotExist
    case res of
        ItemUpdated _ _ _ -> return Created
        NotUpdated  _ _ _ -> return AlreadyExists
        NoSuchItem        -> error "BUG: 'updateIfNotExist' should never return 'NoSuchItem'"
    where
        updateIfNotExist maybeItem = case maybeItem of
            Nothing   ->
                insertItem k v m >>
                return [ItemUpdated k v ()]    -- Doesn't already exist
            Just oldV ->
                return [NotUpdated  k oldV ()] -- Already exists

-- |
updateStoredItem :: (ToFileName k, Serializable v) =>
    DiskMap k v -> k -> v -> IO (MapItemResult k v ())
updateStoredItem m k v =
    mapGetItem m (const . Just $ v) k

-- |
mapGetItem :: (ToFileName k, Serializable v) =>
    DiskMap k v -> (v -> Maybe v) -> k -> IO (MapItemResult k v ())
mapGetItem dm f k = head <$> mapGetItems dm f ( return [k] )

-- |
mapGetItems :: (ToFileName k, Serializable v) =>
    DiskMap k v -> (v -> Maybe v) -> STM [k] -> IO [MapItemResult k v ()]
mapGetItems dm@(DiskMap _ _ _ _) f stmKeys = updateMapItem dm $ do
    keys <- stmKeys
    forM keys (mapStoredItem dm f)

-- | Update the value at the given key if the supplied function
--  applied to the value returns Right
updateIfRight :: (ToFileName k, Serializable v) =>
    DiskMap k v -> k -> (v -> Either r (v,r)) -> IO (MapItemResult k v r)
updateIfRight dm@(DiskMap _ m _ _) key updateFunc =
    head <$> updateMapItem dm (fmap (: []) stmAction)
    where
        updateOnRight oldVal = case updateFunc oldVal of
            Left  r          -> return $ NotUpdated key oldVal r
            Right (newVal,r) -> insertItem key newVal m >>
                                return (ItemUpdated key newVal r)
        stmAction = do
            maybeVal <- getItem' dm key
            case maybeVal of
                Just v -> updateOnRight v
                Nothing -> return NoSuchItem

-- |
getAllItems :: (ToFileName k, Serializable v) => DiskMap k v -> IO [v]
getAllItems (DiskMap _ m _ _) =
    atomically $ map (itemContent . snd) <$> LT.toList (Map.stream m)

-- | Scan through a sorted list of all items in the map, and accumulate items
--  to be returned while the scan function returns 'True'.
collectSortedItemsWhile :: (ToFileName k, Serializable v) =>
    DiskMap k v
    -> (v -> v -> Ordering) -- ^ Sort all items in the map by this function
    -> ([v] -> v -> Bool)   -- ^ Scan sorted items one-by-one, return True to accumulate and False to stop scanning and return all accumulated items
    -> STM [v]
collectSortedItemsWhile (DiskMap _ m _ _) sortFunc scanFunc =
    accumulateWhile scanFunc .
    sortBy sortFunc .
    map (itemContent . snd) <$>
        LT.toList (Map.stream m)

    -- User --
--- Interface ---

-- |
getItemCount :: DiskMap k v -> IO Integer
getItemCount (DiskMap _ m _ _) =
    atomically $ fromIntegral . length <$>
        LT.toList (Map.stream m)

-- |
getFilteredItems :: DiskMap k v -> (v -> Bool) -> STM [v]
getFilteredItems dm =
    fmap (map snd) . (getFilteredKV dm)

-- |
getFilteredKeys :: DiskMap k v -> (v -> Bool) -> STM [k]
getFilteredKeys dm =
    fmap (map fst) . (getFilteredKV dm)

-- |
getFilteredKV :: DiskMap k v -> (v -> Bool) -> STM [(k,v)]
getFilteredKV (DiskMap _ m _ _) filterBy =
    filter (filterBy . snd) . map (mapSnd itemContent) <$>
        LT.toList (Map.stream m)
            where mapSnd f (a,b)= (a,f b)

-- |Prevent further writes to the map. All write operations will throw an exception after
--  evaluating this function. Only the 'SyncNow' action may alter the map hereafter,
--  by deleting items from the map that were queued for deletion before enabling
--  read-only access.
makeReadOnly :: DiskMap k v -> IO ()
makeReadOnly (DiskMap _ _ _ readOnlyTVar) =
    atomically $ writeTVar readOnlyTVar True

-- |If 'f' applied to the value at 'k' in the map returns a Just value, then update the value
--  in the map to this value. Return information about what happened.
mapStoredItem :: (ToFileName k, Serializable v) =>
    DiskMap k v -> (v -> Maybe v) -> k -> STM (MapItemResult k v ())
mapStoredItem dm@(DiskMap _ m _ _) f k = do
    maybeItem <- getItem' dm k
    case maybeItem of
        Nothing  -> return NoSuchItem
        Just oldVal -> maybeUpdate
            where maybeUpdate =
                    case f oldVal of
                        Just newVal ->
                            updateItem m k newVal >>
                            return (ItemUpdated k newVal ())
                        Nothing ->
                            return (NotUpdated  k oldVal ())

-- | Only relevant for deferred sync
isSynced :: DiskMap k v -> IO Bool
isSynced (DiskMap (MapConfig _ True) _ (SyncState deferredSyncMap _) _) =
    atomically $ (== 0) . length <$> LT.toList (Map.stream deferredSyncMap)
-- If deferred sync is disabled, the map is always in sync with disk
isSynced (DiskMap (MapConfig _ False) _ _ _) = return True






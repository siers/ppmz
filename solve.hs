{-# LANGUAGE TupleSections, NamedFieldPuns, BinaryLiterals, TemplateHaskell, CPP #-}

{-# LANGUAGE StrictData, BangPatterns #-}
{-# OPTIONS_GHC -O #-}

#ifndef TRACE
#define TRACE 0
#endif

#ifndef FREQ
#define FREQ 3000
#endif

module Main where

-- solver

import Control.Lens ((&), (%~), (.~), set, view, _1, _2)
import Control.Lens.TH
import Control.Monad.Extra (allM, whenM)
import Control.Monad (join, mplus, mfilter, filterM, void)
import Control.Monad.Primitive (RealWorld)
import Data.Foldable (fold)
import Data.Function (on)
import Data.List (find, elemIndex, foldl', nub)
import Data.Map (Map, (!))
import Data.Maybe (fromMaybe, fromJust)
import Data.Monoid (Sum(..))
import Data.Set (Set)
import Data.Tuple.Extra (dupe)
import Data.Tuple (swap)
import Data.Vector.Mutable (MVector)
import Data.Word (Word8)
import Debug.Trace (trace)
import qualified Data.Bits as Bit
import qualified Data.Map as Map
import qualified Data.Set as S
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import System.Environment (lookupEnv, getArgs)
import System.IO.Unsafe
import Text.Printf (printf)

-- IO

import Data.Foldable (traverse_)
import Data.Text (Text)
import Network.Socket (withSocketsDo)
import qualified Data.Text as T
import qualified Network.WebSockets as WS

t a = seq (trace (show a) a) a
t' l a = seq (trace (show l ++ ": " ++ show a) a) a
tM :: (Functor f, Show a) => f a -> f a
tM = fmap t

type Direction = Int -- top 0, right 1, bottom 2, left 3
type Rotation = Int
type Pix = Word8 -- directions as exponents of 2, packed in a byte, mirrored in (shiftL 4) to help bit rotation
type Cursor = (Int, Int)

-- PartId distinguishes the connected graphs (partitions) by their
-- smallest cursor (unique by def. ascending order)
-- They're marked ahead of solveds, so Continue{direct=false} may already be connected.
type PartId = Cursor

data Piece = Piece
  { pipe :: Pix
  , solved :: Bool
  , partId :: PartId -- meaningless if not connected
  , connected :: Bool -- connected when pointed
  } deriving Show

type PieceDelta = (Piece, Cursor, Direction)

data MMaze = MMaze -- Mutable Maze
  { board :: MVector RealWorld Piece
  , width :: Int
  , height :: Int
  }

-- Continue represents the piece that should be solved next
-- Continues in Progress may turn out to be already solved, which must be checked
data Continue = Continue
  { cursor :: Cursor
  , char :: Pix -- defaulted to ' ', but set when guessing
  , origin :: PartId
  , direct :: Bool -- created by direct pointing from a solved piece
  , score :: Int
  , created :: Int -- unique ID for Ord, particularly: created = Progress.iter
  } deriving Show

type Score = (Int, Int) -- score, created

type Priority = Map Score Continue
type Continues = Map Cursor Continue
type Components = Map PartId Int

type Unwind1 = (Cursor, Piece)
type Unwind = [Unwind1]

data Progress = Progress
  { iter :: Int -- the total number of backtracking iterations (incl. failed ones)
  , depth :: Int -- number of solves, so also the length of unwinds/space
  , priority :: Priority -- priority queue for next guesses (not a heap, because of reprioritizing)
  , continues :: Continues -- for finding if continue exists already in Priority
  , components :: Components -- unconnected network continue count
  , space :: [[(Continue, Progress)]] -- unexplored solution space. enables parallelization. item per choice, per cursor.
  , unwinds :: [Unwind] -- history, essentially. an item per a solve. pop when (last space == [])
  , maze :: MMaze
  }

makeLensesFor ((\n -> (n, n ++ "L")) <$> ["cursor", "char", "origin", "direct", "score", "created"]) ''Continue
makeLensesFor ((\n -> (n, n ++ "L")) <$> ["iter", "depth", "priority", "continues", "components", "space", "unwinds", "maze"]) ''Progress

instance Show Progress where
  show ps@Progress{iter, priority} =
    "Progress" ++ show (iter, length priority)

instance Show MMaze where
  show _ = "MMaze"

{--- Generic functions ---}

-- | Monadic 'dropWhile' from monad-loops package
dropWhileM :: (Monad m) => (a -> m Bool) -> [a] -> m [a]
dropWhileM _ []     = return []
dropWhileM p (x:xs) = p x >>= \q -> if q then dropWhileM p xs else return (x:xs)

{--- MMaze and Matrix operations ---}

parse :: String -> IO MMaze
parse input = do
  board <- V.thaw . V.fromList . map (\c -> Piece c False (0, 0) False) . join $ rect
  maze <- pure (MMaze board (length (head rect)) (length rect))
  maze <$ mazeMap maze (\c p -> p { partId = c })
  where rect = filter (not . null) . map (map toPix) . lines $ input

mazeStore :: MMaze -> String -> IO ()
mazeStore m label = writeFile label =<< renderStr m

mazeBounded :: MMaze -> Cursor -> Bool
mazeBounded MMaze{width, height} (!x, !y) = x >= 0 && y >= 0 && width > x && height > y

{-# INLINE mazeSize #-}
mazeSize :: MMaze -> Int
mazeSize MMaze{width, height} = width * height

vectorLists :: Int -> Int -> V.Vector a -> [[a]]
vectorLists width height board = [ [ board V.! (x + y * width) | x <- [0..width - 1] ] | y <- [0..height - 1] ]

mazeLists :: MMaze -> IO [[Piece]]
mazeLists MMaze{board, width, height} = vectorLists width height . V.convert <$> V.freeze board

mazeCursor :: MMaze -> Int -> Cursor
mazeCursor MMaze{width} = swap . flip quotRem width

{-# INLINE mazeRead #-}
mazeRead :: MMaze -> Cursor -> IO Piece
mazeRead MMaze{board, width} (x, y) = MV.unsafeRead board (x + y * width)

{-# INLINE mazeCursorSolved #-}
mazeCursorSolved :: MMaze -> Cursor -> IO Bool
mazeCursorSolved MMaze{board, width} (x, y) = solved <$> MV.unsafeRead board (x + y * width)

mazeModify :: MMaze -> (Piece -> Piece) -> Cursor -> IO ()
mazeModify m@MMaze{board, width} f (x, y) = MV.unsafeModify board f (x + y * width)

mazeMap :: MMaze -> (Cursor -> Piece -> Piece) -> IO ()
mazeMap m@MMaze{board, width, height} f =
  void . traverse (\cursor -> mazeModify m (f cursor) cursor) . join $
    [ [ (x, y) | x <- [0..width - 1] ] | y <- [0..height - 1] ]

mazeClone :: MMaze -> IO MMaze
mazeClone m@MMaze{board} = (\board -> m { board }) <$> MV.clone board

mazeSolve :: MMaze -> Continue -> IO Unwind1
mazeSolve m Continue{char, cursor} =
  (cursor, ) <$> mazeRead m cursor <* mazeModify m (\p -> p { pipe = char, solved = True }) cursor

mazeEquate :: MMaze -> PartId -> [Cursor] -> IO Unwind
mazeEquate m partId cursors =
  traverse (\c -> (c, ) <$> mazeRead m c) cursors
  <* traverse (mazeModify m (\p -> p { partId, connected = True })) cursors

mazePop :: MMaze -> Unwind -> IO ()
mazePop m@MMaze{board, width} unwind = do
  uncurry (flip (mazeModify m . const)) `traverse_` unwind

-- lookup fixed point (ish) in maze by PartId lookup, stops at first cycle
partEquate :: MMaze -> PartId -> IO PartId
partEquate maze@MMaze{board} v = loop' =<< find v
  where
    find f = (\Piece{connected, partId} -> if connected then partId else f) <$> mazeRead maze f
    loop' v' = (\found -> if v' == v || v' == found then pure v' else loop' found) =<< find v'

partEquateUnsafe :: MMaze -> PartId -> PartId
partEquateUnsafe m p = unsafePerformIO $ partEquate m p

{--- Rendering, tracing ---}

renderWithPositions :: Maybe Continue -> Progress -> IO String
renderWithPositions current Progress{depth, maze=maze@MMaze{board, width, height}, priority} =
  unlines . map concat . vectorLists width height . V.imap fmt . V.convert <$> V.freeze board
  where
    colorHash = (+15) . (\(x, y) -> x * 67 + y * 23)

    color256 = (printf "\x1b[38;5;%im" . ([24 :: Int, 27..231] !!)) . (`mod` 70) . colorHash :: Cursor -> String
    colorPart cur Piece{solved, partId} = if solved then Just (color256 $ partEquateUnsafe maze partId) else Nothing

    -- color256 = (printf "\x1b[38;5;%im" . (\c -> if c == 15 then 8 :: Int else 9)) . colorHash :: Cursor -> String
    -- colorPart cur Piece{solved, partId} = if solved then Just (color256 $ partId) else Nothing

    colorHead cur = printf "\x1b[31m" <$ ((cur ==) `mfilter` (cursor <$> current))
    colorContinues cur = printf "\x1b[32m" <$ find ((cur ==) . cursor) priority
    -- colorContinues cur = color256 . origin <$> find ((cur ==) . cursor) priority

    color :: Cursor -> Piece -> Maybe String
    -- color cur piece = colorHead cur `mplus` colorContinues cur
    color cur piece = colorHead cur `mplus` colorPart cur piece `mplus` colorContinues cur

    fmt idx piece@Piece{pipe} =
      printf $ fromMaybe (toChar pipe : []) . fmap (\c -> printf "%s%c\x1b[39m" c (toChar pipe)) $ color (mazeCursor maze idx) piece

render :: MMaze -> IO ()
render = (putStrLn =<<) . renderWithPositions Nothing . Progress 0 0 Map.empty Map.empty Map.empty [] []

renderStr :: MMaze -> IO String
renderStr MMaze{board, width, height} = do
  unlines . map concat . vectorLists width height . V.map (return . toChar . pipe) . V.convert
  <$> V.freeze board

traceBoard :: Continue -> Progress -> IO Progress
traceBoard current progress@Progress{iter, depth, maze=maze@MMaze{board}} = do
  let mode = TRACE
  let freq = FREQ
  tracer mode freq *> pure progress
  where
    tracer mode freq -- reorder/comment out clauses to disable tracing
      | iter `mod` freq == 0 && mode == 1 = pure solvedStr >>= putStrLn
      | iter `mod` freq == 0 && mode == 2 = ((clear ++) <$> traceStr) >>= putStrLn
      | iter `mod` freq == 0 && mode == 3 = traceStr >>= putStrLn
      | True = pure ()

    percentage = (fromIntegral $ depth) / (fromIntegral $ mazeSize maze)
    ratio = (fromIntegral iter / fromIntegral depth :: Double)
    solvedStr = printf "\x1b[2Ksolved: %02.2f%%, ratio: %0.2f\x1b[1A" (percentage * 100 :: Double) ratio :: String

    stats = (show iter ++ "/" ++ show depth ++ " at " ++ show (cursor current) ++ "\n")
    clear = "\x1b[H\x1b[2K" -- move cursor 1,1; clear line
    traceStr = renderWithPositions (Just current) progress

{--- Model ---}

directions = [0, 1, 2, 3]
rotations = directions

(pixWall, pixUnset) = (0, 0)
charMapEntries = map (_2 %~ (byteify . bitify))
  [ ('╹', [0])
  , ('┗', [0,1])
  , ('┣', [0,1,2])
  , ('╋', [0,1,2,3])
  , ('┻', [0,1,3])
  , ('┃', [0,2])
  , ('┫', [0,2,3])
  , ('┛', [0,3])
  , ('╺', [1])
  , ('┏', [1,2])
  , ('┳', [1,2,3])
  , ('━', [1,3])
  , ('╻', [2])
  , ('┓', [2,3])
  , ('╸', [3])
  , (' ', []) -- chars outside the map
  ]
  where
    bitify = foldr (\exp sum -> 2 ^ exp + sum) 0 . map fromIntegral :: [Direction] -> Pix
    byteify = (\bitified -> bitified + Bit.shiftL bitified 4) :: Pix -> Pix

charMap :: Map Char Pix
charMap = Map.fromList charMapEntries

pixMap :: Map Pix Char
pixMap = Map.fromList $ map swap charMapEntries

pixRotations :: Pix -> [Rotation]
pixRotations 0b11111111 = [0]
pixRotations 0b10101010 = [0,1]
pixRotations 0b01010101 = [0,1]
pixRotations _ = rotations

pixDirections :: Pix -> [Direction]
pixDirections n = fold
  [ if n `Bit.testBit` 0 then [0] else []
  , if n `Bit.testBit` 1 then [1] else []
  , if n `Bit.testBit` 2 then [2] else []
  , if n `Bit.testBit` 3 then [3] else []
  ]

toPix = (charMap !) :: Char -> Pix
toChar = (pixMap !) :: Pix -> Char

rotate :: Rotation -> Pix -> Pix
rotate = flip Bit.rotateL

cursorDelta :: Cursor -> Direction -> Cursor
cursorDelta (x, y) 0 = (x, y - 1)
cursorDelta (x, y) 1 = (x + 1, y)
cursorDelta (x, y) 2 = (x, y + 1)
cursorDelta (x, y) 3 = (x - 1, y)
cursorDelta _ _      = error "only defined for 4 directions"

mazeDeltas :: MMaze -> Cursor -> [Direction] -> IO [PieceDelta]
mazeDeltas m c directions =
  traverse (_1 (mazeRead m))
  . filter (mazeBounded m . (view _1))
  $ (\d -> (cursorDelta c d, cursorDelta c d, d)) `map` directions

mazeDeltasWalls :: MMaze -> Cursor -> IO [(Piece, Direction)]
mazeDeltasWalls m c = traverse (mazeDeltaWall m c) directions

{-# INLINE mazeDeltaWall #-}
mazeDeltaWall :: MMaze -> Cursor -> Direction -> IO (Piece, Direction)
mazeDeltaWall m !c !dir =
  if mazeBounded m delta
  then (, dir) <$> mazeRead m delta
  else pure (Piece 0 True (0, 0) True, dir)
  where
    delta = cursorDelta c dir

{--- Solver bits ---}

-- given current pixel at rotation, does it match the pixel at direction from it?
pixValid :: (Pix, Pix, Rotation, Direction) -> Bool
pixValid (!this, !that, !rotation, !direction) =
  not $ (rotate rotation this `Bit.xor` rotate 2 that) `Bit.testBit` direction

{-# INLINE validateDirection #-}
validateDirection :: Pix -> Rotation -> (Piece, Direction) -> Bool
validateDirection this rotation (Piece{pipe=that, solved}, direction) = do
  not solved || pixValid (this, that, rotation, direction)

validateRotation :: Pix -> [(Piece, Direction)] -> Rotation -> Bool
validateRotation this deltas rotation = all (validateDirection this rotation) deltas

{-# INLINE validateRotationM #-}
validateRotationM :: MMaze -> Cursor -> Pix -> Rotation -> IO Bool
validateRotationM maze cursor this rotation =
  (fmap (validateDirection this rotation) . mazeDeltaWall maze cursor) `allM` directions

pieceRotations :: MMaze -> Cursor -> IO [Pix]
pieceRotations maze@MMaze{board} cur = do
  Piece{pipe=this} <- mazeRead maze cur
  fmap (map (flip rotate this)) . filterM (validateRotationM maze cur this) $ pixRotations this

pieceRotationCount :: MMaze -> Cursor -> IO Int
pieceRotationCount maze@MMaze{board} cur = do
  Piece{pipe=this} <- mazeRead maze cur
  fmap length . filterM (validateRotationM maze cur this) $ pixRotations this

cursorToContinue :: MMaze -> Int -> Continue -> (PieceDelta, Int) -> IO Continue
cursorToContinue maze iter Continue{char, origin} ((_, !c@(x, y), !direction), index) = do
  choices <- pieceRotationCount maze c
  let
    direct = char `Bit.testBit` direction
    origin' = if direct then origin else c
    scoreCoeff = 15
    score = (x + y + choices * scoreCoeff)
  pure $ Continue c pixUnset origin' direct score (iter * 4 + index)

updatePriority :: Progress -> Continue -> IO ((Priority, Components), Continues)
updatePriority
  progress@Progress{iter, depth, maze=maze@MMaze{board}, priority, continues, components}
  continue@Continue{cursor=cur} = do
    deltas <- filter (not . solved . view _1) <$> mazeDeltas maze cur directions
    next <- traverse (cursorToContinue maze iter continue) (zip deltas [0..])
    pure $ foldl'
      (\(acc, continues) c@Continue{cursor} -> Map.alterF (insertContinue acc c) cursor continues)
      ((priority, components), continues)
      next
  where
    cinsert c = Map.insert (cscore c) c :: Priority -> Priority
    cscore Continue{score, created} = (score, created)
    insertContinue :: (Priority, Components) -> Continue -> Maybe Continue -> ((Priority, Components), Maybe Continue)
    insertContinue (p, c) new@Continue{origin} Nothing = ((cinsert new p, Map.insertWith (+) origin 1 c), Just new)
    insertContinue (p, c) new@Continue{score, origin} (Just exists@Continue{origin=oldOrigin}) =
      let
        (newOrigin, putback) = originL (dupe . min origin) exists { score }
        contModify = if cscore new < cscore exists then cinsert putback . Map.delete (cscore exists) else id
      in ((contModify p, c), Just putback)

componentRemove :: PartId -> Components -> Components
componentRemove part c = Map.update (\a -> if a == 0 then Nothing else Just (a - 1)) part c

componentEquate :: PartId -> [PartId] -> Components -> IO Components
componentEquate partId join c =
  let
    extract (sum, m) part = Map.alterF ((, Nothing) . mappend sum . foldMap Sum) part m
    (Sum sum, components) = foldl' extract (Sum 0, c) join
  in pure $ Map.insertWith (+) partId sum components

pieceDead :: MMaze -> Components -> (Continue, Priority) -> IO Bool
pieceDead maze@MMaze{board} components (continue@Continue{cursor=cur, char=this}, priority) = do
  thisPart <- partEquate maze . partId =<< mazeRead maze cur
  ((Just 1 == Map.lookup thisPart components) &&) <$> stuck
  where stuck = allM (fmap solved . mazeRead maze . cursorDelta cur) (pixDirections this)

progressPop :: Progress -> IO Progress
progressPop p@Progress{maze, unwinds=(unwind:unwinds)} = do
  p { unwinds } <$ mazePop maze unwind

{--- Solver ---}

-- Solves a valid piece, mutates the maze and sets unwind
solveContinue :: Progress -> Continue -> IO Progress
solveContinue
  progress@Progress{iter, depth, maze=maze@MMaze{board}, priority, continues, components}
  continue@Continue{cursor=cur, char=this, origin} = do
    unwindThis <- mazeSolve maze continue
    thisPart <- partEquate maze origin
    neighbours <- fmap (nub . (thisPart :)) . traverse (partEquate maze) . map (cursorDelta cur) $ (pixDirections this)
    origin' <- pure . minimum $ neighbours
    components' <- componentEquate origin' (filter (/= origin') (nub neighbours)) (componentRemove thisPart components)
    unwindEquate <- mazeEquate maze origin' neighbours
    ((newPriority, newComponents), newContinues) <- updatePriority progress { components = components' } continue { origin = origin' }

    traceBoard continue $ progress
      & iterL %~ (+1)
      & depthL %~ (+1)
      & priorityL .~ newPriority
      & continuesL .~ newContinues
      & componentsL .~ newComponents
      & unwindsL %~ ((unwindEquate ++ [unwindThis]) :)

findContinue :: Progress -> IO (Progress, Continue)
findContinue p@Progress{maze, priority, continues} = do
  pure . (, continue) $ p { priority = priority' , continues = Map.delete cursor continues }
  where ((_, continue@Continue{cursor}), priority') = Map.deleteFindMin priority

-- Solves pieces by backtracking, stops when maze is solved.
solve' :: Progress -> IO Progress
-- solve' Progress{priority=[]} = error "unlikely"
solve' progressInit@Progress{iter, depth, maze} = do
  (progress@Progress{priority, continues, components}, continue) <- findContinue progressInit

  rotations <- pieceRotations maze (cursor continue)
  guesses <- removeDead components . map ((, progress) . ($ continue) . set charL) $ rotations
  progress' <- uncurry solveContinue =<< backtrack . (spaceL %~ (guesses :)) =<< pure progress

  (if last then pure else solve') progress'
  where
    last = depth == mazeSize maze - 1
    removeDead components = if last then pure else filterM (fmap not . pieceDead maze components . (_2 %~ priority))

    backtrack :: Progress -> IO (Progress, Continue)
    backtrack Progress{space=[]} = error "unlikely" -- for solvable mazes
    backtrack p@Progress{space=([]:space)} = progressPop p { space } >>= backtrack
    backtrack p@Progress{space=(((continue, Progress{depth, priority, continues, components}):guesses):space)} =
      pure (p { depth, priority, continues, components, space = guesses : space }, continue)

solve :: MMaze -> IO MMaze
solve m = do
  solved@Progress{iter, depth} <- solve' $
    Progress 0 0 (Map.singleton (0, 0) (Continue (0, 0) pixUnset (0, 0) True 0 0)) Map.empty (Map.fromList [((0, 0), 1)]) [] [] m
  putStrLn (printf "%i/%i, ratio: %0.5f" iter depth (fromIntegral iter / fromIntegral depth :: Double))
  pure (maze solved)

verify :: MMaze -> IO Bool
verify maze = do
  (mazeSize maze ==) <$> partFollow maze S.empty [(0, 0)]
  where
    partFollow :: MMaze -> Set Cursor -> [Cursor] -> IO Int
    partFollow maze visited [] = pure (S.size visited)
    partFollow maze visited (cursor:next) = do
      this <- pipe <$> mazeRead maze cursor
      valid <- validateRotation this <$> mazeDeltasWalls maze cursor <*> pure 0
      if not valid
      then pure (S.size visited)
      else do
        deltas <- mazeDeltas maze cursor (pixDirections this)
        deltas' <- filter (not . flip S.member visited) . map (view _2) <$> pure deltas
        partFollow maze (S.insert cursor visited) (deltas' ++ next)

storeBad :: Int -> MMaze -> MMaze -> IO MMaze
storeBad level original solved = do
  whenM (fmap not . verify $ solved) $ do
    putStrLn (printf "storing bad level %i solve" level)
    mazeStore original ("samples/bad-" ++ show level)
  pure solved

{--- Main ---}

rotateStr :: MMaze -> MMaze -> IO Text
rotateStr input solved = concatenate <$> rotations input solved
  where
    concatenate :: [(Cursor, Rotation)] -> Text
    concatenate =
      (T.pack "rotate " <>) . T.intercalate (T.pack "\n")
      . (>>= (\((x, y), r) -> replicate r (T.pack (printf "%i %i" x y))))

    rotations :: MMaze -> MMaze -> IO [(Cursor, Rotation)]
    rotations maze@MMaze{board=input, width, height} MMaze{board=solved} = do
      V.toList . V.imap (\i -> (mazeCursor maze i, ) . uncurry (rotations `on` pipe))
      <$> (V.zip <$> V.freeze input <*> V.freeze solved)
      where
        rotations from to = fromJust $ to `elemIndex` iterate (rotate 1) from

pļāpātArWebsocketu :: WS.ClientApp ()
pļāpātArWebsocketu conn = traverse_ solveLevel [1..6]
  where
    send = WS.sendTextData conn
    recv = T.unpack <$> WS.receiveData conn

    solveLevel level = do
      send (T.pack $ "new " ++ show level)
      recv

      send (T.pack "map")
      maze <- parse . T.unpack . T.drop 5 =<< WS.receiveData conn

      send =<< rotateStr maze =<< storeBad level maze =<< solve =<< mazeClone maze
      recv

      send (T.pack "verify")
      putStrLn =<< recv

solveFiles :: String -> IO ()
solveFiles file = do
  solve <- solve =<< parse =<< readFile file
  whenM (not <$> verify solve) (putStrLn "solution invalid")

main :: IO ()
main = do
  websocket <- (== "1") . fromMaybe "0" <$> lookupEnv "websocket"

  if websocket
  then withSocketsDo $ WS.runClient "maze.server.host" 80 "/game-pipes/" pļāpātArWebsocketu
  else traverse_ solveFiles . (\args -> if null args then ["/dev/stdin"] else args) =<< getArgs

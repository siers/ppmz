{-# LANGUAGE TupleSections, NamedFieldPuns, BinaryLiterals, TemplateHaskell, CPP, ScopedTypeVariables, NumericUnderscores #-}

{-# LANGUAGE StrictData, BangPatterns #-}
{-# OPTIONS_GHC -O #-}

{-# OPTIONS_GHC -Wall -Wno-name-shadowing -Wno-unused-do-bind -Wno-type-defaults -Wno-missing-signatures #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-} -- complains about lens :/

-- json
{-# LANGUAGE DeriveGeneric #-}

{-|
Module      : Pipemaze
Description : solves pipe mazes
Copyright   : (c) siers
License     : GPL-3
Maintainer  : wimuan@email.com
Stability   : experimental
Portability : POSIX

A dynamic solver of pipe mazes with an internal 'priority' queue based on scores, position and priority creation order.

The goal of the solver is to find the rotation of each piece in the grid to create a connected graph.
The number of valid rotations of a piece will be called 'choices'. Disconnected graphs that will have to be connected
to the other graphs later are being refered to as /components/. <https://en.wikipedia.org/wiki/Component_(graph_theory)>

Solving each piece gives you hints about nearby pieces,
so solving them in our order('rescoreContinue') is more effective than solving in an arbitrary order. If the connectivity of the pieces is efficiently
computed ('PartId' \/ 'partEquate'), the "open ends" ('Continues') have a good prioritization and the partial solutions on disconnected components
are immediately discarded ('pieceDead' \/ 'compAlive'), the /visited piece/ ratio to /maze size/ is rather small (<4)
for these specific mazes from the maze server.

This combined lets you solve around 98% of the level 6 maze determinstically, but the priority after that (many unsolved islands) is not yet optimal.
-}

#ifndef TRACE
#define TRACE 1
#endif

#define FREQ_DEF 3_000
#ifndef FREQ
#define FREQ FREQ_DEF
#endif

module Pipemaze (
  -- * Types
  Direction, Rotation, Pix, Cursor, MMaze(..), Piece(..), PartId, Continue(..)
  , Priority, Continues, Components(..), Unwind, Progress(..)
  , IslandId, Island
  -- * Maze operations
  , parse, mazeStore, mazeBounded, mazeRead, mazeSolve, mazeDelta, mazeEquate, mazePop, partEquate
  -- * Tracing and rendering
  , renderImage'
  , traceBoard
  -- * Pixel model
  , charMap, pixMap, pixRotations, pixDirections, toPix, toChar, rotate
  -- * Pixel solving
  , pixValid, validateDirection, pieceRotations
  -- * Component indexing
  , compInsert, compRemove, compEquate, compAlive, compConnected
  -- * Continue operations
  , cursorToContinue, prioritizeDeltas, prioritizeIslands, rescoreContinue, prioritizeContinues
  , pieceDead, findContinue
  -- * Island computations
  , FillNext, flood, islandize, islands, graphIslands, previewIslands
  -- * Solver brain
  , solveContinue, solve', initProgress, backtrack, solve
  -- * Main
  , verify, storeBad, rotateStr, pļāpātArWebsocketu, solveFile, main
) where

-- solver

import Control.Lens.Internal.FieldTH (makeFieldOptics, LensRules(..))
import Language.Haskell.TH.Syntax (mkName, nameBase)
import Control.Lens.TH (DefName(..), lensRules)

import Control.Lens ((&), (%~), set, _2, _3, traverseOf)
import Control.Monad.Extra (allM, whenM, ifM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (join, filterM, void, when, mfilter)
import Control.Monad.Primitive (RealWorld)
import Control.Monad.Trans.State.Strict (StateT(..))
import Data.Bifunctor (bimap)
import Data.Char (ord)
import Data.Foldable (fold, traverse_, for_, foldrM)
import Data.Function (on)
import Data.IntMap.Strict (IntMap)
import Data.List (elemIndex, foldl')
import Data.List.Extra (nubOrd)
import Data.Map.Strict (Map, (!))
import Data.Maybe (fromMaybe, fromJust, isJust)
import Data.Monoid (Sum(..))
import Data.Set (Set)
import Data.Traversable (for)
import Data.Tuple (swap)
import Data.Vector.Mutable (MVector)
import Data.Word (Word8)
-- import Debug.Trace (trace)
import Graphics.Image.Interface (thaw, MImage, freeze, write)
import Graphics.Image (writeImage, makeImageR, Pixel(..), toPixelRGB, VU(..), RGB)
import Numeric (showHex)
import qualified Control.Monad.Trans.State.Strict as State
import qualified Data.Bits as Bit
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import System.Environment (lookupEnv, getArgs)
import Text.Printf (printf)

-- graph debug
import Data.Graph.Inductive.Graph (Graph(..))
import Data.Graph.Inductive.PatriciaTree (Gr)
import Data.GraphViz (GraphvizCanvas(..), GraphvizCommand(..), GraphvizParams(..), GraphvizOutput(..))
import Data.GraphViz.Attributes.Colors (WeightedColor(..))
import Data.GraphViz.Attributes.Complete (Color(..), Attribute(..), Shape(..), Overlap(..), EdgeType(..), DPoint(..), createPoint)
import Data.GraphViz (runGraphvizCanvas, runGraphvizCommand, graphToDot, nonClusteredParams)
import Control.Concurrent (forkIO)

-- json for debug outputs
import Data.Aeson (ToJSON(..))
-- import qualified Data.Aeson as Aeson
-- import qualified Data.ByteString.Lazy.Char8 as LBS
import GHC.Generics (Generic)

-- IO

import Data.Text (Text)
import Network.Socket (withSocketsDo)
import qualified Data.Text as T
import qualified Network.WebSockets as WS

-- t a = seq (trace (show a) a) a
-- t' l a = seq (trace (show l ++ ": " ++ show a) a) a
-- tM :: (Functor f, Show a) => f a -> f a
-- tM = fmap t

-- | Directions: top 0, right 1, bottom 2, left 3
type Direction = Int
-- | The set of rotation values are the same as directions.
type Rotation = Int
-- | The maze symbol bit-packed in 'charMap' as @2^d@ per direction, mirrored in @shiftL 4@ to help bit rotation
--
-- > I – ━, ┃
-- > L – ┏, ┛, ┓, ┗
-- > T – ┣, ┫, ┳, ┻
-- > X – ╋
-- > i – ╸, ╹, ╺, ╻
type Pix = Word8
type Cursor = (Int, Int)

-- | Mutable maze operated on by functions in section /"Maze operations"/
data MMaze = MMaze
  { board :: MVector RealWorld Piece -- ^ flat MVector with implied 2d structure via 'Cursor' + index computations
  , width :: Int
  , height :: Int
  , size :: Int
  , sizeLen :: Int -- ^ leading char count for @printf %0ni@ format @(~logBase 10 size + 1.5)@
  , level :: Int
  , trivials :: [Cursor] -- ^ cursors of the edge and @X@ pieces which have only one valid rotation
  , mazeId :: String -- ^ 'board's data scrambled into a 4-byte hexadecimal field
  }

data Piece = Piece
  { pipe :: Pix
  , solved :: Bool
  , partId :: PartId -- ^ meaningless if not connected
  , connected :: Bool -- ^ connected when pointed to by a 'solved' piece
  , wasIsland :: Bool -- ^ was this solved by an island 'Continue'?
  , inland :: Bool -- ^ deltas are bounded, if this is an inland piece (not on the edge)
  } deriving (Generic, Show)

-- Continue represents the piece that should be solved next, which is an open end of a component.
-- Continues in Progress may turn out to be already solved, which must be checked
data Continue = Continue
  { cursor :: Cursor
  , char :: Pix -- ^ defaulted to 0 (i.e. ' '), but set when guessing in 'solve\''
  , origin :: PartId -- ^ component id, to be used with 'partEquate'
  , score :: Int -- ^ see 'rescoreContinue'
  , created :: Int -- ^ any unique id to make score order total ('Ord' requirement), taken from 'iter'
  , island :: Int -- ^ > 0 if island
  , area :: Int -- ^ island area, 0 if not an island
  , choices :: Int -- ^ number of valid rotations
  } deriving (Generic, Show)

-- | 'PartId' distinguishes the graph component by their smallest known 'Cursor' by its 'Ord' (unique),
-- so it is the same as its cursor initially. They're marked in 'origin' ahead of 'solved's.
-- 'PartId' in 'origin' is only to be used through 'partEquate', because 'origin' isn't being
-- updated after components have connected.
type PartId = Cursor

-- | 'Continue' priority queue, inserted by 'prioritizeContinues', popped by 'findContinue'
type Priority = IntMap Cursor
-- | Primary storage of 'Continue' data
type Continues = Map Cursor Continue
-- | The index of components' continues by their 'PartId' (which are always up-to-date).
data Components
  = Components (Map PartId Int) -- ^ marginally faster, but less info
  | Components' (Map PartId (Set Cursor))
  deriving (Show, Generic)

-- | For mutable backtracking
type Unwind = (Cursor, Piece)

-- | Unique arbitrary value
type IslandId = Int
type Island = (IslandId, Int, [Continue]) -- ^ id, size, borders

data Progress = Progress
  { iter :: Int -- ^ the total number of backtracking iterations (incl. failed ones)
  , depth :: Int -- ^ number of solves, so also the length of unwinds/space
  , priority :: Priority -- ^ priority queue for next guesses (tree, not a heap, because reprioritizing is required)
  , continues :: Continues -- ^ Primary continue store, pointed to by 'priority' (all 'Continue's within must be unique by their cursor)
  , components :: Components -- ^ component continue counts (for quickly computing disconnected components via `compAlive`)
  , space :: [[(Continue, Progress)]] -- ^ unexplored solution stack, might help with parallelization; item per choice, per cursor. must be non-empty
  , unwinds :: [[Unwind]] -- ^ backtracking's "rewind"; an item per a solve. pop when (last 'space' == [])
  , maze :: MMaze
  }

makeFieldOptics lensRules { _fieldToDef = (\_ _ -> (:[]) . TopName . mkName . (++ "L") . nameBase) } ''Continue
makeFieldOptics lensRules { _fieldToDef = (\_ _ -> (:[]) . TopName . mkName . (++ "L") . nameBase) } ''Progress
makeFieldOptics lensRules { _fieldToDef = (\_ _ -> (:[]) . TopName . mkName . (++ "L") . nameBase) } ''MMaze

-- | unlawful
instance Show Progress where
  show Progress{iter, priority} =
    "Progress" ++ show (iter, length priority)

-- | unlawful
instance Show MMaze where
  -- | unlawful instance
  show _ = "MMaze"

instance ToJSON Piece
instance ToJSON Continue
instance ToJSON Components

{--- MMaze and Matrix operations ---}

parse :: String -> IO MMaze
parse input = do
  maze <- (\b -> (MMaze b width height size zeros level [] mazeId)) <$> V.thaw (V.fromList (map snd board))
  (trivialsL (\_ -> trivials maze)) maze
  where
    mazeId = showHex (foldr (\a b -> (ord a + b) `mod` (2 ^ 16)) 0 input) ""
    rect :: [[Pix]] = filter (not . null) . map (map toPix) . lines $ input
    board = map piece . zip [0..] . join $ rect
    piece (i, c) = (i, Piece c False (mazeCursor width i) False False (not (edge (mazeCursor width i))))
    edge (x, y) = ((x + 1) `mod` width) < 2 || ((y + 1) `mod` height) < 2
    trivials :: MMaze -> IO [Cursor]
    trivials maze = map (mazeCursor width . fst) <$> filterM (trivial maze) board
    trivial maze (i, Piece{pipe, inland}) =
      if inland then pure (pipe == 0b11111111) else (< 2) <$> pieceRotationCount maze (mazeCursor width i)

    (width, height) = (length (head rect), (length rect))
    size = width * height
    zeros = floor (logBase 10 (fromIntegral size) + 1.5)
    level = fromMaybe 0 (lookup width [(8,1), (25,2), (50,3), (200,4), (400,5), (1000,6)])

mazeStore :: MMaze -> String -> IO ()
mazeStore m label = writeFile label =<< renderStr m

{-# INLINE mazeBounded #-}
mazeBounded :: MMaze -> Cursor -> Bool
mazeBounded MMaze{width, height} (!x, !y) = x >= 0 && y >= 0 && width > x && height > y

vectorLists :: Int -> Int -> V.Vector a -> [[a]]
vectorLists width height board = [ [ board V.! (x + y * width) | x <- [0..width - 1] ] | y <- [0..height - 1] ]

mazeCursor :: Int -> Int -> Cursor
mazeCursor width = swap . flip quotRem width

{-# INLINE mazeRead #-}
mazeRead :: MMaze -> Cursor -> IO Piece
mazeRead MMaze{board, width} (x, y) = MV.unsafeRead board (x + y * width)

{-# INLINE mazeModify #-}
mazeModify :: MMaze -> (Piece -> Piece) -> Cursor -> IO ()
mazeModify MMaze{board, width} f (x, y) = MV.unsafeModify board f (x + y * width)

mazeClone :: MMaze -> IO MMaze
mazeClone m@MMaze{board} = (\board -> m { board }) <$> MV.clone board

{-# INLINE mazeSolve #-}
mazeSolve :: MMaze -> Continue -> IO Unwind
mazeSolve m Continue{char, cursor, island} =
  (cursor, ) <$> mazeRead m cursor <* mazeModify m modify cursor
  where modify p = p { pipe = char, solved = True, wasIsland = if island > 0 then True else False }

{-# INLINE mazeDelta #-}
mazeDelta :: Cursor -> Direction -> Cursor
mazeDelta (x, y) 0 = (x, y - 1)
mazeDelta (x, y) 1 = (x + 1, y)
mazeDelta (x, y) 2 = (x, y + 1)
mazeDelta (x, y) 3 = (x - 1, y)
mazeDelta _ _      = error "only defined for 4 directions"

mazeDeltasWalls :: MMaze -> Cursor -> IO [(Piece, Direction)]
mazeDeltasWalls m c = traverse (mazeDeltaWall m c) directions

{-# INLINE mazeDeltaWall #-}
mazeDeltaWall :: MMaze -> Cursor -> Direction -> IO (Piece, Direction)
mazeDeltaWall m !c !dir =
  if mazeBounded m delta
  then (, dir) <$> mazeRead m delta
  else pure (Piece 0 True (0, 0) True False True, dir)
  where delta = mazeDelta c dir

{-# INLINE mazeEquate #-}
-- | Connects 'PartId's on the board
mazeEquate :: MMaze -> PartId -> [Cursor] -> IO [Unwind]
mazeEquate m partId cursors =
  traverse (\c -> (c, ) <$> mazeRead m c) cursors
  <* traverse (mazeModify m (\p -> p { partId, connected = True })) cursors

mazePop :: MMaze -> [Unwind] -> IO ()
mazePop m = traverse_ (uncurry (flip (mazeModify m . const)))

-- | Looks up the fixed point of 'PartId' (i.e. when it points to itself)
{-# INLINE partEquate #-}
partEquate :: MMaze -> PartId -> IO PartId
partEquate maze v = loop' =<< find v
  where
    find f = (\Piece{connected, partId} -> if connected then partId else f) <$> mazeRead maze f
    loop' v' = (\found -> if v' == v || v' == found then pure v' else loop' found) =<< find v'

{--- Rendering, tracing ---}

renderImage :: String -> MMaze -> Continues -> IO ()
renderImage fn maze@MMaze{width, height} continues = seq continues $ do
  mcanvas <- thaw canvas :: IO (MImage RealWorld VU RGB Double)
  traverse (drawPiece mcanvas) grid
  writeImage fn =<< freeze mcanvas
  where
    (pw, ph) = (3, 3)
    border = 3
    canvas = makeImageR VU ((width + 2) * pw, (height + 2) * ph) $ const (PixelRGB 0 0 0)
    grid = (,) <$> [0..width - 1] <*> [0..height - 1]

    colorHash :: Cursor -> Double
    colorHash (x, y) =
      let
        n = ((83 * fromIntegral x) / (37 * fromIntegral (y + 2))) + 0.5
        unfloor m = m - fromIntegral (floor m)
      in unfloor $ (unfloor n) / 4 - 0.15

    drawPiece :: MImage RealWorld VU RGB Double -> PartId -> IO ()
    drawPiece image cur@(x, y) = do
      Piece{pipe, partId, solved} <- mazeRead maze cur
      ch <- colorHash <$> partEquate maze partId
      let cont = Map.lookup cur continues
      let colo = maybe ch (\c -> if island c == 2 then 0.25 else (if island c == 1 then 0.5 else 0.7)) cont
      let satu = if solved then 0.15 else (if isJust cont then 1 else 0)
      let inte = if solved then 0.5 else (if isJust cont then 1 else 0.3)
      let fill = if not solved && pipe == 0b11111111 then PixelRGB 1 1 1 else toPixelRGB $ PixelHSI colo satu inte
      write image (border + x * pw + 1, border + y * ph + 1) fill
      for_ (pixDirections pipe) $ \d ->
        when (Bit.testBit pipe d) $ write image (mazeDelta (border + x * pw + 1, border + y * ph + 1) d) fill

-- | The output format is: @images/lvl%i-%s-%0*i-%s.png level mazeId (sizeLen iter) name@
renderImage' :: String -> Progress -> IO Progress
renderImage' name p@Progress{maze=maze@MMaze{sizeLen, level, mazeId}, iter, continues} =
  p <$ renderImage (printf ("images/lvl%i-%s-%0*i-%s.png") level mazeId sizeLen iter name) maze continues

renderWithPositions :: Maybe Continue -> Progress -> IO String
renderWithPositions _ Progress{maze=maze@MMaze{board, width, height}} =
  pure . unlines . map concat . vectorLists width height =<< V.imapM fmt . V.convert =<< V.freeze board
  where
    colorHash = (`mod` 70) . (+15) . (\(x, y) -> x * 67 + y * 23)
    fmt _ Piece{pipe, partId, solved} = do
      color <- mfilter (\_ -> solved) . Just . colorHash <$> partEquate maze partId
      pure $ case color of
        Just color -> printf "\x1b[38;5;%im%c\x1b[39m" ([24 :: Int, 27..231] !! color) (toChar pipe)
        _ -> (toChar pipe) : []

render :: MMaze -> IO ()
render = (putStrLn =<<) . renderWithPositions Nothing . Progress 0 0 IntMap.empty Map.empty (Components Map.empty) [] []

renderStr :: MMaze -> IO String
renderStr MMaze{board, width, height} = do
  unlines . map concat . vectorLists width height . V.map (return . toChar . pipe) . V.convert
  <$> V.freeze board

islandCounts :: Progress -> (Int, Int)
islandCounts Progress{continues} = bimap getSum getSum . foldMap count $ Map.toList continues
  where
    icount i n = Sum (fromEnum (i == n))
    count (_, Continue{island=i}) = (icount i 2, icount i 1)

-- | Tracing with at each @F\REQ@th step via @T\RACE@ (both compile-time variables, use with with @ghc -D@).
--
-- Modes: 1. print stats \/ 2. print maze with terminal escape code codes \/ 3. as 2., but with clear-screen before \/
-- 4. as 1., but with image output \/ 5. as 4., but only after islands have started
traceBoard :: Continue -> Progress -> IO Progress
traceBoard current progress@Progress{iter, depth, maze=MMaze{size}} = do
  let (mode, freq) = (TRACE :: Int, FREQ :: Int)
  tracer mode freq False
  pure progress
  where
    tracer :: Int -> Int -> Bool -> IO ()
    tracer mode freq islandish
      | iter `mod` freq == 0 && mode == 1 = putStrLn solvedStr
      | iter `mod` freq == 0 && mode == 2 = traceStr >>= putStrLn
      | iter `mod` freq == 0 && mode == 3 = ((clear ++) <$> traceStr) >>= putStrLn
      | iter `mod` freq == 0 && mode == 4 = do
        tracer 1 FREQ_DEF False
        when islandish (void (renderImage' ("trace") progress))
      | iter `mod` freq == 0 && mode == 5 =
        tracer 4 freq ((> 0) . island . snd $ findContinue progress)
      | True = pure ()

    perc = (fromIntegral $ depth) / (fromIntegral size) * 100 :: Double
    ratio = (fromIntegral iter / fromIntegral depth :: Double)
    (i, is) = islandCounts progress
    solvedStr = printf "\x1b[2Kislands: %2i/%2i, solved: %02.2f%%, ratio: %0.2f\x1b[1A" i is perc ratio

    clear = "\x1b[H\x1b[2K" -- move cursor 1,1; clear line
    traceStr = renderWithPositions (Just current) progress

{--- Model ---}

directions = [0, 1, 2, 3]
rotations = directions

charMapEntries :: [(Char, Pix)]
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

{-# INLINE pixRotations #-}
-- | This accounts for some piece's rotational symmetry
pixRotations :: Pix -> [Rotation]
pixRotations 0b11111111 = [0]
pixRotations 0b10101010 = [0,1]
pixRotations 0b01010101 = [0,1]
pixRotations _ = rotations

{-# INLINE pixDirections #-}
pixDirections :: Pix -> [Direction]
pixDirections n = fold
  [ if n `Bit.testBit` 0 then [0] else []
  , if n `Bit.testBit` 1 then [1] else []
  , if n `Bit.testBit` 2 then [2] else []
  , if n `Bit.testBit` 3 then [3] else []
  ]

toPix = (charMap !) :: Char -> Pix
toChar = (pixMap !) :: Pix -> Char

{-# INLINE rotate #-}
rotate :: Rotation -> Pix -> Pix
rotate = flip Bit.rotateL

{--- Solver bits: per-pixel stuff ---}

-- given current pixel at rotation, does it match the pixel at direction from it?
{-# INLINE pixValid #-}
pixValid :: (Pix, Pix, Rotation, Direction) -> Bool
pixValid (!this, !that, !rotation, !direction) =
  not $ (rotate rotation this `Bit.xor` rotate 2 that) `Bit.testBit` direction

{-# INLINE validateDirection #-}
validateDirection :: Pix -> Rotation -> (Piece, Direction) -> Bool
validateDirection this rotation (Piece{pipe=that, solved}, direction) = do
  not solved || pixValid (this, that, rotation, direction)

{-# INLINE validateRotation #-}
validateRotation :: Pix -> [(Piece, Direction)] -> Rotation -> Bool
validateRotation this deltas rotation = all (validateDirection this rotation) deltas

{-# INLINE validateRotationM #-}
validateRotationM :: MMaze -> Cursor -> Pix -> Rotation -> IO Bool
validateRotationM maze cursor this rotation =
  (fmap (validateDirection this rotation) . mazeDeltaWall maze cursor) `allM` directions

{-# INLINE pieceRotations #-}
-- | Returns the list of valid 'Pix' rotations
pieceRotations :: MMaze -> Cursor -> IO [Pix]
pieceRotations maze cur = do
  Piece{pipe=this} <- mazeRead maze cur
  fmap (map (flip rotate this)) . filterM (validateRotationM maze cur this) $ pixRotations this

{-# INLINE pieceRotationCount #-}
pieceRotationCount :: MMaze -> Cursor -> IO Int
pieceRotationCount maze cur = do
  Piece{pipe=this} <- mazeRead maze cur
  fmap length . filterM (validateRotationM maze cur this) $ pixRotations this

{--- Solver bits: components ---}

{-# INLINE compInsert #-}
compInsert :: Continue -> Components -> Components
compInsert Continue{origin} (Components c) = Components (Map.insertWith (+) origin 1 c)
compInsert Continue{origin, cursor} (Components' c) = Components' (Map.insertWith (Set.union) origin (Set.singleton cursor) c)

{-# INLINE compRemove #-}
compRemove :: PartId -> Cursor -> Components -> Components
compRemove origin _cursor (Components c) = Components (Map.update (Just . (subtract 1)) origin c)
compRemove origin cursor (Components' c) = Components' (Map.update (Just . Set.delete cursor) origin c)

{-# INLINE compEquate #-}
compEquate :: PartId -> [PartId] -> Components -> Components
compEquate hub connections c = equate c
  where
    {-# INLINE equate #-}
    equate (Components c) = Components $ equate' Sum getSum c
    equate (Components' c) = Components' $ equate' id id c

    {-# INLINE equate' #-}
    equate' :: Monoid m => (a -> m) -> (m -> a) -> Map PartId a -> Map PartId a
    equate' lift drop c = Map.insertWith (\a b -> drop (lift a <> lift b)) hub (drop sum) removed
      where (sum, removed) = (foldl' (extract lift) (mempty, c) connections)

    {-# INLINE extract #-}
    extract lift (sum, m) part = Map.alterF ((, Nothing) . mappend sum . foldMap lift) part m

{-# INLINE compAlive #-}
compAlive :: PartId -> Components -> Bool
compAlive k (Components c) = (Just 1 ==) $ Map.lookup k c
compAlive k (Components' c) = (Just 1 ==) . fmap Set.size $ Map.lookup k c

{-# INLINE compConnected #-}
compConnected :: PartId -> Components -> [Cursor]
compConnected k (Components' c) = foldMap Set.toList (Map.lookup k c)
compConnected _ _ = []

{--- Solver bits: continues ---}

{-# INLINE cursorToContinue #-}
cursorToContinue :: MMaze -> Int -> Continue -> (Cursor, Direction, Int) -> IO Continue
cursorToContinue maze iter Continue{char, origin, island, area} (c, !direction, index) = do
  let origin' = if char `Bit.testBit` direction then origin else c
  let island' = min 2 (island * 2)
  Continue c 0 origin' 0 (iter * 4 + index) island' area <$> pieceRotationCount maze c

{-# INLINE prioritizeDeltas #-}
-- | Calls 'prioritizeContinues' on nearby pieces (delta = 1)
prioritizeDeltas :: Progress -> Continue -> IO Progress
prioritizeDeltas p@Progress{iter, maze} continue@Continue{cursor=cur} = do
  (\f -> foldrM f p (zip [0..] directions)) $ \(i, d) p' ->
    ifM (((mazeBounded maze (mazeDelta cur d)) &&) <$> (not . solved <$> mazeRead maze (mazeDelta cur d)))
    (prioritizeContinues p' <$> cursorToContinue maze iter continue (mazeDelta cur d, d, i))
    (pure p')

{-# INLINE prioritizeIslands #-}
-- | Sets 'island' to @1@ to nearby components to activate when in island mode.
prioritizeIslands :: [Cursor] -> Progress -> IO Progress
prioritizeIslands _ p@Progress{components = (Components _)} = pure p
prioritizeIslands directDeltas p@Progress{maze, components = (Components' _)} = do
  shores <- filterM (fmap solvedSea . mazeRead maze) directDeltas
  foldr prioritizeIsland p <$> traverse (partEquate maze) shores
  where
    solvedSea Piece{solved, wasIsland} = solved && not wasIsland

    prioritizeIsland :: PartId -> Progress -> Progress
    prioritizeIsland k p =
      (\f -> foldr f p (compConnected k (components p))) $
        (\c p@Progress{continues} -> prioritizeContinues p (continues Map.! c) { island = 1 })

{-# INLINE rescoreContinue #-}
-- | Recalculates the 'Continue's score, less is better (because of 'IntMap.deleteFindMin' in 'findContinue').
--
-- > score = (x + y + choices * 2^15 - island * 2^17) * 2^32 + created
rescoreContinue :: Continue -> Continue
rescoreContinue c@Continue{cursor=(x, y), choices, island, created} =
  c { score = (x + y + choices * 2^15 - island * 2^17) * 2^32 + created }

{-# INLINE prioritizeContinues #-}
-- | Inserts or reprioritizes 'Continue'
prioritizeContinues :: Progress -> Continue -> Progress
prioritizeContinues progress@Progress{priority, continues, components} continue =
  (\((p, cp), cn) -> progress { priority = p, components = cp, continues = cn }) $
    (\c@Continue{cursor} -> Map.alterF (insertContinue (priority, components) c) cursor continues) $
      rescoreContinue continue
  where
    {-# INLINE insertContinue #-}
    insertContinue :: (Priority, Components) -> Continue -> Maybe Continue -> ((Priority, Components), Maybe Continue)
    insertContinue (p, c) new@Continue{cursor} Nothing =
      ((IntMap.insert (score new) cursor p, compInsert new c), Just new)
    insertContinue (p, c) new (Just (exists@Continue{cursor, created})) =
      ((contModify p, c), Just putback)
      where
        (putback, contModify) =
          if score new < score exists
          then (new { created }, IntMap.insert (score new) cursor . IntMap.delete (score exists))
          else (exists, id)

{-# INLINE pieceDead #-}
-- | Check if 'Continue' is about to close its component.
pieceDead :: MMaze -> Components -> (Continue, Priority) -> IO Bool
pieceDead maze components (Continue{cursor=cur, char=this}, _) = do
  thisPart <- partEquate maze . partId =<< mazeRead maze cur
  (compAlive thisPart components &&) <$> stuck
  where stuck = allM (fmap solved . mazeRead maze . mazeDelta cur) (pixDirections this)

-- | Pops `priority` by `score`, deletes from `continues`.
{-# INLINE findContinue #-}
findContinue :: Progress -> (Progress, Continue)
findContinue p@Progress{priority, continues} = do
  (p { priority = priority', continues = continues' }, continue)
  where
    ((_, cursor), priority') = IntMap.deleteFindMin priority
    (continue, continues') = Map.alterF ((, Nothing) . fromJust) cursor continues

{--- Island computations ---}

-- | The generic /pain/ of the 'flood' fill.
type FillNext s = MMaze -> Cursor -> Piece -> [(Piece, Direction)] -> StateT s IO [Cursor]

-- | Four-way flood fill with 'FillNext' as the "paint". The initial piece is assumed to be valid FillNext.
flood :: Monoid s => FillNext s -> MMaze -> Cursor -> IO (Set Cursor, s)
flood n m = flip runStateT mempty . flood' n m Set.empty . return
  where
  flood' :: FillNext s -> MMaze -> Set Cursor -> [Cursor] -> StateT s IO (Set Cursor)
  flood' _ _ visited [] = pure visited
  flood' fillNext maze visited (cursor:next) = do
    this <- liftIO (mazeRead maze cursor)
    more <- fillNext maze cursor this =<< liftIO (mazeDeltasWalls maze cursor)
    let next' = filter (not . flip Set.member visited) more ++ next
    flood' fillNext maze (Set.insert cursor visited) next'

islandize :: Progress -> IO Progress
islandize p@Progress{continues} = do
  let firstIsland = (\c -> (continues Map.! c) { island = 1 }) . snd <$> IntMap.lookupMin (priority p)
  pure (maybe p (prioritizeContinues p) firstIsland)

islands :: Progress -> IO ([Island], Map Cursor IslandId)
islands Progress{maze=maze@MMaze{width}, continues} = do
  islands <- snd <$> foldIsland perIsland (map (cursor . snd) . Map.toList $ continues)
  pure (islands, foldMap (\(id, _, cs) -> Map.fromList $ (, id) <$> map cursor cs) islands)
  where
    foldIsland perIsland continues =
      (\acc -> foldrM acc (Set.empty, []) continues) $ \cursor acc@(visited, _) ->
        if (cursor `Set.member` visited) then pure acc else perIsland cursor acc

    -- border = island's border by continues
    perIsland :: Cursor -> (Set Cursor, [Island]) -> IO (Set Cursor, [Island])
    perIsland cursor (visited, islands) = do
      (area, borders) <- flood (fillNextSolved continues) maze cursor
      let island = ((maybe 0 (\(x, y) -> x + y * width) (Set.lookupMin borders)), Set.size area, (continues Map.!) <$> (Set.toList borders))
      pure (visited `Set.union` borders, island : islands)

    fillNextSolved :: Continues -> FillNext (Set Cursor)
    fillNextSolved continues _ cur _ deltasWall = do
      when (cur `Map.member` continues) $ State.modify (Set.insert cur)
      pure . map (mazeDelta cur . snd) . filter (\(Piece{pipe, solved}, _) -> pipe /= 0 && not solved) $ deltasWall

graphIslands :: Progress -> IO (Gr Island String)
graphIslands Progress{components=Components _} = pure (mkGraph [] [])
graphIslands p@Progress{maze, components=Components' components} = do
  (islands, embedCursor) <- bimap id (Map.!) <$> islands p
  let
    nodes = map (\island@(id, _, _) -> (id, island)) islands
    connectedIslands island Continue{cursor, origin} =
      nubOrd . filter (> island) . map embedCursor . filter (/= cursor)
      . foldMap Set.toList . (`Map.lookup` components) <$> partEquate maze origin
    islandContinues = islands >>= traverseOf _3 id
    edges = for islandContinues (\(id, _, continue) -> map ((id, , "")) <$> connectedIslands id continue)
  mkGraph nodes . join <$> edges

previewIslands :: Progress -> IO Progress
previewIslands p = (p <$) . forkIO . void $ do
  graph <- graphToDot params { isDirected = False } <$> graphIslands p
  runGraphvizCanvas Neato graph Xlib
  runGraphvizCommand Neato graph DotOutput "images/graph.dot"
  where
    params = nonClusteredParams { fmtNode = \(_, (_id, size, _cont)) ->
      [ Shape PointShape
      , Width (log (1.1 + (fromIntegral size) / 500))
      , NodeSep 0.01
      , Sep (PVal (createPoint 10 10))
      -- , Overlap ScaleXYOverlaps
      -- , Overlap VoronoiOverlap
      , Overlap (PrismOverlap (Just 4000))
      , LWidth 1000
      , Splines SplineEdges
      , Color [WC (RGB 252 160 18) Nothing]
      ]
    }

{--- Solver ---}

-- | Solves a valid piece, mutates the maze and sets unwind.
-- Inefficient access: partEquate reads the same data as islands reads.
-- (All methods within this method are inlined)
solveContinue :: Progress -> Continue -> IO Progress
solveContinue
  progress@Progress{maze, components = components_}
  continue@Continue{cursor, char, origin = origin_} = do
    unwindThis <- mazeSolve maze continue
    thisPart <- partEquate maze origin_
    let directDeltas = map (mazeDelta cursor) $ pixDirections char
    neighbours <- fmap (nubOrd . (thisPart :)) . traverse (partEquate maze) $ directDeltas
    let origin = minimum neighbours
    let components = compEquate origin (filter (/= origin) (neighbours)) (compRemove thisPart cursor components_)
    unwindEquate <- mazeEquate maze origin neighbours

    progress' <- prioritizeIslands directDeltas =<< prioritizeDeltas progress { components } continue { origin }
    traceBoard continue $ progress' & iterL %~ (+1) & depthL %~ (+1) & unwindsL %~ ((unwindEquate ++ [unwindThis]) :)

-- | 'space' stack, 'Progress' and 'MMaze' backtracking operations
backtrack :: Progress -> IO (Progress, Continue)
backtrack Progress{space=[]} = error "unsolvable"
backtrack Progress{space=([]:_), unwinds=[]} = error "unlikely"
backtrack p@Progress{space=([]:space), unwinds=(unwind:unwinds), maze} = mazePop maze unwind >> backtrack p { space, unwinds }
backtrack p@Progress{space=(((continue, Progress{depth, priority, continues, components}):guesses):space)} =
  pure (p { depth, priority, continues, components, space = guesses : space }, continue)

-- | Solves pieces by backtracking, stops when the maze is solved, lifespan reached or first choice encountered.
solve' :: Int -> Bool -> Progress -> IO Progress
-- solve' _ _ p@Progress{priority} | Map.null priority = pure p
solve' lifespan first progressInit@Progress{depth, maze=maze@MMaze{size}} = do
  let (progress@Progress{components}, continue) = findContinue progressInit

  rotations <- pieceRotations maze (cursor continue)
  guesses <- removeDead components . map ((, progress) . ($ continue) . set charL) $ rotations
  progress' <- uncurry solveContinue =<< backtrack . (spaceL %~ (guesses :)) =<< pure progress

  let islandish = length guesses /= 1
  let stop = last || lifespan == 0 || (islandish && first)
  (if stop then pure else solve' (lifespan - 1) first) progress'
  where
    last = depth == size - 1
    removeDead components = if last then pure else filterM (fmap not . pieceDead maze components . (_2 %~ priority))

initProgress :: MMaze -> IO Progress
initProgress m@MMaze{trivials} =
  let
    init = \(i, c) -> Continue c 0 c 0 (-i) 0 0 1
    p = Progress 0 0 IntMap.empty Map.empty (Components Map.empty) [] [] m
  in pure $ foldr (flip prioritizeContinues) p (map init . zip [0..] $ trivials)

-- | Solver main, returns solved maze
solve :: MMaze -> IO MMaze
solve m = do
  p <- initProgress m
  p <- islandize =<< reconnect =<< solve' (-1) True p
  p <- solve' (-1) False =<< traceIslands p
  -- p <- foldrM id p . replicate 10 $ (\p -> previewIslands =<< solve' 300000 False =<< traceIslands p)

  let solved@Progress{iter, depth, maze} = p
  putStrLn (printf "\x1b[2K%i/%i, ratio: %0.5f" iter depth (fromIntegral iter / fromIntegral depth :: Double))
  maze <$ renderImage' "done" solved
  where
    traceIslands = renderImage' "islandize"
    reconnect = componentRecalc True

    -- Progress.components = Components -> Components'
    componentRecalc :: Bool -> Progress -> IO Progress
    componentRecalc deep p@Progress{maze, continues} = do
      comps <- foldr1 (Map.unionWith Set.union) <$> traverse component (Map.toList continues)
      pure . (\c -> p { components = c }) $
        if deep then Components' comps else Components (Map.map Set.size comps)
      where component (_, Continue{origin, cursor}) = Map.singleton <$> partEquate maze origin <*> pure (Set.singleton cursor)

{--- Main ---}

verify :: MMaze -> IO Bool
verify maze@MMaze{size} = do
  (size ==) . Set.size . fst <$> flood fillNextValid maze (0, 0)
  where
    fillNextValid :: FillNext ()
    fillNextValid maze cur Piece{pipe=this} deltasWalls = pure $
      if validateRotation this deltasWalls 0
      then filter (mazeBounded maze) . map (mazeDelta cur) $ pixDirections this
      else []

storeBad :: Int -> MMaze -> MMaze -> IO MMaze
storeBad level original solved = do
  whenM (fmap not . verify $ solved) $ do
    putStrLn (printf "storing bad level %i solve" level)
    mazeStore original ("samples/bad-" ++ show level)
  pure solved

rotateStr :: MMaze -> MMaze -> IO Text
rotateStr input solved = concatenate <$> rotations input solved
  where
    concatenate :: [(Cursor, Rotation)] -> Text
    concatenate =
      (T.pack "rotate " <>) . T.intercalate (T.pack "\n")
      . (>>= (\((x, y), r) -> replicate r (T.pack (printf "%i %i" x y))))

    rotations :: MMaze -> MMaze -> IO [(Cursor, Rotation)]
    rotations MMaze{width, board=input} MMaze{board=solved} = do
      V.toList . V.imap (\i -> (mazeCursor width i, ) . uncurry (rotations `on` pipe))
      <$> (V.zip <$> V.freeze input <*> V.freeze solved)
      where
        rotations from to = fromJust $ to `elemIndex` iterate (rotate 1) from

-- | Gets passwords for solved levels from the maze server.
pļāpātArWebsocketu :: WS.ClientApp ()
pļāpātArWebsocketu conn = for_ [1..6] solveLevel
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

-- | Run solver, likely produce trace output and complain if solve is invalid ('verify').
solveFile :: String -> IO ()
solveFile file = do
  solved <- solve =<< parse =<< readFile file
  whenM (not <$> verify solved) (putStrLn "solution invalid")

-- | Executable entry point.
main :: IO ()
main = do
  websocket <- (== "1") . fromMaybe "0" <$> lookupEnv "websocket"

  if websocket
  then withSocketsDo $ WS.runClient "maze.server.host" 80 "/game-pipes/" pļāpātArWebsocketu
  else traverse_ solveFile . (\args -> if null args then ["/dev/stdin"] else args) =<< getArgs
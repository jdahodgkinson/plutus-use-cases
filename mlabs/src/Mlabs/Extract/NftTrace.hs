module Mlabs.Extract.NftTrace (run, runTrace) where

import PlutusTx.Prelude
import Prelude qualified as Hask

import Data.Default (def)
import Data.Monoid (Last)
import Data.Text (Text)

import Plutus.Trace
import qualified Cardano.Api                 as C
-- import qualified Cardano.Api.Shelley         as C
import Wallet.Emulator qualified as WE

import Mlabs.Utils.Wallet (walletFromNumber)

import Mlabs.NFT.Contract
import Mlabs.NFT.Types


nftConfig :: ScriptsConfig
nftConfig = ScriptsConfig
  { scPath = "./extract/txs"
  , scCommand = Transactions
    { networkId = C.Testnet $ C.NetworkMagic 8 
    , protocolParamsJSON = "./extract/pparams.json"
    }
  }


runTrace :: Hask.IO ()
runTrace = runEmulatorTraceIO eTrace1

run :: Hask.IO ()
run = writeNftTx >>= Hask.print
  where
    writeNftTx = 
      writeScriptsTo
        nftConfig
        "nft"
        eTrace1
        def

-- import Data.Monoid (Last (..))
-- import Data.Text (Text)

-- import Control.Monad (void)
-- import Control.Monad.Freer.Extras.Log as Extra (logInfo)

-- import Plutus.Trace.Emulator (EmulatorTrace, activateContractWallet, callEndpoint, runEmulatorTraceIO)
-- import Plutus.Trace.Emulator qualified as Trace
-- import Wallet.Emulator qualified as Emulator

-- 

-- import Mlabs.NFT.Contract
-- import Mlabs.NFT.Types

-- -- | Generic application Trace Handle.
type AppTraceHandle = ContractHandle (Last NftId) NFTAppSchema Text

-- | Emulator Trace 1. Mints Some NFT.
eTrace1 :: EmulatorTrace ()
eTrace1 = do
  let wallet1 = walletFromNumber 1 :: WE.Wallet
      -- wallet2 = walletFromNumber 2 :: WE.Wallet
  h1 :: AppTraceHandle <- activateContractWallet wallet1 endpoints
  -- h2 :: AppTraceHandle <- activateContractWallet wallet2 endpoints
  callEndpoint @"mint" h1 artwork
  -- callEndpoint @"mint" h2 artwork2

  -- void $ Trace.waitNSlots 1
  -- oState <- Trace.observableState h1
  -- nftId <- case getLast oState of
  --   Nothing -> Trace.throwError (Trace.GenericError "NftId not found")
  --   Just nid -> return nid
  -- void $ Trace.waitNSlots 1
  -- callEndpoint @"buy" h2 (buyParams nftId)

--   logInfo @Hask.String $ Hask.show oState
  where
    --  callEndpoint @"mint" h1 artwork
    artwork =
      MintParams
        { mp'content = Content "A painting."
        , mp'title = Title "Fiona Lisa"
        , mp'share = 1 % 10
        , mp'price = Just 5
        }
    -- artwork2 = artwork {mp'content = Content "Another Painting"}

--     buyParams nftId = BuyRequestUser nftId 6 (Just 200)

-- setPriceTrace :: EmulatorTrace ()
-- setPriceTrace = do
--   let wallet1 = walletFromNumber 1 :: Emulator.Wallet
--       wallet2 = walletFromNumber 5 :: Emulator.Wallet
--   authMintH <- activateContractWallet wallet1 endpoints
--   callEndpoint @"mint" authMintH artwork
--   void $ Trace.waitNSlots 2
--   oState <- Trace.observableState authMintH
--   nftId <- case getLast oState of
--     Nothing -> Trace.throwError (Trace.GenericError "NftId not found")
--     Just nid -> return nid
--   logInfo $ Hask.show nftId
--   void $ Trace.waitNSlots 1
--   authUseH :: AppTraceHandle <- activateContractWallet wallet1 endpoints
--   callEndpoint @"set-price" authUseH (SetPriceParams nftId (Just 20))
--   void $ Trace.waitNSlots 1
--   callEndpoint @"set-price" authUseH (SetPriceParams nftId (Just (-20)))
--   void $ Trace.waitNSlots 1
--   userUseH :: AppTraceHandle <- activateContractWallet wallet2 endpoints
--   callEndpoint @"set-price" userUseH (SetPriceParams nftId Nothing)
--   void $ Trace.waitNSlots 1
--   callEndpoint @"set-price" userUseH (SetPriceParams nftId (Just 30))
--   void $ Trace.waitNSlots 1
--   where
--     artwork =
--       MintParams
--         { mp'content = Content "A painting."
--         , mp'title = Title "Fiona Lisa"
--         , mp'share = 1 % 10
--         , mp'price = Just 100
--         }

-- queryPriceTrace :: EmulatorTrace ()
-- queryPriceTrace = do
--   let wallet1 = walletFromNumber 1 :: Emulator.Wallet
--       wallet2 = walletFromNumber 5 :: Emulator.Wallet
--   authMintH :: AppTraceHandle <- activateContractWallet wallet1 endpoints
--   callEndpoint @"mint" authMintH artwork
--   void $ Trace.waitNSlots 2
--   oState <- Trace.observableState authMintH
--   nftId <- case getLast oState of
--     Nothing -> Trace.throwError (Trace.GenericError "NftId not found")
--     Just nid -> return nid
--   logInfo $ Hask.show nftId
--   void $ Trace.waitNSlots 1

--   authUseH <- activateContractWallet wallet1 endpoints
--   callEndpoint @"set-price" authUseH (SetPriceParams nftId (Just 20))
--   void $ Trace.waitNSlots 2

--   queryHandle <- activateContractWallet wallet2 queryEndpoints
--   callEndpoint @"query-current-price" queryHandle nftId
--   -- hangs if this is not called before `observableState`
--   void $ Trace.waitNSlots 1
--   queryState <- Trace.observableState queryHandle
--   queriedPrice <- case getLast queryState of
--     Nothing -> Trace.throwError (Trace.GenericError "QueryResponse not found")
--     Just resp -> case resp of
--       QueryCurrentOwner _ -> Trace.throwError (Trace.GenericError "wrong query state, got owner instead of price")
--       QueryCurrentPrice price -> return price
--   logInfo $ "Queried price: " <> Hask.show queriedPrice

--   callEndpoint @"query-current-owner" queryHandle nftId
--   void $ Trace.waitNSlots 1
--   queryState2 <- Trace.observableState queryHandle
--   queriedOwner <- case getLast queryState2 of
--     Nothing -> Trace.throwError (Trace.GenericError "QueryResponse not found")
--     Just resp -> case resp of
--       QueryCurrentOwner owner -> return owner
--       QueryCurrentPrice _ -> Trace.throwError (Trace.GenericError "wrong query state, got price instead of owner")
--   logInfo $ "Queried owner: " <> Hask.show queriedOwner

--   void $ Trace.waitNSlots 1
--   where
--     artwork =
--       MintParams
--         { mp'content = Content "A painting."
--         , mp'title = Title "Fiona Lisa"
--         , mp'share = 1 % 10
--         , mp'price = Just 100
--         }

-- -- | Test for prototyping.
-- test :: Hask.IO ()
-- test = runEmulatorTraceIO eTrace1

-- testSetPrice :: Hask.IO ()
-- testSetPrice = runEmulatorTraceIO setPriceTrace

-- testQueryPrice :: Hask.IO ()
-- testQueryPrice = runEmulatorTraceIO queryPriceTrace
module Mlabs.NFT.Contract (
  NFTAppSchema,
  schemas,
  endpoints,
  queryEndpoints,
  hashData,
) where

import PlutusTx.Prelude hiding (mconcat, (<>))
import Prelude (mconcat, (<>))
import Prelude qualified as Hask

import Control.Lens (filtered, traversed, (^.), (^..), _Just, _Right)
import Control.Lens qualified as Lens (to)
import Control.Monad (void, when)
import Data.List qualified as L
import Data.Map qualified as Map
import Data.Monoid (Last (..))
import Data.Text (Text, pack)

import Text.Printf (printf)

import Plutus.Contract (Contract, Endpoint, endpoint, utxosTxOutTxAt, type (.\/))
import Plutus.Contract qualified as Contract
import Plutus.V1.Ledger.Ada qualified as Ada
import PlutusTx qualified

import Ledger (
  Address,
  ChainIndexTxOut,
  Datum (..),
  Redeemer (..),
  TxOutRef,
  ciTxOutDatum,
  ciTxOutValue,
  from,
  getDatum,
  pubKeyAddress,
  pubKeyHash,
  scriptCurrencySymbol,
  to,
  txId,
 )

import Ledger.Constraints qualified as Constraints
import Ledger.Typed.Scripts (validatorScript)
import Ledger.Value as Value (TokenName (..), singleton, unAssetClass, valueOf)

import Playground.Contract (mkSchemaDefinitions)

import Mlabs.NFT.Types (
  AuctionBid (..),
  AuctionBidParams (..),
  AuctionCloseParams (..),
  AuctionOpenParams (..),
  AuctionState (..),
  BuyRequestUser (..),
  Content (..),
  MintParams (..),
  NftId (..),
  QueryResponse (..),
  SetPriceParams (..),
  UserId (..),
 )

import Mlabs.NFT.Validation (
  DatumNft (..),
  NftTrade,
  UserAct (..),
  asRedeemer,
  calculateShares,
  mintPolicy,
  nftAsset,
  nftCurrency,
  priceNotNegative,
  txPolicy,
  txScrAddress,
 )

import Mlabs.Plutus.Contract (readDatum', selectForever)

-- | A contract used exclusively for query actions.
type QueryContract a = Contract (Last QueryResponse) NFTAppSchema Text a

-- | A contract used for all user actions.
type UserContract a = Contract (Last NftId) NFTAppSchema Text a

-- | A common App schema works for now.
type NFTAppSchema =
  -- Author Endpoint
  Endpoint "mint" MintParams
    -- User Action Endpoints
    .\/ Endpoint "buy" BuyRequestUser
    .\/ Endpoint "set-price" SetPriceParams
    -- Query Endpoints
    .\/ Endpoint "query-current-owner" NftId
    .\/ Endpoint "query-current-price" NftId
    -- Auction endpoints
    .\/ Endpoint "auction-open" AuctionOpenParams
    .\/ Endpoint "auction-bid" AuctionBidParams
    .\/ Endpoint "auction-close" AuctionCloseParams

mkSchemaDefinitions ''NFTAppSchema

-- MINT --

-- | Mints an NFT and sends it to the App Address.
mint :: MintParams -> UserContract ()
mint nftContent = do
  addr <- getUserAddr
  nft <- nftInit nftContent
  utxos <- Contract.utxosAt addr
  oref <- fstUtxo addr
  let nftId = dNft'id nft
      scrAddress = txScrAddress
      nftPolicy = mintPolicy scrAddress oref nftId
      val = Value.singleton (scriptCurrencySymbol nftPolicy) (nftId'token nftId) 1
      (lookups, tx) =
        ( mconcat
            [ Constraints.unspentOutputs utxos
            , Constraints.mintingPolicy nftPolicy
            , Constraints.typedValidatorLookups txPolicy
            ]
        , mconcat
            [ Constraints.mustMintValue val
            , Constraints.mustSpendPubKeyOutput oref
            , Constraints.mustPayToTheScript nft val
            ]
        )
  ledgerTx <- Contract.submitTxConstraintsWith @NftTrade lookups tx
  void $ Contract.logInfo @Hask.String $ printf "DEBUG mint TX: %s" (Hask.show ledgerTx)
  Contract.tell . Last . Just $ nftId
  Contract.logInfo @Hask.String $ printf "forged %s" (Hask.show val)

-- | Initialise an NFT using the current wallet.
nftInit :: MintParams -> Contract w s Text DatumNft
nftInit mintP = do
  user <- getUId
  nftId <- nftIdInit mintP
  pure $
    DatumNft
      { dNft'id = nftId
      , dNft'share = mp'share mintP
      , dNft'author = user
      , dNft'owner = user
      , dNft'price = mp'price mintP
      , dNft'auctionState = Nothing
      }

-- | Initialise new NftId
nftIdInit :: MintParams -> Contract w s Text NftId
nftIdInit mP = do
  userAddress <- getUserAddr
  oref <- fstUtxo userAddress
  let hData = hashData $ mp'content mP
  pure $
    NftId
      { nftId'title = mp'title mP
      , nftId'token = TokenName hData
      , nftId'outRef = oref
      }

openAuction :: AuctionOpenParams -> Contract w NFTAppSchema Text ()
openAuction (AuctionOpenParams nftId deadline minBid) = do
  oldDatum <- getNftDatum nftId
  -- TODO: what's difference between this `oref` and `nftOref`?
  let oref = nftId'outRef . dNft'id $ oldDatum
  (nftOref, ciTxOut, _oldDatum) <- findNft txScrAddress $ nftId
  let scrAddress = txScrAddress
      nftPolicy = mintPolicy scrAddress oref nftId
      val = Value.singleton (scriptCurrencySymbol nftPolicy) (nftId'token nftId) 1
      auctionState = dNft'auctionState oldDatum
      isOwner datum pkh = pkh == (getUserId . dNft'owner) datum

  when (isJust auctionState) $ Contract.throwError "Can't open: auction is already in progress"

  ownPkh <- pubKeyHash <$> Contract.ownPubKey
  unless (isOwner oldDatum ownPkh) $ Contract.throwError "Only owner can start auction"

  let newAuctionState =
        AuctionState
          { as'highestBid = Nothing
          , as'deadline = deadline
          , as'minBid = minBid
          }
      newDatum' =
        -- Unserialised Datum
        DatumNft
          { dNft'id = dNft'id oldDatum
          , dNft'share = dNft'share oldDatum
          , dNft'author = dNft'author oldDatum
          , dNft'owner = dNft'owner oldDatum
          , dNft'price = dNft'price oldDatum
          , dNft'auctionState = Just newAuctionState
          }
      action = OpenAuctionAct (nftCurrency nftId)
      redeemer = asRedeemer action
      newDatum = Datum . PlutusTx.toBuiltinData $ newDatum' -- Serialised Datum
      (lookups, txConstraints) =
        ( mconcat
            [ Constraints.typedValidatorLookups txPolicy
            , Constraints.otherScript (validatorScript txPolicy)
            , Constraints.unspentOutputs $ Map.singleton nftOref ciTxOut
            ]
        , mconcat
            [ Constraints.mustPayToTheScript newDatum' val
            , Constraints.mustIncludeDatum newDatum
            , Constraints.mustSpendScriptOutput nftOref redeemer
            ]
        )
  ledgerTx <- Contract.submitTxConstraintsWith @NftTrade lookups txConstraints
  void $ Contract.logInfo @Hask.String $ printf "DEBUG open auction TX: %s" (Hask.show ledgerTx)
  void $ Contract.logInfo @Hask.String $ printf "Started auction for %s" $ Hask.show val
  void $ Contract.awaitTxConfirmed $ Ledger.txId ledgerTx
  void $ Contract.logInfo @Hask.String $ printf "Confirmed start auction for %s" $ Hask.show val

bidAuction :: AuctionBidParams -> Contract w NFTAppSchema Text ()
bidAuction (AuctionBidParams nftId bidAmount) = do
  oldDatum <- getNftDatum nftId
  let oref = nftId'outRef . dNft'id $ oldDatum
  (nftOref, ciTxOut, _oldDatum) <- findNft txScrAddress $ nftId
  let scrAddress = txScrAddress
      nftPolicy = mintPolicy scrAddress oref nftId
      val = Value.singleton (scriptCurrencySymbol nftPolicy) (nftId'token nftId) 1
      mauctionState = dNft'auctionState oldDatum

  when (isNothing mauctionState) $ Contract.throwError "Can't bid: no auction in progress"
  auctionState <- maybe (Contract.throwError "No auction state when expected") pure mauctionState

  when (bidAmount < as'minBid auctionState) (Contract.throwError "Auction bid lower than minimal bid")
  ownPkh <- pubKeyHash <$> Contract.ownPubKey
  let newHighestBid =
        AuctionBid
          { ab'bid = bidAmount
          , ab'bidder = UserId ownPkh
          }
      newAuctionState =
        -- TODO: checks that only owner can set deadline & minBid
        -- TODO: check that bid == value in lovelace locked
        auctionState {as'highestBid = Just newHighestBid}
      newDatum' =
        -- Unserialised Datum
        DatumNft
          { dNft'id = dNft'id oldDatum
          , dNft'share = dNft'share oldDatum
          , dNft'author = dNft'author oldDatum
          , dNft'owner = dNft'owner oldDatum
          , dNft'price = dNft'price oldDatum
          , dNft'auctionState = Just newAuctionState
          }
      action = BidAuctionAct bidAmount (nftCurrency nftId)
      redeemer = asRedeemer action
      newValue = val <> Ada.lovelaceValueOf bidAmount
      newDatum = Datum . PlutusTx.toBuiltinData $ newDatum' -- Serialised Datum
      bidDependentTxConstraints =
        case as'highestBid auctionState of
          Nothing -> []
          Just (AuctionBid bid bidder) ->
            [ Constraints.mustPayToPubKey (getUserId bidder) (Ada.lovelaceValueOf bid)
            ]

      (lookups, txConstraints) =
        ( mconcat
            [ Constraints.typedValidatorLookups txPolicy
            , Constraints.otherScript (validatorScript txPolicy)
            , Constraints.unspentOutputs $ Map.singleton nftOref ciTxOut
            ]
        , mconcat
            ( [ Constraints.mustPayToTheScript newDatum' newValue
              , Constraints.mustIncludeDatum newDatum
              , Constraints.mustSpendScriptOutput nftOref redeemer
              , Constraints.mustValidateIn (to $ as'deadline auctionState)
              ]
                ++ bidDependentTxConstraints
            )
        )
  void $ Contract.logInfo @Hask.String $ printf "DEBUG bid auction newValue: %s" (Hask.show newValue)
  ledgerTx <- Contract.submitTxConstraintsWith @NftTrade lookups txConstraints
  void $ Contract.logInfo @Hask.String $ printf "DEBUG bid auction TX: %s" (Hask.show ledgerTx)
  void $ Contract.logInfo @Hask.String $ printf "Bidding %s in auction for %s" (Hask.show newHighestBid) (Hask.show val)
  void $ Contract.awaitTxConfirmed $ Ledger.txId ledgerTx
  void $ Contract.logInfo @Hask.String $ printf "Confirmed bid %s in auction for %s" (Hask.show newHighestBid) (Hask.show val)

closeAuction :: AuctionCloseParams -> Contract w NFTAppSchema Text ()
closeAuction (AuctionCloseParams nftId) = do
  oldDatum <- getNftDatum nftId
  let oref = nftId'outRef . dNft'id $ oldDatum
  (nftOref, ciTxOut, _oldDatum) <- findNft txScrAddress $ nftId
  let scrAddress = txScrAddress
      nftPolicy = mintPolicy scrAddress oref nftId
      val = Value.singleton (scriptCurrencySymbol nftPolicy) (nftId'token nftId) 1
      mauctionState = dNft'auctionState oldDatum
      isOwner datum pkh = pkh == (getUserId . dNft'owner) datum

  when (isNothing mauctionState) $ Contract.throwError "Can't close: no auction in progress"
  auctionState <- maybe (Contract.throwError "No auction state when expected") pure mauctionState
  ownPkh <- pubKeyHash <$> Contract.ownPubKey
  unless (isOwner oldDatum ownPkh) $ Contract.throwError "Only owner can close auction"

  let newOwner =
        case as'highestBid auctionState of
          Nothing -> dNft'owner oldDatum
          Just (AuctionBid _ bidder) -> bidder

      newDatum' =
        -- Unserialised Datum
        DatumNft
          { dNft'id = dNft'id oldDatum
          , dNft'share = dNft'share oldDatum
          , dNft'author = dNft'author oldDatum
          , dNft'owner = newOwner
          , dNft'price = dNft'price oldDatum
          , dNft'auctionState = Nothing
          }
      action = CloseAuctionAct (nftCurrency nftId)
      redeemer = asRedeemer action
      newValue = val
      newDatum = Datum . PlutusTx.toBuiltinData $ newDatum' -- Serialised Datum
      bidDependentTxConstraints =
        case as'highestBid auctionState of
          Nothing -> []
          Just (AuctionBid bid _bidder) ->
            let (amountPaidToOwner, amountPaidToAuthor) = calculateShares bid $ dNft'share oldDatum
             in [ Constraints.mustPayToPubKey (getUserId . dNft'owner $ oldDatum) amountPaidToOwner
                , Constraints.mustPayToPubKey (getUserId . dNft'author $ oldDatum) amountPaidToAuthor
                ]

      (lookups, txConstraints) =
        ( mconcat
            [ Constraints.typedValidatorLookups txPolicy
            , Constraints.otherScript (validatorScript txPolicy)
            , Constraints.unspentOutputs $ Map.singleton nftOref ciTxOut
            ]
        , mconcat
            ( [ Constraints.mustPayToTheScript newDatum' newValue
              , Constraints.mustIncludeDatum newDatum
              , Constraints.mustSpendScriptOutput nftOref redeemer
              , Constraints.mustValidateIn (from $ as'deadline auctionState)
              ]
                ++ bidDependentTxConstraints
            )
        )
  void $ Contract.logInfo @Hask.String $ printf "DEBUG close auction highestBid: %s" (Hask.show $ as'highestBid auctionState)
  void $ Contract.logInfo @Hask.String $ printf "DEBUG close auction newValue: %s" (Hask.show newValue)
  ledgerTx <- Contract.submitTxConstraintsWith @NftTrade lookups txConstraints
  void $ Contract.logInfo @Hask.String $ printf "DEBUG close auction TX: %s" (Hask.show ledgerTx)
  void $ Contract.logInfo @Hask.String $ printf "Closing auction for %s" $ Hask.show val
  void $ Contract.awaitTxConfirmed $ Ledger.txId ledgerTx
  void $ Contract.logInfo @Hask.String $ printf "Confirmed close auction for %s" $ Hask.show val

{- | BUY.
 Attempts to buy a new NFT by changing the owner, pays the current owner and
 the author, and sets a new price for the NFT.
-}
buy :: BuyRequestUser -> Contract w NFTAppSchema Text ()
buy (BuyRequestUser nftId bid newPrice) = do
  oldDatum <- getNftDatum nftId
  let scrAddress = txScrAddress
      oref = nftId'outRef . dNft'id $ oldDatum
      nftPolicy = mintPolicy scrAddress oref nftId
      val = Value.singleton (scriptCurrencySymbol nftPolicy) (nftId'token nftId) 1
      auctionState = dNft'auctionState oldDatum
  when (isJust auctionState) $ Contract.throwError "Can't buy: auction is in progress"
  case dNft'price oldDatum of
    Nothing -> Contract.logError @Hask.String "NFT not for sale."
    Just price ->
      if bid < price
        then Contract.logError @Hask.String "Bid Price is too low."
        else do
          user <- getUId
          userUtxos <- getUserUtxos
          (nftOref, ciTxOut, _) <- findNft txScrAddress nftId
          oref' <- fstUtxo =<< getUserAddr
          let nftPolicy' = mintPolicy scrAddress oref' nftId
              nftCurrency' = nftCurrency nftId
              newDatum' =
                -- Unserialised Datum
                DatumNft
                  { dNft'id = dNft'id oldDatum
                  , dNft'share = dNft'share oldDatum
                  , dNft'author = dNft'author oldDatum
                  , dNft'owner = user
                  , dNft'price = newPrice
                  , dNft'auctionState = Nothing
                  }
              action =
                BuyAct
                  { act'bid = bid
                  , act'newPrice = newPrice
                  , act'cs = nftCurrency'
                  }
              newDatum = Datum . PlutusTx.toBuiltinData $ newDatum' -- Serialised Datum
              (paidToOwner, paidToAuthor) = calculateShares bid $ dNft'share oldDatum
              newValue = ciTxOut ^. ciTxOutValue
              (lookups, tx) =
                ( mconcat
                    [ Constraints.unspentOutputs userUtxos
                    , Constraints.typedValidatorLookups txPolicy
                    , Constraints.mintingPolicy nftPolicy'
                    , Constraints.otherScript (validatorScript txPolicy)
                    , Constraints.unspentOutputs $ Map.singleton nftOref ciTxOut
                    ]
                , mconcat
                    [ Constraints.mustPayToTheScript newDatum' newValue
                    , Constraints.mustIncludeDatum newDatum
                    , Constraints.mustPayToPubKey (getUserId . dNft'owner $ oldDatum) paidToOwner
                    , Constraints.mustPayToPubKey (getUserId . dNft'author $ oldDatum) paidToAuthor
                    , Constraints.mustSpendScriptOutput
                        nftOref
                        (Redeemer . PlutusTx.toBuiltinData $ action)
                    ]
                )
          void $ Contract.submitTxConstraintsWith @NftTrade lookups tx
          void $ Contract.logInfo @Hask.String $ printf "Bought %s" $ Hask.show val

-- SET PRICE --
setPrice :: SetPriceParams -> Contract w NFTAppSchema Text ()
setPrice spParams = do
  result <-
    Contract.runError $ do
      (oref, ciTxOut, datum) <- findNft txScrAddress $ sp'nftId spParams
      runOffChainChecks datum
      let (tx, lookups) = mkTxLookups oref ciTxOut datum
      ledgerTx <- Contract.submitTxConstraintsWith @NftTrade lookups tx
      void $ Contract.awaitTxConfirmed $ Ledger.txId ledgerTx
  either Contract.logError (const $ Contract.logInfo @Hask.String "New price set") result
  where
    mkTxLookups oref ciTxOut datum =
      let newDatum = datum {dNft'price = sp'price spParams}
          redeemer = asRedeemer $ SetPriceAct (sp'price spParams) $ nftCurrency (dNft'id datum)
          newValue = ciTxOut ^. ciTxOutValue
          lookups =
            mconcat
              [ Constraints.unspentOutputs $ Map.singleton oref ciTxOut
              , Constraints.typedValidatorLookups txPolicy
              , Constraints.otherScript (validatorScript txPolicy)
              ]
          tx =
            mconcat
              [ Constraints.mustSpendScriptOutput oref redeemer
              , Constraints.mustPayToTheScript newDatum newValue
              ]
       in (tx, lookups)

    runOffChainChecks :: DatumNft -> Contract w NFTAppSchema Text ()
    runOffChainChecks datum = do
      ownPkh <- pubKeyHash <$> Contract.ownPubKey
      if isOwner datum ownPkh
        then pure ()
        else Contract.throwError "Only owner can set price"
      if priceNotNegative (sp'price spParams)
        then pure ()
        else Contract.throwError "New price can not be negative"

    isOwner datum pkh = pkh == (getUserId . dNft'owner) datum

{- | Query the current price of a given NFTid. Writes it to the Writer instance
 and also returns it, to be used in other contracts.
-}
queryCurrentPrice :: NftId -> QueryContract QueryResponse
queryCurrentPrice nftid = do
  price <- wrap <$> getsNftDatum dNft'price nftid
  Contract.tell (Last . Just $ price) >> log price >> return price
  where
    wrap = QueryCurrentPrice
    log price =
      Contract.logInfo @Hask.String $
        "Current price of: " <> Hask.show nftid <> " is: " <> Hask.show price

{- | Query the current owner of a given NFTid. Writes it to the Writer instance
 and also returns it, to be used in other contracts.
-}
queryCurrentOwner :: NftId -> QueryContract QueryResponse
queryCurrentOwner nftid = do
  ownerResp <- wrap <$> getsNftDatum dNft'owner nftid
  Contract.tell (Last . Just $ ownerResp) >> log ownerResp >> return ownerResp
  where
    wrap = QueryCurrentOwner
    log owner =
      Contract.logInfo @Hask.String $
        "Current owner of: " <> Hask.show nftid <> " is: " <> Hask.show owner

-- ENDPOINTS --

-- | User Endpoints .
endpoints :: UserContract ()
endpoints =
  selectForever
    [ endpoint @"mint" mint
    , endpoint @"buy" buy
    , endpoint @"set-price" setPrice
    , endpoint @"auction-open" openAuction
    , endpoint @"auction-close" closeAuction
    , endpoint @"auction-bid" bidAuction
    ]

-- Query Endpoints are used for Querying, with no on-chain tx generation.
queryEndpoints :: QueryContract ()
queryEndpoints =
  selectForever
    [ endpoint @"query-current-price" queryCurrentPrice
    , endpoint @"query-current-owner" queryCurrentOwner
    ]

-- HELPER FUNCTIONS AND CONTRACTS --

-- | Get the current Wallet's publick key.
getUserAddr :: Contract w s Text Address
getUserAddr = pubKeyAddress <$> Contract.ownPubKey

-- | Get the current wallet's utxos.
getUserUtxos :: Contract w s Text (Map.Map TxOutRef Ledger.ChainIndexTxOut)
getUserUtxos = getAddrUtxos =<< getUserAddr

-- | Get the current wallet's userId.
getUId :: Contract w s Text UserId
getUId = UserId . pubKeyHash <$> Contract.ownPubKey

-- | Get the ChainIndexTxOut at an address.
getAddrUtxos :: Address -> Contract w s Text (Map.Map TxOutRef ChainIndexTxOut)
getAddrUtxos adr = Map.map fst <$> utxosTxOutTxAt adr

-- | Get first utxo at address. Will throw an error if no utxo can be found.
fstUtxo :: Address -> Contract w s Text TxOutRef
fstUtxo address = do
  utxos <- Contract.utxosAt address
  case Map.keys utxos of
    [] -> Contract.throwError @Text "No utxo found at address."
    x : _ -> pure x

-- | Returns the Datum of a specific nftId from the Script address.
getNftDatum :: NftId -> Contract w s Text DatumNft
getNftDatum nftId = do
  utxos :: [Ledger.ChainIndexTxOut] <- Map.elems <$> getAddrUtxos txScrAddress
  let datums :: [DatumNft] =
        utxos
          ^.. traversed . Ledger.ciTxOutDatum
            . _Right
            . Lens.to (PlutusTx.fromBuiltinData @DatumNft . getDatum)
            . _Just
            . filtered (\d -> dNft'id d == nftId)
  Contract.logInfo @Hask.String $ Hask.show $ "Datum Found:" <> Hask.show datums
  Contract.logInfo @Hask.String $ Hask.show $ "Datum length:" <> Hask.show (Hask.length datums)
  case datums of
    [x] -> pure x
    [] -> Contract.throwError "No Datum can be found."
    _ : _ -> Contract.throwError "More than one suitable Datums can be found."

{- | Gets the Datum of a specific nftId from the Script address, and applies an
 extraction function to it.
-}
getsNftDatum :: (DatumNft -> field) -> NftId -> Contract a s Text field
getsNftDatum getField = fmap getField . getNftDatum

-- | A hashing function to minimise the data to be attached to the NTFid.
hashData :: Content -> BuiltinByteString
hashData (Content b) = sha2_256 b

-- | Find NFTs at a specific Address. Will throw an error if none or many are found.
findNft :: Address -> NftId -> Contract w s Text (TxOutRef, ChainIndexTxOut, DatumNft)
findNft addr nftId = do
  utxos <- Contract.utxosTxOutTxAt addr
  case findData utxos of
    [v] -> do
      Contract.logInfo @Hask.String $ Hask.show $ "NFT Found:" <> Hask.show v
      pure v
    [] -> Contract.throwError $ "DatumNft not found for " <> (pack . Hask.show) nftId
    _ ->
      Contract.throwError $
        "Should not happen! More than one DatumNft found for "
          <> (pack . Hask.show) nftId
  where
    findData =
      L.filter hasCorrectNft -- filter only datums with desired NftId
        . mapMaybe readTxData -- map to Maybe (TxOutRef, ChainIndexTxOut, DatumNft)
        . Map.toList
    readTxData (oref, (ciTxOut, _)) = (oref,ciTxOut,) <$> readDatum' ciTxOut
    hasCorrectNft (_, ciTxOut, datum) =
      let (cs, tn) = unAssetClass $ nftAsset nftId
       in tn == nftId'token nftId -- sanity check
            && dNft'id datum == nftId -- check that Datum has correct NftId
            && valueOf (ciTxOut ^. ciTxOutValue) cs tn == 1 -- check that UTXO has single NFT in Value

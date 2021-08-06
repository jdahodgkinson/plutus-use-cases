{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

module Test.Governance.Contract(
  test
) where

import Prelude (
    ($)
  , negate
  , (==)
  , (-)
  )
import Data.Functor (void)
import Data.Monoid ((<>), mempty)

import Plutus.Contract.Test 
  ( checkPredicateOptions
  , assertNoFailedTransactions
  , assertContractError
  , walletFundsChange
  , valueAtAddress 
  , not
  , (.&&.)
  )
import qualified Plutus.Trace.Emulator as Trace
import Mlabs.Plutus.Contract (callEndpoint')


import Test.Tasty (TestTree, testGroup)
import Data.Text as T (isInfixOf)

import Test.Utils (next)
import Test.Governance.Init as Test
import qualified Mlabs.Governance.Contract.Server as Gov
import qualified Mlabs.Governance.Contract.Emulator.Client as Gov (callDeposit, )
import qualified Mlabs.Governance.Contract.Api        as Api

theContract :: Gov.GovernanceContract ()
theContract = Gov.governanceEndpoints Test.testGovCurrencySymbol

test :: TestTree
test = testGroup "Contract"
  [ testGroup "Deposit" 
    [ testDepositHappyPath
    , testInsuficcientGOVFails
    , testCantDepositWithoutGov
    , testCantDepositNegativeAmount
    ]
  , testGroup "Withdraw"
    [ testFullWithdraw
    , testPartialWithdraw
    , testCantWithdrawMoreThandeposited
    , testCantWithdrawNegativeAmount
    ] 
  ]

-- deposit tests

testDepositHappyPath :: TestTree
testDepositHappyPath =
  let 
    testWallet = Test.fstWalletWithGOV
    depoAmt = 50
  in
  checkPredicateOptions Test.checkOptions "Deopsit"
    ( assertNoFailedTransactions
      .&&. walletFundsChange testWallet (Test.gov (negate depoAmt) <> Test.xgov depoAmt)
      .&&. valueAtAddress Test.scriptAddress (== Test.gov depoAmt)
    ) 
    $ Gov.callDeposit Test.testGovCurrencySymbol testWallet (Api.Deposit depoAmt)

testInsuficcientGOVFails :: TestTree
testInsuficcientGOVFails = 
  let 
    testWallet = Test.fstWalletWithGOV
    tag = Trace.walletInstanceTag testWallet
    errCheck = ("InsufficientFunds" `T.isInfixOf`) -- todo probably matching some concrete error type will be better
  in
  checkPredicateOptions Test.checkOptions "Can't deposit more GOV than wallet owns"
    ( assertNoFailedTransactions
      .&&. assertContractError theContract tag errCheck "Should fail with `InsufficientFunds`"
      .&&. walletFundsChange testWallet mempty -- todo factor out
      .&&. valueAtAddress Test.scriptAddress (== mempty)
    )
    $ do
        hdl <- Trace.activateContractWallet testWallet theContract
        void $ callEndpoint' @Api.Deposit hdl (Api.Deposit 1000) -- TODO get value from wallet

testCantDepositWithoutGov :: TestTree
testCantDepositWithoutGov =
  let
    pred = ("InsufficientFunds" `T.isInfixOf`)
    testWallet = Test.walletNoGOV
    tag = Trace.walletInstanceTag testWallet
  in
  checkPredicateOptions Test.checkOptions "Can't deposit with no GOV in wallet"
    (assertNoFailedTransactions
      .&&. assertContractError theContract tag pred "Should fail with `InsufficientFunds`"
      .&&. walletFundsChange testWallet mempty
      .&&. valueAtAddress Test.scriptAddress (== mempty)
    )
    $ do
        hdl <- Trace.activateContractWallet testWallet theContract
        void $ callEndpoint' @Api.Deposit hdl (Api.Deposit 50)

testCantDepositNegativeAmount :: TestTree
testCantDepositNegativeAmount = 
  let
    testWallet = Test.fstWalletWithGOV
    tag = Trace.walletInstanceTag testWallet
    depoAmt = 50
  in
  checkPredicateOptions Test.checkOptions "Can't depositing negative GOV amount"
    ( -- just check that some contract error was thrown before we get more concrete errors
      Test.assertHasErrorOutcome theContract tag "Should fail depositing negative GOV amount"
      .&&. walletFundsChange testWallet (Test.gov (negate depoAmt) <> Test.xgov depoAmt)
      .&&. valueAtAddress Test.scriptAddress (== Test.gov depoAmt)
    )
    $ do
        hdl <- Trace.activateContractWallet testWallet theContract
        {- setup some initial funds to make sure we aren't failing with insufficient funds
           while trying to burn xGOV tokens
        -}
        void $ callEndpoint' @Api.Deposit hdl (Api.Deposit (50))
        next
        void $ callEndpoint' @Api.Deposit hdl (Api.Deposit (negate 2))


-- withdraw tests

testFullWithdraw :: TestTree
testFullWithdraw =
  let 
    testWallet = Test.fstWalletWithGOV
    depoAmt = 50
  in
  checkPredicateOptions Test.checkOptions "Full withdraw"
  ( assertNoFailedTransactions
    .&&. walletFundsChange testWallet mempty
    .&&. valueAtAddress Test.scriptAddress (== mempty)
  )
  $ do
    hdl <- Trace.activateContractWallet testWallet theContract
    next
    void $ callEndpoint' @Api.Deposit hdl (Api.Deposit depoAmt)
    next
    void $ callEndpoint' @Api.Withdraw hdl (Api.Withdraw depoAmt)

testPartialWithdraw :: TestTree
testPartialWithdraw =
  let 
    testWallet = Test.fstWalletWithGOV
    depoAmt = 50
    withdrawAmt = 20
    diff = depoAmt - withdrawAmt
  in
  checkPredicateOptions Test.checkOptions "Partial withdraw"
  ( assertNoFailedTransactions
    .&&. walletFundsChange testWallet (Test.gov (negate diff) <> Test.xgov diff)
    .&&. valueAtAddress Test.scriptAddress (== Test.gov diff)
  )
  $ do
    hdl <- Trace.activateContractWallet testWallet theContract
    next
    void $ callEndpoint' @Api.Deposit hdl (Api.Deposit depoAmt)
    next
    void $ callEndpoint' @Api.Withdraw hdl (Api.Withdraw depoAmt)


testCantWithdrawMoreThandeposited :: TestTree
testCantWithdrawMoreThandeposited =
  checkPredicateOptions Test.checkOptions "Can't withdraw more GOV than deposited"
  -- todo
  {- not sure what behaviour expected here: failed transaction, contract error
     or user just gets back all his deposit?
     assuming for now, that transaction should fail
  -}
  ( not assertNoFailedTransactions )
  $ do
    h1 <- Trace.activateContractWallet Test.fstWalletWithGOV theContract
    h2 <- Trace.activateContractWallet Test.sndWalletWithGOV theContract
    next
    void $ callEndpoint' @Api.Deposit h1 (Api.Deposit 50)
    next
    void $ callEndpoint' @Api.Deposit h2 (Api.Deposit 50)
    next
    void $ callEndpoint' @Api.Withdraw h2 (Api.Withdraw 60)

testCantWithdrawNegativeAmount :: TestTree
testCantWithdrawNegativeAmount = 
  let
    testWallet = Test.fstWalletWithGOV
    tag = Trace.walletInstanceTag testWallet
    depoAmt = 50
  in
  checkPredicateOptions Test.checkOptions "Can't withdraw negative GOV amount"
    ( -- just check that some contract error was thrown before we get more concrete errors
      Test.assertHasErrorOutcome theContract tag "Can't withdraw negative GOV amount"
      .&&. walletFundsChange testWallet (Test.gov (negate depoAmt) <> Test.xgov depoAmt)
      .&&. valueAtAddress Test.scriptAddress (== Test.gov depoAmt)
    )
    $ do
        hdl <- Trace.activateContractWallet testWallet theContract
        void $ callEndpoint' @Api.Deposit hdl (Api.Deposit depoAmt)
        next
        void $ callEndpoint' @Api.Withdraw hdl (Api.Withdraw (negate 2))
      
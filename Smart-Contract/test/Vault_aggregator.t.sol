// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/Console.sol";
import {Vault} from "../src/Vault.sol";
import {Strategy} from "../src/Strategy.sol";
import {Token} from "../src/Token.sol";
import {IStrategy} from "../src/Vault.sol";
import {ReentrancyAttacker} from "../src/ReentrantAttack.sol";
contract vaultAggregatorTest is Test{
    Vault public vault;
    Strategy public strategy1;
    Strategy public strategy2;
    Strategy public strategy3;

    address user1 = address(1);
    address user2 = address(2);
    address user3 = address(3);
    address user4 = address(4);
    Token public token;

    function setUp() public {
        token = new Token();

        vault = new Vault(
            IERC20(address(token)),
            "Vault share",
            "VSH",
            200
        );

        strategy1 = new Strategy(IERC20(address(token)), address(vault), 5, 1, 9, 1);
        strategy2 = new Strategy(IERC20(address(token)), address(vault), 10, 5, 6, 2);
        strategy3 = new Strategy(IERC20(address(token)), address(vault), 20, 10, 3, 5);

        IStrategy[3] memory strats = [
            IStrategy(address(strategy1)),
            IStrategy(address(strategy2)),
            IStrategy(address(strategy3))
        ];

        vault.setStrategies(strats);

        token.transfer(user1, 1000 ether);
    }
    function _deposit() private {
        vm.startPrank(user1);
        uint256 assets = 122 ether;
        token.approve(address(vault), assets);
        vault.deposit(assets, user1);
        vm.stopPrank();
    }
    function testDeposit() public {
        vm.startPrank(user1);
        uint256 assets = 122 ether;
        token.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, user1);
        vm.stopPrank();
        assertEq(token.balanceOf(address(vault)),assets);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalSupply(), shares);
        assertEq(vault.balanceOf(user1),shares);
    }
    function testWithdraw() public {
        _deposit(); // assumes user1 deposited
        uint256 assets = 12 ether;
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 userSharesBefore = vault.balanceOf(user1);
        vm.startPrank(user1);
        uint256 sharesBurned = vault.withdraw(assets, user1, user1);
        vm.stopPrank();
        uint256 userSharesAfter = vault.balanceOf(user1);
        assertEq(userSharesBefore - userSharesAfter, sharesBurned);
        assertEq(vault.totalSupply(), supplyBefore - sharesBurned);
        assertEq(vault.totalAssets(), totalAssetsBefore - assets);
        assertGt(sharesBurned, 0);
    }
    function testMint() public {
        _deposit();
        uint256 PrevShare = vault.totalSupply();
        uint256 PrevAssets = vault.totalAssets();
        uint256 shares = 15 ether;
        uint256 assets = vault.previewMint(shares);
        vm.startPrank(user1);
        token.approve(address(vault), assets);
        vault.mint(shares, user2);
        vm.stopPrank();
        assertEq(vault.totalAssets(),PrevAssets + assets);
        assertEq(vault.balanceOf(user2), shares);
        assertEq(vault.totalSupply(), PrevShare + shares);
    }
    function testRedeem() public{
        _deposit();
        uint256 PrevShare = vault.totalSupply();
        uint256 PrevAssets = vault.totalAssets();
        uint256 user = vault.balanceOf(user1);
        uint256 shares = 15 ether;
        uint256 assets = vault.previewRedeem(shares);
        vm.startPrank(user1);
        vault.redeem(shares, user2, user1);
        vm.stopPrank();
        assertEq(vault.totalAssets(), PrevAssets - assets);
        assertEq(vault.totalSupply(),PrevShare - shares);
        assertEq(token.balanceOf(user2), shares);
        assertEq(vault.balanceOf(user1), user - shares);
    }
    function testInvest() public {    
        _deposit();
        vm.startPrank(address(this));
        uint256 PrevAssets = vault.totalAssets();
        uint256 InvAmt = PrevAssets * 70 / 100;
        vault.rebalance();
        vault.invest();
        vm.stopPrank();
        uint256 vaultBal = token.balanceOf(address(vault));
        assertEq(vaultBal, PrevAssets - InvAmt);
        uint256 strat = vault.activeStrategyId();
        uint256 stratBal = IStrategy(address(vault.strategies(strat))).totalAssets(address(vault));
        assertEq(stratBal, InvAmt);
    }
    function _invest() private {
        _deposit();
        vm.startPrank(address(this));
        vault.rebalance();
        vault.invest();
        vm.stopPrank();
    }
    function testDirectInvWithdraw() public {
        _invest();
        uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));
        uint256 stratBefore =IStrategy(stratAddr).totalAssets(address(vault));
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 amount = 0.1 ether;
        vm.startPrank(address(vault));
        IStrategy(stratAddr).withdraw(amount);
        vm.stopPrank();
        uint256 stratAfter =IStrategy(stratAddr).totalAssets(address(vault));
        uint256 vaultAfter = token.balanceOf(address(vault));
        assertEq(vaultAfter, vaultBefore + amount);
        assertEq(stratAfter, stratBefore - amount);
    }
    function testInvWithdraw() public {
        _invest();

        uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));

        vm.startPrank(user1);
        uint256 stratBefore = IStrategy(stratAddr).totalAssets(address(vault));
        uint256 vaultBal = token.balanceOf(address(vault));
        uint256 userBefore = token.balanceOf(user1);
        uint256 amount = 100 ether;
        vault.withdraw(amount, user1, user1);
        uint256 stratAfter = IStrategy(stratAddr).totalAssets(address(vault));
        uint256 userAfter = token.balanceOf(user1);
        uint256 actualWithdrawnFromStrategy = stratBefore - stratAfter;
        uint256 expectedFromStrategy = amount > vaultBal
            ? (amount - vaultBal)
            : 0;
        assertEq(actualWithdrawnFromStrategy, expectedFromStrategy);
        assertEq(userAfter, userBefore + amount);
    }
    function testProfitWithdraw() public {
        _invest();
        vm.startPrank(address(vault));
        uint256 profit = 200 ether;
        uint256 assets = 150 ether;
        uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));
        Strategy(stratAddr).simulateProfit(profit);
        vm.stopPrank();

        vm.startPrank(user1);

        uint256 userBefore = token.balanceOf(user1);
        uint256 max = vault.maxWithdraw(user1);
        if(assets > max){
            vault.withdraw(max,user1,user1);
        }else{
            vault.withdraw(assets, user1, user1);
        }
        uint256 userAfter = token.balanceOf(user1);
        uint256 amt = (max > assets)? assets : max;
        assertEq(userAfter, userBefore + amt);
        vm.stopPrank();
    }
    function testLossWithdraw()public{
        _invest();//85.4
        vm.startPrank(address(vault));
        uint256 loss = 85 ether;
        uint256 assets = 85 ether;
        uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));
        Strategy(stratAddr).simulateLoss(loss);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        vault.withdraw(assets, user1, user1);
        vm.stopPrank();
    }
    function testOnlyOwnerCanSetStrategies() public{
        vm.startPrank(user1);
        strategy1 = new Strategy(IERC20(address(token)), address(vault), 5, 1, 9, 1);
        strategy2 = new Strategy(IERC20(address(token)), address(vault), 10, 5, 6, 2);
        strategy3 = new Strategy(IERC20(address(token)), address(vault), 20, 10, 3, 5);

        IStrategy[3] memory strats = [
            IStrategy(address(strategy1)),
            IStrategy(address(strategy2)),
            IStrategy(address(strategy3))
        ];
        vm.expectRevert();
        vault.setStrategies(strats);
        
        vm.stopPrank();
    }
    function testOnlyVaultCanCallStrategy() public {
        _invest();

        uint256 amount = 12 ether;
        address strat = address(vault.strategies(vault.activeStrategyId()));

        vm.startPrank(user1); // simulate external user

        vm.expectRevert("Only vault"); 
        Strategy(strat).withdraw(amount);

        vm.stopPrank();
    }
    function testDepositZero() public{
        uint256 assets = 0;
        vm.startPrank(user1);
        token.approve(address(vault), assets);
        vm.expectRevert("Can't deposit 0 assets");
        vault.deposit(assets,user1);
    }
    function testWithdrawZero() public {
        _deposit();
        uint256 assets = 0;
        vm.expectRevert("Can't withdraw 0 assets");
        vault.withdraw(assets, user1, user1);
    }
    function testWithdrawExceedsBalanceReverts() public{
        _deposit();
        vm.expectRevert();
        vault.withdraw(123, user1, user1);
    }
    function testPreviewDepositMatchesDeposit() public {
        uint256 assets = 10 ether;
        vm.startPrank(user1);
        token.approve(address(vault), assets);
        uint256 preview = vault.previewDeposit(assets);
        uint256 shares = vault.deposit(assets, user1);
        assertEq(shares,preview);
        vm.stopPrank();
    }
    function testPreviewWithdrawMatchesWithdraw() public{
        uint256 assets = 10 ether;
        vm.startPrank(user1);
        token.approve(address(vault), assets);
        vault.deposit(assets, user1);
        uint256 preview = vault.previewWithdraw(assets);
        uint256 withdrawn = vault.withdraw(assets, user1, user1);
        assertEq(withdrawn,preview);
        vm.stopPrank();
    }
    function testPreviewRedeemMatchesRedeem() public {
        uint256 assets = 10 ether;
        vm.startPrank(user1);
        token.approve(address(vault), assets);
        vault.deposit(assets, user1);
        uint256 shares = 5 ether;
        uint256 preview = vault.previewRedeem(shares);
        uint256 redeemedAsset = vault.redeem(shares, user1, user1);
        assertEq(preview, redeemedAsset);
    }
    function testTotalAssetsConsistency() public{
        _invest();
        uint256 stratAssets;
        for (uint256 i = 0; i < 3; i++) {
            stratAssets += IStrategy(address(vault.strategies(i))).totalAssets(address(vault));
        }        
        uint256 vaultAssets = token.balanceOf(address(vault));
        assertEq(vault.totalAssets(), vaultAssets + stratAssets);
    }
    function testShareSupplyBackedByAssets() public{
        _deposit();
        vm.startPrank(user1);
        uint256 assets = 122 ether;
        token.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, user1);
        vm.stopPrank();
        uint256 backedAssets = vault.convertToAssets(shares);
        assertEq(backedAssets, assets);
    }
    function testSharePriceIncreasesOnProfit() public {
        _invest();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 assetsPerShareBefore = vault.convertToAssets(1 ether);
        uint256 profit = 25 ether;
        Strategy(address(vault.strategies(vault.activeStrategyId()))).simulateProfit(profit);
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 assetsPerShareAfter = vault.convertToAssets(1 ether);
        assertEq(totalAssetsAfter, totalAssetsBefore + profit);
        assertGt(assetsPerShareAfter, assetsPerShareBefore);
        assertEq(vault.totalSupply(), totalSupplyBefore);
    }
    function testSharePriceDecreasesOnLoss() public{
         _invest();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 assetsPerShareBefore = vault.convertToAssets(1 ether);
        uint256 loss = 25 ether;
        Strategy(address(vault.strategies(vault.activeStrategyId()))).simulateLoss(loss);
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 assetsPerShareAfter = vault.convertToAssets(1 ether);
        assertEq(totalAssetsAfter, totalAssetsBefore - loss);
        assertLe(assetsPerShareAfter, assetsPerShareBefore);
        assertEq(vault.totalSupply(), totalSupplyBefore);
    }
    function testMultipleUsersDepositWithdraw() public{
        token.transfer(user2, 1000 ether);
        token.transfer(user3, 1000 ether);
        token.transfer(user4, 1000 ether);

        vm.startPrank(user1);
        uint256 assets = 100 ether;
        token.approve(address(vault), assets);
        uint256 User1 =vault.deposit(assets,user1);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(vault), assets);
        uint256 User2 =vault.deposit(assets,user2);
        vm.stopPrank();

        vm.startPrank(user3);
        token.approve(address(vault), assets);
        uint256 User3 =vault.deposit(assets,user4);
        vm.stopPrank();

        vm.startPrank(user4);
        token.approve(address(vault), assets);
        uint256 User4 =vault.deposit(assets,user4);
        vm.stopPrank();

        assertEq(User1, User2);
        assertEq(User3, User4);
    }
    function testProportionalOwnership() public {
        uint256 deposit1 = 100 ether;
        uint256 deposit2 = 300 ether;
        token.transfer(user2, 1000 ether);

        vm.startPrank(user1);
        token.approve(address(vault), deposit1);
        vault.deposit(deposit1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        token.transfer(user2, deposit2);
        token.approve(address(vault), deposit2);
        vault.deposit(deposit2, user2);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 user1Shares = vault.balanceOf(user1);
        uint256 user2Shares = vault.balanceOf(user2);

        vm.startPrank(user1);
        uint256 user1Assets = vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Assets = vault.redeem(user2Shares, user2, user2);
        vm.stopPrank();
        assertApproxEqAbs(
            user1Assets + user2Assets,
            totalAssetsBefore,
            1
        );
        
        assertApproxEqAbs(user2Assets, user1Assets * 3, 1);
    }
    function testRebalanceSelectsBestStrategy() public {
        vm.startPrank(address(this));
        vault.rebalance();
        vm.stopPrank();
        uint256 best = vault.activeStrategyId();
        int256 score0 = int256(strategy1.apy())
            + int256(strategy1.liquidityScore())
            - int256(strategy1.riskScore())
            - int256(strategy1.cost());
        int256 score1 = int256(strategy2.apy())
            + int256(strategy2.liquidityScore())
            - int256(strategy2.riskScore())
            - int256(strategy2.cost());
        int256 score2 = int256(strategy3.apy())
            + int256(strategy3.liquidityScore())
            - int256(strategy3.riskScore())
            - int256(strategy3.cost());
        int256 maxScore = score0;
        uint256 expected = 0;
        if (score1 > maxScore) {
            maxScore = score1;
            expected = 1;
        }
        if (score2 > maxScore) {
            expected = 2;
        }
        assertEq(best, expected);
    }
    function testManagementFeeAccrual() public{
        uint256 fee = 12 ether;
        vault.setManagementFee(fee);
        uint256 managementFee = vault.managementFee();
        assertEq(managementFee,fee);
    }
    function testFeeMintingDilutesShares() public {
        _deposit();
        uint256 fee = 200;
        vault.setManagementFee(fee);
        uint256 prevSupply = vault.totalSupply();
        uint256 prevAssets = vault.totalAssets();
        vm.warp(block.timestamp + 365 days);
        vm.startPrank(user1);
        token.approve(address(vault), 1 ether);
        vault.deposit(1 ether, user1); 
        vm.stopPrank();
        uint256 newSupply = vault.totalSupply();
        uint256 newAssets = vault.totalAssets();
        assertGt(newSupply, prevSupply);
        assertApproxEqAbs(newAssets, prevAssets + 1 ether, 1);
        uint256 prevPrice = (prevAssets * 1e18) / prevSupply;
        uint256 newPrice = (newAssets * 1e18) / newSupply;
        assertLt(newPrice, prevPrice);
    }
    function testWithdrawWithInsufficientLiquidityRevertsOrPullsFromStrategy() public{
        _deposit();
        uint256 assets = 130 ether;
        vm.expectRevert("Insufficient Liquidity");
        vault.withdraw(assets, user1, user1);
    }
    function testStrategyPartialWithdrawWorks() public{
        _invest();//122 ether deposit, 70% invested
        uint256 userbalBefore = token.balanceOf(user1);
        uint256 vaultTotalBefore = vault.totalAssets();
        uint256 stratBalBefore = IStrategy(address(vault.strategies(vault.activeStrategyId()))).totalAssets(address(user1));
        uint256 vaultBal = token.balanceOf(address(vault));
        uint256 assets = 50 ether;
        vm.startPrank(user1);
        vault.withdraw(assets, user1, user1);
        vm.stopPrank();
        uint256 userbalAfter = token.balanceOf(user1);
        uint256 vaultTotalAfter = vault.totalAssets();
        uint256 stratBalAfter = IStrategy(address(vault.strategies(vault.activeStrategyId()))).totalAssets(address(user1));
        uint256 expectedWithdrawFromStrat = (assets > vaultBal)? assets - vaultBal : 0;

        assertEq(userbalAfter, userbalBefore + assets);
        assertEq(vaultTotalAfter, vaultTotalBefore - assets);
        assertEq(stratBalAfter,stratBalBefore - expectedWithdrawFromStrat);
    }
    function testFallbackReentrancyDoesNothing() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(vault), address(token));
        token.mint(address(attacker), 2 ether);
        attacker.attack();
        assertGe(token.balanceOf(address(vault)), 0);
    }
   
    function testFullLifecycleDepositInvestProfitWithdraw() public{
        uint256 assets = 25 ether;
       
        vm.startPrank(user1);
        uint256 userBalBefore = token.balanceOf(user1);
        token.approve(address(vault), assets);
        vault.deposit(assets,user1);
        uint256 vaultBalBefore = vault.totalAssets();
        vm.stopPrank();

        vm.startPrank(address(this));
        vault.rebalance();
         uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));
        vault.invest();
        uint256 stratBalBefore = IStrategy(stratAddr).totalAssets(address(vault));
        vm.stopPrank();

        uint256 profit = 10 ether;
        Strategy(stratAddr).simulateProfit(profit);
        vm.startPrank(user1);
        uint256 max = vault.maxWithdraw(user1);
        uint256 vaultBalBeforeWithdraw = token.balanceOf(address(vault));
        vault.withdraw(max, user1, user1);
        uint256 withdrawal = max > vaultBalBeforeWithdraw
            ? max - vaultBalBeforeWithdraw
            : 0;
            uint256 vaultBalAfter = vault.totalAssets();
        uint256 stratBalAfter = IStrategy(stratAddr).totalAssets(address(vault));
        uint256 userBalAfter = token.balanceOf(user1);

        assertEq(userBalAfter, (userBalBefore - assets) + max);
        assertEq(vaultBalAfter,vaultBalBefore + profit -max);
        assertEq(stratBalAfter, stratBalBefore + profit - withdrawal);
    }
    function testDepositAfterProfitSharesLess() public{
        uint256 assets = 10 ether;
        vm.startPrank(user1);
        token.approve(address(vault), assets);
        uint256 share = vault.deposit(assets, user1);
        vm.stopPrank();
        _invest();
        uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));
        uint256 profit = 12 ether;
        Strategy(stratAddr).simulateProfit(profit);
        vm.startPrank(user1);
        vault.withdraw(22 ether, user1, user1);
        vm.stopPrank();
        token.transfer(user2, 100 ether);
        vm.startPrank(user2);
        token.approve(address(vault),assets);
        uint256 share1 = vault.deposit(assets, user2);
        vm.stopPrank();
        
        assertLt(share1, share);
    }
    function testFuzz_DepositWithdraw(uint256 amount) public{
        amount = bound(amount, 1 ether, 10000000000 ether);
        deal(address(token),user1, amount);
        vm.startPrank(user1);
        token.approve(address(vault), amount);
        vault.deposit(amount, user1);
        assertEq(vault.balanceOf(user1), amount);
        vault.withdraw(amount, user1, user1);
        assertEq(vault.totalAssets(), 0);
    }
    function testFuzz_MultiUserProportional(uint256 a, uint256 b) public{
        a = bound(a, 1 ether, 1000 ether);
        b = bound(b, 1 ether, 1000 ether);
        deal(address(token),user1,a);
        deal(address(token),user2,b);

        vm.startPrank(user1);
        token.approve(address(vault), a);
        vault.deposit(a, user1);
        assertEq(vault.balanceOf(user1), a);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(vault), b);
        vault.deposit(b, user2);
        assertEq(vault.balanceOf(user2), b);
        vault.withdraw(b, user2, user2);
        vm.stopPrank();

    }
    function testFuzz_ProfitDistribution(uint256 profit) public {
        profit = bound(profit, 1 ether, 10000 ether);
        deal(address(token), user2,1000 ether);

        vm.startPrank(user1);
        uint256 assets = 122 ether;
        token.approve(address(vault), assets);
        vault.deposit(assets, user1);
        uint256 user1VaultBefore = vault.balanceOf(user1);
        uint256 user1VaultAssetsBefore = vault.convertToAssets(user1VaultBefore);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 assets1 = 125 ether;
        token.approve(address(vault), assets1);
        vault.deposit(assets1, user2);
        uint256 user2VaultBefore = vault.balanceOf(user2);
        uint256 user2VaultAssetBefore = vault.convertToAssets(user2VaultBefore);
        vm.stopPrank();

        vm.startPrank(address(this));
        vault.rebalance();
        vault.invest();
        Strategy(address(vault.strategies(vault.activeStrategyId()))).simulateProfit(profit);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 user1VaultAfter = vault.balanceOf(user1);
        uint256 user1ValtAssetsAfter = vault.convertToAssets(user1VaultAfter);
        vault.withdraw(user1ValtAssetsAfter, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2VaultAfter = vault.balanceOf(user2);
        uint256 user2VaultAssetsAfter = vault.convertToAssets(user2VaultAfter);
        vault.withdraw(user2VaultAssetsAfter, user2, user2);
        vm.stopPrank();

        assertEq(user1VaultAfter, user1VaultBefore);
        assertEq(user2VaultAfter, user2VaultBefore);
        assertGt(user1ValtAssetsAfter, user1VaultAssetsBefore);
        assertGt(user2VaultAssetsAfter, user2VaultAssetBefore);
    }
    function testFuzz_LossHandling(uint256 loss) public {
        loss = bound(loss, 1 ether, 10000 ether);
        deal(address(token), user2,1000 ether);

        vm.startPrank(user1);
        uint256 assets = 122 ether;
        token.approve(address(vault), assets);
        vault.deposit(assets, user1);
        uint256 user1VaultBefore = vault.balanceOf(user1);
        uint256 user1VaultAssetsBefore = vault.convertToAssets(user1VaultBefore);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 assets1 = 125 ether;
        token.approve(address(vault), assets1);
        vault.deposit(assets1, user2);
        uint256 user2VaultBefore = vault.balanceOf(user2);
        uint256 user2VaultAssetBefore = vault.convertToAssets(user2VaultBefore);
        vm.stopPrank();

        vm.startPrank(address(this));
        vault.rebalance();
        vault.invest();
        Strategy(address(vault.strategies(vault.activeStrategyId()))).simulateLoss(loss);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 user1VaultAfter = vault.balanceOf(user1);
        uint256 user1VaultAssetsAfter = vault.convertToAssets(user1VaultAfter);
        vault.withdraw(user1VaultAssetsAfter, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2VaultAfter = vault.balanceOf(user2);
        uint256 user2VaultAssetsAfter = vault.convertToAssets(user2VaultAfter);
        vault.withdraw(user2VaultAssetsAfter, user2, user2);
        vm.stopPrank();

        assertEq(user1VaultAfter, user1VaultBefore);
        assertEq(user2VaultAfter, user2VaultBefore);
        assertLt(user1VaultAssetsAfter, user1VaultAssetsBefore);
        assertLt(user2VaultAssetsAfter, user2VaultAssetBefore);
    }
    
    function testFuzz_ProfitLossSequence(uint256 profit, uint256 loss) public {
        _invest();

        uint256 strat = vault.activeStrategyId();
        address stratAddr = address(vault.strategies(strat));

        uint256 vaultIdleBefore = token.balanceOf(address(vault));
        uint256 stratBefore = IStrategy(stratAddr).totalAssets(address(vault));
        profit = bound(profit, 0, 1000 ether);
        vm.startPrank(address(vault));
        Strategy(stratAddr).simulateProfit(profit);
        vm.stopPrank();

        uint256 stratAfterProfit = IStrategy(stratAddr).totalAssets(address(vault));
        loss = bound(loss, 0, stratAfterProfit);
        vm.startPrank(address(vault));
        Strategy(stratAddr).simulateLoss(loss);
        vm.stopPrank();

        uint256 stratAfter = IStrategy(stratAddr).totalAssets(address(vault));
        uint256 expectedStrat = stratBefore + profit - loss;

        assertEq(stratAfter, expectedStrat);

        uint256 expectedTotal = vaultIdleBefore + expectedStrat;
        assertEq(vault.totalAssets(), expectedTotal);

        uint256 maxWithdraw = vault.maxWithdraw(user1);
        assertLe(maxWithdraw, vault.totalAssets());

        vm.startPrank(user1);

        if (maxWithdraw == 0) {
            vm.expectRevert();
            vault.withdraw(1 ether, user1, user1);
        } else {
            uint256 userBefore = token.balanceOf(user1);
            vault.withdraw(maxWithdraw, user1, user1);
            uint256 userAfter = token.balanceOf(user1);
            assertEq(userAfter, userBefore + maxWithdraw);
        }

        vm.stopPrank();
    }
    function invariant_TotalAssetsConsistency() public {
        uint256 total;
        total += token.balanceOf(address(vault));

        for (uint256 i = 0; i < 3; i++) {
            total += IStrategy(address(vault.strategies(i)))
                .totalAssets(address(vault));
        }

        assertEq(vault.totalAssets(), total);
    }  
    function invariant_StrategyBalanceMatchesAccounting() public {
        for (uint256 i = 0; i < 3; i++) {
            address strat = address(vault.strategies(i));

            uint256 reported = IStrategy(strat).totalAssets(address(vault));
            uint256 actual = token.balanceOf(strat);

            assertEq(reported, actual);
        }
    }
    function invariant_MaxWithdrawSafe() public {
        uint256 max = vault.maxWithdraw(user1);
        assertLe(max, vault.totalAssets());
    }
    function invariant_SupplyBackedByAssets() public {
        if (vault.totalSupply() == 0) return;

        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();

        assertGt(assets * 1e18 / supply, 0);
    }
    function invariant_NonNegativeAssets() public {
        assertGe(vault.totalAssets(), 0);
    }

    function invariant_RebalanceSelectsBest() public {
        vault.rebalance();
        uint256 bestId = vault.activeStrategyId();
        int256 bestScore = type(int256).min;
        for (uint256 i = 0; i < 3; i++) {
            int256 score =
                int256(IStrategy(address(vault.strategies(i))).apy()) +
                int256(IStrategy(address(vault.strategies(i))).liquidityScore()) -
                int256(IStrategy(address(vault.strategies(i))).riskScore()) -
                int256(IStrategy(address(vault.strategies(i))).cost());

            if (score > bestScore) {
                bestScore = score;
            }
        }

        int256 activeScore =
            int256(IStrategy(address(vault.strategies(bestId))).apy()) +
            int256(IStrategy(address(vault.strategies(bestId))).liquidityScore()) -
            int256(IStrategy(address(vault.strategies(bestId))).riskScore()) -
            int256(IStrategy(address(vault.strategies(bestId))).cost());

        assertEq(activeScore, bestScore);
    }
    function invariant_TotalSystemBalance() public {
        uint256 total;

        total += token.balanceOf(address(vault));

        for (uint256 i = 0; i < 3; i++) {
            total += token.balanceOf(address(vault.strategies(i)));
        }

        assertEq(total, vault.totalAssets());
}
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Token} from "./Token.sol";

/**
 * @title Strategy
 * @notice A mock yield-generating strategy used to test the Vault's allocation logic.
 * @dev Implements the IStrategy interface. Allows manual simulation of profits and losses
 * by minting/burning the underlying mock token.
 */
contract Strategy {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    IERC20 public immutable asset;
    address public vault;
    uint256 public totalManagedAssets;
    
    // Strategy performance metrics used for Vault rebalancing
    uint256 public _apy;
    uint256 public _risk;
    uint256 public _liquidity;
    uint256 public _cost;

    /**
     * @param _asset The underlying token (MTK).
     * @param _vault The address of the Vault authorized to invest.
     * @param apy_ The hardcoded APY for this strategy.
     * @param risk_ The hardcoded risk score (1-10).
     * @param liquidity_ The hardcoded liquidity score (1-10).
     * @param cost_ The hardcoded operational cost.
     */
    constructor(
        IERC20 _asset,
        address _vault,
        uint256 apy_,
        uint256 risk_,
        uint256 liquidity_,
        uint256 cost_
    ) {
        asset = _asset;
        vault = _vault;
        _apy = apy_;
        _risk = risk_;
        _liquidity = liquidity_;
        _cost = cost_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    /**
     * @notice Accepts capital from the vault to be "invested".
     * @param amount Amount of assets to transfer from the vault.
     */
    function invest(uint256 amount) onlyVault external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalManagedAssets += amount;
    }

    /**
     * @notice Pulls capital back to the vault.
     * @param amount Requested amount to withdraw.
     * @return withdrawAmount The actual amount transferred back.
     */
    function withdraw(uint256 amount) onlyVault external returns(uint256) {
        uint256 withdrawAmount = amount;
        if(withdrawAmount > totalManagedAssets) {
            withdrawAmount = totalManagedAssets;
        }
        totalManagedAssets -= withdrawAmount;
        asset.safeTransfer(msg.sender, withdrawAmount);
        return withdrawAmount;
    }

    /**
     * @notice Returns the current value of assets held by this strategy.
     */
    function totalAssets(address) external view returns(uint256) {
        return totalManagedAssets;  
    }

    /**
     * @notice TEST ONLY: Manually burns tokens to simulate a protocol hack or loss.
     */
    function simulateLoss(uint256 amount) external {
        uint256 toBurn = (amount > totalManagedAssets) ? totalManagedAssets : amount;
        Token(address(asset)).burn(address(this), toBurn);
        totalManagedAssets -= toBurn;
    }

    /**
     * @notice TEST ONLY: Manually mints tokens to simulate yield generation.
     */
    function simulateProfit(uint256 _amount) external {
        Token(address(asset)).mint(address(this), _amount);
        totalManagedAssets += _amount;
    }

    // --- Interface Getters ---
    function apy() external view returns (uint256) { return _apy; }
    function riskScore() external view returns (uint256) { return _risk; }
    function liquidityScore() external view returns (uint256) { return _liquidity; }
    function cost() external view returns (uint256) { return _cost; }
}
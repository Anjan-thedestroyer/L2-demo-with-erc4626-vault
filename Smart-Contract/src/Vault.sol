// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * @title  IStrategy
 * @notice Any yield-generating strategy plugged into this vault must
 *         implement this interface. It gives the vault a uniform way to
 *         deposit capital, pull it back, and query how well each strategy
 *         is performing at any given time.
 */
interface IStrategy {
    // Send capital into the strategy to start earning yield.
    function invest(uint256 amount) external;

    // Pull capital back from the strategy; returns what was actually received.
    function withdraw(uint256 amount) external returns (uint256);

    // How much yield this strategy is currently generating (annualised).
    function apy() external view returns (uint256);

    // How risky this strategy is — higher means more dangerous.
    function riskScore() external view returns (uint256);

    // How quickly funds can be retrieved — higher means more liquid.
    function liquidityScore() external view returns (uint256);

    // Operational costs of running this strategy — higher means more expensive.
    function cost() external view returns (uint256);

    // How much of `owner`'s capital is currently sitting inside this strategy.
    function totalAssets(address owner) external view returns (uint256);
}

/*
 * @title  Vault
 * @notice An ERC-4626 tokenised vault that distributes deposited capital
 *         across three yield strategies, always preferring the one that
 *         scores best on a combined APY / liquidity / risk / cost basis.
 *
 * @dev    Depositors receive vault shares (ERC-20 tokens) that represent
 *         their proportional ownership of the total assets. The owner can
 *         trigger investment and the vault will figure out where to put
 *         the money. A continuous management fee is charged by minting
 *         new shares to the owner over time.
 *
 *         Inherits:
 *           - ERC4626        — standard tokenised vault mechanics
 *           - Ownable        — restricts sensitive operations to the deployer
 *           - ReentrancyGuard — prevents re-entrant calls on state-changing functions
 */
contract Vault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    // The three strategies the vault can route capital to.
    IStrategy[3] public strategies;

    // Keeps track of which strategy is worst, middle, and best (index 0 → worst).
    // During withdrawals we drain the worst one first to protect our best performer.
    uint256[3] public strategyOrder;

    // When no shares exist yet, we report this as the starting exchange rate
    // so the first depositor always gets a clean 1:1 share price.
    uint256 private constant INITIAL_RATE = 1e18;

    // We never put 100% of idle cash to work — 30% stays in the vault as a
    // liquidity buffer so small withdrawals don't need to touch strategies at all.
    uint256 public constant INVEST_PERCENTAGE = 70;

    // Annual management fee in basis points (e.g. 200 = 2%).
    uint256 public managementFee;

    // The last time we collected fees; used to calculate how much has accrued.
    uint256 public lastFeeUpdate;

    // Which of the three strategies is currently ranked the best.
    uint256 public activeStrategyId;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event managementFeeUpdated(uint256 newFee);
    event FeesCollected(uint256 amount);
    event invested(uint256 _activeStrategyId, uint256 amount);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /*
     * @param _asset         The token depositors will contribute (e.g. USDC).
     * @param _name          Name of the vault's share token.
     * @param _symbol        Symbol of the vault's share token.
     * @param _managementFee Starting annual fee in basis points.
     */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint256 _managementFee
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        managementFee = _managementFee;
        lastFeeUpdate = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Core ERC-4626 Overrides
    // -------------------------------------------------------------------------

    /*
     * @notice Returns the combined value of everything the vault controls —
     *         both what's sitting idle here and what's deployed across strategies.
     *         This number is what drives the share price.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < 3; i++) {
            total += strategies[i].totalAssets(address(this));
        }
        return total;
    }

    /*
     * @notice Deposit tokens and receive vault shares in return.
     * @dev    Fees are collected first so the share price reflects the latest
     *         fee dilution before we calculate how many shares to issue.
     */
    function deposit(uint256 assets, address receiver)
        public
        nonReentrant
        override
        returns (uint256 shares)
    {
        require(assets > 0, "Can't deposit 0 assets");
        _collectManagementFee();
        return shares = super.deposit(assets, receiver);
    }

    /*
     * @notice Mint a specific number of shares, pulling whatever tokens are needed.
     * @dev    Same fee-first pattern as deposit() for consistent share pricing.
     */
    function mint(uint256 shares, address receiver)
        public
        nonReentrant
        override
        returns (uint256 assets)
    {
        require(shares > 0, "Can't mint 0 shares");
        _collectManagementFee();
        return assets = super.mint(shares, receiver);
    }

    /*
     * @notice Burn shares and receive proportional tokens back.
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        require(shares > 0, "Can't redeem 0 shares");
        _collectManagementFee();
        return assets = super.redeem(shares, receiver, owner);
    }

    /*
     * @notice Withdraw a specific token amount, burning the required shares.
     * @dev    If the vault's idle balance isn't enough, we pull from strategies
     *         starting with the worst-performing one. This way we avoid
     *         disrupting our best strategy unless absolutely necessary.
     *         Reverts if there simply isn't enough liquidity anywhere.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        require(assets > 0, "Can't withdraw 0 assets");
        _collectManagementFee();

        uint256 vaultBal = IERC20(asset()).balanceOf(address(this));

        // Only bother touching strategies if we don't have enough idle cash.
        if (vaultBal < assets) {
            uint256 needed = assets - vaultBal;

            // Go through strategies worst-first to assemble what we need.
            for (uint256 i = 0; i < 3 && needed > 0; i++) {
                uint256 id = strategyOrder[i];
                uint256 stratBal = strategies[id].totalAssets(address(this));

                if (stratBal == 0) continue;

                // Don't pull more than we need, or more than the strategy holds.
                uint256 pullAmount = (needed < stratBal) ? needed : stratBal;

                uint256 balBefore = IERC20(asset()).balanceOf(address(this));
                strategies[id].withdraw(pullAmount);
                uint256 balAfter = IERC20(asset()).balanceOf(address(this));

                // Track what actually came back — strategies can have slippage.
                uint256 extracted = balAfter - balBefore;

                if (extracted >= needed) {
                    needed = 0;
                } else {
                    needed -= extracted;
                }
            }

            require(
                IERC20(asset()).balanceOf(address(this)) >= assets,
                "Insufficient Liquidity"
            );
        }

        return super.withdraw(assets, receiver, owner);
    }

    // -------------------------------------------------------------------------
    // Owner Controls
    // -------------------------------------------------------------------------

    /*
     * @notice Update the annual management fee.
     * @dev    Any fees accrued at the old rate will be settled the next time
     *         someone interacts with the vault. The new rate takes effect from
     *         that point forward.
     * @param _newFee New annual fee in basis points.
     */
    function setManagementFee(uint256 _newFee) external onlyOwner {
        managementFee = _newFee;
        emit managementFeeUpdated(_newFee);
    }

    /*
     * @notice Put 70% of the vault's idle balance to work in the best strategy.
     * @dev    Rebalances first to make sure activeStrategyId is current, then
     *         approves and transfers. We do a before/after balance check to
     *         confirm the strategy actually consumed the right amount.
     *         forceApprove is used to handle tokens like USDT that don't allow
     *         changing a non-zero allowance directly.
     */
    function invest() public onlyOwner nonReentrant {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 investAmount = (total * INVEST_PERCENTAGE) / 100;

        // Always rebalance before investing so money goes to the right place.
        rebalance();

        require(investAmount > 0, "Nothing to invest");

        address strategy = address(strategies[activeStrategyId]);

        // Grant the strategy the exact allowance it needs, nothing extra.
        SafeERC20.forceApprove(IERC20(asset()), strategy, investAmount);

        uint256 beforeBal = IERC20(asset()).balanceOf(address(this));
        uint256 _activeStrategyId = activeStrategyId;

        strategies[activeStrategyId].invest(investAmount);

        // Make sure the strategy took exactly what we intended.
        uint256 actualInvested = beforeBal - IERC20(asset()).balanceOf(address(this));
        require(actualInvested == investAmount, "Invest amount mismatch");

        // Clean up the allowance so nothing lingers.
        SafeERC20.forceApprove(IERC20(asset()), strategy, 0);

        emit invested(_activeStrategyId, actualInvested);
    }

    /*
     * @notice Register the three strategies the vault will use.
     * @dev    All addresses must be non-zero and distinct from each other.
     *         Replaces whatever strategies were set before.
     */
    function setStrategies(IStrategy[3] calldata _strats) external onlyOwner {
        for (uint256 i = 0; i < 3; i++) {
            require(address(_strats[i]) != address(0), "Invalid strategy");
            for (uint256 j = i + 1; j < 3; j++) {
                require(address(_strats[i]) != address(_strats[j]), "Duplicate strategy");
            }
        }
        strategies = _strats;
    }

    // -------------------------------------------------------------------------
    // View Helpers
    // -------------------------------------------------------------------------

    // Returns the address of whichever strategy is currently ranked best.
    function activeStrategy() external view returns (address) {
        return address(strategies[activeStrategyId]);
    }

    /*
     * @notice A quick summary of the vault's current state — useful for
     *         dashboards and frontend integrations.
     * @return assetAddress   The underlying token this vault accepts.
     * @return totalAssets_   Everything the vault controls, valued in that token.
     * @return totalSupply_   How many vault shares are in circulation.
     * @return exchangeRate   How many tokens one share is worth right now.
     * @return managementFee_ The current annual fee rate in basis points.
     */
    function getVaultInfo()
        external
        view
        returns (
            address assetAddress,
            uint256 totalAssets_,
            uint256 totalSupply_,
            uint256 exchangeRate,
            uint256 managementFee_
        )
    {
        assetAddress = asset();
        totalAssets_ = totalAssets();
        totalSupply_ = totalSupply();
        // If no shares exist yet, report the clean starting rate of 1:1.
        exchangeRate = totalSupply_ == 0
            ? INITIAL_RATE
            : (totalAssets_ * 1e18) / totalSupply_;
        managementFee_ = managementFee;
    }

    // -------------------------------------------------------------------------
    // Rebalancing
    // -------------------------------------------------------------------------

    /*
     * @notice Score all three strategies and update which one is active.
     * @dev    The scoring formula is straightforward:
     *             score = apy + liquidityScore - riskScore - cost
     *
     *         The winner becomes the active strategy. The full ranking (worst
     *         to best) is stored in strategyOrder so withdrawals know which
     *         strategies to drain first.
     *
     *         Anyone can call this — the vault benefits from being rebalanced
     *         frequently as market conditions shift.
     */
    function rebalance() public {
        uint256 bestId = 0;
        int256 bestScore = type(int256).min;
        int256[3] memory scores;
        uint256[3] memory ids = [uint256(0), 1, 2];

        for (uint256 i = 0; i < strategies.length; i++) {
            int256 score =
                int256(strategies[i].apy())
                + int256(strategies[i].liquidityScore())
                - int256(strategies[i].riskScore())
                - int256(strategies[i].cost());

            scores[i] = score;

            if (score > bestScore) {
                bestScore = score;
                bestId = i;
            }
        }

        activeStrategyId = bestId;

        // Sort ids from worst to best score so we know the withdrawal order.
        // n is always 3 so a simple bubble sort is perfectly fine here.
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (scores[ids[i]] > scores[ids[j]]) {
                    (ids[i], ids[j]) = (ids[j], ids[i]);
                }
            }
        }

        strategyOrder = ids;
    }

    // -------------------------------------------------------------------------
    // Internal / Private Helpers
    // -------------------------------------------------------------------------

    /*
     * @dev Calculates how much management fee has accrued since the last
     *      collection and mints that amount as new shares to the owner.
     *
     *      Minting shares (rather than transferring tokens) is the standard
     *      approach — it dilutes existing holders proportionally, which is
     *      economically equivalent to taking a cut of the assets.
     *
     *      Called at the top of every user-facing function so the share price
     *      is always up to date before any deposits or withdrawals are processed.
     *
     *      Fee calculation:
     *          annualFee = totalSupply x managementFee / 10,000
     *          feeAmount = annualFee x timeElapsed / 365 days
     */
    function _collectManagementFee() internal {
        if (managementFee == 0) return;

        uint256 timeElapsed = block.timestamp - lastFeeUpdate;
        if (timeElapsed == 0) return;

        uint256 totalSupply_ = totalSupply();

        // No shares in existence means no one to charge; just reset the clock.
        if (totalSupply_ == 0) {
            lastFeeUpdate = block.timestamp;
            return;
        }

        uint256 annualFee = (totalSupply_ * managementFee) / 10_000;
        uint256 feeAmount = (annualFee * timeElapsed) / 365 days;

        if (feeAmount > 0) {
            _mint(owner(), feeAmount);
            lastFeeUpdate = block.timestamp;
            emit FeesCollected(feeAmount);
        }
    }

    /*
     * @dev Pulls `amount` from the current active strategy back into the vault.
     *      This is for targeted owner-controlled withdrawals, separate from the
     *      multi-strategy sweep that happens during user withdrawals.
     */
    function _Stratwithdraw(uint256 amount) private {
        require(amount > 0, "Amount must be greater than 0");
        require(
            strategies[activeStrategyId].totalAssets(address(this)) >= amount,
            "Not enough balance in the strategy"
        );
        strategies[activeStrategyId].withdraw(amount);
    }
}

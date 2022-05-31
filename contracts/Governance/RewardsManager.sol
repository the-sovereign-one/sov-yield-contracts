// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../../interfaces/IPair.sol";
import "../../interfaces/BaseSavingsStrategy.sol";
import "./StakingRewards.sol";

contract RewardsManager is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;

    // Whitelisted strategies that offer SVB rewards
    EnumerableSet.AddressSet private strategies;

    // Maps strategies to their associated StakingRewards contract
    mapping(address => address) public stakes;

    // Map of pools to weights
    mapping(address => uint256) public weights;

    // TreasuryVester contract that distributes SVB
    address public treasuryVester;

    uint256 public numStrategies = 0;

    bool private readyToDistribute = false;

    // Tokens to distribute to each strategy.
    uint256[] public distribution;

    uint256 public unallocatedSvb = 0;

    address public svb;
    address public stable;
    address public avax;
    address public stableSvbPair;
    address operationsAddress;
    address investorsAddress;
    address treasuryAddress;
    uint256 operationsShare = 0;
    uint256 investorsShare = 0;
    uint256 treasuryShare = 0;

    event UpdateOperationsAddr(address oldValue, address newValue);
    event UpdateInvestorsAddr(address oldValue, address newValue);
    event UpdateTreasuryAddr(address oldValue, address newValue);

    constructor(
        address svb_,
        address stable_,
        address treasuryVester_,
        address _operations,
        address _investors,
        address _treasury
    ) {
        require(
            svb_ != address(0) &&
                treasuryVester_ != address(0) &&
                _operations != address(0) &&
                _investors != address(0) &&
                _treasury != address(0),
            "LiquidityPoolManager::constructor: Arguments can't be the zero address"
        );
        svb = svb_;
        stable = stable_;
        treasuryVester = treasuryVester_;
        operationsAddress = _operations;
        investorsAddress = _investors;
        treasuryAddress = _treasury;
    }

    /**
     * @notice Only called by team operations
     */
    modifier onlyOperations() {
        require(msg.sender == operationsAddress, "SovStrategy::onlyOpperations");
        _;
    }

    /**
     * @notice Only called by investors
     */
    modifier onlyInvestors() {
        require(msg.sender == investorsAddress, "SovStrategy::onlyInvestors");
        _;
    }

    /**
     * @notice Only called by treasury
     */
    modifier onlyTreasury() {
        require(msg.sender == treasuryAddress, "SovStrategy::onlyTreasury");
        _;
    }

    /**
     * Sets the USD/SVB pair or any stable coin svb pair. Pair's tokens must be stable coin such as USDC and the SVB token.
     *
     * Args:
     *   pair: USDC/SVB pair
     */
    function setStableSvbPair(address stableSvbPair_) external onlyOwner {
        require(
            stableSvbPair_ != address(0),
            "LiquidityPoolManager::setStableSvbPair: Pool cannot be the zero address"
        );
        stableSvbPair = stableSvbPair_;
    }

    /**
     * Check if the given pair is a whitelisted pair
     *
     * Args:
     *   pair: pair to check if whitelisted
     *
     * Return: True if whitelisted
     */
    function isWhitelisted(address _strategy) public view returns (bool) {
        return strategies.contains(_strategy);
    }

    /**
     * Adds a new whitelisted liquidity pool pair. Generates a staking contract.
     * Liquidity providers may stake this liquidity provider reward token and
     * claim SVB rewards proportional to their stake. Pair must contain either
     * AVAX or SVB. Associates a weight with the strategy. Rewards are distributed
     * to the strategy proportionally based on its share of the total weight.
     *
     * Args:
     *   pair: pair to whitelist
     *   weight: how heavily to distribute rewards to this strategy relative to other
     *     strategies
     */
    function addWhitelistedStrategy(address _strategy, uint256 weight)
        external
        onlyOwner
    {
        require(
            !readyToDistribute,
            "LiquidityPoolManager::addWhitelistedPool: Cannot add pool between calculating and distributing returns"
        );
        require(
            _strategy != address(0),
            "LiquidityPoolManager::addWhitelistedPool: Pool cannot be the zero address"
        );
        require(
            isWhitelisted(_strategy) == false,
            "LiquidityPoolManager::addWhitelistedPool: Pool already whitelisted"
        );
        require(
            weight > 0,
            "LiquidityPoolManager::addWhitelistedPool: Weight cannot be zero"
        );

        // Create the staking contract and associate it with the pair
        address stakeContract = address(new StakingRewards(svb, _strategy));
        stakes[_strategy] = stakeContract;
        weights[_strategy] = weight;
        require(
            strategies.add(_strategy),
            "LiquidityPoolManager::addWhitelistedPool: Pair add failed"
        );
        numStrategies = numStrategies.add(1);
    }

    /**
     * Delists a whitelisted pool. Liquidity providers will not receiving future rewards.
     * Already vested funds can still be claimed. Re-whitelisting a delisted pool will
     * deploy a new staking contract.
     *
     * Args:
     *   pair: pair to remove from whitelist
     */
    function removeWhitelistedPool(address _strategy) external onlyOwner {
        require(
            !readyToDistribute,
            "LiquidityPoolManager::removeWhitelistedPool: Cannot remove pool between calculating and distributing returns"
        );
        require(
            isWhitelisted(_strategy),
            "LiquidityPoolManager::removeWhitelistedPool: Pool not whitelisted"
        );

        stakes[_strategy] = address(0);
        weights[_strategy] = 0;

        require(
            strategies.remove(_strategy),
            "LiquidityPoolManager::removeWhitelistedPool: Pair remove failed"
        );

        numStrategies = numStrategies.sub(1);
    }

    /**
     * Adjust the weight of an existing pool
     *
     * Args:
     *   pair: pool to adjust weight of
     *   weight: new weight
     */
    function changeWeight(address _strategy, uint256 weight) external onlyOwner {
        require(
            weights[_strategy] > 0,
            "LiquidityPoolManager::changeWeight: _strategy not whitelisted"
        );
        require(weight > 0, "LiquidityPoolManager::changeWeight: Remove pool instead");
        weights[_strategy] = weight;
    }

    /**
     * Calculate the equivalent of 1e18 of token A denominated in token B for a pair
     * with reserveA and reserveB reserves.
     *
     * Args:
     *   reserveA: reserves of token A
     *   reserveB: reserves of token B
     *
     * Returns: the amount of token B equivalent to 1e18 of token A
     */
    function quote(uint256 reserveA, uint256 reserveB)
        internal
        pure
        returns (uint256 amountB)
    {
        require(reserveA > 0 && reserveB > 0, "Library: INSUFFICIENT_LIQUIDITY");
        uint256 oneToken = 1e18;
        amountB = SafeMath.div(SafeMath.mul(oneToken, reserveB), reserveA);
    }

    /**
     * Calculates the price of swapping USD for 1 SVB
     *
     * Returns: the price of swapping USD for 1 SVB
     */
    function getStableSvbRatio() public view returns (uint256 conversionFactor) {
        require(
            !(stableSvbPair == address(0)),
            "LiquidityPoolManager::getUsdcSvbRatio: No USD-SVB pair set"
        );
        (uint256 reserve0, uint256 reserve1, ) = IPair(stableSvbPair).getReserves();

        if (IPair(stableSvbPair).token0() == stable) {
            conversionFactor = quote(reserve1, reserve0);
        } else {
            conversionFactor = quote(reserve0, reserve1);
        }
    }

    /**
    Determine the balance locked in a strategy
     */

    function getTotalValueLocked(address _strategy)
        public
        view
        returns (uint256 balance)
    {
        require(
            isWhitelisted(_strategy),
            "LiquidityPoolManager::removeWhitelistedPool: Pool not whitelisted"
        );
        balance = BaseSavingsStrategy(_strategy).totalDeposits();
    }

    /**
     * Determine how the vested SVB allocation will be distributed to the liquidity
     * pool staking contracts. Must be called before distributeTokens(). Tokens are
     * distributed to strategies based on relative liquidity proportional to total
     * liquidity. Should be called after vestAllocation()/
     */
    function calculateReturnsSVB() public {
        require(
            !readyToDistribute,
            "LiquidityPoolManager::calculateReturns: Previous returns not distributed. Call distributeTokens()"
        );
        require(
            unallocatedSvb > 0,
            "LiquidityPoolManager::calculateReturns: No SVB to allocate. Call vestAllocation()."
        );
        if (strategies.length() > 0) {
            require(
                !(stableSvbPair == address(0)),
                "LiquidityPoolManager::calculateReturns: Stable/SVB Pair not set"
            );
        }

        // Calculate total liquidity
        distribution = new uint256[](numStrategies);
        uint256 strategyLiquidity = 0;

        for (uint256 i = 0; i < strategies.length(); i++) {
            address strategy = strategies.at(i);
            uint256 weightedLiquidity = (weights[strategy]);
            distribution[i] = weightedLiquidity;
            strategyLiquidity = SafeMath.add(strategyLiquidity, weightedLiquidity);
        }

        // Calculate tokens for each pool
        uint256 transferred = 0;

        uint256 totalLiquidity = strategyLiquidity;

        for (uint256 i = 0; i < distribution.length; i++) {
            uint256 strategyTokens = distribution[i].mul(unallocatedSvb).div(
                totalLiquidity
            );
            distribution[i] = strategyTokens;
            transferred = transferred.add(strategyTokens);
        }

        readyToDistribute = true;
    }

    /**
     * After token distributions have been calculated, actually distribute the vested SVB
     * allocation to the staking pools. Must be called after calculateReturns().
     */
    function distributeTokens() public nonReentrant {
        require(
            readyToDistribute,
            "LiquidityPoolManager::distributeTokens: Previous returns not allocated. Call calculateReturns()"
        );
        readyToDistribute = false;
        address stakeContract;
        uint256 rewardTokens;
        for (uint256 i = 0; i < distribution.length; i++) {
            if (i < strategies.length()) {
                stakeContract = stakes[strategies.at(i)];
            }
            rewardTokens = distribution[i];
            if (rewardTokens > 0) {
                require(
                    ISVB(svb).transfer(stakeContract, rewardTokens),
                    "LiquidityPoolManager::distributeTokens: Transfer failed"
                );
                StakingRewards(stakeContract).notifyRewardAmount(rewardTokens);
            }
        }
        unallocatedSvb = 0;
    }

    /**
     * Fallback for distributeTokens in case of gas overflow. Distributes SVB tokens to a single pool.
     * distibuteTokens() must still be called once to reset the contract state before calling vestAllocation.
     *
     * Args:
     *   strategyIndex: index of strategy to distribute tokens to
     */
    function distributeTokensSinglePool(uint256 strategyIndex) external nonReentrant {
        require(
            readyToDistribute,
            "LiquidityPoolManager::distributeTokensSinglePool: Previous returns not allocated. Call calculateReturns()"
        );
        require(
            strategyIndex < numStrategies,
            "LiquidityPoolManager::distributeTokensSinglePool: Index out of bounds"
        );

        address stakeContract;
        if (strategyIndex < strategies.length()) {
            stakeContract = stakes[strategies.at(strategyIndex)];
        }

        uint256 rewardTokens = distribution[strategyIndex];
        if (rewardTokens > 0) {
            distribution[strategyIndex] = 0;
            require(
                ISVB(svb).transfer(stakeContract, rewardTokens),
                "LiquidityPoolManager::distributeTokens: Transfer failed"
            );
            StakingRewards(stakeContract).notifyRewardAmount(rewardTokens);
        }
    }

    /**
     * Calculate pool token distribution and distribute tokens. Methods are separate
     * to use risk of approaching the gas limit. There must be vested tokens to
     * distribute, so this method should be called after vestAllocation.
     */
    function calculateAndDistribute() external {
        calculateReturnsSVB();
        distributeTokens();
    }

    /**
     * Claim today's vested tokens for the manager to distribute. Moves tokens from
     * the TreasuryVester to the LiquidityPoolManager. Can only be called if all
     * previously allocated tokens have been distributed. Call distributeTokens() if
     * that is not the case. If any additional PNG tokens have been transferred to this
     * this contract, they will be marked as unallocated and prepared for distribution.
     */
    function vestAllocation() external nonReentrant {
        require(
            unallocatedSvb == 0,
            "LiquidityPoolManager::vestAllocation: Old SVB is unallocated. Call distributeTokens()."
        );
        unallocatedSvb = ITreasuryVester(treasuryVester).claim();
        require(
            unallocatedSvb > 0,
            "LiquidityPoolManager::vestAllocation: No SVB to claim. Try again tomorrow."
        );

        // Check if we've received extra tokens or didn't receive enough
        uint256 actualBalance = ISVB(svb).balanceOf(address(this));
        require(
            actualBalance >= unallocatedSvb,
            "LiquidityPoolManager::vestAllocation: Insufficient SVB transferred"
        );

        unallocatedSvb = actualBalance;

        uint256 _operationsShare = (unallocatedSvb.mul(25)).div(100);
        uint256 _treasuryShare = (unallocatedSvb.mul(30)).div(100);
        uint256 _investorsShare = (unallocatedSvb.mul(10)).div(100);
        uint256 vestedShares = _operationsShare.add(_treasuryShare).add(_investorsShare);

        unallocatedSvb = actualBalance.sub(vestedShares);

        operationsShare = operationsShare.add(_operationsShare);
        treasuryShare = treasuryShare.add(_treasuryShare);
        investorsShare = investorsShare.add(_investorsShare);
    }

    /**
     * Claim operating team shares.
     */
    function claimOperationShares() external onlyOperations {
        require(
            operationsShare > 0,
            "LiquidityPoolManager::vestAllocation: No SVB to claim. Try again tomorrow."
        );
        if (operationsShare > 0) {
            require(
                ISVB(svb).transfer(operationsAddress, operationsShare),
                "LiquidityPoolManager::distributeTokens: Transfer failed"
            );
            operationsShare = 0;
        }
    }

    /**
     * Claim investors shares.
     */
    function claimInvestorShares() external onlyInvestors {
        require(
            investorsShare > 0,
            "LiquidityPoolManager::vestAllocation: No SVB to claim. Try again tomorrow."
        );
        if (investorsShare > 0) {
            require(
                ISVB(svb).transfer(investorsAddress, investorsShare),
                "LiquidityPoolManager::distributeTokens: Transfer failed"
            );
            investorsShare = 0;
        }
    }

    /**
     * Claim treasury team shares.
     */
    function claimTreasuryShares() external onlyTreasury {
        require(
            treasuryShare > 0,
            "LiquidityPoolManager::vestAllocation: No SVB to claim. Try again tomorrow."
        );
        if (treasuryShare > 0) {
            require(
                ISVB(svb).transfer(treasuryAddress, treasuryShare),
                "LiquidityPoolManager::distributeTokens: Transfer failed"
            );
            treasuryShare = 0;
        }
    }

    /**
     * @notice Update oppAddr
     * @param newValue address
     */
    function updateOperationsAddr(address newValue) public onlyOperations {
        emit UpdateOperationsAddr(operationsAddress, newValue);
        operationsAddress = newValue;
    }

    /**
     * @notice Update invAddr
     * @param newValue address
     */
    function updateInvestorsAddr(address newValue) public onlyInvestors {
        emit UpdateInvestorsAddr(investorsAddress, newValue);
        investorsAddress = newValue;
    }

    /**
     * @notice Update treasuryAddr
     * @param newValue address
     */
    function updateTreasuryAddr(address newValue) public onlyTreasury {
        emit UpdateTreasuryAddr(treasuryAddress, newValue);
        treasuryAddress = newValue;
    }
}

interface ITreasuryVester {
    function claim() external returns (uint256);
}

interface ISVB {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address dst, uint256 rawAmount) external returns (bool);
}

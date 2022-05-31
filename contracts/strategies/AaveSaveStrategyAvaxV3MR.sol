// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;
import "../../interfaces/BaseStrategyPayable.sol";
import "../../interfaces/IAaveV3IncentivesController.sol";
import "../../interfaces/ILendingPoolAaveV3.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../../interfaces/IPair.sol";
import "../../interfaces/IWAVAX.sol";
import "../../lib/DexLibrary.sol";

/**
 * @title Aave strategy for ERC20
 */
contract AaveSaveStrategyAvaxV3MR is BaseSavingsStrategy, ReentrancyGuard {
    IAaveV3IncentivesController private rewardController;
    ILendingPoolAaveV3 private tokenDelegator;
    IWAVAX private constant WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7); //check network before deploying
    IPair private swapRewardToStableTokenPair;
    IPair private swapStablePlatformTokenPair;
    address private avToken;
    uint256 public minMinting;
    uint256 public rewardCount;

    struct RewardSwapPairs {
        address reward;
        address swapPair;
    }

    // reward -> swapPair
    mapping(address => address) public rewardSwapPairs;
    address[] public supportedRewards;

    event AddReward(address rewardToken, address swapPair);
    event RemoveReward(address rewardToken);

    constructor(
        string memory _name,
        address _avToken,
        address _timelock,
        address _treasury,
        uint256[] memory reinvestNums,
        address[] memory contracts,
        address[] memory swapPairs,
        RewardSwapPairs[] memory _rewardSwapPairs
    ) {
        name = _name;
        rewardController = IAaveV3IncentivesController(contracts[0]);
        tokenDelegator = ILendingPoolAaveV3(contracts[1]);
        stableToken = IERC20(contracts[2]);
        platformToken = IERC20(contracts[3]);
        rewardToken = IERC20(address(WAVAX));
        setSwapPairSafelyRewardStable(swapPairs[0]);
        setSwapPairSafelySvb(swapPairs[1]);
        devAddr = msg.sender;
        avToken = _avToken;
        updateMinRewardTokensToReinvest(reinvestNums[0]);
        updateMinTokensToBuyBack(reinvestNums[1]);
        updateReinvestReward(reinvestNums[2]);
        minMinting = reinvestNums[3];
        updateDepositsEnabled(true);
        transferOwnership(_timelock);
        treasury = _treasury;
        for (uint256 i = 0; i < _rewardSwapPairs.length; i++) {
            _addReward(_rewardSwapPairs[i].reward, _rewardSwapPairs[i].swapPair);
        }
        emit Reinvest(0, 0);
    }

    function addReward(address _rewardToken, address _swapPair) public onlyDev {
        _addReward(_rewardToken, _swapPair);
    }

    function _addReward(address _rewardToken, address _swapPair) internal {
        if (_rewardToken != address(rewardToken)) {
            require(
                DexLibrary.checkSwapPairCompatibility(
                    IPair(_swapPair),
                    _rewardToken,
                    address(rewardToken)
                ),
                "VariableRewardsStrategy::Swap pair does not contain reward token"
            );
        }
        rewardSwapPairs[_rewardToken] = _swapPair;
        supportedRewards.push(_rewardToken);
        rewardCount = rewardCount + 1;
        emit AddReward(_rewardToken, _swapPair);
    }

    function removeReward(address _rewardToken) public onlyDev {
        delete rewardSwapPairs[_rewardToken];
        bool found = false;
        for (uint256 i = 0; i < supportedRewards.length; i++) {
            if (_rewardToken == supportedRewards[i]) {
                found = true;
                supportedRewards[i] = supportedRewards[supportedRewards.length - 1];
            }
        }
        require(found, "VariableRewardsStrategy::Reward to delete not found!");
        supportedRewards.pop();
        rewardCount = rewardCount - 1;
        emit RemoveReward(_rewardToken);
    }

    function isPairEquals(
        IPair pair,
        IERC20 left,
        IERC20 right
    ) private pure returns (bool) {
        return pair.token0() == address(left) && pair.token1() == address(right);
    }

    /* swap reward token into stablecoin dai step1*/
    function setSwapPairSafelyRewardStable(address _swapPairToken) private {
        require(_swapPairToken > address(0), "Swap pair is necessary but not supplied");
        swapRewardToStableTokenPair = IPair(_swapPairToken);
        require(
            isPairEquals(swapRewardToStableTokenPair, stableToken, rewardToken) ||
                isPairEquals(swapRewardToStableTokenPair, rewardToken, stableToken),
            "Swap pair does not match stableToken and rewardToken."
        );
    }

    /* swap stablecoin dai into svb step2*/
    function setSwapPairSafelySvb(address _swapPairToken) private {
        require(_swapPairToken > address(0), "Swap pair is necessary but not supplied");
        swapStablePlatformTokenPair = IPair(_swapPairToken);
        require(
            isPairEquals(swapStablePlatformTokenPair, platformToken, stableToken) ||
                isPairEquals(swapStablePlatformTokenPair, stableToken, platformToken),
            "Swap pair does not match platformToken and stableToken."
        );
    }

    /// @notice Internal method to get account state
    /// @dev Values provided in 1e18 (WAD) instead of 1e27 (RAY)
    function _getAccountData() internal view returns (uint256 balance) {
        balance = IERC20(avToken).balanceOf(address(this));
        return balance;
    }

    receive() external payable {
        require(msg.sender == address(WAVAX), "not allowed");
    }

    function totalDeposits() public view override returns (uint256) {
        uint256 balance = _getAccountData();
        return balance;
    }

    function setAllowances() public override onlyOwner {
        WAVAX.approve(address(tokenDelegator), type(uint256).max);
        IERC20(avToken).approve(address(tokenDelegator), type(uint256).max);
    }

    function deposit() external payable nonReentrant {
        WAVAX.deposit{value: msg.value}();
        _deposit(msg.sender, msg.value);
    }

    function depositFor(address account) external payable nonReentrant {
        WAVAX.deposit{value: msg.value}();
        _deposit(account, msg.value);
    }

    function deposit(uint256 amount) external override {
        revert();
    }

    function _deposit(address account, uint256 amount) private {
        require(DEPOSITS_ENABLED == true, "AaveStrategyV1::_deposit");
        if (MAX_REWARD_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            uint256 avaxRewards = _checkRewards();
            if (avaxRewards > MAX_REWARD_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(amount);
            }
        }
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_BUYBACK > 0) {
            uint256 depositRewards = _checkBuyBack();
            if (depositRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_BUYBACK) {
                _buyBack(depositRewards);
            }
        }
        _mint(account, amount);
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override nonReentrant {
        uint256 WAVAXAmount = amount;
        require(WAVAXAmount > minMinting, "AaveStrategyAvaxV1::below minimum withdraw");
        if (WAVAXAmount > 0) {
            _burn(msg.sender, amount);
            uint256 avaxAmount = _withdrawDepositTokens(WAVAXAmount);
            (bool success, ) = msg.sender.call{value: avaxAmount}("");
            require(success, "AaveStrategyAvaxV1::transfer failed");
            emit Withdraw(msg.sender, avaxAmount);
        }
    }

    function _withdrawDepositTokens(uint256 amount) private returns (uint256) {
        uint256 balance = _getAccountData();
        if (amount > balance) {
            // withdraws all
            amount = type(uint256).max;
        }
        uint256 withdrawn = tokenDelegator.withdraw(
            address(WAVAX),
            amount,
            address(this)
        );
        WAVAX.withdraw(withdrawn);
        return withdrawn;
    }

    function _stakeDepositTokens(uint256 amount) private {
        require(amount > 0, "AaveStrategyAvaxV1::_stakeDepositTokens");
        tokenDelegator.supply(address(WAVAX), amount, address(this), 0);
    }

    /**
     * @notice Safely transfer using an anonymous ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        require(
            IERC20(token).transfer(to, value),
            "AaveStrategyV1::TRANSFER_FROM_FAILED"
        );
    }

    function buyBack() external override {
        uint256 buyBackAmount = _checkBuyBack();
        require(buyBackAmount >= MIN_TOKENS_TO_BUYBACK, "AaveStrategyV1::buyback");
        _buyBack(buyBackAmount);
    }

    /**
     * @notice Use rewards from staking contract to purchase Svb tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount rewards tokens to reinvest
     */
    function _buyBack(uint256 amount) private {
        uint256 buyAmount = tokenDelegator.withdraw(
            address(WAVAX),
            amount,
            address(this)
        );
        uint256 devFee = (buyAmount * (DEV_FEE_BIPS)) / (BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint256 adminFee = (buyAmount * (ADMIN_FEE_BIPS)) / (BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }

        uint256 reinvestFee = (buyAmount * (REINVEST_REWARD_BIPS)) / (BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint256 platformTokenAmount;

        uint256 stableTokenAmount = DexLibrary.swap(
            buyAmount - (devFee) - (adminFee) - (reinvestFee),
            address(rewardToken),
            address(stableToken),
            swapRewardToStableTokenPair
        );

        platformTokenAmount = DexLibrary.swap(
            stableTokenAmount,
            address(stableToken),
            address(platformToken),
            swapStablePlatformTokenPair
        );

        if (platformTokenAmount > 0) {
            _safeTransfer(
                address(platformToken),
                address(treasury),
                platformTokenAmount
            );
        }
        emit Purchased(platformTokenAmount);
    }

    function _checkBuyBack() internal view returns (uint256 avaxAmount) {
        if (totalDeposits() < totalSupply) {
            return 0;
        }
        return (totalDeposits() - totalSupply);
    }

    function checkBuyBack() public view override returns (uint256) {
        return _checkBuyBack();
    }

    /*
     * @notice Used for converting multiple rewards into base reward token
     * @return reward amount
     */
    function _convertRewardsIntoBaseRewardToken() private returns (uint256) {
        uint256 rewardAmount = WAVAX.balanceOf(address(this));
        uint256 count = supportedRewards.length;
        for (uint256 i = 0; i < count; i++) {
            address reward = supportedRewards[i];
            if (reward == address(WAVAX)) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    WAVAX.deposit{value: balance}();
                    rewardAmount = rewardAmount + balance;
                }
                continue;
            }
            uint256 amount = IERC20(reward).balanceOf(address(this));
            if (amount > 0) {
                address swapPair = rewardSwapPairs[reward];
                if (swapPair > address(0)) {
                    rewardAmount =
                        rewardAmount +
                        (
                            DexLibrary.swap(
                                amount,
                                reward,
                                address(rewardToken),
                                IPair(swapPair)
                            )
                        );
                }
            }
        }
        return rewardAmount;
    }

    function reinvest() external override nonReentrant {
        _reinvest(0);
    }

    /*
     * @notice Use rewards from staking contract to purchase Svb tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount rewards tokens to reinvest
     */
    function _reinvest(uint256 userDeposit) private {
        address[] memory assets = new address[](1);
        assets[0] = avToken;
        rewardController.claimAllRewards(assets, address(this));
        uint256 amount = _convertRewardsIntoBaseRewardToken();

        if (userDeposit == 0) {
            require(
                amount >= MIN_REWARD_TOKENS_TO_REINVEST,
                "VariableRewardsStrategy::Reinvest amount too low"
            );
        }
        uint256 devFee = (amount * (DEV_FEE_BIPS)) / (BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint256 adminFee = (amount * (ADMIN_FEE_BIPS)) / (BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }

        uint256 reinvestFee = (amount * (REINVEST_REWARD_BIPS)) / (BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint256 stableTokenAmount = DexLibrary.swap(
            amount - (devFee) - (adminFee) - (reinvestFee),
            address(rewardToken),
            address(stableToken),
            swapRewardToStableTokenPair
        );

        uint256 platformTokenAmount = DexLibrary.swap(
            stableTokenAmount,
            address(stableToken),
            address(platformToken),
            swapStablePlatformTokenPair
        );

        if (platformTokenAmount > 0) {
            _safeTransfer(
                address(platformToken),
                address(treasury),
                platformTokenAmount
            );
        }
        emit Purchased(platformTokenAmount);
    }

    function _checkRewards() internal view returns (uint256 avaxAmount) {
        address[] memory assets = new address[](1);
        assets[0] = avToken;

        (address[] memory rewards, uint256[] memory amounts) = rewardController
            .getAllUserRewards(assets, address(this));
        uint256 estimatedTotalReward;
        for (uint256 i = 0; i < rewards.length; i++) {
            address reward = rewards[i];
            if (reward == address(rewardToken)) {
                estimatedTotalReward = estimatedTotalReward + (amounts[i]);
            }
        }
        return estimatedTotalReward;
    }

    function checkReward() public view override returns (uint256) {
        return _checkRewards();
    }

    function rescueDeployedFunds(uint256 minReturnAmountAccepted, bool disableDeposits)
        external
        override
        onlyOwner
    {
        uint256 balanceBefore = depositToken.balanceOf(address(this));

        tokenDelegator.withdraw(address(depositToken), type(uint256).max, address(this));
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter - (balanceBefore) >= minReturnAmountAccepted,
            "AaveStrategyV1::rescueDeployedFunds"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }
}

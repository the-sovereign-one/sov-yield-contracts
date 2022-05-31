// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./SovereignLpToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice BaseStrategy should be inherited by new strategies
 */
abstract contract BaseSavingsStrategy is SovereignYieldERC20, Ownable {
    IERC20 public depositToken;
    IERC20 public stableToken;
    IERC20 public platformToken;
    IERC20 public rewardToken;
    address public devAddr;
    address public treasury;

    uint256 public MIN_REWARD_TOKENS_TO_REINVEST;
    uint256 public MIN_TOKENS_TO_BUYBACK;
    uint256 public MAX_REWARD_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST;
    uint256 public MAX_TOKENS_TO_DEPOSIT_WITHOUT_BUYBACK;
    bool public DEPOSITS_ENABLED;

    uint256 public REINVEST_REWARD_BIPS;
    uint256 public ADMIN_FEE_BIPS;
    uint256 public DEV_FEE_BIPS;

    uint256 internal constant BIPS_DIVISOR = 10000;
    uint256 internal constant MAX_UINT = type(uint256).max;

    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event Reinvest(uint256 newTotalDeposits, uint256 newTotalSupply);
    event Recovered(address token, uint256 amount);
    event UpdateAdminFee(uint256 oldValue, uint256 newValue);
    event UpdateDevFee(uint256 oldValue, uint256 newValue);
    event UpdateReinvestReward(uint256 oldValue, uint256 newValue);
    event UpdateMinRewardTokensToReinvest(uint256 oldValue, uint256 newValue);
    event UpdateMaxRewardTokensToDepositWithoutReinvest(
        uint256 oldValue,
        uint256 newValue
    );
    event UpdateMinTokensToBuyback(uint256 oldValue, uint256 newValue);
    event UpdateMaxTokensToDepositWithoutBuyBack(uint256 oldValue, uint256 newValue);
    event UpdateDevAddr(address oldValue, address newValue);
    event DepositsEnabled(bool newValue);
    event Purchased(uint256 platformTokenAmount);

    /**
     * @notice Only called by dev
     */
    modifier onlyDev() {
        require(msg.sender == devAddr, "SovStrategy::onlyDev");
        _;
    }

    /**
     * @notice Approve tokens for use in Strategy
     * @dev Should use modifier `onlyOwner` to avoid griefing
     */
    function setAllowances() public virtual;

    /**
     * @notice Revoke token allowance
     * @param token address
     * @param spender address
     */
    function revokeAllowance(address token, address spender) external onlyOwner {
        require(IERC20(token).approve(spender, 0));
    }

    /**
     * @notice Deposit and deploy deposits tokens to the strategy
     * @dev Must mint receipt tokens to `msg.sender`
     * @param amount deposit tokens
     */
    function deposit(uint256 amount) external virtual;

    /**
     * @notice Redeem receipt tokens for deposit tokens
     * @param amount receipt tokens
     */
    function withdraw(uint256 amount) external virtual;

    // /**
    //  * @notice purchase SVB tokens from rewards
    //  */
    // function purchaseSvb() external virtual;

    /**
     * @notice Reinvest reward tokens into deposit tokens
     */
    function reinvest() external virtual;

    /**
     * @notice Buyback deposit tokens into platform tokens
     */
    function buyBack() external virtual;

    /**
     * @notice Estimate reinvest reward
     * @return reward tokens
     */
    function estimateReinvestReward() external view returns (uint256) {
        uint256 unclaimedRewards = checkReward();
        if (unclaimedRewards >= MIN_REWARD_TOKENS_TO_REINVEST) {
            return (unclaimedRewards * (REINVEST_REWARD_BIPS)) / (BIPS_DIVISOR);
        }
        return 0;
    }

    /**
     * @notice Estimate buyback reward
     * @return reward tokens
     */
    function estimateBuyBackReward() external view returns (uint256) {
        uint256 unclaimedRewards = checkBuyBack();
        if (unclaimedRewards >= MIN_TOKENS_TO_BUYBACK) {
            return (unclaimedRewards * (REINVEST_REWARD_BIPS)) / (BIPS_DIVISOR);
        }
        return 0;
    }

    /**
     * @notice Reward tokens avialable to strategy, including balance
     * @return reward tokens
     */
    function checkReward() public view virtual returns (uint256);

    /**
     * @notice Deposit tokens avialable to strategy, including balance
     * @return deposit tokens
     */
    function checkBuyBack() public view virtual returns (uint256);

    /**
     * @notice Rescue all available deployed deposit tokens back to Strategy
     * @param minReturnAmountAccepted min deposit tokens to receive
     * @param disableDeposits bool
     */
    function rescueDeployedFunds(uint256 minReturnAmountAccepted, bool disableDeposits)
        external
        virtual;

    /**
     * @notice This function returns a snapshot of last available quotes
     * @return total deposits available on the contract
     */
    function totalDeposits() public view virtual returns (uint256);

    /**
     * @notice Update reinvest min threshold
     * @param newValue threshold
     */
    function updateMinRewardTokensToReinvest(uint256 newValue) public onlyOwner {
        emit UpdateMinRewardTokensToReinvest(MIN_REWARD_TOKENS_TO_REINVEST, newValue);
        MIN_REWARD_TOKENS_TO_REINVEST = newValue;
    }

    /**
     * @notice Update reinvest max threshold before a deposit
     * @param newValue threshold
     */
    function updateMaxRewardTokensToDepositWithoutReinvest(uint256 newValue)
        public
        onlyOwner
    {
        emit UpdateMaxRewardTokensToDepositWithoutReinvest(
            MAX_REWARD_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST,
            newValue
        );
        MAX_REWARD_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST = newValue;
    }

    /**
     * @notice Update reinvest min threshold
     * @param newValue threshold
     */
    function updateMinTokensToBuyBack(uint256 newValue) public onlyOwner {
        emit UpdateMinTokensToBuyback(MIN_TOKENS_TO_BUYBACK, newValue);
        MIN_TOKENS_TO_BUYBACK = newValue;
    }

    /**
     * @notice Update reinvest max threshold before a deposit
     * @param newValue threshold
     */
    function updateMaxTokensToDepositWithoutBuyback(uint256 newValue) public onlyOwner {
        emit UpdateMaxTokensToDepositWithoutBuyBack(
            MAX_TOKENS_TO_DEPOSIT_WITHOUT_BUYBACK,
            newValue
        );
        MAX_TOKENS_TO_DEPOSIT_WITHOUT_BUYBACK = newValue;
    }

    /**
     * @notice Update developer fee
     * @param newValue fee in BIPS
     */
    function updateDevFee(uint256 newValue) public onlyOwner {
        require(newValue + (ADMIN_FEE_BIPS) + (REINVEST_REWARD_BIPS) <= BIPS_DIVISOR);
        emit UpdateDevFee(DEV_FEE_BIPS, newValue);
        DEV_FEE_BIPS = newValue;
    }

    /**
     * @notice Update admin fee
     * @param newValue fee in BIPS
     */
    function updateAdminFee(uint256 newValue) public onlyOwner {
        require(newValue + (DEV_FEE_BIPS) + (REINVEST_REWARD_BIPS) <= BIPS_DIVISOR);
        emit UpdateAdminFee(ADMIN_FEE_BIPS, newValue);
        ADMIN_FEE_BIPS = newValue;
    }

    /**
     * @notice Update reinvest reward
     * @param newValue fee in BIPS
     */
    function updateReinvestReward(uint256 newValue) public onlyOwner {
        require(newValue + (ADMIN_FEE_BIPS) + (DEV_FEE_BIPS) <= BIPS_DIVISOR);
        emit UpdateReinvestReward(REINVEST_REWARD_BIPS, newValue);
        REINVEST_REWARD_BIPS = newValue;
    }

    /**
     * @notice Enable/disable deposits
     * @param newValue bool
     */
    function updateDepositsEnabled(bool newValue) public onlyOwner {
        require(DEPOSITS_ENABLED != newValue);
        DEPOSITS_ENABLED = newValue;
        emit DepositsEnabled(newValue);
    }

    /**
     * @notice Update devAddr
     * @param newValue address
     */
    function updateDevAddr(address newValue) public onlyDev {
        emit UpdateDevAddr(devAddr, newValue);
        devAddr = newValue;
    }

    /**
     * @notice Recover ERC20 from contract
     * @param tokenAddress token address
     * @param tokenAmount amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAmount > 0);
        require(IERC20(tokenAddress).transfer(msg.sender, tokenAmount));
        emit Recovered(tokenAddress, tokenAmount);
    }

    /**
     * @notice Recover AVAX from contract
     * @param amount amount
     */
    function recoverAVAX(uint256 amount) external onlyOwner {
        require(amount > 0);
        payable(msg.sender).transfer(amount);
        emit Recovered(address(0), amount);
    }
}

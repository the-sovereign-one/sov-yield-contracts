// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);

    function balanceOf(address owner) external view returns (uint256);
}

interface IStrategy {
    function REINVEST_REWARD_BIPS() external view returns (uint256);

    function ADMIN_FEE_BIPS() external view returns (uint256);

    function DEV_FEE_BIPS() external view returns (uint256);

    function transferOwnership(address newOwner) external;

    function updateMinRewardTokensToReinvest(uint256 newValue) external;

    function updateMinTokensToBuyBack(uint256 newValue) external;

    function updateAdminFee(uint256 newValue) external;

    function updateDevFee(uint256 newValue) external;

    function updateDepositsEnabled(bool newValue) external;

    function updateMaxRewardTokensToDepositWithoutReinvest(uint256 newValue) external;

    function updateMaxTokensToDepositWithoutBuyback(uint256 newValue) external;

    function rescueDeployedFunds(uint256 minReturnAmountAccepted, bool disableDeposits)
        external;

    function updateReinvestReward(uint256 newValue) external;

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external;

    function recoverAVAX(uint256 amount) external;

    function setAllowances() external;

    function revokeAllowance(address token, address spender) external;
}

/**
 * @notice Role-based manager for SovStrategy contracts
 * @dev SovStrategyManager may be used as `owner` on SovStrategy contracts
 */
contract StrategyManagerSA is AccessControl {
    using SafeMath for uint256;

    uint256 public constant timelockLengthForOwnershipTransfer = 2 days;

    /// @notice Sets a global maximum for fee changes using bips (100 bips = 1%)
    uint256 public maxFeeBips = 1000;

    /// @notice Pending strategy owners (strategy => pending owner)
    mapping(address => address) public pendingOwners;

    /// @notice Earliest time pending owner can take effect (strategy => timestamp)
    mapping(address => uint256) public pendingOwnersTimelock;

    /// @notice Role to manage strategy owners
    bytes32 public constant STRATEGY_OWNER_SETTER_ROLE =
        keccak256("STRATEGY_OWNER_SETTER_ROLE");

    /// @notice Role to initiate an emergency withdraw from strategies
    bytes32 public constant EMERGENCY_RESCUER_ROLE = keccak256("EMERGENCY_RESCUER_ROLE");

    /// @notice Role to sweep funds from strategies
    bytes32 public constant EMERGENCY_SWEEPER_ROLE = keccak256("EMERGENCY_SWEEPER_ROLE");

    /// @notice Role to manage global max fee configuration
    bytes32 public constant GLOBAL_MAX_FEE_SETTER_ROLE =
        keccak256("GLOBAL_MAX_FEE_SETTER_ROLE");

    /// @notice Role to manage strategy fees and reinvest configurations
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");

    /// @notice Role to allow/deny use of strategies
    bytes32 public constant STRATEGY_PERMISSIONER_ROLE =
        keccak256("STRATEGY_PERMISSIONER_ROLE");

    /// @notice Role to disable deposits on strategies
    bytes32 public constant STRATEGY_DISABLER_ROLE = keccak256("STRATEGY_DISABLER_ROLE");

    /// @notice Role to enable deposits on strategies
    bytes32 public constant STRATEGY_ENABLER_ROLE = keccak256("STRATEGY_ENABLER_ROLE");

    event ProposeOwner(address indexed strategy, address indexed newOwner);
    event SetOwner(address indexed strategy, address indexed newValue);
    event SetFees(
        address indexed strategy,
        uint256 adminFeeBips,
        uint256 devFeeBips,
        uint256 reinvestFeeBips
    );
    event SetMinRewardTokensToReinvest(address indexed strategy, uint256 newValue);
    event SetMinAmountToBuyBack(address indexed strategy, uint256 newValue);
    event SetMaxRewardTokensToDepositWithoutReinvest(
        address indexed strategy,
        uint256 newValue
    );
    event SetMaxTokensToDepositWithoutBuyback(
        address indexed strategy,
        uint256 newValue
    );
    event SetGlobalMaxFee(uint256 maxFeeBips, uint256 newMaxFeeBips);
    event SetDepositsEnabled(address indexed strategy, bool newValue);
    event SetAllowances(address indexed strategy);
    event Recover(address indexed strategy, address indexed token, uint256 amount);
    event Recovered(address token, uint256 amount);
    event EmergencyWithdraw(address indexed strategy);
    event AllowDepositor(address indexed strategy, address indexed depositor);
    event RemoveDepositor(address indexed strategy, address indexed depositor);

    constructor(address _deployer, address _team) {
        _setupRole(DEFAULT_ADMIN_ROLE, _deployer);
        _setupRole(EMERGENCY_RESCUER_ROLE, _team);
        _setupRole(EMERGENCY_SWEEPER_ROLE, _deployer);
        _setupRole(GLOBAL_MAX_FEE_SETTER_ROLE, _team);
        _setupRole(FEE_SETTER_ROLE, _team);
        _setupRole(STRATEGY_OWNER_SETTER_ROLE, _team);
        _setupRole(STRATEGY_DISABLER_ROLE, _team);
        _setupRole(STRATEGY_ENABLER_ROLE, _team);
        _setupRole(STRATEGY_PERMISSIONER_ROLE, _team);
    }

    receive() external payable {}

    /**
     * @notice Pass new value of `owner` through timelock
     * @dev Restricted to `STRATEGY_OWNER_SETTER_ROLE` to avoid griefing
     * @dev Resets timelock
     * @param strategy address
     * @param newOwner new value
     */
    function proposeOwner(address strategy, address newOwner) external {
        require(hasRole(STRATEGY_OWNER_SETTER_ROLE, msg.sender), "proposeOwner::auth");
        pendingOwnersTimelock[strategy] = block.timestamp.add(
            timelockLengthForOwnershipTransfer
        );
        pendingOwners[strategy] = newOwner;
        emit ProposeOwner(strategy, newOwner);
    }

    /**
     * @notice Set new value of `owner` and resets timelock
     * @dev This can be called by anyone
     * @param strategy address
     */
    function setOwner(address strategy) external {
        require(hasRole(STRATEGY_OWNER_SETTER_ROLE, msg.sender), "proposeOwner::auth");
        require(pendingOwnersTimelock[strategy] != 0, "setOwner::not allowed");
        require(
            pendingOwnersTimelock[strategy] <= block.timestamp,
            "setOwner::too soon"
        );
        IStrategy(strategy).transferOwnership(pendingOwners[strategy]);
        emit SetOwner(strategy, pendingOwners[strategy]);
        delete pendingOwners[strategy];
        delete pendingOwnersTimelock[strategy];
    }

    /**
     * @notice Set strategy fees
     * @dev Restricted to `FEE_SETTER_ROLE` and global max fee
     * @param strategy address
     * @param adminFeeBips deprecated
     * @param devFeeBips platform fees
     * @param reinvestRewardBips reinvest reward
     */
    function setFees(
        address strategy,
        uint256 adminFeeBips,
        uint256 devFeeBips,
        uint256 reinvestRewardBips
    ) external {
        require(hasRole(FEE_SETTER_ROLE, msg.sender), "setFees::auth");
        require(
            adminFeeBips.add(devFeeBips).add(reinvestRewardBips) <= maxFeeBips,
            "setFees::Fees too high"
        );
        if (adminFeeBips != IStrategy(strategy).ADMIN_FEE_BIPS()) {
            IStrategy(strategy).updateAdminFee(adminFeeBips);
        }
        if (devFeeBips != IStrategy(strategy).DEV_FEE_BIPS()) {
            IStrategy(strategy).updateDevFee(devFeeBips);
        }
        if (reinvestRewardBips != IStrategy(strategy).REINVEST_REWARD_BIPS()) {
            IStrategy(strategy).updateReinvestReward(reinvestRewardBips);
        }
        emit SetFees(strategy, adminFeeBips, devFeeBips, reinvestRewardBips);
    }

    /**
     * @notice Set token approvals
     * @dev Restricted to `STRATEGY_ENABLER_ROLE` to avoid griefing
     * @param strategy address
     */
    function setAllowances(address strategy) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "setAllowances::auth");
        IStrategy(strategy).setAllowances();
        emit SetAllowances(strategy);
    }

    /**
     * @notice Revoke token approvals
     * @dev Restricted to `STRATEGY_DISABLER_ROLE` and `EMERGENCY_RESCUER_ROLE` to avoid griefing
     * @param strategy address
     * @param token address
     * @param spender address
     */
    function revokeAllowance(
        address strategy,
        address token,
        address spender
    ) external {
        require(
            hasRole(STRATEGY_DISABLER_ROLE, msg.sender) ||
                hasRole(EMERGENCY_RESCUER_ROLE, msg.sender),
            "revokeAllowance::auth"
        );
        IStrategy(strategy).revokeAllowance(token, spender);
    }

    /**
     * @notice Set max strategy fees
     * @dev Restricted to `GLOBAL_MAX_FEE_SETTER_ROLE`
     * @param newMaxFeeBips max strategy fees
     */
    function updateGlobalMaxFees(uint256 newMaxFeeBips) external {
        require(
            hasRole(GLOBAL_MAX_FEE_SETTER_ROLE, msg.sender),
            "updateGlobalMaxFees::auth"
        );
        emit SetGlobalMaxFee(maxFeeBips, newMaxFeeBips);
        maxFeeBips = newMaxFeeBips;
    }

    /**
     * @notice Permissioned function to set min tokens to buyback
     * @dev Restricted to `FEE_SETTER_ROLE`
     * @param strategy address
     * @param newValue min tokens to buyback
     */
    function setMinAmountToBuyBack(address strategy, uint256 newValue) external {
        require(hasRole(FEE_SETTER_ROLE, msg.sender), "setMinAmountToBuyBack::auth");
        IStrategy(strategy).updateMinTokensToBuyBack(newValue);
        emit SetMinAmountToBuyBack(strategy, newValue);
    }

    /**
     * @notice Permissioned function to set min tokens to reinvest
     * @dev Restricted to `FEE_SETTER_ROLE`
     * @param strategy address
     * @param newValue min tokens to reinvest
     */
    function setMinRewardTokensToReinvest(address strategy, uint256 newValue) external {
        require(
            hasRole(FEE_SETTER_ROLE, msg.sender),
            "setMinRewardTokensToReinvest::auth"
        );
        IStrategy(strategy).updateMinRewardTokensToReinvest(newValue);
        emit SetMinRewardTokensToReinvest(strategy, newValue);
    }

    /**
     * @notice Permissioned function to set max tokens to deposit without reinvest
     * @dev Restricted to `FEE_SETTER_ROLE`
     * @param strategy address
     * @param newValue max tokens to deposit without reinvest
     */
    function setMaxRewardTokensToDepositWithoutReinvest(
        address strategy,
        uint256 newValue
    ) external {
        require(
            hasRole(FEE_SETTER_ROLE, msg.sender),
            "setMaxRewardTokensToDepositWithoutReinvest::auth"
        );
        IStrategy(strategy).updateMaxRewardTokensToDepositWithoutReinvest(newValue);
        emit SetMaxRewardTokensToDepositWithoutReinvest(strategy, newValue);
    }

    /**
     * @notice Permissioned function to set max tokens to deposit without buyback
     * @dev Restricted to `FEE_SETTER_ROLE`
     * @param strategy address
     * @param newValue max tokens to deposit without buyback
     */
    function setMaxTokensToDepositWithoutBuyback(address strategy, uint256 newValue)
        external
    {
        require(
            hasRole(FEE_SETTER_ROLE, msg.sender),
            "setMaxTokensToDepositWithoutBuyBack::auth"
        );
        IStrategy(strategy).updateMaxTokensToDepositWithoutBuyback(newValue);
        emit SetMaxTokensToDepositWithoutBuyback(strategy, newValue);
    }

    /**
     * @notice Permissioned function to enable deposits
     * @dev Restricted to `STRATEGY_ENABLER_ROLE`
     * @param strategy address
     */
    function enableDeposits(address strategy) external {
        require(hasRole(STRATEGY_ENABLER_ROLE, msg.sender), "enableDeposits::auth");
        IStrategy(strategy).updateDepositsEnabled(true);
        emit SetDepositsEnabled(strategy, true);
    }

    /**
     * @notice Permissioned function to disable deposits
     * @dev Restricted to `STRATEGY_DISABLER_ROLE`
     * @param strategy address
     */
    function disableDeposits(address strategy) external {
        require(hasRole(STRATEGY_DISABLER_ROLE, msg.sender), "disableDeposits::auth");
        IStrategy(strategy).updateDepositsEnabled(false);
        emit SetDepositsEnabled(strategy, false);
    }

    /**
     * @notice Permissioned function to recover deployed assets back into the strategy contract
     * @dev Restricted to `EMERGENCY_RESCUER_ROLE`
     * @dev Always passes `true` to disable deposits
     * @dev Rescued funds stay in strategy until recovered (see `recover*`)
     * @param strategy address
     * @param minReturnAmountAccepted amount
     */
    function rescueDeployedFunds(address strategy, uint256 minReturnAmountAccepted)
        external
    {
        require(
            hasRole(EMERGENCY_RESCUER_ROLE, msg.sender),
            "rescueDeployedFunds::auth"
        );
        IStrategy(strategy).rescueDeployedFunds(minReturnAmountAccepted, true);
        emit EmergencyWithdraw(strategy);
    }

    /**
     * @notice Permissioned function to recover and transfer any token from strategy contract
     * @dev Restricted to `EMERGENCY_SWEEPER_ROLE`
     * @dev Intended for use in case of `rescueDeployedFunds`
     * @param strategy address
     * @param tokenAddress address
     * @param tokenAmount amount
     */
    function recoverTokens(
        address strategy,
        address tokenAddress,
        uint256 tokenAmount
    ) external {
        require(hasRole(EMERGENCY_SWEEPER_ROLE, msg.sender), "recoverTokens::auth");
        IStrategy(strategy).recoverERC20(tokenAddress, tokenAmount);
        _transferTokens(tokenAddress, tokenAmount);
        emit Recover(strategy, tokenAddress, tokenAmount);
    }

    /**
     * @notice Permissioned function to transfer any token from this contract
     * @dev Restricted to `EMERGENCY_SWEEPER_ROLE`
     * @param tokenAddress token address
     * @param tokenAmount amount
     */
    function sweepTokens(address tokenAddress, uint256 tokenAmount) external {
        require(hasRole(EMERGENCY_SWEEPER_ROLE, msg.sender), "sweepTokens::auth");
        _transferTokens(tokenAddress, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /**
     * @notice Internal function to transfer tokens to msg.sender
     * @param tokenAddress token address
     * @param tokenAmount amount
     */
    function _transferTokens(address tokenAddress, uint256 tokenAmount) internal {
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        if (tokenAmount < balance) {
            tokenAmount = balance;
        }
        require(
            IERC20(tokenAddress).transfer(msg.sender, tokenAmount),
            "_transferTokens::transfer failed"
        );
    }

    /**
     * @notice Permissioned function to transfer AVAX from any strategy into this contract
     * @dev Restricted to `EMERGENCY_SWEEPER_ROLE`
     * @dev After recovery, contract may become gas-bound.
     * @dev Intended for use in case of `rescueDeployedFunds`, as deposit tokens will be locked in the strategy.
     * @param strategy address
     * @param amount amount
     */
    function recoverAVAX(address strategy, uint256 amount) external {
        require(hasRole(EMERGENCY_SWEEPER_ROLE, msg.sender), "recoverAVAX::auth");
        emit Recover(strategy, address(0), amount);
        IStrategy(strategy).recoverAVAX(amount);
    }

    /**
     * @notice Permissioned function to transfer AVAX from this contract
     * @dev Restricted to `EMERGENCY_SWEEPER_ROLE`
     * @param amount amount
     */
    function sweepAVAX(uint256 amount) external {
        require(hasRole(EMERGENCY_SWEEPER_ROLE, msg.sender), "sweepAVAX::auth");
        uint256 balance = address(this).balance;
        if (amount < balance) {
            amount = balance;
        }
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success == true, "recoverAVAX::transfer failed");
        emit Recovered(address(0), amount);
    }
}

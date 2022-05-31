// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "../../interfaces/SovereignLpToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../registry/SovRegistry.sol";
import "../../interfaces/BaseSavingsStrategy.sol";

/**
 * @notice SovVault is a managed vault for `deposit tokens` that accepts deposits in the form of `deposit tokens` OR `strategy tokens`.
 */
contract SovSavingsVaultForSA is SovereignYieldERC20, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant BIPS_DIVISOR = 10000;

    /// @notice Vault version number
    string public constant version = "0.0.1";

    /// @notice SovRegistry address
    SovRegistry public sovRegistry;

    /// @notice Deposit token that the vault manages
    IERC20 public depositToken;

    /// @notice Active strategy where deposits are sent by default
    address public activeStrategy;

    EnumerableSet.AddressSet internal supportedStrategies;

    event Deposit(address indexed account, address indexed token, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event AddStrategy(address indexed strategy);
    event RemoveStrategy(address indexed strategy);
    event SetActiveStrategy(address indexed strategy);

    constructor(
        string memory _name,
        address _depositToken,
        address _sovRegistry
    ) {
        name = _name;
        depositToken = IERC20(_depositToken);
        sovRegistry = SovRegistry(_sovRegistry);
    }

    /**
     * @notice Deposit to currently active strategy
     * @dev Vaults may allow multiple types of tokens to be deposited
     * @dev By default, Vaults send new deposits to the active strategy
     * @param amount amount
     */
    function deposit(uint256 amount) external nonReentrant {
        _deposit(msg.sender, amount);
    }

    function _deposit(address account, uint256 amount) private {
        require(amount > 0, "SovVault::deposit, amount too low");
        require(checkStrategies(), "SovVault::deposit, deposit temporarily paused");
        _mint(account, amount);
        IERC20(depositToken).safeTransferFrom(msg.sender, address(this), amount);
        if (activeStrategy != address(0)) {
            depositToken.safeApprove(activeStrategy, amount);
            BaseSavingsStrategy(activeStrategy).deposit(amount);
            depositToken.safeApprove(activeStrategy, 0);
        }
        emit Deposit(account, address(depositToken), amount);
    }

    /**
     * @notice Withdraw from the vault
     * @param amount receipt tokens
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(checkStrategies(), "SovVault::withdraw, withdraw temporarily paused");
        uint256 depositTokenAmount = amount;
        require(depositTokenAmount > 0, "SovVault::withdraw, amount too low");
        uint256 liquidDeposits = depositToken.balanceOf(address(this));
        if (liquidDeposits < depositTokenAmount) {
            uint256 remainingDebt = depositTokenAmount - (liquidDeposits);
            for (uint256 i = 0; i < supportedStrategies.length(); i++) {
                address strategy = supportedStrategies.at(i);
                uint256 deployedBalance = getDeployedBalance(strategy);
                if (deployedBalance > remainingDebt) {
                    _withdrawFromStrategy(strategy, remainingDebt);
                    break;
                } else if (deployedBalance > 0) {
                    _withdrawPercentageFromStrategy(strategy, 10000);
                    remainingDebt = remainingDebt - (deployedBalance);
                    if (remainingDebt <= 1) {
                        break;
                    }
                }
            }
            uint256 balance = depositToken.balanceOf(address(this));
            if (balance < depositTokenAmount) {
                depositTokenAmount = balance;
            }
        }
        depositToken.safeTransfer(msg.sender, depositTokenAmount);
        _burn(msg.sender, amount);
        emit Withdraw(msg.sender, depositTokenAmount);
    }

    function setRegistry(address _sovRegistry) external onlyOwner {
        sovRegistry = SovRegistry(_sovRegistry);
    }

    function checkStrategies() internal view returns (bool) {
        for (uint256 i = 0; i < supportedStrategies.length(); i++) {
            if (sovRegistry.isHaltedStrategy(supportedStrategies.at(i))) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Set an active strategy
     * @dev Set to address(0) to disable automatic deposits to active strategy on vault deposits
     * @param strategy address for new strategy
     */
    function setActiveStrategy(address strategy) public onlyOwner {
        require(
            strategy == address(0) || supportedStrategies.contains(strategy),
            "SovVault::setActiveStrategy, not found"
        );
        activeStrategy = strategy;
        emit SetActiveStrategy(strategy);
    }

    /**
     * @notice Add a supported strategy and allow deposits
     * @dev Makes light checks for compatible deposit tokens
     * @param strategy address for new strategy
     */
    function addStrategy(address strategy) public onlyOwner {
        require(
            sovRegistry.isActiveStrategy(strategy),
            "SovVault::addStrategy, not registered"
        );
        require(
            supportedStrategies.contains(strategy) == false,
            "SovVault::addStrategy, already supported"
        );
        require(
            depositToken == BaseSavingsStrategy(strategy).depositToken(),
            "SovVault::addStrategy, not compatible"
        );
        supportedStrategies.add(strategy);
        emit AddStrategy(strategy);
    }

    /**
     * @notice Remove a supported strategy and revoke approval
     * @param strategy address for new strategy
     */
    function removeStrategy(address strategy) public onlyOwner {
        require(
            sovRegistry.pausedStrategies(strategy) == false,
            "SovVault::removeStrategy, cannot remove paused strategy"
        );
        require(
            sovRegistry.isActiveStrategy(strategy) == false,
            "SovVault::removeStrategy, cannot remove activeStrategy"
        );

        require(
            supportedStrategies.contains(strategy),
            "SovVault::removeStrategy, not supported"
        );
        require(
            sovRegistry.disabledStrategies(strategy) ||
                getDeployedBalance(strategy) == 0,
            "SovVault::removeStrategy, cannot remove enabled strategy with funds"
        );
        depositToken.safeApprove(strategy, 0);
        supportedStrategies.remove(strategy);
        setActiveStrategy(address(0));
        emit RemoveStrategy(strategy);
    }

    /**
     * @notice Owner method for removing funds from strategy (to rebalance, typically)
     * @param strategy address
     * @param amount deposit tokens
     */
    function withdrawFromStrategy(address strategy, uint256 amount) public onlyOwner {
        _withdrawFromStrategy(strategy, amount);
    }

    function _withdrawFromStrategy(address strategy, uint256 amount) private {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        BaseSavingsStrategy(strategy).withdraw(amount);
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter > balanceBefore,
            "SovVault::_withdrawDepositTokensFromStrategy, withdrawal failed"
        );
    }

    /**
     * @notice Owner method for removing funds from strategy (to rebalance, typically)
     * @param strategy address
     * @param withdrawPercentageBips percentage to withdraw from strategy, 10000 = 100%
     */
    function withdrawPercentageFromStrategy(
        address strategy,
        uint256 withdrawPercentageBips
    ) public onlyOwner {
        _withdrawPercentageFromStrategy(strategy, withdrawPercentageBips);
    }

    function _withdrawPercentageFromStrategy(
        address strategy,
        uint256 withdrawPercentageBips
    ) private {
        require(
            withdrawPercentageBips > 0 && withdrawPercentageBips <= BIPS_DIVISOR,
            "SovVault::_withdrawPercentageFromStrategy, invalid percentage"
        );
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        uint256 withdrawalStrategyShares = 0;
        uint256 shareBalance = BaseSavingsStrategy(strategy).balanceOf(address(this));
        withdrawalStrategyShares = shareBalance.mul(withdrawPercentageBips).div(
            BIPS_DIVISOR
        );
        BaseSavingsStrategy(strategy).withdraw(withdrawalStrategyShares);
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter > balanceBefore,
            "SovVault::_withdrawPercentageFromStrategy, withdrawal failed"
        );
    }

    /**
     * @notice Owner method for deposit funds into strategy
     * @param strategy address
     * @param amount deposit tokens
     */
    function depositToStrategy(address strategy, uint256 amount) public onlyOwner {
        require(
            supportedStrategies.contains(strategy),
            "SovVault::depositToStrategy, strategy not registered"
        );
        uint256 depositTokenBalance = depositToken.balanceOf(address(this));
        require(
            depositTokenBalance >= amount,
            "SovVault::depositToStrategy, amount exceeds balance"
        );
        depositToken.safeApprove(strategy, amount);
        BaseSavingsStrategy(strategy).deposit(amount);
        depositToken.safeApprove(strategy, 0);
    }

    /**
     * @notice Owner method for deposit funds into strategy
     * @param strategy address
     * @param depositPercentageBips percentage to deposit into strategy, 10000 = 100%
     */
    function depositPercentageToStrategy(address strategy, uint256 depositPercentageBips)
        public
        onlyOwner
    {
        require(
            depositPercentageBips > 0 && depositPercentageBips <= BIPS_DIVISOR,
            "SovVault::depositPercentageToStrategy, invalid percentage"
        );
        require(
            supportedStrategies.contains(strategy),
            "SovVault::depositPercentageToStrategy, strategy not registered"
        );
        uint256 depositTokenBalance = depositToken.balanceOf(address(this));
        require(
            depositTokenBalance >= 0,
            "SovVault::depositPercentageToStrategy, balance zero"
        );
        uint256 amount = depositTokenBalance.mul(depositPercentageBips).div(
            BIPS_DIVISOR
        );
        depositToken.safeApprove(strategy, amount);
        BaseSavingsStrategy(strategy).deposit(amount);
        depositToken.safeApprove(strategy, 0);
    }

    /**
     * @notice Count deposit tokens deployed in a strategy
     * @param strategy address
     * @return amount deposit tokens
     */
    function getDeployedBalance(address strategy) public view returns (uint256) {
        uint256 vaultShares = BaseSavingsStrategy(strategy).balanceOf(address(this));
        return vaultShares;
    }

    /**
     * @notice Count deposit tokens deployed across supported strategies
     * @dev Does not include deprecated strategies
     * @return amount deposit tokens
     */
    function estimateDeployedBalances() public view returns (uint256) {
        uint256 deployedFunds = 0;
        for (uint256 i = 0; i < supportedStrategies.length(); i++) {
            deployedFunds =
                deployedFunds +
                (getDeployedBalance(supportedStrategies.at(i)));
        }
        return deployedFunds;
    }

    function totalDeposits() public view returns (uint256) {
        uint256 deposits = depositToken.balanceOf(address(this));
        for (uint256 i = 0; i < supportedStrategies.length(); i++) {
            BaseSavingsStrategy strategy = BaseSavingsStrategy(
                supportedStrategies.at(i)
            );
            deposits = deposits + (strategy.totalDeposits());
        }
        return deposits;
    }
}

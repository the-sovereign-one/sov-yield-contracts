// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SovereignLpToken.sol";
import "./BaseSavingsStrategy.sol";

/**
 * @notice SovStrategy should be inherited by new strategies
 */
abstract contract BaseStrategyPayable is BaseSavingsStrategy {
    /**
     * @notice Deposit and deploy deposits tokens to the strategy using AVAX
     * @dev Must mint receipt tokens to `msg.sender`
     */
    function deposit() external payable virtual;

    /**
     * @notice Deposit on behalf of another account using AVAX
     * @dev Must mint receipt tokens to `account`
     * @param account address to receive receipt tokens
     */
    function depositFor(address account) external payable virtual;
}

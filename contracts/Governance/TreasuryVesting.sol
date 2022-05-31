// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Contract to control the release of SVB.
 */
contract TreasuryVester is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public svb;
    address public recipient;

    // Amount to distribute at each interval in wei
    // 480,769.23 SVB
    uint256 public vestingAmount = 480_769_230_000_000_000_000_000;

    // Interval to distribute in seconds
    uint256 public vestingCliff = 604_800;

    bool public vestingEnabled;

    // Timestamp of latest distribution
    uint256 public lastUpdate;

    // Amount of SVB required to start distributing denominated in wei
    // Should be 100 million SVB
    uint256 public startingBalance = 100_000_000_000_000_000_000_000_000;

    event VestingEnabled();
    event TokensVested(uint256 amount, address recipient);
    event RecipientChanged(address recipient);

    // SVB Distribution plan:
    // According to the Sovereign Litepaper, we will distribute
    // 68493.15 SVB per day. Vesting period will be 24 hours: 86400 seconds.

    constructor(address svb_) {
        svb = svb_;
        lastUpdate = 0;
    }

    /**
     * Enable distribution. A sufficient amount of SVB >= startingBalance must be transferred
     * to the contract before enabling. The recipient must also be set. Can only be called by
     * the owner.
     */
    function startVesting() external onlyOwner {
        require(
            !vestingEnabled,
            "TreasuryVester::startVesting: vesting already started"
        );
        require(
            IERC20(svb).balanceOf(address(this)) >= startingBalance,
            "TreasuryVester::startVesting: incorrect SVB supply"
        );
        require(
            recipient != address(0),
            "TreasuryVester::startVesting: recipient not set"
        );
        vestingEnabled = true;

        emit VestingEnabled();
    }

    /**
     * Sets the recipient of the vested distributions. In the initial Soveriegn scheme, this
     * should be the address of the LiquidityManager. Can only be called by the contract
     * owner.
     */
    function setRecipient(address recipient_) external onlyOwner {
        require(
            recipient_ != address(0),
            "TreasuryVester::setRecipient: Recipient can't be the zero address"
        );
        recipient = recipient_;
        emit RecipientChanged(recipient);
    }

    /**
     * Vest the next SVG allocation. Requires vestingCliff seconds in between calls. SVG will
     * be distributed to the recipient.
     */
    function claim() external nonReentrant returns (uint256) {
        require(vestingEnabled, "TreasuryVester::claim: vesting not enabled");
        require(
            msg.sender == recipient,
            "TreasuryVester::claim: only recipient can claim"
        );
        require(
            block.timestamp >= lastUpdate + vestingCliff,
            "TreasuryVester::claim: not time yet"
        );

        // Update the timelock
        lastUpdate = block.timestamp;

        // Distribute the tokens
        IERC20(svb).safeTransfer(recipient, vestingAmount);
        emit TokensVested(vestingAmount, recipient);

        return vestingAmount;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../../interfaces/BaseSavingsStrategy.sol";

/**
 * @notice SovRegistry is a list of officially supported strategies.
 */
contract SovRegistry is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => uint256) public strategyIdForStrategyAddress;
    mapping(address => uint256[]) public strategyIdsForDepositToken;
    mapping(address => bool) public pausedStrategies;
    mapping(address => bool) public disabledStrategies;
    EnumerableSet.AddressSet private strategies;

    struct StrategyInfo {
        uint256 id;
        address strategyAddress;
        bool depositsEnabled;
        address depositToken;
        address rewardToken;
        uint256 minRewardTokensToReinvest;
        uint256 maxRewardTokensToDepositWithoutReinvest;
        uint256 minTokensToBuyback;
        uint256 maxTokensToDepositWithoutBuyback;
        uint256 adminFeeBips;
        uint256 devFeeBips;
        uint256 reinvestRewardBips;
    }

    event AddStrategy(address indexed strategy);

    constructor() {}

    function isActiveStrategy(address _strategy) external view returns (bool) {
        BaseSavingsStrategy strategy = BaseSavingsStrategy(_strategy);
        return
            strategies.contains(_strategy) &&
            strategy.DEPOSITS_ENABLED() &&
            !pausedStrategies[_strategy] &&
            !disabledStrategies[_strategy];
    }

    function isHaltedStrategy(address _strategy) external view returns (bool) {
        return pausedStrategies[_strategy] || disabledStrategies[_strategy];
    }

    function strategiesForDepositTokenCount(address _depositToken)
        external
        view
        returns (uint256)
    {
        return strategyIdsForDepositToken[_depositToken].length;
    }

    function strategyInfo(uint256 _sId) external view returns (StrategyInfo memory) {
        address strategyAddress = strategies.at(_sId);
        BaseSavingsStrategy strategy = BaseSavingsStrategy(strategyAddress);
        return
            StrategyInfo({
                id: _sId,
                strategyAddress: address(strategy),
                depositsEnabled: strategy.DEPOSITS_ENABLED(),
                depositToken: address(strategy.depositToken()),
                rewardToken: address(strategy.rewardToken()),
                minRewardTokensToReinvest: strategy.MIN_REWARD_TOKENS_TO_REINVEST(),
                maxRewardTokensToDepositWithoutReinvest: strategy
                    .MAX_REWARD_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST(),
                minTokensToBuyback: strategy.MIN_TOKENS_TO_BUYBACK(),
                maxTokensToDepositWithoutBuyback: strategy
                    .MAX_TOKENS_TO_DEPOSIT_WITHOUT_BUYBACK(),
                adminFeeBips: strategy.ADMIN_FEE_BIPS(),
                devFeeBips: strategy.DEV_FEE_BIPS(),
                reinvestRewardBips: strategy.REINVEST_REWARD_BIPS()
            });
    }

    function strategyId(address _strategy) public view returns (uint256) {
        return strategyIdForStrategyAddress[_strategy];
    }

    function strategiesCount() external view returns (uint256) {
        return strategies.length();
    }

    /**
     * @notice Add a new SovStrategy
     * @dev Calls strategyInfo() to verify the new strategy implements required interface
     * @param _strategy address for new strategy
     * @return StrategyInfo of added strategy
     */
    function addStrategy(address _strategy)
        external
        onlyOwner
        returns (StrategyInfo memory)
    {
        require(
            strategies.add(_strategy),
            "SovRegistry::addStrategy, strategy already added"
        );
        uint256 id = strategies.length() - 1;
        address depositToken = address(BaseSavingsStrategy(_strategy).depositToken());
        strategyIdsForDepositToken[depositToken].push(id);
        strategyIdForStrategyAddress[_strategy] = id;
        StrategyInfo memory info = this.strategyInfo(id);
        emit AddStrategy(_strategy);
        return info;
    }

    function pauseStrategy(address _strategy) external onlyOwner {
        pausedStrategies[_strategy] = true;
    }

    function disableStrategy(address _strategy) external onlyOwner {
        pausedStrategies[_strategy] = false;
        disabledStrategies[_strategy] = true;
    }

    function resumeStrategy(address _strategy) external onlyOwner {
        pausedStrategies[_strategy] = false;
        disabledStrategies[_strategy] = false;
    }

    function removeStrategy(address _strategy) external onlyOwner {
        require(
            strategies.contains(_strategy) &&
                !pausedStrategies[_strategy] &&
                !disabledStrategies[_strategy],
            "SovRegistry::removeStrategy, cant' remove active strategy"
        );
        uint256 _id = strategyId(_strategy);
        strategies.remove(_strategy);
        delete disabledStrategies[_strategy];
        delete pausedStrategies[_strategy];
        delete strategyIdForStrategyAddress[_strategy];
        address _depositToken = address(BaseSavingsStrategy(_strategy).depositToken());
        delete strategyIdsForDepositToken[_depositToken][_id];
    }
}

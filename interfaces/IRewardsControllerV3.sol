// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface IRewardsControllerV3 {
    function setRewardBalance() external returns (uint256);

    function deposit(uint256 amount) external;

    /**
     * @dev Claims all rewards for a user to the desired address, on all the assets of the pool, accumulating the pending rewards
     * @param assets The list of assets to check eligible distributions before claiming rewards
     * @param to The address that will be receiving the rewards
     * @return rewardsList List of addresses of the reward tokens
     * @return claimedAmounts List that contains the claimed amount per reward, following same order as "rewardList"
     **/
    function claimAllRewards(address[] calldata assets, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);

    function claimRewards(
        address[] calldata assets,
        uint256 amount,
        address to,
        address reward
    ) external returns (uint256);

    function getAllUserRewards(address[] calldata assets, address to)
        external
        view
        returns (address[] memory, uint256[] memory);
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract IRewardDistributionRecipient is Ownable {
    address rewardDistribution;

    function notifyRewardAmount(uint256 reward, uint256 duration)
        external
        virtual;

    modifier onlyRewardDistribution() {
        require(
            _msgSender() == rewardDistribution,
            "Caller is not reward distribution"
        );
        _;
    }

    function setRewardDistribution(address _rewardDistribution)
        external
        onlyOwner
    {
        rewardDistribution = _rewardDistribution;
    }
}

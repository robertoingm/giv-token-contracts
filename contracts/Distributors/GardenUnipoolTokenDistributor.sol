/**
 * Contract has the most of the functionalities of UnipoolTokenDistributor contract, but is updated
 * to be compatible with token-manager-app of 1Hive.
 * 1. Stake/Withdraw methods are updated to internal type.
 * 2. Methods related to permit are removed.
 * 3. Stake/Withdraw are update based on 1Hive unipool (https://github.com/1Hive/unipool/blob/master/contracts/Unipool.sol).
 * This PR was the guide: https://github.com/1Hive/unipool/pull/7/files
 */

// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.8.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../Interfaces/IDistro.sol";
import "./TokenManagerHook.sol";

// Based on: https://github.com/Synthetixio/Unipool/tree/master/contracts
/*
 * changelog:
 *      * Added SPDX-License-Identifier
 *      * Update to solidity ^0.8.0
 *      * Update openzeppelin imports
 *      * IRewardDistributionRecipient integrated in Unipool and removed
 *      * Added virtual and override to stake and withdraw methods
 *      * Added constructors to LPTokenWrapper and Unipool
 *      * Change transfer to allocate (TokenVesting)
 *      * Added `stakeWithPermit` function for NODE and the BridgeToken
 */
contract LPTokenWrapper {
    using SafeMathUpgradeable for uint256;

    uint256 private _totalSupply;
    mapping(address => uint256) internal _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(address user, uint256 amount) internal virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[user] = _balances[user].add(amount);
    }

    function withdraw(address user, uint256 amount) internal virtual {
        _totalSupply = _totalSupply.sub(amount);
        _balances[user] = _balances[user].sub(amount);
    }
}

contract GardenUnipoolTokenDistributor is
    LPTokenWrapper,
    TokenManagerHook,
    OwnableUpgradeable
{
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IDistro public tokenDistro;
    uint256 public duration;

    address public rewardDistribution;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    modifier onlyRewardDistribution() {
        require(
            _msgSender() == rewardDistribution,
            "Caller is not reward distribution"
        );
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function initialize(
        IDistro _tokenDistribution,
        IERC20Upgradeable _uni,
        uint256 _duration
    ) public initializer {
        __Ownable_init();
        tokenDistro = _tokenDistribution;
        duration = _duration;
        periodFinish = 0;
        rewardRate = 0;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return MathUpgradeable.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    function stake(address user, uint256 amount)
        internal
        override
        updateReward(user)
    {
        require(amount > 0, "Cannot stake 0");
        super.stake(user, amount);
        emit Staked(user, amount);
    }

    function withdraw(address user, uint256 amount)
        internal
        override
        updateReward(user)
    {
        require(amount > 0, "Cannot withdraw 0");
        super.withdraw(user, amount);
        if (_balances[user] == 0) {
            _getReward(user);
        }
        emit Withdrawn(user, amount);
    }

    function getReward() public updateReward(msg.sender) {
        _getReward(msg.sender);
    }

    function _getReward(address user) internal {
        uint256 reward = earned(user);
        if (reward > 0) {
            rewards[user] = 0;
            //token.safeTransfer(msg.sender, reward);
            tokenDistro.allocate(user, reward);
            emit RewardPaid(user, reward);
        }
    }

    function notifyRewardAmount(uint256 reward)
        external
        onlyRewardDistribution
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(duration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(duration);
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(duration);
        emit RewardAdded(reward);
    }

    function setRewardDistribution(address _rewardDistribution)
        external
        onlyOwner
    {
        rewardDistribution = _rewardDistribution;
    }

    /**
     * @dev Overrides TokenManagerHook's `_onTransfer`
     * @notice this function is a complete copy/paste from
     * https://github.com/1Hive/unipool/blob/master/contracts/Unipool.sol
     */
    function _onTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override returns (bool) {
        if (_from == address(0)) {
            // Token mintings (wrapping tokens)
            stake(_to, _amount);
            return true;
        } else if (_to == address(0)) {
            // Token burning (unwrapping tokens)
            withdraw(_from, _amount);
            return true;
        } else {
            // Standard transfer
            withdraw(_from, _amount);
            stake(_to, _amount);
            return true;
        }
    }
}

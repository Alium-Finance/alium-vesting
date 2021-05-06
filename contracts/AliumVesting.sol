// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IAliumVesting.sol";
import "./interfaces/IAliumCash.sol";

/**
 * @title AliumVesting - Vesting contract for alium
 * tokens distribution.
 *
 * @author Eugene Rupakov <eugene.rupakov@gmail.com>
 * @author Pavel Bolhar <paul.bolhar@gmail.com>
 */
contract AliumVesting is Ownable, IAliumVesting {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_LOCK_PLANS = 3;
    uint256 public constant MAX_PLAN_LENGTH = 32;
    uint256 public constant SYS_DECIMAL = 100;

    /* Real beneficiary address is a param to this mapping */
    // stores total locked amounts
    mapping(address => uint256[MAX_LOCK_PLANS]) private _lockTable;
    // stores withdrawn amounts
    mapping(address => uint256[MAX_LOCK_PLANS]) private _withdrawTable;

    uint256[][MAX_LOCK_PLANS] public lockPlanTimes;
    uint256[][MAX_LOCK_PLANS] public lockPlanPercents;
    uint256[MAX_LOCK_PLANS] private _lockedTotal;

    event TokensLocked(address indexed beneficiary, uint256 amount);
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event PlanAdded(uint256 planId);
    event PlanRemoved(uint256 planId);
    event ReleaseTimeSet(uint256 releaseTime);

    address public token;
    address public cashier;
    address public freezerRole;
    uint256 public releaseTime;

    /**
     * @dev Constructor setting {_vestingToken}, {_cashier} and {_freezer} addresses,
     * {_releaseAt} timestamp
     */
    constructor(
        address _vestingToken,
        address _cashier,
        address _freezer,
        uint256 _releaseAt
    ) public {
        require(_vestingToken != address(0), "Vesting: token address cannot be empty");
        require(_cashier != address(0), "Vesting: cashier address cannot be empty");
        require(_freezer != address(0), "Vesting: freezer address cannot be empty");

        token = _vestingToken;
        cashier = _cashier;
        freezerRole = _freezer;

        _setReleaseTime(_releaseAt);
    }

    /**
     * @dev Returns unlock date and amount of given lock.
     */
    function getLockPlanLen(uint256 _planId)
        external
        view
        returns (uint256)
    {
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        return lockPlanTimes[_planId].length;
    }

    /**
     * @dev Returns closest unlock date and amount.
     */
    function getNextUnlockFor(address _beneficiary)
        external
        view
        override
        returns (uint256 timestamp, uint256 amount)
    {
        for (uint256 i = 0; i < MAX_LOCK_PLANS; i++) {
            // cycle through each plan
            (uint256 t2, uint256 percent) = _getNextUnlock(i);
            if (t2 < timestamp) {
                timestamp = t2;
                amount = _lockTable[_beneficiary][i].mul(percent).div(100);
            } else if (t2 == timestamp) {
                amount = amount.add(_lockTable[_beneficiary][i].mul(percent).div(100));
            }
        }

        return (timestamp, amount);
    }

    /**
     * @dev Returns the total amount of next unlock amounts for different plans.
     */
    function getNextUnlockAt(uint256 _planId)
        external
        view
        override
        returns (uint256 timestamp, uint256 amount)
    {
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        (uint256 unlockTime, uint256 unlockPercents) = _getNextUnlock(_planId);

        return (unlockTime, _lockedTotal[_planId].mul(unlockPercents).div(100));
    }

    /**
     * @dev returns balances(total frozen, available frozen, withdrawn) of
     * {_beneficiary} for all plans
     */
    function getTotalBalanceOf(address _beneficiary)
        external
        view
        override
        returns (
            uint256 totalBalance,
            uint256 frozenBalance,
            uint256 withdrawnBalance
        )
    {
        uint8 i = 0;
        for (; i < MAX_LOCK_PLANS; i++) {
            totalBalance = totalBalance.add(_lockTable[_beneficiary][i]);
            withdrawnBalance = withdrawnBalance.add(
                _withdrawTable[_beneficiary][i]
            );
        }

        return (
            totalBalance,
            totalBalance.sub(withdrawnBalance),
            withdrawnBalance
        );
    }

    /**
     * @dev returns balances(total frozen, available frozen, withdrawn) of
     * {_beneficiary} by {_planId}
     */
    function getBalanceOf(address _beneficiary, uint256 _planId)
        external
        view
        override
        returns (
            uint256 totalBalance,
            uint256 frozenBalance,
            uint256 withdrawnBalance
        )
    {
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        totalBalance = _lockTable[_beneficiary][_planId];
        withdrawnBalance = _withdrawTable[_beneficiary][_planId];

        return (
            totalBalance,
            totalBalance.sub(withdrawnBalance),
            withdrawnBalance
        );
    }

    // @dev returns possible reward at current time
    function pendingReward(address _beneficiary, uint256 _planId)
        external
        view
        override
        returns (uint256)
    {
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        if (block.timestamp < releaseTime) {
            return 0;
        }

        uint256 unlockPercents;
        uint256 j;
        for (j; j < lockPlanTimes[_planId].length; j++) {
            if (lockPlanTimes[_planId][j] + releaseTime <= block.timestamp) {
                unlockPercents += lockPlanPercents[_planId][j];
            }
        }

        uint256 claimedBalance = _withdrawTable[_beneficiary][_planId];
        uint256 unlockedPlanned = _lockTable[_beneficiary][_planId].mul(unlockPercents).div(100);
        if (unlockedPlanned > claimedBalance) {
            return unlockedPlanned - claimedBalance;
        }

        return 0;
    }

    /**
     * @dev claim from all possible plans
     */
    function claimAll() external override {
        for (uint i = 0; i < MAX_LOCK_PLANS; i++) {
            _claim(msg.sender, i);
        }
    }

    /**
     * @dev claim from a given plan
     */
    function claim(uint256 _planId) external override {
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        _claim(msg.sender, _planId);
    }

    /**
     * @dev freeze some token {_amount} by alium collectible type,
     * what represented as {_planId}
     *
     * Permission: {onlyFreezer}
     */
    function freeze(
        address _beneficiary,
        uint256 _amount,
        uint8 _planId
    ) external override onlyFreezer returns (bool success) {
        require(_beneficiary != address(0), "Vesting: beneficiary address cannot be 0");
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        _lockTable[_beneficiary][_planId] =
        _lockTable[_beneficiary][_planId].add(_amount);
        _lockedTotal[_planId] = _lockedTotal[_planId].add(_amount);
        IAliumCash(cashier).withdraw(_amount);
        emit TokensLocked(_beneficiary, _amount);

        return true;
    }

    /**
     * @dev add a new blocking plan with a specific {_planId}, {_times} and
     * {_percents} allocation
     *
     * Permission: {onlyOwner}
     */
    function addLockPlan(
        uint256 _planId,
        uint256[] calldata _times,
        uint256[] calldata _percents
    ) external onlyOwner {
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        uint items = _percents.length;

        require(lockPlanTimes[_planId].length == 0, "Vesting: plan update is not possible");
        require(items > 0, "Vesting: invalid percents length");
        require(
            items == _times.length,
            "Vesting: percents length not equal times length"
        );
        require(items < MAX_PLAN_LENGTH, "Vesting: plan length is too large");

        uint i = 0;
        uint currentFillPercent = 0;
        for (; i < items; i++) {
            require(_percents[i] > 0, "Vesting: wrong percents configs, zero set");
            if (i > 0) {
                require(_times[i] > _times[i-1], "Vesting: previous percent higher then current");
            }
            currentFillPercent += _percents[i];
        }

        require(currentFillPercent == SYS_DECIMAL, "Vesting: wrong percents configs by total sum");

        i = 0;
        for (; i < items; i++) {
            lockPlanPercents[_planId].push(_percents[i]);
            lockPlanTimes[_planId].push(_times[i]);
        }

        emit PlanAdded(_planId);
    }

    /**
     * @dev repair any ERC20 tokens from contract, exclude native
     *
     * Permission: {onlyOwner}
     */
    function transferAnyERC20Token(
        address _tokenAddress,
        address _beneficiary,
        uint256 _tokens
    ) external onlyOwner returns (bool success) {
        require(_tokenAddress != address(0), "Vesting: token address cannot be 0");
        require(_tokenAddress != token, "Vesting: token cannot be ours");

        return IERC20(_tokenAddress).transfer(_beneficiary, _tokens);
    }

    /**
     * @dev returns next unlock timestamp and unlock percent
     */
    function _getNextUnlock(uint256 _planId)
        internal
        view
        returns (uint256, uint256)
    {
        if (releaseTime == 0) {
            // no release time set yet -- all tokens are frozen
            return (0, 0);
        }

        uint256 _unlockTime;
        uint256 _unlockPercents;
        uint256 k = 0xFFFFFFF;

        for (uint256 j = 0; j < lockPlanTimes[_planId].length; j++) {
            if (lockPlanTimes[_planId][j] + releaseTime <= block.timestamp) {
                k = j;
            }
        }
        if (k == 0xFFFFFFF) {
            // no release time met yet, set first unlock point
            _unlockPercents = lockPlanPercents[_planId][0];
            _unlockTime = lockPlanTimes[_planId][0] + releaseTime;
        } else {
            if (k == lockPlanTimes[_planId].length - 1) {
                // all release points passed
                _unlockPercents = 0;
                _unlockTime = 0;
            } else {
                // k is the last passed release point, get next release point
                _unlockPercents = lockPlanPercents[_planId][k + 1];
                _unlockTime = lockPlanTimes[_planId][k + 1] + releaseTime;
            }
        }

        return (_unlockTime, _unlockPercents);
    }

    /**
     * @dev claim tokens
     */
    function _claim(address _beneficiary, uint256 _planId) internal {
        uint256 unlockPercents;
        uint256 j;
        for (j; j < lockPlanTimes[_planId].length; j++) {
            if (lockPlanTimes[_planId][j] + releaseTime <= block.timestamp) {
                unlockPercents += lockPlanPercents[_planId][j];
            }
        }

        uint256 claimedBalance = _withdrawTable[_beneficiary][_planId];
        uint256 unlockedPlanned = _lockTable[_beneficiary][_planId].mul(unlockPercents).div(100);

        if (unlockedPlanned > claimedBalance) {
            uint256 reward = unlockedPlanned - claimedBalance;
            _withdrawTable[_beneficiary][_planId] =
            _withdrawTable[_beneficiary][_planId].add(reward);
            IERC20(token).transfer(_beneficiary, reward);
            emit TokensClaimed(_beneficiary, reward);
        }
    }

    /**
     * @dev set release time, should be called in constructor only
     */
    function _setReleaseTime(uint256 _time) internal {
        require(_time > block.timestamp, "Vesting: release time should be in future");
        require(releaseTime == 0, "Vesting: release time can be set only once");

        releaseTime = _time;
        emit ReleaseTimeSet(_time);
    }

    /**
     * @dev access modifier, freezer role permission required
     */
    modifier onlyFreezer() {
        require(
            msg.sender == freezerRole,
            "Vesting: caller is not the freezer"
        );
        _;
    }
}

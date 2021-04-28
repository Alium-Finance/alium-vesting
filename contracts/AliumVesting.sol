// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/TransferHelper.sol";
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
    function getLockPlanLen(uint256 planId)
        external
        view
        returns (uint256)
    {
        require(planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        return lockPlanTimes[planId].length;
    }

    /**
     * @dev Returns closest unlock date and amount.
     */
    function getNextUnlockFor(address beneficiary)
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
                amount = _lockTable[beneficiary][i].mul(percent).div(100);
            } else if (t2 == timestamp) {
                amount = amount.add(_lockTable[beneficiary][i].mul(percent).div(100));
            }
        }

        return (timestamp, amount);
    }

    /**
     * @dev Returns the total amount of next unlock amounts for different plans.
     */
    function getNextUnlockAt(uint256 planId)
        external
        view
        override
        returns (uint256 timestamp, uint256 amount)
    {
        require(planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        (uint256 unlockTime, uint256 unlockPercents) = _getNextUnlock(planId);

        return (unlockTime, _lockedTotal[planId].mul(unlockPercents).div(100));
    }

    /**
     * @dev returns balances(total frozen, available frozen, withdrawn) of
     * {beneficiary} for all plans
     */
    function getTotalBalanceOf(address beneficiary)
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
            totalBalance = totalBalance.add(_lockTable[beneficiary][i]);
            withdrawnBalance = withdrawnBalance.add(
                _withdrawTable[beneficiary][i]
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
     * {beneficiary} by {planId}
     */
    function getBalanceOf(address beneficiary, uint256 planId)
        external
        view
        override
        returns (
            uint256 totalBalance,
            uint256 frozenBalance,
            uint256 withdrawnBalance
        )
    {
        if (planId >= MAX_LOCK_PLANS) {
            return (totalBalance, frozenBalance, withdrawnBalance);
        }

        totalBalance = _lockTable[beneficiary][planId];
        withdrawnBalance = _withdrawTable[beneficiary][planId];

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
        if (block.timestamp < releaseTime || _planId >= MAX_LOCK_PLANS) {
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
    function claimAll(address _beneficiary) external override {
        require(msg.sender == _beneficiary, "Vesting: caller is not the beneficiary");

        for (uint i = 0; i < MAX_LOCK_PLANS; i++) {
            _claim(_beneficiary, i);
        }
    }

    /**
     * @dev claim from a given plan
     */
    function claim(address _beneficiary, uint256 _planId) external override {
        require(msg.sender == _beneficiary, "Vesting: caller is not the beneficiary");
        require(_planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        _claim(_beneficiary, _planId);
    }

    /**
     * @dev freeze some token {amount} by alium collectible type,
     * what represented as {vestingPlanId}
     *
     * Permission: {onlyFreezer}
     */
    function freeze(
        address beneficiary,
        uint256 amount,
        uint8 vestingPlanId
    ) external override onlyFreezer returns (bool success) {
        require(beneficiary != address(0), "Vesting: beneficiary address cannot be 0");
        require(vestingPlanId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        _lockTable[beneficiary][vestingPlanId] =
        _lockTable[beneficiary][vestingPlanId].add(amount);
        _lockedTotal[vestingPlanId] = _lockedTotal[vestingPlanId].add(amount);
        IAliumCash(cashier).withdraw(amount);
        emit TokensLocked(beneficiary, amount);

        return true;
    }

    /**
     * @dev add a new blocking plan with a specific {planId}, {times} and
     * {percents} allocation
     *
     * Permission: {onlyOwner}
     */
    function addLockPlan(
        uint256 planId,
        uint256[] calldata times,
        uint256[] calldata percents
    ) external onlyOwner {
        require(planId < MAX_LOCK_PLANS, "Vesting: planId is out of range");

        uint items = percents.length;

        require(items > 0, "Vesting: invalid percents length");
        require(
            items == times.length,
            "Vesting: percents length not equal times length"
        );
        require(items < MAX_PLAN_LENGTH, "Vesting: plan length is too large");

        uint i = 0;
        uint currentFillPercent = 0;
        for (; i < items; i++) {
            require(percents[i] > 0, "Vesting: wrong percents configs, zero set");
            if (i > 0) {
                require(times[i] > times[i-1], "Vesting: previous percent higher then current");
            }
            currentFillPercent += percents[i];
        }

        require(currentFillPercent == SYS_DECIMAL, "Vesting: wrong percents configs by total sum");

        i = 0;
        for (; i < items; i++) {
            lockPlanPercents[planId].push(percents[i]);
            lockPlanTimes[planId].push(times[i]);
        }

        emit PlanAdded(planId);
    }

    /**
     * @dev repair any ERC20 tokens from contract, exclude native
     *
     * Permission: {onlyOwner}
     */
    function transferAnyERC20Token(
        address tokenAddress,
        address beneficiary,
        uint256 tokens
    ) external onlyOwner returns (bool success) {
        require(tokenAddress != address(0), "Vesting: token address cannot be 0");
        require(tokenAddress != token, "Vesting: token cannot be ours");

        return IERC20(tokenAddress).transfer(beneficiary, tokens);
    }

    /**
     * @dev returns next unlock timestamp and unlock percent
     */
    function _getNextUnlock(uint256 planId)
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

        for (uint256 j = 0; j < lockPlanTimes[planId].length; j++) {
            if (lockPlanTimes[planId][j] + releaseTime <= block.timestamp) {
                k = j;
            }
        }
        if (k == 0xFFFFFFF) {
            // no release time met yet, set first unlock point
            _unlockPercents = lockPlanPercents[planId][0];
            _unlockTime = lockPlanTimes[planId][0] + releaseTime;
        } else {
            if (k == lockPlanTimes[planId].length - 1) {
                // all release points passed
                _unlockPercents = 0;
                _unlockTime = 0;
            } else {
                // k is the last passed release point, get next release point
                _unlockPercents = lockPlanPercents[planId][k + 1];
                _unlockTime = lockPlanTimes[planId][k + 1] + releaseTime;
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
            emit TokensClaimed(_beneficiary, reward);
            IERC20(token).transfer(_beneficiary, reward);
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

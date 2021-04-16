// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/TransferHelper.sol";
import "./interfaces/IAliumVesting.sol";
import "./interfaces/IAliumCash.sol";

contract AliumVesting is Ownable, IAliumVesting {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------
    // Data Structures
    //--------------------------------------------------------------------------
    uint256 public constant MAX_LOCK_PLANS = 3;
    uint256 public constant MAX_PLAN_LENGTH = 32;

    /* Real beneficiary address is a param to this mapping */
    // stores total locked amounts
    mapping(address => uint256[MAX_LOCK_PLANS]) private _lockTable;
    // stores withdrawn amounts
    mapping(address => uint256[MAX_LOCK_PLANS]) private _withdrawTable;

    uint256[][MAX_LOCK_PLANS] public lockPlanTimes;
    uint256[][MAX_LOCK_PLANS] public lockPlanPercents;
    uint256[MAX_LOCK_PLANS] private lockedTotal;

    event TokensLocked(address indexed beneficiary, uint256 amount);
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event PlanAdded(uint256 planId);
    event PlanRemoved(uint256 planId);
    event ReleaseTimeSet(uint256 releaseTime);

    //--------------------------------------------------------------------------
    // Variables, Instances, Mappings
    //--------------------------------------------------------------------------
    /* Real beneficiary address is a param to this mapping */

    address public token;
    address public cashier;
    address public freezerRole;
    uint256 public releaseTime;

    //--------------------------------------------------------------------------
    // Smart contract Constructor
    //--------------------------------------------------------------------------
    constructor(
        address _vestingtoken,
        address _cashier,
        address _freezer
    ) public {
        require(_vestingtoken != address(0), "Token address cannot be empty");
        require(_cashier != address(0), "Cashier address cannot be empty");
        require(_freezer != address(0), "Freezer address cannot be empty");
        token = _vestingtoken;
        cashier = _cashier;
        freezerRole = _freezer;
    }

    //--------------------------------------------------------------------------
    // Observers
    //--------------------------------------------------------------------------
    // Return unlock date and amount of given lock
    function getLockPlanLen(uint256 planId)
        external
        view
        onlyOwner
        returns (uint256)
    {
        require(planId < MAX_LOCK_PLANS, "planId is out of range");

        return lockPlanTimes[planId].length;
    }

    // Return closest unlock date and amount
    function getNextUnlock(address beneficiary)
        external
        view
        override
        returns (uint256 timestamp, uint256 amount)
    {
        uint256 t;
        uint256 t2;
        uint256 a;
        uint256 p;

        for (uint256 i = 0; i < MAX_LOCK_PLANS; i++) {
            // cycle through each plan
            (t2, p) = _getNextUnlock(i);
            if (t2 < t) {
                t = t2;
                a = _lockTable[beneficiary][i].mul(p).div(100);
            } else if (t2 == t) {
                a = a.add(_lockTable[beneficiary][i].mul(p).div(100));
            }
        }
        return (t, a);
    }

    // return the total amount of next unlock amounts for different plans
    function getNextUnlock(uint256 planId)
        external
        view
        override
        returns (uint256 timestamp, uint256 amount)
    {
        require(planId < MAX_LOCK_PLANS, "planId is out of range");
        (uint256 unlockTime, uint256 unlockPercents) = _getNextUnlock(planId);

        return (unlockTime, lockedTotal[planId].mul(unlockPercents).div(100));
    }

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
        if (releaseTime == 0 || _planId >= MAX_LOCK_PLANS) {
            return 0;
        }

        uint256 unlockPercents;
        uint256 j;
        for (j; j < lockPlanTimes[_planId].length; j++) {
            if (lockPlanTimes[_planId][j] + releaseTime <= block.timestamp) {
                unlockPercents += lockPlanPercents[_planId][j];
            }
        }

        uint256 unlockedPlanned = _lockTable[_beneficiary][_planId].mul(unlockPercents).div(100);
        uint256 claimedBalance = _withdrawTable[_beneficiary][_planId];
        if (unlockedPlanned > claimedBalance) {
            claimedBalance += unlockedPlanned; // @todo is it ok?
        }
        if (unlockedPlanned > claimedBalance) {
            return unlockedPlanned - claimedBalance;
        }

        return 0;
    }

    function freeze(
        address beneficiary,
        uint256 amount,
        uint8 vestingPlanId
    ) external override returns (bool success) {
        require(beneficiary != address(0), "Beneficiary address cannot be 0");
        require(vestingPlanId < MAX_LOCK_PLANS, "planId is out of range");
        require(
            msg.sender == freezerRole || msg.sender == owner(),
            "Method not allowed to run"
        );

        _lockTable[beneficiary][vestingPlanId] =
        _lockTable[beneficiary][vestingPlanId].add(amount);
        lockedTotal[vestingPlanId] = lockedTotal[vestingPlanId].add(amount);
        IAliumCash(cashier).withdraw(amount);
        emit TokensLocked(beneficiary, amount);
        return true;
    }

    /**
    * @dev claim from all possible plans
    */
    function claimAll(address beneficiary) external override returns (bool) {
        require(beneficiary != address(0), "Beneficiary address cannot be 0");

        if (releaseTime == 0) {
            // @dev no release time set yet -- all tokens are frozen
            return false;
        }

        uint256 _unlockedBalance = 0;
        uint256 _claimedBalance = 0;
        uint256 _unlockPercents = 0;
        uint256 _unlockedPlanned;

        for (uint256 i = 0; i < MAX_LOCK_PLANS; i++) {
            for (uint256 j = 0; j < lockPlanTimes[i].length; j++) {
                if (lockPlanTimes[i][j] + releaseTime <= block.timestamp) {
                    _unlockPercents = _unlockPercents.add(
                        lockPlanPercents[i][j]
                    );
                }
            }
            _unlockedPlanned = _lockTable[msg.sender][i].mul(_unlockPercents).div(100);
            if (_unlockedPlanned > _withdrawTable[msg.sender][i]) {
                _withdrawTable[msg.sender][i] =
                _withdrawTable[msg.sender][i].add(_unlockedPlanned); // @todo is it ok?
            }
            _unlockedBalance = _unlockedBalance.add(_unlockedPlanned);
            _claimedBalance = _claimedBalance.add(
                _withdrawTable[msg.sender][i]
            );
        }

        if (_unlockedBalance > _claimedBalance) {
            emit TokensClaimed(msg.sender, _unlockedBalance - _claimedBalance);
            return
                IERC20(token).transfer(
                    beneficiary,
                    _unlockedBalance - _claimedBalance
                );
        }

        return true;
    }

    function claim(address _beneficiary, uint256 _planId) external override returns (bool) {
        require(_beneficiary != address(0), "Vesting: beneficiary address cannot be 0");
        require(releaseTime != 0, "Vesting: release time undefined");

        if (releaseTime == 0) {
            // @dev no release time set yet -- all tokens are frozen
            return false;
        }

        uint256 unlockPercents;
        uint256 j;
        for (j; j < lockPlanTimes[_planId].length; j++) {
            if (lockPlanTimes[_planId][j] + releaseTime <= block.timestamp) {
                unlockPercents += lockPlanPercents[_planId][j];
            }
        }

        uint256 unlockedPlanned = _lockTable[msg.sender][_planId].mul(unlockPercents).div(100);
        if (unlockedPlanned > _withdrawTable[msg.sender][_planId]) {
            _withdrawTable[msg.sender][_planId] =
            _withdrawTable[msg.sender][_planId].add(unlockedPlanned); // @todo is it ok?
        }

        uint256 claimedBalance = _withdrawTable[msg.sender][_planId];
        if (unlockedPlanned > claimedBalance) {
            uint256 reward = unlockedPlanned - claimedBalance;
            emit TokensClaimed(msg.sender, reward);
            return IERC20(token).transfer(_beneficiary, reward);
        }

        return false;
    }

    function setReleaseTime(uint256 _time) external override onlyOwner {
        require(_time > block.timestamp, "Release time should be in future");
        require(releaseTime == 0, "Release time can be set only once");

        releaseTime = _time;
        emit ReleaseTimeSet(_time);
    }

    //--------------------------------------------------------------------------
    // Locks manipulation
    //--------------------------------------------------------------------------
    function addLockPlan(
        uint256 planId,
        uint256[] calldata percents,
        uint256[] calldata times
    ) external onlyOwner {
        require(planId < MAX_LOCK_PLANS, "planId is out of range");
        require(
            percents.length == times.length,
            "percents length not equal times length"
        );
        require(percents.length < MAX_PLAN_LENGTH, "Plan length is too large");

        delete lockPlanPercents[planId];
        delete lockPlanTimes[planId];

        for (uint256 i = 0; i < percents.length; i++) {
            lockPlanPercents[planId].push(percents[i]);
            lockPlanTimes[planId].push(times[i]);
        }
        emit PlanAdded(planId);
    }

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

    // ------------------------------------------------------------------------
    // Owner can transfer out any accidentally sent ERC20 tokens
    // ------------------------------------------------------------------------
    function transferAnyERC20Token(
        address tokenAddress,
        address beneficiary,
        uint256 tokens
    ) public onlyOwner returns (bool success) {
        require(tokenAddress != address(0), "Token address cannot be 0");
        require(tokenAddress != token, "Token cannot be ours");

        return IERC20(tokenAddress).transfer(beneficiary, tokens);
    }
}

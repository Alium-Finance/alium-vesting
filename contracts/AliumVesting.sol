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

    /* Real beneficiary address is a param to this mapping */
    // stores total locked amounts
    mapping(address => uint256[3]) private _lockTable;
    // stores withdrawn amounts
    mapping(address => uint256[3]) private _withdrawTable;

    uint256[][3] public lockPlanTimes;
    uint256[][3] public lockPlanPercents;

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
        /*
        lockPlanTimes[0] = new uint256[](1);
        lockPlanTimes[1] = new uint256[](1);
        lockPlanTimes[2] = new uint256[](1);
        lockPlanPercents[0] = new uint256[](1);
        lockPlanPercents[1] = new uint256[](1);
        lockPlanPercents[2] = new uint256[](1);
*/
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
        uint256 a2;

        for (uint256 i = 0; i < MAX_LOCK_PLANS; i++) {
            (t2, a2) = _getNextUnlock(i);
            if (t2 < t) {
                t = t2;
                a = a2;
            }
        }
        return (t, amount);
    }

    // return the total amount of next unlock amounts for different plans
    function getNextUnlock(uint256 planId)
        external
        view
        override
        returns (uint256 timestamp, uint256 amount)
    {
        require(planId < MAX_LOCK_PLANS, "planId is out of range");
        return _getNextUnlock(planId);
    }

    function getTotalBalanceOf(address beneficiary)
        external
        view
        override
        returns (uint256 totalBalance, uint256 frozenBalance, uint256 withdrawnBalance)
    {
        uint8 i = 0;
        for (; i < MAX_LOCK_PLANS; i++) {
            totalBalance = totalBalance.add(_lockTable[beneficiary][i]);
            withdrawnBalance = withdrawnBalance.add(
                _withdrawTable[beneficiary][i]
            );
        }

        return (totalBalance, totalBalance.sub(withdrawnBalance), withdrawnBalance);
    }

    function getBalanceOf(address beneficiary, uint256 planId)
        external
        view
        override
        returns (uint256 totalBalance, uint256 frozenBalance, uint256 withdrawnBalance)
    {
        if (planId >= MAX_LOCK_PLANS) {
            return (totalBalance, frozenBalance, withdrawnBalance);
        }

        totalBalance = _lockTable[beneficiary][planId];
        withdrawnBalance = _withdrawTable[beneficiary][planId];

        return (totalBalance, totalBalance.sub(withdrawnBalance), withdrawnBalance);
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
        IAliumCash(cashier).withdraw(amount);
        emit TokensLocked(beneficiary, amount);
        return true;
    }

    function claim(address beneficiary) external override returns (bool) {
        require(beneficiary != address(0), "Beneficiary address cannot be 0");
        if (releaseTime == 0) {
            // no release time set yet -- all tokens are frozen
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
            _unlockedPlanned = _lockTable[msg.sender][i]
                .mul(_unlockPercents)
                .div(100);
            if (_unlockedPlanned > _withdrawTable[msg.sender][i]) {
                _withdrawTable[msg.sender][i] = _withdrawTable[msg.sender][i].add(
                    _unlockedPlanned
                );
            }
            _unlockedBalance = _unlockedBalance.add(_unlockedPlanned);
            _claimedBalance = _claimedBalance.add(_withdrawTable[msg.sender][i]);
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

    function setReleaseTime(uint256 _time) external override onlyOwner {
        require(_time > block.timestamp, "Release time should be in future");
        releaseTime = _time;
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

        uint256 _unlockTime = lockPlanTimes[planId][0] + releaseTime;
        uint256 _unlockPercents = lockPlanPercents[planId][0];
        uint256 _unlockedPlanned;

        for (uint256 j = 1; j < lockPlanTimes[planId].length; j++) {
            if (lockPlanTimes[planId][j] + releaseTime <= block.timestamp) {
                _unlockPercents = lockPlanPercents[planId][j];
            }
        }
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAliumVesting {
    function freeze(
        address beneficiary,
        uint256 amount,
        uint8 vestingPlanId
    ) external returns (bool success);

    function getTotalBalanceOf(address beneficiary)
        external
        view
        returns
    (
        uint256 totalBalance,
        uint256 frozenBalance,
        uint256 withdrawnBalance
    );

    function getBalanceOf(address beneficiary, uint planId)
        external
        view
        returns
    (
        uint256 totalBalance,
        uint256 frozenBalance,
        uint256 withdrawnBalance
    );

    function getNextUnlock(address beneficiary)
        external
        view
        returns (uint256 timestamp, uint256 amount);

    function getNextUnlock(uint256 planId)
        external
        view
        returns (uint256 timestamp, uint256 amount);

    function claimAll(address beneficiary) external returns (bool success);

    function claim(address beneficiary, uint planId) external returns (bool success);

    function pendingReward(address beneficiary, uint256 planId)
        external
        view
        returns (uint256 reward);

    function setReleaseTime(uint256 time) external;
}

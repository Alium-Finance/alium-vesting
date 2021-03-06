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

    function getNextUnlockFor(address beneficiary)
        external
        view
        returns (uint256 timestamp, uint256 amount);

    function getNextUnlockAt(uint256 planId)
        external
        view
        returns (uint256 timestamp, uint256 amount);

    function claimAll() external;

    function claim(uint planId) external;

    function pendingReward(address beneficiary, uint256 planId)
        external
        view
        returns (uint256 reward);
}

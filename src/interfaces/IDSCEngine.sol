// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IDSCEngine {
    function mintForAirdrop(address _to, uint256 _amount) external;
    function mintForPool(address _to, uint256 _amount) external;
}

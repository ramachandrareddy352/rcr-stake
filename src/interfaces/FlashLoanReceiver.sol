// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface FlashLoanReceiver {
    function onFlashLoan(address _caller, address _collateral, uint256 _amount, bytes memory _payload)
        external
        returns (bytes32);
}

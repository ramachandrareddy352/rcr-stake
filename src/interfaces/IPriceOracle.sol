// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IPriceOracle {
    function oracleTimeOut(address _priceFeed) external view returns (uint256);
    function updateTimeOut(address _priceFeed, uint256 _timeOut) external;
    function staleCheckLatestRoundData(address chainlinkFeed) external view returns (uint256);
}

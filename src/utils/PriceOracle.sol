// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {Owned} from "@solmate/src/auth/Owned.sol";

/**
 * @title Price Oracle
 * @author Rama chandra reddy
 * @notice Contract returns price using chainlink datafeeds, if aby bug occusrs we updated the contract address at  pool.
 * If chainlink pricefeed hacked we use same interface to return price using Uniswap oracle.
 * If we update and get the price of token we use token0price, token1price by comparing with USDT token as a one of the token with the pair.
 * After update we always return the price of token in 8 decimals only. Then the pool is safe for calculations.
 */
contract PriceOracle is Owned {
    event UpdatePriceTime(address indexed priceFeed, uint256 time);

    mapping(address priceFeed => uint256 timeOut) public oracleTimeOut;

    constructor(address[] memory _priceFeeds, uint256[] memory _timeOuts, address _owner) Owned(_owner) {
        for (uint256 i; i < _priceFeeds.length;) {
            oracleTimeOut[_priceFeeds[i]] = _timeOuts[i];
            emit UpdatePriceTime(_priceFeeds[i], _timeOuts[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Updates the timeout data for every pricefeed address to free from stale timeout error.
     * @param _priceFeed : Address of the pricefeed of chainlink data.
     * @param _timeOut : Max time for oracle to update price data.
     */
    function updateTimeOut(address _priceFeed, uint256 _timeOut) external onlyOwner {
        if (_timeOut == 0) {
            delete oracleTimeOut[_priceFeed];
        } else {
            oracleTimeOut[_priceFeed] = _timeOut;
            emit UpdatePriceTime(_priceFeed, _timeOut);
        }
    }

    /**
     * @notice Returns the data using chainlink pricefeed address
     * @param chainlinkFeed : Address of chainlink pricefeed
     */
    function staleCheckLatestRoundData(address chainlinkFeed) external view returns (uint256) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(chainlinkFeed).latestRoundData();

        require(answeredInRound == roundId && startedAt == updatedAt, "PriceOracle : Invalid roundId data result");

        uint256 secondsSince = block.timestamp - updatedAt;
        require(oracleTimeOut[address(chainlinkFeed)] >= secondsSince, "PriceOracle : Timeout data result");

        return uint256(answer);
    }
}

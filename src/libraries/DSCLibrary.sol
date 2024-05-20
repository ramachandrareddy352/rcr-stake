// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

library DSCLibrary {
    function getUSDAmount(uint256 price, uint256 amount, uint256 precision, uint256 decimalPrecision)
        internal
        pure
        returns (uint256 result)
    {
        assembly {
            let num := mul(mul(price, amount), precision)
            result := div(num, decimalPrecision)
        }
    }

    function getTokenAmount(uint256 usdAmountInWei, uint256 decimalPrecision, uint256 price, uint256 precision)
        internal
        pure
        returns (uint256 result)
    {
        assembly {
            let num := mul(usdAmountInWei, decimalPrecision)
            let den := mul(price, precision)
            result := div(num, den)
        }
    }
}

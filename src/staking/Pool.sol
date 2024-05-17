// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Owned} from "@solmate/src/auth/Owned.sol";
import {ReentrancyGuard} from "@solmate/src/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDSCEngine} from "../interfaces/IDSCEngine.sol";

/**
 * For fixed stake mint NFT and the verification is done through that NFT only.
 * For fixed stakings we mint high rewards.
 * Based on the total DSC tokens are minted we have to mint rewards for staking.
 * 
 */
contract Pool is Owned, Pausable, ReentrancyGuard, Multicall {
    using SafeERC20 for IERC20;

    mapping(address collateral => address pricefeed) public s_collaterals;
    mapping(address user => mapping(address collateral => Collateral)) public s_UserData;
    mapping(uint256 dayS => uint256 apy) public s_fixedStakeRewardRate;
    mapping(address collateral => uint256 rewardRate) public s_rewardRate;

    address private immutable i_dscEngine;
    address private immutable i_dscToken;

    constructor(address _owner) Owned(_owner) {
        s_fixedStakeRewardRate[30] = 100;
        s_fixedStakeRewardRate[60] = 200;
        s_fixedStakeRewardRate[90] = 300;
        s_fixedStakeRewardRate[120] = 400;
    }

    struct Collateral {
        uint256 totalDeposited;
        uint256 totalRewarded;
        uint256 lastUpdated;
    }

    modifier isAcceptableToken(address _collateralToken) {
        require(s_collaterals[_collateralToken] != address(0), "Pool : Invalid collateral token");
        _;
    }
    
    modifier isNonZero(uint256 _value) {
        require(_value != 0, "Pool : Invalid zero amount");
        _;
    }
    
    // staking functions
    function fixedStake(address _for, address _collateralToken, uint256 _amount, uint256 _fixedDays) external isAcceptableToken(_collateralToken) isNonZero(_amount) whenNotPaused() nonReentrant() {
        require(s_fixedStakeRewardRate[_fixedDays] != 0, "Invalid no.of days to stake");
        SafeERC20.safeTransferFrom(IERC20(_collateralToken), msg.sender, address(this), _amount);
        s_UserData[_for][_collateralToken] = Collateral({totalDeposited: _amount += _amount});
    }
    
    function stake() external {}

    function fixedStakeWithPermit() external {}
    function stakeWithPermit() external {}

    // redeem deposited collateral
    function redeemCollateral() external {}
    
    // withdraw rewards
    function withdrawRewards() external {}

    // borrow loan
    function getLoan() external {}  // for 1 year have some fee, after 2 years have other fee etc

    // flashloan
    function getFlashLoan() external {}  // which collateral we take that are taken as fee

    // repay loan
    function repayLoan() external {}

    // un-pay laon
    function unpayLoan() external {}   // will be rewarded

    // pause and unpause functions
    function pause() external onlyOwner() {
        _pause();
    }

    function unpause() external onlyOwner() {
        _unpause();
    }
}

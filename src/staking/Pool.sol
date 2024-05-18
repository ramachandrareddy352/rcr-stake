// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Owned} from "@solmate/src/auth/Owned.sol";
import {ReentrancyGuard} from "@solmate/src/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

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
    mapping(address collateralToken => mapping(uint256 dayS => uint256 apy)) public s_fixedStakeRewardRate;
    mapping(address collateral => uint256 rewardRate) public s_rewardRate;

    address private immutable i_dscEngine;
    address private immutable i_dscToken;

    mapping(bytes32 stakingId => FixedStaked) public s_userFixedStaking;
    mapping(address collateral => uint256 totalAmount) public s_totalFixedStakingAmount;

    struct FixedStaked {
        address staker;
        uint256 amount;
        address collateral;
        uint256 startTime;
        uint256 endTime;
        uint256 rewardRate; // per second
    }

    constructor(address[] memory _collateralTokens, address _owner) Owned(_owner) {
        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            s_fixedStakeRewardRate[_collateralTokens[i]][30] = 100;
            s_fixedStakeRewardRate[_collateralTokens[i]][60] = 200;
            s_fixedStakeRewardRate[_collateralTokens[i]][90] = 300;
            s_fixedStakeRewardRate[_collateralTokens[i]][120] = 400;
        }
    }

    function updateFixedRewardRate(uint256 _days, address _collateralToken, uint256 _apy)
        external
        onlyOwner
        isAcceptableToken(_collateralToken)
    {
        s_fixedStakeRewardRate[_collateralToken][_days] = _apy;
    }

    // staking functions
    function fixedStake(address _for, address _collateralToken, uint256 _amount, uint256 _fixedDays)
        external
        isAcceptableToken(_collateralToken)
        isNonZero(_amount)
        whenNotPaused
        nonReentrant
    {
        require(_for != address(0), "Pool : Invalid zero address");
        require(s_fixedStakeRewardRate[_collateralToken][_fixedDays] != 0, "Pool : Invalid no.of days to stake");
        SafeERC20.safeTransferFrom(IERC20(_collateralToken), msg.sender, address(this), _amount);

        bytes32 stakingId = _getStakingId(_amount, _collateralToken, block.timestamp, _for, _fixedDays, 1);

        s_userFixedStaking[stakingId] = FixedStaked(
            _for,
            _amount,
            _collateralToken,
            block.timestamp,
            block.timestamp + (_fixedDays * 1 days),
            s_fixedStakeRewardRate[_collateralToken][_fixedDays]
        );
        s_totalFixedStakingAmount[_collateralToken] += _amount;
    }

    function fixedStakeWithPermit(
        address _for,
        address _collateralToken,
        uint256 _amount,
        uint256 _fixedDays,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint256 _deadline
    ) external isAcceptableToken(_collateralToken) isNonZero(_amount) whenNotPaused nonReentrant {
        require(s_fixedStakeRewardRate[_collateralToken][_fixedDays] != 0, "Pool : Invalid no.of days to stake");

        IERC20Permit(_collateralToken).permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s);
        SafeERC20.safeTransferFrom(IERC20(_collateralToken), msg.sender, address(this), _amount);

        bytes32 stakingId = _getStakingId(_amount, _collateralToken, block.timestamp, _for, _fixedDays, 1);

        s_userFixedStaking[stakingId] = FixedStaked(
            _for,
            _amount,
            _collateralToken,
            block.timestamp,
            block.timestamp + (_fixedDays * 1 days),
            s_fixedStakeRewardRate[_collateralToken][_fixedDays]
        );
        s_totalFixedStakingAmount[_collateralToken] += _amount;
    }

    function _getStakingId(uint _amount, address _collateralToken, uint256 _timestamp, address _owner, uint256 _fixedDays, uint256 _userNonce) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_amount, _collateralToken, _timestamp, _owner, _fixedDays, _userNonce));
    }

    function stake() external {}
    function stakeWithPermit() external {}

    // redeem deposited collateral
    function redeemFixedCollateral(bytes32 _stakingId, address _receiver) external {
        FixedStaked memory stakingData = s_userFixedStaking[_stakingId];
        require(msg.sender == stakingData.staker && msg.sender != address(0), "Pool : Invalid staker");
        require(block.timestamp > stakingData.endTime, "Pool : Staking perion is not ended");
        SafeERC20.safeTransfer(IERC20(stakingData.collateral), _receiver, stakingData.amount);
        s_totalFixedStakingAmount[stakingData.collateral] -= stakingData.amount;
        delete s_userFixedStaking[_stakingId];
    }
    
    function redeemCollateral() external {}

    // withdraw rewards
    function withdrawRewards() external {}

    // borrow loan
    function getLoan() external {} // for 1 year have some fee, after 2 years have other fee etc

    // flashloan
    function getFlashLoan() external {} // which collateral we take that are taken as fee

    // repay loan
    function repayLoan() external {}

    // un-pay laon
    function dropLoan() external {} // will be rewarded

    // pause and unpause functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    modifier isAcceptableToken(address _collateralToken) {
        require(s_collaterals[_collateralToken] != address(0), "Pool : Invalid collateral token");
        _;
    }

    modifier isNonZero(uint256 _value) {
        require(_value != 0, "Pool : Invalid zero amount");
        _;
    }
}

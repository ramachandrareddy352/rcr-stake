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
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {FlashLoanReceiver} from "../interfaces/FlashLoanReceiver.sol";

/**
 * @title : FixedPool
 * @author : Rama Chandra Reddy
 * @notice : This is mainly used to earn DSC tokens by staking the pool accepted collateral tokens for fixed days.
 * User can execute multiple functions at a time using multiCall().
 * For different tokens have different reward rate, for more no.of fixed staking have more reward rate.
 * You can use flash loan, but pool takes some amount of Fee(0.3%) of respective collateral tokens.
 */
contract FixedPool is Owned, Pausable, ReentrancyGuard, Multicall {
    using SafeERC20 for IERC20;

    event FlashLoan(
        address indexed executor,
        address indexed loanReceiver,
        address collateral,
        uint256 amount,
        bytes payload,
        uint256 loanFee
    );
    event Stake(
        uint256 indexed stakingId,
        address indexed user,
        address indexed forTo,
        address collateralToken,
        uint256 amount,
        uint256 stratTime,
        uint256 endTime,
        uint256 rewardRate,
        uint256 fixedDays
    );
    event Redeemed(
        address indexed user,
        uint256 indexed stakingId,
        address collateral,
        uint256 amount,
        address collateralReceiver,
        address rewardReceiver
    );
    event WithdrawRewards(address indexed user, address indexed dscReceiver, uint256 amount);

    uint256 public constant PROTOCOL_FEE = 3000;
    bytes32 public constant CALLBACK_DATA = keccak256(
        abi.encodePacked("onFlashLoan(address _caller, address _collateral, uint256 _amount, bytes memory _payload)")
    );

    address private immutable i_dscEngine;
    uint256 private s_stakingIdTracker;
    address private s_feeReceiver;

    // returns whether the collateral is accepted by pool or not
    mapping(address collateral => bool isAccepted) public s_collaterals;
    // staking data stored by key value of respective unique staking id
    mapping(uint256 stakingId => FixedStaked) public s_userFixedStaking;
    // tracking the total collateral staked in the pool
    mapping(address collateral => uint256 totalStaked) public s_totalFixedStakingAmount;
    // mapping to reward rate with respective to the collateral token and no.of days user staked
    mapping(address collateral => mapping(uint256 day => uint256 rewardRate)) public s_fixedStakeRewardRate;
    // traking the total rewars earned by user, by staking their collaterals
    mapping(address user => uint256 rewardsOwned) public s_userRewardedAmount;
    // all user staking ids array
    mapping(address user => uint256[] stakingIds) public s_userStakingIds;

    struct FixedStaked {
        address staker;
        uint256 amount;
        address collateral;
        uint256 startTime;
        uint256 endTime;
        uint256 rewardRate;
        bool isRedeemed;
    }

    modifier isAcceptableToken(address _collateralToken) {
        _isAcceptableToken(_collateralToken);
        _;
    }


    modifier isNonZero(uint256 _value) {
        _isNonZero(_value);
        _;
    }

    /**
     * At initially all the collaterl haave same amount of reward rates.
     * @param _dscEngine : address DSC engine contract
     * @param _collateralTokens : all the collateral tokens that are accepted by pool
     * @param _owner : owner of the pool
     */
    constructor(
        address _dscEngine,
        address _feeReceiver,
        address[] memory _collateralTokens,
        address _owner
    ) Owned(_owner) {
        uint256 len = _collateralTokens.length;

        i_dscEngine = _dscEngine;
        s_feeReceiver = _feeReceiver;

        for (uint256 i = 0; i < len; i++) {
            require(!s_collaterals[_collateralTokens[i]], "Pool : Collateral token already exist");
            s_collaterals[_collateralTokens[i]] = true;
        }

        for (uint256 i = 0; i < len; i++) {
            s_fixedStakeRewardRate[_collateralTokens[i]][30] = 1000;
            s_fixedStakeRewardRate[_collateralTokens[i]][60] = 1250;
            s_fixedStakeRewardRate[_collateralTokens[i]][90] = 1500;
            s_fixedStakeRewardRate[_collateralTokens[i]][120] = 1750;
            s_fixedStakeRewardRate[_collateralTokens[i]][180] = 2000;
        }
    }

    /**
     * Change the flash loan fees receiver address
     * @param _newReceiver : new fee receiver address
     */
    function changeFeeReceiver(address _newReceiver) external onlyOwner() {
        s_feeReceiver = _newReceiver;
    }

    /**
     * Returns the pending reward amount that staker will get by thier staked collaterals.
     * @param _user : address of user to fetch
     */
    function getPendingReward(address _user) external view returns (uint256) {
        uint256 len = s_userStakingIds[_user].length;
        uint256[] memory stakingIds = s_userStakingIds[_user];
        uint256 pendingRewards = 0;

        for (uint256 i = 0; i < len; ) {
            FixedStaked memory stakingData = s_userFixedStaking[stakingIds[i]];
            if (!stakingData.isRedeemed) {
                pendingRewards += (stakingData.endTime - stakingData.startTime) * stakingData.rewardRate;
            }

            unchecked {
                i++;
            }
        }

        return pendingRewards;
    }

    /**
     * Returns all the staking and redeemed data of the user.
     * @param _user : address of user to fetch
     */
    function getUserStakingData(address _user) external view returns (FixedStaked[] memory) {
        uint256 len = s_userStakingIds[_user].length;
        FixedStaked[] memory fixedStakings = new FixedStaked(len)[];
        uint256[] memory stakingIds = s_userStakingIds[_user];

        for (uint256 i = 0; i < len; i++) {
            fixedStakings[i] = s_userFixedStaking[stakingIds[i]];
        }

        return fixedStakings;
    }

    /**
     * Fixed pool offers flash loan on collateral tokens
     * @param _collateral : Collateral token that flash loan is taking.
     * @param _amount : amount of flash loan is taking
     * @param _loanReceiver : flash laon amount receiver address
     * @param _payload : call data passed in onFlashLoan() calllback
     */
    function getFlashLoan(address _collateral, uint256 _amount, address _loanReceiver, bytes memory _payload)
        external
        whenNotPaused
        nonReentrant
        isAcceptableToken(_collateral)
        isNonZero(_amount)
    {
        require(_loanReceiver.code.length != 0, "Pool : Loan receiver is not a smart contract");

        uint256 balance = IERC20(_collateral).balanceOf(address(this));
        require(balance >= _amount, "Pool : Insufficinet flash loan amount");

        SafeERC20.safeTransfer(IERC20(_collateral), _loanReceiver, _amount);

        bytes32 callbackData = FlashLoanReceiver(_loanReceiver).onFlashLoan(msg.sender, _collateral, _amount, _payload);
        require(callbackData == CALLBACK_DATA, "Pool : Invalid callback data");

        uint256 loanFee = (_amount * PROTOCOL_FEE) / 1000000;

        SafeERC20.safeTransferFrom(IERC20(_collateral), _loanReceiver, address(this), _amount);
        SafeERC20.safeTransferFrom(IERC20(_collateral), _loanReceiver, s_feeReceiver, loanFee);

        emit FlashLoan(msg.sender, _loanReceiver, _collateral, _amount, _payload, loanFee);
    }

    /**
     * Stake the collateral bby approving the pool to spend their amount. Only for some fixed days only we can stake. Reward rate is applied when the time of staking the collateral.
     * @param _for : address which receives the collateral and rewards after the ending of the staking period
     * @param _collateralToken : Collater token address whick is being staked
     * @param _amount : amount of collateral staking to pool
     * @param _fixedDays : no.of fixed days that the amount is loacked in pool
     */
    function stake(address _for, address _collateralToken, uint256 _amount, uint256 _fixedDays)
        external
        whenNotPaused
        nonReentrant
        isAcceptableToken(_collateralToken)
        isNonZero(_amount)
    {
        require(
            IERC20(_collateralToken).allowance(msg.sender, address(this)) >= _amount, "Pool : Insufficient allowance"
        );

        _stake(
            msg.sender,
            _for,
            _collateralToken,
            _amount,
            _fixedDays,
            s_fixedStakeRewardRate[_collateralToken][_fixedDays]
        );
    }

    function _stake(address _user, address _for, address _collateralToken, uint256 _amount, uint256 _fixedDays, uint256 _rewardRate) private {
        require(_for != address(0), "Pool : Invalid zero address");
        require(_rewardRate != 0, "Pool : Invalid no.of days to stake");

        SafeERC20.safeTransferFrom(IERC20(_collateralToken), _user, address(this), _amount);

        uint256 stakingId = ++s_stakingIdTracker;

        s_userFixedStaking[stakingId] = FixedStaked(
            _for,
            _amount,
            _collateralToken,
            block.timestamp,
            block.timestamp + (_fixedDays * 1 days),
            _rewardRate,
            false
        );

        s_totalFixedStakingAmount[_collateralToken] += _amount;
        s_userStakingIds[_for].push(stakingId);

        emit Stake(stakingId, _user, _for, _collateralToken, _amount, block.timestamp, block.timestamp + (_fixedDays * 1 days), _rewardRate, _fixedDays);
    }

    /**
     * Stake the collateral by approving the pool using `signature` to spend their amount. Only for some fixed days only we can stake. Reward rate is applied when the time of staking the collateral.
     * @param _for : address which receives the collateral and rewards after the ending of the staking period
     * @param _collateralToken : Collater token address whick is being staked
     * @param _amount : amount of collateral staking to pool
     * @param _fixedDays : no.of fixed days that the amount is loacked in pool
     * @param _v : signature V parameter
     * @param _r : signature R parameter
     * @param _s : signature S parameter
     * @param _deadline : last time for that the signature is valid
     */
    function stakeWithPermit(
        address _for,
        address _collateralToken,
        uint256 _amount,
        uint256 _fixedDays,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint256 _deadline
    ) external whenNotPaused nonReentrant isAcceptableToken(_collateralToken) isNonZero(_amount) {
        IERC20Permit(_collateralToken).permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s);
        require(
            IERC20(_collateralToken).allowance(msg.sender, address(this)) >= _amount, "Pool : Insufficient allowance"
        );

        _fixedStake(
            msg.sender,
            _for,
            _collateralToken,
            _amount,
            _fixedDays,
            s_fixedStakeRewardRate[_collateralToken][_fixedDays]
        );
    }

    /**
     * Redeem the collatreal after ending of the staking period. Even if the collateral is not accepeted during the redeem staker can get the reward(DCS) tokens. Reward rate is fixed at the time of staking collatreals.
     * @param _stakingId : staking id of the FixedStaking struct maps
     * @param _collateralReceiver : after redeeming collateral the address who receives redeemed collateral
     * @param _rewardReceiver : address who receives the rewards(DSC Tokens) by staking the collateral.
     */
    function redeemCollateral(uint256 _stakingId, address _collateralReceiver, address _rewardReceiver) external whenNotPaused() {
        FixedStaked memory stakingData = s_userFixedStaking[_stakingId];
        address user = msg.sender;

        require(!stakingData.isRedeemed, "Pool : Already redeemed tokens");
        require(user != address(0) && user == stakingData.staker, "Pool : Invalid staker");
        require(block.timestamp >= stakingData.endTime, "Pool : Staking perion is not ended");

        s_userRewardedAmount[_rewardReceiver] += (stakingData.endTime - stakingData.startTime) * stakingData.rewardRate;
        s_userFixedStaking[_stakingId].isRedeemed = true;
        s_totalFixedStakingAmount[stakingData.collateral] -= stakingData.amount;

        SafeERC20.safeTransfer(IERC20(stakingData.collateral), _collateralReceiver, stakingData.amount);

        emit Redeemed(
            user, _stakingId, stakingData.collateral, stakingData.amount, _collateralReceiver, _rewardReceiver
        );
    }

    /**
     * Withdraw the earned DSC tokens by redeemed thier staked collateral.
     * @param _amount : amount of DSC tokens to withdraw
     * @param _dscReceiver : DSC Token receiver address
     */
    function withdrawRewards(uint256 _amount, address _dscReceiver) external whenNotPaused nonReentrant {
        address user = msg.sender;
        uint256 rewards = s_userRewardedAmount[user];
        require(rewards >= _amount, "Pool : Insufficient rewards to withdraw");
        s_userRewardedAmount[user] = rewards - _amount;

        IDSCEngine(i_dscEngine).mintForPool(_dscReceiver, _amount);

        emit WithdrawRewards(user, _dscReceiver, _amount);
    }

    /**
     * Addding new collateral to accept to stake in pool.
     * @param _collateralToken : collatreal token address
     */
    function addCollateral(address _collateralToken) external onlyOwner {
        require(!s_collaterals[_collateralToken], "Pool : Collateral token already exist");
        s_collaterals[_collateralToken] = true;

        s_fixedStakeRewardRate[_collateralToken][30] = 1000;
        s_fixedStakeRewardRate[_collateralToken][60] = 1250;
        s_fixedStakeRewardRate[_collateralToken][90] = 1500;
        s_fixedStakeRewardRate[_collateralToken][120] = 1750;
        s_fixedStakeRewardRate[_collateralToken][180] = 2000;
    }

    /**
     * Remove the collateral token to accept for staking.
     * @param _collateralToken : collateral token address
     */
    function removeCollateral(address _collateralToken) external onlyOwner {
        require(s_collaterals[_collateralToken], "Pool : Collateral not exist");
        delete s_collaterals[_collateralToken]; // not much needed to delete the s_fixedStakeRewardRate
    }

    /**
     * Update the reward rate for the existing collatreal tokens.
     * @param _days : no.of days of staking period
     * @param _collateralToken : collateral token address
     * @param _rewardRate : new reward rate for staking
     */
    function updateFixedRewardRate(uint256[] memory _days, address _collateralToken, uint256[] memory _rewardRate)
        external
        onlyOwner
        isAcceptableToken(_collateralToken)
    {
        require(_days.length == _rewardRate.length, "Pool : Invalid elements length");
        for (uint256 i = 0; i < _days.length; i++) {
            s_fixedStakeRewardRate[_collateralToken][_days[i]] = _rewardRate[i];
        }
    }

    function _isAcceptableToken(address _collateralToken) private view {
        require(s_collaterals[_collateralToken], "Pool : Invalid collateral token");
    }

    function _isNonZero(uint256 _value) private pure {
        require(_value != 0, "Pool : Invalid zero amount");
    }

    /* ------- pause and unpause functions ------- */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

}

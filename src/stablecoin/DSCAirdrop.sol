// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

/*
 * Protocol announce the airdrop for every interval of time.
 * User register for every airdrop in that interval and first person got air drops.
 * After completeing of airdrop, chainlink automatically call anounce winner function using VRF consumer
 * Write a contract for VRF consumer to fund through it.
 * Based on the no.of user and the amount then deposited the no.of dsc aslo minted, then only protocol does not loss more dcs tokens
 * Pause the airdrop you want
 * minimum 5 users to register a airdrop
 * Interval time should be adjustable by only owner
 * Register amount is changes based on the airdrop amount.
 * Only take Eth for register airdrop.
 */

import {Owned} from "@solmate/src/auth/Owned.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/v0.8/VRFConsumerBaseV2.sol";
import {KeeperCompatibleInterface} from "@chainlink/contracts/v0.8/interfaces/KeeperCompatibleInterface.sol";

import {IDSCEngine} from "../interfaces/IDSCEngine.sol";

contract DSCAirdrop is Owned, Pausable, VRFConsumerBaseV2, KeeperCompatibleInterface {
    event AirdropCreated(
        uint64 indexed airdropId, uint64 startTime, uint64 endTime, uint256 entranceFee, uint256 reward
    );
    event RegisterAirdrop(
        uint64 indexed airdropId, address indexed caller, address indexed player, uint256 entranceFee
    );
    event AnounceWinner(
        uint64 indexed requestId,
        uint256[] randomWords,
        uint64 indexed airdropId,
        uint256 playersLength,
        address winner,
        uint256 reward
    );
    event SubscriptionCreated(uint64 subscriptionId, address consumer);
    event AddConsumer(uint64 subscriptionId, address consumerAddress);
    event RemoveConsumer(uint64 subscriptionId, address consumerAddress);
    event CancelSubscription(uint64 subscriptionId, address receivingWallet);
    event WithdrawEth(address to, uint256 amount);

    // Chainlink VRF Variables
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    LinkTokenInterface private immutable i_linkToken;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit; // based on the network gaslane and callbackgaslimit are changes
    uint32 private constant NUM_WORDS = 1;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;

    // Airdrop Variables
    struct Airdrop {
        uint256 entranceFee;
        uint256 reward;
        uint64 startTime;
        uint64 endTime;
        address winner;
        bool state;
        address payable[] players;
    }

    IDSCEngine public immutable i_DSCEngine;
    uint64 public constant MIN_INTERVAL = 10 days;
    uint64 private s_airdropId;
    uint64 private s_currentId;

    mapping(uint64 airdropId => Airdrop) private s_airdropData;
    mapping(uint64 airdropId => mapping(address player => bool)) s_playerRegister;

    constructor(
        address _vrfCoordinatorV2,
        address _linkToken,
        address _dscEngine,
        bytes32 _gasLane, // keyHash
        uint32 _callbackGasLimit,
        address _owner
    ) Owned(_owner) VRFConsumerBaseV2(_vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinatorV2);
        i_linkToken = LinkTokenInterface(_linkToken);
        i_DSCEngine = IDSCEngine(_dscEngine);
        i_gasLane = _gasLane;
        i_subscriptionId = _createNewSubscription();
        i_callbackGasLimit = _callbackGasLimit;
    }

    /**
     * Setting airdrop data, once data is set then anounce of winner is automatically declared using chainlink automation.
     * @param _interval : Time interval period for airdrop to register.
     * @param _entranceFee : airdrop entrance fee.
     * @param _startTime : airdrop start time stamp.
     * @param _rewardAmount : reward amount that airdrop winner gets.
     */
    function setAirdrop(uint64 _interval, uint256 _entranceFee, uint64 _startTime, uint256 _rewardAmount)
        external
        onlyOwner
    {
        require(_interval > MIN_INTERVAL, "DSCAirdrop : Minimum interval is needed to register airdrop");
        ++s_airdropId;
        s_airdropData[s_airdropId] = Airdrop({
            state: true,
            entranceFee: _entranceFee,
            reward: _rewardAmount,
            startTime: _startTime + 1,
            endTime: _startTime + _interval
        });
        emit AirdropCreated(s_airdropId, _startTime + 1, _startTime + _interval, _entranceFee, _rewardAmount);
    }

    /**
     * Any user can register for existed airdrop. One player can register for one airdrop.
     * @param _airdropId : Airdrop id which we have to register.
     * @param _player : address of player who participate in airdrop.
     */
    function registerAirdrop(uint64 _airdropId, address payable _player) external payable whenNotPaused {
        Airdrop airdrop = s_airdropData[_airdropId];
        require(!s_playerRegister[_airdropId][_player], "DSCAirdrop : Player has already registered");
        require(airdrop.state, "DSCAirdrop : Airdrop is not in active state");
        require(msg.value == airdrop.entranceFee, "DSCAirdrop : Invalid entrance fee");
        require(
            block.timestamp > airdrop.startTime && block.timestamp < airdrop.endTime,
            "DSCAirdrop : Airdrop time interval is closed"
        );
        s_airdropData[_airdropId].players.push(_player);
        s_playerRegister[_airdropId][_player] = true;
        emit RegisterAirdrop(_airdropId, msg.sender, _player, airdrop.entranceFee);
    }

    /**
     * @notice : Include a checkUpkeep function that contains the logic that will be executed offchain to see if performUpkeep should be executed. checkUpkeep can use onchain data and a specified checkData parameter to perform complex calculations offchain and then send the result to performUpkeep as performData.
     */
    function checkUpkeep(
        bytes memory _checkData // airdrop is decode
    ) public view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 airdropId = abi.decode(_checkData, (uint64));
        Airdrop airdrop = s_airdropData[airdropId];

        bool isOpen = airdrop.state;
        bool timePassed = block.timestamp > airdrop.endTime;
        bool hasPlayers = airdrop.players.length >= 5; // minimum 5 players have to register the airdrop
        upkeepNeeded = (timePassed && isOpen && hasPlayers);
        return (upkeepNeeded, _checkData);
    }

    function performUpkeep(bytes calldata _performData) external override {
        // airdrop id is encoded into bytes
        (bool upkeepNeeded, bytes memory checkData) = checkUpkeep(_performData);
        require(upkeepNeeded, "DSCAirdrop : Upkeed was not met conditions");

        s_currentId = abi.decode(checkData, (uint64));
        s_airdropData[s_currentId].state = false;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, i_subscriptionId, REQUEST_CONFIRMATIONS, i_callbackGasLimit, NUM_WORDS
        );
    }

    /**
     * @dev This is the function that Chainlink VRF node
     * calls to send the money to the random winner.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        Airdrop memory m_airdrop = s_airdropData[s_currentId];
        Airdrop storage s_airdrop = s_airdropData[s_currentId];
        require(!m_airdrop.state, "DSCAirdrop : Airdrop is in active state");

        uint256 indexOfWinner = randomWords[0] % m_airdrop.players.length;
        s_airdrop.winner = m_airdrop.players[indexOfWinner];

        emit AnounceWinner(
            requestId,
            randomWords,
            s_currentId,
            m_airdrop.players.length,
            m_airdrop.players[indexOfWinner],
            m_airdrop.reward
        );

        s_currentId = 0;
        i_DSCEngine.mintForAirdrop(s_airdrop.winner, m_airdrop.reward);
    }

    function pause() onlyOwner {
        _pause();
    }

    function unpause() onlyOwner {
        _unpause();
    }

    /* ----------------------------- CONSUMER MANAGER ----------------------------- */
    // creates a subscription id while creating the contract
    function _createNewSubscription() private returns (uint64 subscriptionId) {
        subscriptionId = i_vrfCoordinator.createSubscription();
        // Add this contract as a consumer of its own subscription.
        // (consumer is contract address which uses randomness function)
        i_vrfCoordinator.addConsumer(subscriptionId, address(this));
        emit SubscriptionCreated(subscriptionId, address(this));
    }

    /**
     * Pay the link tokens for the subscription id.
     * @param _amount : Amount of link tokens that are funded to call the randomness functions
     */
    function topUpSubscription(uint256 _amount) external onlyOwner {
        i_linkToken.transferAndCall(address(i_vrfCoordinator), _amount, abi.encode(i_subscriptionId));
    }

    /**
     * Add a consumer for the subscription id.
     * @param _consumerAddress : new consumer address
     */
    function addConsumer(address _consumerAddress) external onlyOwner {
        // Add a consumer contract to the subscription.
        // only subscription created wallet address have able to add or remove consumers.
        i_vrfCoordinator.addConsumer(i_subscriptionId, _consumerAddress);
        emit AddConsumer(i_subscriptionId, _consumerAddress);
    }

    /**
     * Remove consumer from the subscription id.
     * @param _consumerAddress : consumer address
     */
    function removeConsumer(address _consumerAddress) external onlyOwner {
        // Remove a consumer contract from the subscription.
        i_vrfCoordinator.removeConsumer(i_subscriptionId, _consumerAddress);
        emit RemoveConsumer(i_subscriptionId, _consumerAddress);
    }

    /**
     * Cancel the subscription for permenantly.
     * @param _receivingWallet : After canceling subscription the remaining funds are received to this address.
     */
    function cancelSubscription(address _receivingWallet) external onlyOwner {
        // Cancel the subscription and send the remaining LINK to a wallet address.
        i_vrfCoordinator.cancelSubscription(i_subscriptionId, _receivingWallet);
        emit CancelSubscription(i_subscriptionId, _receivingWallet);
    }

    /**
     * Transfer this contract's funds to an address.
     * @param _amount : Amount to withdraw link tokens.
     * @param _to : Address who receives link tokens.
     */
    function withdraw(uint256 _amount, address _to) external onlyOwner {
        i_linkToken.transfer(_to, _amount);
    }

    /**
     * Withdraw the entrance fee amount from the contract.
     * @param _amount : Amount to withdraw.
     * @param _to : address who receives tokens.
     */
    function withdrawEth(uint256 _amount, address _to) external onlyOwner {
        (bool success,) = payable(_to).call{value: _amount}("");
        require(success, "DSCAirdrop : Transfer failed");
        emit WithdrawEth(_to, _amount);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Owned} from "@solmate/src/auth/Owned.sol";
import {ReentrancyGuard} from "@solmate/src/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {DSCLibrary} from "../libraries/DSCLibrary.sol";
import {DSC} from "./DSC.sol";

/**
 * @title DSC Engine
 * @author Rama chandra reddy
 * @notice Engine controls the minting and burning of dsc tokens.
 * At first DSCEngine is created, then dsc airdrop and pool contracts are deployed.
 * Overall minting and burning of DSC tokens are controlled from DSCEngine only.
 */
contract DSCEngine is Owned, ReentrancyGuard, Pausable, Multicall {
    using DSCLibrary for uint256;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event DSCMinted(address indexed user, address indexed mintedTo, uint256 amount);
    event DSCBurned(address indexed user, uint256 amount);

    DSC public immutable i_dsc; // DSC contract address

    address public i_DSCAirdrop; // airdrop contract address
    address public s_priceOracle; // priceOracle contract address
    address public i_pool; // staking pool address
    bool internal i_isSet;

    // Collateral to chain link pricefeed address
    mapping(address collateralToken => address priceFeed) public s_priceFeeds;
    // Amount of collateral deposited by user
    mapping(address user => mapping(address collateralToken => uint256 amount)) public s_collateralDeposited;
    // Amount of DSC minted by user
    mapping(address user => uint256 amount) public s_DSCMinted;
    // token collateral(weth/wbtc) coins addresses
    address[] public s_collateralTokens;

    modifier moreThanZero(uint256 _amount) {
        require(_amount != 0, "DSCEngine : Invalid zero amount");
        _;
    }

    modifier isAllowedToken(address _collateralToken) {
        require(s_priceFeeds[_collateralToken] != address(0), "DSCEngine : Invalid collateral token address");
        _;
    }

    /**
     * Setting the collaterals and its pricefeeds.
     * Price of collateral token is retrived using PriceOracle interface.
     * @param _tokenAddresses : array of collateral address
     * @param _priceFeedAddresses : array of chainlink priceFeed address
     * @param _dscAddress : DSC contract address
     * @param _priceOracle : chainlink PriceOracle address
     */
    constructor(
        address[] memory _tokenAddresses,
        address[] memory _priceFeedAddresses,
        address _dscAddress,
        address _priceOracle,
        address _owner
    ) Owned(_owner) {
        require(_tokenAddresses.length == _priceFeedAddresses.length, "DSCEngine : Invalid data length elements");
        // duplicate collateral address are not allowed;
        for (uint256 i; i < _tokenAddresses.length;) {
            require(s_priceFeeds[_tokenAddresses[i]] == address(0), "DSCEngine : Duplicate data entry");
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);

            unchecked {
                ++i;
            }
        }
        i_dsc = DSC(_dscAddress);
        s_priceOracle = _priceOracle;
    }

    /**
     * Deposit collateral and mint DSC tokens in single transaction to save some gas.
     * @param _tokenCollateralAddress : Address of collateral token that you are depositing.
     * @param _amountCollateral : Amount of collateral that you are depositing.
     * @param _amountDscToMint : Amount of Dsc tokens you want to mint after deposting collateral tokens.
     * @param _mintDscTo : Account who receives DSC tokens.
     */
    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint,
        address _mintDscTo
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint, _mintDscTo);
    }

    /**
     * Deposit collateral and mint DSC tokens in same function using signature for approving collateral tokens.
     * @param _tokenCollateralAddress : Address of collateral token that you are depositing.
     * @param _amountCollateral : Amount of collateral that you are depositing.
     * @param _deadline : Last time that the permit signature is valid.
     * @param _v : signature V parameter.
     * @param _r : signature R parameter.
     * @param _s : signature S parameter.
     * @param _amountDscToMint : Amount of Dsc tokens you want to mint after deposting collateral tokens.
     * @param _mintDscTo : Account who receives DSC tokens.
     */
    function depositCollateralAndMintDscWithPermit(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint256 _amountDscToMint,
        address _mintDscTo
    ) external {
        IERC20Permit(_tokenCollateralAddress).permit(
            msg.sender, address(this), _amountCollateral, _deadline, _v, _r, _s
        );
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint, _mintDscTo);
    }

    /**
     * Deposit collateral tokens into this contract by making another transaction for approval of collateral tokens.
     * @param _tokenCollateralAddress : Address of collateral token that you are depositing.
     * @param _amountCollateral : Amount of collateral that you are depositing.
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        whenNotPaused
        nonReentrant
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
    {
        address user = msg.sender;
        s_collateralDeposited[user][_tokenCollateralAddress] += _amountCollateral;
        SafeERC20.safeTransferFrom(IERC20(_tokenCollateralAddress), user, address(this), _amountCollateral);
        emit CollateralDeposited(user, _tokenCollateralAddress, _amountCollateral);
    }

    /**
     * Burn DSC tokens directly without any approving and redeem collateral tokens, then a user able to maintain his health factor correctly.
     * @param _tokenCollateralAddress : Address of collateral token
     * @param _amountCollateral : Amount of collaterl to redeem.
     * @param _amountDscToBurn : Amount of DCS to burn.
     * @param _redeemTo : Address of account who receives redeemed collateral.
     */
    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn,
        address _redeemTo
    ) external {
        // for burning the healthFactor is reduced then we can redeem the tokens
        burnDsc(_amountDscToBurn);
        // if we burn the dsc tokens then the health factor is increased and we can get more collateral without breaking the health factor
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, _redeemTo);
    }

    /**
     * Burn DSC tokens by approving token transfer and redeem collateral tokens, then a user able to maintain his health factor correctly.
     * @param _tokenCollateralAddress : Address of collateral token
     * @param _amountCollateral : Amount of collaterl to redeem.
     * @param _amountDscToBurn : Amount of DCS to burn.
     * @param _redeemTo : Address of account who receives redeemed collateral.
     */
    function redeemCollateralForDscByApprove(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn,
        address _redeemTo
    ) external {
        burnDscByApprove(_amountDscToBurn);
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, _redeemTo);
    }

    /**
     * Burn DSC tokens by approving token transfer using signature and redeem collateral tokens, then a user able to maintain his health factor correctly.
     * @param _tokenCollateralAddress : Address of collateral token
     * @param _amountCollateral : Amount of collaterl to redeem.
     * @param _amountDscToBurn : Amount of DCS to burn.
     * @param _redeemTo : Address of account who receives redeemed collateral.
     * @param _deadline : Last time that the signature is valid.
     * @param _v : signature V parameter.
     * @param _r : signature R parameter.
     * @param _s : signature S parameter.
     */
    function redeemCollateralForDscByPermit(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn,
        address _redeemTo,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        burnDscByPermit(_amountDscToBurn, _deadline, _v, _r, _s);
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, _redeemTo);
    }

    /**
     * Redeem collateral tokens that are deposited by user, after meeting health factor condition only.
     * @param _tokenCollateralAddress : Address of collateral token.
     * @param _amountCollateral : Amount of collaterl to redeem.
     * @param _redeemTo : Address of account who receives redeemed collateral.
     */
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _redeemTo) external {
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, _redeemTo);
        // _redeemcolleteral function. already checks the healthFactor, no need to check again
    }

    function _redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _from, address _to)
        private
        whenNotPaused
        nonReentrant
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
    {
        uint256 balanceCollateral = s_collateralDeposited[_from][_tokenCollateralAddress];
        require(balanceCollateral >= _amountCollateral, "DSCEngine : Insufficient balance to redeem collateral");
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        SafeERC20.safeTransfer(IERC20(_tokenCollateralAddress), _to, _amountCollateral);
        revertIfHealthFactorIsBroken(_from);
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);
    }

    /**
     * Burn Dsc tokens without approving for burning user tokens.
     * @param _amountDscToBurn : Amount of DSC to burn.
     */
    function burnDsc(uint256 _amountDscToBurn) public whenNotPaused nonReentrant moreThanZero(_amountDscToBurn) {
        address user = msg.sender;
        s_DSCMinted[user] -= _amountDscToBurn;
        i_dsc.burn(user, _amountDscToBurn); // overflow conditions are checked by solidity in new versions
        emit DSCBurned(user, _amountDscToBurn);
    }

    /**
     * Burn Dsc tokens by approving the DSCEngine to burn.
     * @param _amountDscToBurn : Amount of DSC to burn.
     */
    function burnDscByApprove(uint256 _amountDscToBurn) public {
        _burnDsc(_amountDscToBurn, msg.sender);
    }

    /**
     * Burn DSC tokens by approving token through signature.
     * @param _amountDscToBurn : Amount of DSC tokens to burn.
     * @param _deadline : Last timestamp that the signature is valid.
     * @param _v : signature V parameter.
     * @param _r : signature R parameter.
     * @param _s : signature S parameter.
     */
    function burnDscByPermit(uint256 _amountDscToBurn, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
        IERC20Permit(address(i_dsc)).permit(msg.sender, address(this), _amountDscToBurn, _deadline, _v, _r, _s);
        _burnDsc(_amountDscToBurn, msg.sender);
    }

    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf)
        private
        whenNotPaused
        nonReentrant
        moreThanZero(_amountDscToBurn)
    {
        // in DecentralizedStableCoin contract owner is the enginee so he can only burn the tokens
        s_DSCMinted[_onBehalfOf] -= _amountDscToBurn;
        SafeERC20.safeTransferFrom(IERC20(address(i_dsc)), _onBehalfOf, address(this), _amountDscToBurn);
        i_dsc.burn(address(this), _amountDscToBurn);
        emit DSCBurned(_onBehalfOf, _amountDscToBurn);
    }

    /**
     * Mint DSC tokens based on Health factor of over collateral of 200%
     * @param _amountDscToMint :Amount of DSC token to mint.
     */
    function mintDsc(uint256 _amountDscToMint, address _mintTo)
        public
        whenNotPaused
        nonReentrant
        moreThanZero(_amountDscToMint)
    {
        address user = msg.sender;
        s_DSCMinted[user] += _amountDscToMint;
        revertIfHealthFactorIsBroken(user);
        i_dsc.mint(_mintTo, _amountDscToMint);
        emit DSCMinted(user, _mintTo, _amountDscToMint);
    }

    /* ------------------------------- HELPER FUNCTIONS ------------------------------- */
    function revertIfHealthFactorIsBroken(address _user) private view {
        uint256 userHealthFactor = healthFactor(_user);
        require(userHealthFactor >= 1e18, "DSCEngine : Min health factory");
    }

    /**
     * Returns the health factor of user.
     * @param _user : Account address of user.
     */
    function healthFactor(address _user) public view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (_totalDscMinted == 0) return type(uint256).max;
        return (_collateralValueInUsd * 1e17) / (_totalDscMinted);
        // This means you need to be 200% over-collateralized
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /**
     * Returns the total collateral value in USD of a user.
     * @param _user : Address of user.
     */
    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUSD) {
        address[] memory m_collateralTokens = s_collateralTokens;
        uint256 len = m_collateralTokens.length;

        for (uint256 index; index < len;) {
            address token = m_collateralTokens[index];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUSD += _getUsdValue(token, amount);

            unchecked {
                ++index;
            }
        }
        return totalCollateralValueInUSD;
        // returns total collateral value in USD 18 decimals
    }

    /**
     * Returns the amount of USD value for given collateral amount.
     * @param _token : Collaterl token address.
     * @param _amount : amount of token.
     */
    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        return _getUsdValue(_token, _amount);
    }

    function _getUsdValue(address _token, uint256 _amount) private view returns (uint256 result) {
        // amount in WEI , if we want to find `x` amount of value in USD, then we have to pass `xe18`
        uint256 price = IPriceOracle(s_priceOracle).staleCheckLatestRoundData(s_priceFeeds[_token]);

        uint8 decimals = IERC20Metadata(_token).decimals();
        uint256 precision = 1e10;
        uint256 decimalPrecision = 10 ** decimals;

        // result = ((price * _amount * 1e10) / (10 ** decimals));
        return DSCLibrary.getUSDAmount(price, _amount, precision, decimalPrecision);
    }

    /**
     * Returns the amount of collaterl we get using USD value in WEI.
     * @param _token : Collaterl token address.
     * @param _usdAmountInWei : Amount of wei in USD value(18 decimals).
     */
    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256 result) {
        uint256 price = IPriceOracle(s_priceOracle).staleCheckLatestRoundData(s_priceFeeds[_token]);

        uint256 decimals = uint256(IERC20Metadata(_token).decimals());
        uint256 precision = 1e10;
        uint256 decimalPrecision = 10 ** decimals;

        // ((_usdAmountInWei * 10 ** decimals) / (price * 1e10));
        return DSCLibrary.getTokenAmount(_usdAmountInWei, decimalPrecision, price, precision);
    }
    /* ------------------------------- HELPER FUNCTIONS ------------------------------- */

    // If any hacks in oracle we can address of pricefeed and call the same functions using interfaces.
    function changePriceOracle(address _priceOracle) external onlyOwner {
        s_priceOracle = _priceOracle;
    }

    // this address is set for once after deploying airdrop and pool contracts
    function setAddress(address _dscAirdrop, address _pool) external onlyOwner {
        require(!i_isSet, "DSCEngine : Address are already set");
        i_pool = _pool;
        i_DSCAirdrop = _dscAirdrop;
        i_isSet = true;
    }

    // update the pricefeed when any oracle is changes.
    function updatePriceFeedAddress(address _collateralToken, address _priceFeed)
        external
        isAllowedToken(_collateralToken)
        onlyOwner
    {
        s_priceFeeds[_collateralToken] = _priceFeed;
    }

    function pauseFunctions() external onlyOwner {
        _pause();
    }

    function unPauseFunctions() external onlyOwner {
        _unpause();
    }

    /**
     * This function is only called by the Air drop contract to mint DSC tokesn as reward tokens.
     * @param _to : Address to mint DSC tokens.
     * @param _amount : Amount to mint tokens.
     */
    function mintForAirdrop(address _to, uint256 _amount) external whenNotPaused nonReentrant {
        require(msg.sender == i_DSCAirdrop, "DSCEngine : Invalid call from Airdrop");
        i_dsc.mint(_to, _amount);
    }

    /**
     * This function is only called by the pool contract to mint DSC tokesn as reward tokens.
     * @param _to : Address to mint DSC tokens.
     * @param _amount : Amount to mint tokens.
     */
    function mintForPool(address _to, uint256 _amount) external whenNotPaused nonReentrant {
        require(msg.sender == i_pool, "DSCEngine : Invalid call from pool");
        i_dsc.mint(_to, _amount);
    }
}

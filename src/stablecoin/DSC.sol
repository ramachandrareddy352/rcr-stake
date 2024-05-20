// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Owned} from "@solmate/src/auth/Owned.sol";
import {ERC20Permit, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/**
 * @title Dencentralized Stable Coin
 * @author Rama chandra reddy
 * @notice Owner of DSC Token contract is DSCEngine contract
 * Using multicall contract you can do both approve and tarnsferFrom in a single call.
 */
contract DSC is ERC20Permit, Owned, Multicall {
    /**
     * @param _owner : Owner of DSC Token contract is DSCEngine.
     * @param _name : Name of token.
     * @param _symbol : Symbol of token.
     */
    constructor(address _owner, string memory _name, string memory _symbol)
        Owned(_owner)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
    {}

    /**
     * Mint DSC tokens
     * @param _to : Address to mint DSC tokens.
     * @param _amount : Amount to mint.
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }

    /**
     * Burn DSC tokens
     * @param _from : Burn token from address.
     * @param _amount : Amount to burn.
     */
    function burn(address _from, uint256 _amount) external onlyOwner {
        _burn(_from, _amount);
    }
}

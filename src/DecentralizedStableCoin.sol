// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.22;

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    /*
    * @title DecentralizedStableCoin
    * @author Allen
    * @Collateral Exogenous(ETH & BTC)
    * Minting: Algorithmic
    * Relative Stability: Pegged to USD
    * This contract is meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our StableCoin System
    */
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoint__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable() {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //using the burn function from the parent class from ERC20Burnable
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoint__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}

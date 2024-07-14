//Handler is going to narrow down the way we call functions

// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.22;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

//Price feed

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max; //the max uint96 value..

    ERC20Mock weth;
    ERC20Mock wbtc;

    //Ghost variable to track if mint is called and its repetitions
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine __dscEngine, DecentralizedStableCoin _dsc) {
        dsce = __dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokensPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);
        console.log("MaxDscToMint:", uint256(maxDscToMint));

        if (maxDscToMint < 0) {
            console.log("MaxDscToMint < 0 , returning");
            return;
        }
        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        if (amountDscToMint == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amountDscToMint);
        vm.stopPrank();
        timesMintIsCalled++;
        console.log("Minted DSC, new count:", timesMintIsCalled);
    }

    //redeem collateral <-

    //these parameters are gonna be randomized

    //Call deposit collateral through handler which'll call all our engine's functionss...Will limit the errors while fail_On_revert = true
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); //comes with std utils
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateral.mint(msg.sender, amountCollateral);
        vm.startPrank(msg.sender);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // double push if same address is pushed twice
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem); //If max collateral to redeem is 0 this will break
        if (amountCollateral == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        collateral.approve(address(dsce), amountCollateral);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        require(collateral.balanceOf(msg.sender) >= amountCollateral, "Collateral transfer failed");
    }

    // $2000e8 updating it from thiss to
    //471 this

    //This breaks our invariant test suite!!

    // function updateCollateralPrice(uint96 newPrice) public{
    //     int256 newPriceInt = int256(uint(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    //Helper function
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}

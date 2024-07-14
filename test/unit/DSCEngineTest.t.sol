// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {VmSafe} from "lib/forge-std/src/Vm.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    address liquidator = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 DEBT_AMOUNT = 7 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    uint256 public LIQUIDATION_THRESHOLD;
    uint256 public LIQUIDATION_PRECISION;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);

        LIQUIDATION_THRESHOLD = dsce.getLiquidationThreshold();
        LIQUIDATION_PRECISION = dsce.getLiquidationPrecision(); //Initialize things in the constructor
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS 
    //////////////////////////////////////////////////////////////*/

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdInValue() public view {
        uint256 ethAmount = 15e18;
        //15e18 = 2000/ETH = 30000e18 Because 1 ETH equals $2000
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdInValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000/ETH , $100 , wEth = 100/2000
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //Test reentrancy too

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralAndMintDsc() public depositedCollateral {
        vm.startPrank(address(dsce));
        uint256 amountToMint = 1e18;
        dsc.mint(address(dsce), amountToMint);
        uint256 balance = dsc.balanceOf(address(dsce));
        assertEq(balance, amountToMint);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        //10 ether*2000 = $20000
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    function testRedeemCollateralForDsc() public depositedCollateral {
        //Start the prank for the USER
        vm.startPrank(USER);

        //Mint some DSC first
        uint256 amountToMint = 1e18;
        dsce.mintDsc(amountToMint);

        //Get the initial balances
        uint256 initialDscBalance = dsc.balanceOf(USER);
        uint256 initialCollateralBalance = ERC20Mock(weth).balanceOf(USER);

        //Calculate the amount to collateral to redeem
        uint256 collateralToRedeem = 1 ether;

        //Approve DSCEngine to spend user's DSC
        dsc.approve(address(dsce), amountToMint);

        dsce.redeemCollateralForDsc(weth, collateralToRedeem, amountToMint);

        //Get updated balances
        uint256 updatedDscBalance = dsc.balanceOf(USER);
        uint256 updatedCollateralBalance = ERC20Mock(weth).balanceOf(USER);
        vm.stopPrank();

        assertEq(updatedDscBalance, initialDscBalance - amountToMint);
        assertEq(updatedCollateralBalance, initialCollateralBalance + collateralToRedeem);
    }

    function testIfRevertsIfHealthFactorIsBroken() public depositedCollateral {
        //Calculating the maximum amount of DSC that can be minted
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 maxDscToMint = collateralValueInUsd * dsce.getLiquidationThreshold() / dsce.getLiquidationPrecision();

        //Attempt to mint slightly more than the maximum allowed
        uint256 amountToMint = maxDscToMint + 1;
        vm.startPrank(USER);

        //This should revert due to broken health factor
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 999999999999999999));
        dsce.mintDsc(amountToMint);

        vm.stopPrank();
    }

    //Write these tests yourself, you might need to refractor some code

    /*//////////////////////////////////////////////////////////////
                               LIQUIDATE
    //////////////////////////////////////////////////////////////*/

    function testIfLiquidatesCorrectly() public depositedCollateral {
        //Setup , done
        //Provide collateral and mint dsc for the user , done
        dsce.mintDsc(DEBT_AMOUNT/20);

        //Check health factor
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        assertLt(userHealthFactor, dsce.MIN_HEALTH_FACTOR());

        //Prepare the liquidator
        vm.startPrank(liquidator);
        uint256 debtToCover = DEBT_AMOUNT/4;
        uint256 liquidatorCollateral = 10 ether;
        ERC20Mock(weth).mint(liquidator, debtToCover);
        ERC20Mock(weth).approve(address(dsce), debtToCover);
        // Deposit more collateral than the debt to ensure a good health factor
        dsce.depositCollateralAndMintDSC(weth, liquidatorCollateral, debtToCover);
        dsc.approve(address(dsce), debtToCover);

        //Record balances after liquidation
        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(liquidator);
        uint256 liquidatorDscBefore = dsc.balanceOf(liquidator);
        uint256 userWethBefore = ERC20Mock(weth).balanceOf(USER);
        uint256 userDscBefore = dsc.balanceOf(USER);

        //Perform liquidation
        dsce.liquidate(liquidator, USER, debtToCover);
        vm.stopPrank();

        //Check balances after liquidation
        uint256 liquidatorWethAfter = ERC20Mock(weth).balanceOf(liquidator);
        uint256 liquidatorDscAfter = dsc.balanceOf(liquidator);
        uint256 userWethAfter = ERC20Mock(weth).balanceOf(USER);
        uint256 userDscAfter = dsc.balanceOf(USER);

        assertLt(liquidatorWethAfter, liquidatorWethBefore, "Liquidator WETH should decrease");
        assertGt(liquidatorDscAfter, liquidatorDscBefore, "Liquidator DSC amount should increase");
        assertLt(userWethAfter, userWethBefore, "User WETH should decrease");
        assertEq(userDscAfter, userDscBefore - debtToCover, "User DSC should decrease by debtToCover");

        //Check health factor improvement
        uint256 userHealthFactorAfter = dsce.getHealthFactor(USER);
        assertGt(userHealthFactorAfter, userHealthFactor, "User health factor should improve");
    }
}

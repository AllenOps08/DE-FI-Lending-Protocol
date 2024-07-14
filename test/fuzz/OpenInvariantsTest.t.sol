// // SPDX-License-Identifier: SEE LICENSE IN LICENSE
// pragma solidity 0.8.22;

// //Have our invariant aka our properties of the system that always hold

// //What are our invariants?

// //1. The total supply of DSC should ne less than the total value of collateral
// //2. The Getter functions should never recvert <-- evergreen invariant

// import {Test,console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "script/DeployDSC.s.sol";
// import {DSCEngine} from "src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract InvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (,,weth,wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view{
//         //get the value of all the collateral in the protocol
//         //compare it to all the debt(dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 wethValue = dsce.getUsdInValue(weth,totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdInValue(wbtc,totalBtcDeposited);

//         console.log("weth value: ", wbtcValue);
//         console.log("weth value : ", wbtcValue);
//         console.log("total supplu", totalSupply);
//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }

// //this calls all types of tests on your dsce and tries to break it

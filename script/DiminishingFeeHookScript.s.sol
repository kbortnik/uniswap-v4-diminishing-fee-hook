// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

import { Constants } from "./base/Constants.sol";
import { DiminishingFeeHook } from "../src/DiminishingFeeHook.sol";
import { HookMiner } from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Mines the address and deploys the DiminishingFeeHook.sol Hook contract
contract DiminishingFeeHookScript is Script, Constants {
    function setUp() public {}

    function run() public {
        uint24[] memory feeTiers = new uint24[](7);
        feeTiers[0] = 150_000; // 15%
        feeTiers[1] = 70_000; // 7%
        feeTiers[2] = 50_000; // 5%
        feeTiers[3] = 20_000; // 2%
        feeTiers[4] = 10_000; // 1%
        feeTiers[5] = 5_000; // 0.5%
        feeTiers[6] = 2_500; // 0.25%

        uint256[] memory timeThresholds = new uint256[](6);
        // First fee tier starts immediately!
        timeThresholds[0] = 10; // 10 mins after pool init
        timeThresholds[1] = 130; // 120 min after tier 1
        timeThresholds[2] = 250; // 120 min after tier 2
        timeThresholds[3] = 370; // 120 min after tier 3
        timeThresholds[4] = 490; // 120 min after tier 4
        timeThresholds[5] = 1440; // 950 min after tier 5

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOLMANAGER, feeTiers, timeThresholds, address(msg.sender));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(DiminishingFeeHook).creationCode,
            constructorArgs
        );

        // Deploy the hook using CREATE2
        vm.broadcast();

        DiminishingFeeHook diminishingFeeHook = new DiminishingFeeHook{ salt: salt }(
            IPoolManager(POOLMANAGER),
            feeTiers,
            timeThresholds,
            address(msg.sender)
        );
        require(address(diminishingFeeHook) == hookAddress, "DiminishingFeeHookScript: hook address mismatch");
    }
}

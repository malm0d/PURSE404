// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {PurseToken} from "src/PurseToken.sol";
import {Upgrades} from "lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

// forge clean && forge build
// forge test --mc PurseTokenTest -vvvv --ffi
contract PurseTokenTest is Test {
    PurseToken purseToken;
    address purseTokenAddress;
    address owner;
    address user1;

    function setUp() public {
        owner = address(0xbeefbeef);
        user1 = address(0xdeadbeef);
        purseTokenAddress = Upgrades.deployUUPSProxy(
            "PurseToken.sol",
            abi.encodeCall(PurseToken.initialize, (owner, owner, owner, owner))
        );
        purseToken = PurseToken(purseTokenAddress);
    }

    function test_initialize() public {
        assertEq(purseToken.name(), "PURSE TOKEN");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "lib/forge-std/src/Test.sol";
import {PurseToken} from "src/PurseToken.sol";
import {PurseToken404} from "src/PurseToken404.sol";
import {Upgrades} from "lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// forge clean && forge build
// forge test --mc PurseTokenTest -vvvv --ffi

interface IERC20Errors {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
}

contract SafeERC721Recipient is IERC721Receiver {
    PurseToken404 purseToken404;
    address owner;
    address user1;

    constructor(PurseToken404 _purseToken404, address _owner, address _user1) {
        purseToken404 = _purseToken404;
        owner = _owner;
        user1 = _user1;
    }

    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*tokenId*/,
        bytes calldata /*data*/
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract UnsafeERC721Recipient {
    PurseToken404 purseToken404;
    address owner;
    address user1;

    constructor(PurseToken404 _purseToken404, address _owner, address _user1) {
        purseToken404 = _purseToken404;
        owner = _owner;
        user1 = _user1;
    }

}

contract PurseTokenTest is Test {
    PurseToken purseToken;
    PurseToken404 purseToken404;
    address purseTokenAddress;
    address owner;
    address user1;
    uint256 balanceOnDeployment = 10_000_000_000 ether;
    uint256 UNITS;
    uint256 ID_ENCODING_PREFIX = 1 << 255;

    SafeERC721Recipient safeERC721Recipient;
    UnsafeERC721Recipient unsafeERC721Recipient;

    function setUp() public {
        owner = address(this);
        user1 = address(0xdeadbeef);
        purseTokenAddress = Upgrades.deployTransparentProxy(
            "PurseToken.sol",
            address(this),
            abi.encodeCall(PurseToken.initialize, (owner, owner, owner, owner))
        );
        purseToken = PurseToken(purseTokenAddress);

        Upgrades.upgradeProxy(purseTokenAddress, "PurseToken404.sol", "");
        purseToken404 = PurseToken404(purseTokenAddress);

        purseToken404.init404(24);
        purseToken404.setMaxTokenId(10_000);

        UNITS = purseToken404.units(); //1 million ether (10^24)

        safeERC721Recipient = new SafeERC721Recipient(purseToken404, owner, user1);
        unsafeERC721Recipient = new UnsafeERC721Recipient(purseToken404, owner, user1);
    }

    ///@dev Test that the contract is initialized correctly
    function test_initialize() public {
        assertEq(purseToken.name(), "PURSE TOKEN");
    }

    ///@dev Test that units are set correctly
    function testInit404() public {
        uint256 decimals = 18;
        purseToken404.init404(decimals);
        assertEq(purseToken404.units(), 10 ** decimals);
    }

    ///@dev Test that max token id is set correctly
    function testUpdateMaxTokenId() public {
        purseToken404.setMaxTokenId(10_001);
        assertEq(purseToken404.erc721MaxTokenId(), (1 << 255) + 10_001);
    }

    ///@dev Test that setting max token id fails correctly
    function testUpdateMaxTokenId_failure() public {
        purseToken404.mintERC721();

        assertEq(purseToken404.minted(), 10_000);
        assertEq(purseToken404.erc721BalanceOf(owner), 10_000);
        assertEq(purseToken404.activeBalance(owner), 10_000 * UNITS);
        assertEq(purseToken404.inactiveBalance(owner), balanceOnDeployment - 10_000 * UNITS);
        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment);

        vm.expectRevert("Less than minted");
        purseToken404.setMaxTokenId(9000);
    }

    ///@dev Test that approve updates correctly
    function testApproveAsERC20() public {
        purseToken404.approve(user1, 1_000_000_000_000 ether);
        assertEq(purseToken404.allowance(owner, user1), 1_000_000_000_000 ether);
    }

    ///@dev Test that approve updates correctly
    function testApproveAsERC20_fuzz(uint256 amt) public {
        amt = amt % (1 << 255);
        purseToken404.approve(user1, amt);
        assertEq(purseToken404.allowance(owner, user1), amt);
    }

    ///@dev Test that approve fails correctly
    function testApproveAsERC20_failure() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InvalidSpender(address)")),
                address(0)
            )
        );
        purseToken404.approve(address(0), 1_000_000_000_000 ether);
    }

    ///@dev Test that approve as ERC721 updates correctly
    function testApproveAsERC721() public {
        uint256 tokenId1 = purseToken404.ID_ENCODING_PREFIX() + 1;
        purseToken404.mintERC721();
        purseToken404.approve(user1, tokenId1);
        assertEq(purseToken404.getApproved(tokenId1), user1);
    }

    ///@dev Test that approve as ERC721 updates correctly
    function testApproveAsERC721_fuzz(uint256 _tokenId) public {
        uint256 tokenId = bound(_tokenId, 1, 10_000);
        uint256 tokenIdActual = purseToken404.ID_ENCODING_PREFIX() + tokenId;
        purseToken404.mintERC721();
        purseToken404.approve(user1, tokenIdActual);
        assertEq(purseToken404.getApproved(tokenIdActual), user1);
    }

    ///@dev Edge case where token id is 0. This approval should behave like an ERC20 approval
    function testApproveAsERC721_failure_TokenIdZero_asERC20() public {
        uint256 tokenId0 = purseToken404.ID_ENCODING_PREFIX() + 0;
        purseToken404.mintERC721();
        purseToken404.approve(user1, tokenId0);

        assertEq(purseToken404.getApproved(tokenId0), address(0));

        //since token id 0 is non existent, approval will be erc20
        assertEq(purseToken404.allowance(owner, user1), tokenId0);
    }

    ///@dev Test approve as ERC721 token, but approves as ERC20 since invalid token id
    function testApproveAsERC721_failure_TokenIdInvalid_asERC20() public {
        uint256 tokenIdInvalid = purseToken404.ID_ENCODING_PREFIX() + 1_000_000;
        purseToken404.mintERC721();
        purseToken404.approve(user1, tokenIdInvalid);

        assertEq(purseToken404.getApproved(tokenIdInvalid), address(0));

        //since token id invalid, will be ERC20 approval
        assertEq(purseToken404.allowance(owner, user1), tokenIdInvalid);
    }

    ///@dev Test approve as ERC721 token, but approves as ERC20 since invalid token id
    function testApproveAsERC721_failure_TokenIdInvalid_asERC20_fuzz(uint256 _tokenId) public {
        _tokenId = bound(_tokenId, 10_001, (1 << 255) - 1);
        uint256 tokenIdInvalid = purseToken404.ID_ENCODING_PREFIX() + _tokenId;
        purseToken404.mintERC721();
        purseToken404.approve(user1, tokenIdInvalid);

        assertEq(purseToken404.getApproved(tokenIdInvalid), address(0));

        //since token id invalid, will be ERC20 approval
        assertEq(purseToken404.allowance(owner, user1), tokenIdInvalid);
    }

    ///@dev Test setApprovalForAll updates correctly
    function testSetApprovalForAll() public {
        purseToken404.setApprovalForAll(user1, true);
        assert(purseToken404.isApprovedForAll(owner, user1));

        purseToken404.setApprovalForAll(user1, false);
        assert(!purseToken404.isApprovedForAll(owner, user1));
    }

    ///@dev Test setApprovalForAll fails correctly
    function testSetApprovalForAll_failure() public {
        vm.expectRevert(bytes4(keccak256("InvalidOperator()")));
        purseToken404.setApprovalForAll(address(0), true);
    }

    ///@dev Test ERC20 mint updates correctly
    function testMintERC20() public {
        uint256 initialERC20Balance = purseToken404.balanceOf(owner);
        uint256 initialERC721Balance = purseToken404.activeBalance(owner);
        purseToken404.mint(owner, 100);
        assertEq(purseToken404.balanceOf(owner), initialERC20Balance + 100);
        assertEq(purseToken404.activeBalance(owner), 0);
    }

    ///@dev Test ERC20 mint updates correctly
    function testMintERC20_fuzz(uint256 amt) public {
        amt = amt % 1_000_000_000_000_000 ether;
        uint256 initialERC20Balance = purseToken404.balanceOf(owner);
        uint256 initialERC721Balance = purseToken404.activeBalance(owner);
        purseToken404.mint(owner, amt);
        assertEq(purseToken404.balanceOf(owner), initialERC20Balance + amt);
        assertEq(purseToken404.activeBalance(owner), 0);
    }

    ///@dev Test ERC20 mint fails correctly
    function testMintERC20_failure() public {
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        purseToken404.mint(address(0), 100);

        vm.expectRevert(bytes4(keccak256("MintLimitReached()")));
        purseToken404.mint(user1, (1 << 255));
    }

    ///@dev Test ERC20 mint fails correctly
    function testMintERC20_failure_fuzz(uint256 amt) public {
        amt = bound(amt, (1 << 255) - 9_999_999_999 ether, (1 << 255));
        vm.expectRevert(bytes4(keccak256("MintLimitReached()")));
        purseToken404.mint(owner, amt);
    }

    ///@dev Test ERC721 mint updates correctly
    function testMintERC721() public {
        purseToken404.transfer(user1, 2_500_000_000 ether);
        assertEq(purseToken404.balanceOf(owner), 7_500_000_000 ether);
        assertEq(purseToken404.balanceOf(user1), 2_500_000_000 ether);

        assertEq(purseToken404.erc721BalanceOf(owner), 0);
        assertEq(purseToken404.activeBalance(owner), 0);
        assertEq(purseToken404.inactiveBalance(owner), 7_500_000_000 ether);

        purseToken404.mintERC721();

        assertEq(purseToken404.units(), 1_000_000 ether);

        assertEq(purseToken404.minted(), 7_500);
        assertEq(purseToken404.erc721BalanceOf(owner), 7_500);
        assertEq(purseToken404.activeBalance(owner), 7_500 * UNITS);
        assertEq(purseToken404.inactiveBalance(owner), purseToken404.balanceOf(owner) - 7_500 * UNITS);
        
        assertEq(purseToken404.ownerOf(purseToken404.ID_ENCODING_PREFIX() + 1), owner);
        assertEq(purseToken404.ownerOf(purseToken404.ID_ENCODING_PREFIX() + 7_500), owner);

        vm.startPrank(user1);
        assertEq(purseToken404.balanceOf(user1), 2_500_000_000 ether);
        purseToken404.mintERC721();
        vm.stopPrank();

        assertEq(purseToken404.minted(), 10_000);

        assertEq(purseToken404.erc721BalanceOf(user1), 2_500);
        assertEq(purseToken404.activeBalance(user1), 2_500 * UNITS);
        assertEq(purseToken404.inactiveBalance(user1), purseToken404.balanceOf(user1) - 2_500 * UNITS);

        assertEq(purseToken404.ownerOf(purseToken404.ID_ENCODING_PREFIX() + 7_501), user1);
        assertEq(purseToken404.ownerOf(purseToken404.ID_ENCODING_PREFIX() + 10_000), user1);
    }

    ///@dev Test ERC721 mint fails correctly
    function testMintERC721_failure() public {
        purseToken404.mintERC721();
        assertEq(purseToken404.minted(), 10_000);
        
        purseToken404.mint(user1, 1_000_000 ether);
        assertEq(purseToken404.balanceOf(user1), 1_000_000 ether);

        //Not reverting although mint limit is reached, check `mintERC721`
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("MintLimitReached()")));
        purseToken404.mintERC721();
        vm.stopPrank();

        assertEq(purseToken404.activeBalance(user1), 0);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.minted(), 10_000);
    }

    ///@dev Test ERC20 burn updates correctly
    function testBurnOnlyERC20() public {
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        purseToken404.burn(1_000_000 ether);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);

        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment - 1_000_000 ether);
        assertEq(activeBalanceAfter, activeBalanceBefore);
    }

    ///@dev Test ERC20 burn updates correctly
    function testBurnOnlyERC20_fuzz(uint256 amt) public {
        amt = amt % balanceOnDeployment + 1;

        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        purseToken404.burn(amt);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);

        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment - amt);
        assertEq(activeBalanceAfter, activeBalanceBefore);
    }

    ///@dev Test ERC20 burn updates correctly with ERC721s
    function testBurnERC20WithERC721() public {
        //Mint 10_000 NFTs,
        //so active balance = 10_000 * UNITS
        //inactive balance = 0
        //balance of = 10_000_000_000 ether
        purseToken404.mintERC721();

        purseToken404.mint(owner, 5_000_000 ether);

        //balance of = 10_005_000_000 ether
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        //inactive balance = 5_000_000 ether
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        //active balance = 10_000_000_000 ether
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        //erc721 balance = 10_000
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //This should burn 5_000_005 ether from balanceOf.
        //Inactive balance first gets burned completely, then
        //1 NFT gets burned in the process because 1 NFT = 1_000_000 ether.
        //Since active balance is in multiples of 1_000_000 ether,
        //there should be a rebalance in the inactive balance.
        //Such that the inactive balance is 1_000_000 ether - (5_000_005 ether % 1_000_000 ether).
        purseToken404.burn(5_000_005 ether);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);
        
        assertEq(balanceOfAfter, balanceOfBefore - 5_000_005 ether);
        assertEq(inactiveBalanceAfter, UNITS - (5_000_005 ether % UNITS));
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);
    }

    ///@dev Test ERC20 burn updates correctly with ERC721s
    function testBurnERC20WithERC721_fuzz1(uint256 amt) public {
        //burn only between 1 million and 1 billion ether to simulate burning 1 to 5000 NFTs
        amt = bound(amt, 1_000_000 ether, 5_000_000_000 ether);

        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.burn(amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 diffInValue = amt - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);
        
        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter);
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);
    }

    ///@dev Test ERC20 burn updates correctly with ERC721s
    function testBurnERC20WithERC721_fuzz2(uint256 amt) public {
        //burnbetween 5 million and 5 billion ether to simulate burning 5 to 5000 NFTs
        amt = bound(amt, 5_000_000 ether, 5_000_000_000 ether);

        purseToken404.mintERC721();

        //Increase inactive balance to non-zero value
        purseToken404.mint(owner, 5_000_000 ether);

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.burn(amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 diffInValue = amt - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);
        
        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter);
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);
    }

    ///@dev Test ERC20 burn fails correctly
    function testBurnAsERC20_failure() public {
        //Not reverting with the correct error - underflow error thrown in _transferERC20 where its calculating for
        //tokensToWithdrawAndStore if user did not mint any ERC721s prior to burning
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                owner, 
                balanceOnDeployment, 
                balanceOnDeployment + 1
            )
        );
        // vm.expectRevert("Insufficient balance");
        purseToken404.burn(balanceOnDeployment + 1);
    }

    ///@dev Test ERC20 burn fails correctly
    function testBurnAsERC20_failure_fuzz(uint256 amt) public {
        //same issue as above
        vm.assume(amt > balanceOnDeployment);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                owner, 
                balanceOnDeployment, 
                amt
            )
        );
        //vm.expectRevert("Insufficient balance");
        purseToken404.burn(amt);
    }

    ///@dev Test ERC20 transfer updates correctly
    function testERC20Transfer() public {
        //Without any NFT minted
        purseToken404.transfer(user1, 1_000_000 ether);
        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment - 1_000_000 ether);
        assertEq(purseToken404.balanceOf(user1), 1_000_000 ether);

        //After NFT minted - inactive and active balances should adjust accordingly
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.transfer(user1, 4_007_777 ether);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 tokensBurned = 4_007_777 ether / UNITS + (4_007_777 ether % UNITS == 0 ? 0 : 1);

        assertEq(balanceOfAfter, balanceOfBefore - 4_007_777 ether);
        assertEq(inactiveBalanceAfter, UNITS - (4_007_777 ether % UNITS));
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensBurned * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensBurned);
        assertEq(tokensBurned, erc721BalanceBefore - erc721BalanceAfter);

        assertEq(purseToken404.balanceOf(user1), 1_000_000 ether + 4_007_777 ether);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transfer updates correctly
    //Transfer where inactive balance starts at zero, in this case, NFTs are adjusted
    function testERC20Transfer_fuzz1(uint256 amt) public {
        amt = amt % balanceOnDeployment + 1;
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.transfer(user1, amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 diffInValue = amt - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);

        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter); 
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);

        assertEq(purseToken404.balanceOf(user1), amt);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transfer updates correctly
    //Transfer where transfer value is always more than inactive balance
    //so that NFT amounts get adjusted
    function testERC20Transfer_fuzz2(uint256 amt) public {
        purseToken404.mintERC721();
        //Increase inactive balance to non-zero value
        uint256 additionalBalance = 7_777_777 ether;
        purseToken404.mint(owner, additionalBalance);

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        amt = bound(amt, inactiveBalanceBefore + 1, balanceOfBefore);

        purseToken404.transfer(user1, amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        console2.logUint(amt);
        console2.logUint(inactiveBalanceBefore);
        uint256 diffInValue = amt - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);

        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter); 
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);

        assertEq(purseToken404.balanceOf(user1), amt);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transfer updates correctly
    //Transfer where transfer value is always less than inactive balance
    //so that NFT amounts do not get adjusted
    function testERC20Transfer_fuzz3(uint256 amt) public {
        purseToken404.mintERC721();
        //Increase inactive balance to non-zero value
        uint256 additionalBalance = 7_777_777 ether;
        purseToken404.mint(owner, additionalBalance);

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        amt = bound(amt, 0, inactiveBalanceBefore);

        purseToken404.transfer(user1, amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore - amt);
        assertEq(activeBalanceAfter, activeBalanceBefore);
        assertEq(erc721BalanceAfter, erc721BalanceBefore);

        assertEq(purseToken404.balanceOf(user1), amt);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transfer updates correctly in a self transfer
    function testSelfTransferERC20() public {
        //Without any NFT minted
        purseToken404.transfer(owner, 1_000_000 ether);
        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment);

        //After NFT minted - there should be only be NFT changes
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.transfer(owner, 4_007_777 ether);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);


        uint256 tokensBurned = 4_007_777 ether / UNITS + (4_007_777 ether % UNITS == 0 ? 0 : 1);

        assertEq(balanceOfAfter, balanceOfBefore);
        assertEq(inactiveBalanceAfter, tokensBurned * UNITS);
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensBurned * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensBurned);
        assertEq(tokensBurned, erc721BalanceBefore - erc721BalanceAfter);
    }

    ///@dev Test ERC20 transfer updates correctly in a self transfer
    function testSelfTransferERC20_fuzz(uint256 amt) public {
        amt = amt % balanceOnDeployment + 1;

        //After NFT minted - there should be only be NFT changes
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.transfer(owner, amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);


        uint256 tokensBurned = amt / UNITS + (amt % UNITS == 0 ? 0 : 1);

        assertEq(balanceOfAfter, balanceOfBefore);
        assertEq(inactiveBalanceAfter, tokensBurned * UNITS);
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensBurned * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensBurned);
        assertEq(tokensBurned, erc721BalanceBefore - erc721BalanceAfter);
    }

    ///@dev Test ERC20 transfer fails correctly
    function testERC20Transfer_failure() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                owner, 
                balanceOnDeployment, 
                balanceOnDeployment + 1
            )
        );
        //vm.expectRevert("Insufficient balance");
        purseToken404.transfer(user1, balanceOnDeployment + 1);
    }

    ///@dev Test ERC20 transfer fails correctly
    function testERC20Transfer_failure_fuzz(uint256 amt) public {
        vm.assume(amt > balanceOnDeployment);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                owner, 
                balanceOnDeployment, 
                amt
            )
        );
        //vm.expectRevert("Insufficient balance");
        purseToken404.transfer(user1, amt);
    }

    ///@dev Test ERC20 transferFrom updates correctly
    function testERC20TransferFrom() public {
        //Without any NFT minted
        purseToken404.approve(user1, 1_000_000 ether);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, 1_000_000 ether);
        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment - 1_000_000 ether);
        assertEq(purseToken404.balanceOf(user1), 1_000_000 ether);
        assertEq(purseToken404.allowance(owner, user1), 0);
        vm.stopPrank();

        //After NFT minted - inactive and active balances should adjust accordingly
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.approve(user1, balanceOfBefore);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, 8_888_888 ether);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 diffInValue = 8_888_888 ether - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);
        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);
        uint256 tokensBurned = 8_888_888 ether / UNITS + (8_888_888 ether % UNITS == 0 ? 0 : 1);

        assertEq(balanceOfAfter, balanceOfBefore - 8_888_888 ether);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter);
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);
        assertEq(tokensBurned, erc721BalanceBefore - erc721BalanceAfter);
        assertEq(purseToken404.allowance(owner, user1), balanceOfBefore - 8_888_888 ether);

        assertEq(purseToken404.balanceOf(user1), 1_000_000 ether + 8_888_888 ether);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transferFrom updates correctly
    //TransferFrom where inactive balance starts at zero, in this case, NFTs are adjusted
    function testERC20TransferFrom_fuzz1(uint256 amt) public {
        amt = amt % balanceOnDeployment + 1;
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.approve(user1, balanceOfBefore);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, amt);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 diffInValue = amt - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);

        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter); 
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);
        assertEq(purseToken404.allowance(owner, user1), balanceOfBefore - amt);

        assertEq(purseToken404.balanceOf(user1), amt);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transferFrom updates correctly
    //TransferFrom where transfer value is always more than inactive balance
    //so that NFT amounts get adjusted
    function testERC20TransferFrom_fuzz2(uint256 amt) public {
        purseToken404.mintERC721();
        //Increase inactive balance to non-zero value
        uint256 additionalBalance = 7_777_777 ether;
        purseToken404.mint(owner, additionalBalance);

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        amt = bound(amt, inactiveBalanceBefore + 1, balanceOfBefore);

        purseToken404.approve(user1, balanceOfBefore);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, amt);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        console2.logUint(amt);
        console2.logUint(inactiveBalanceBefore);
        uint256 diffInValue = amt - inactiveBalanceBefore;
        uint256 tokensWithdrawAndStored = diffInValue / UNITS + (diffInValue % UNITS == 0 ? 0 : 1);

        uint256 inactiveBalanceAfter = diffInValue % UNITS == 0 ? 0 : UNITS - (diffInValue % UNITS);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(purseToken404.inactiveBalance(owner), inactiveBalanceAfter); 
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensWithdrawAndStored * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensWithdrawAndStored);
        assertEq(purseToken404.allowance(owner, user1), balanceOfBefore - amt);

        assertEq(purseToken404.balanceOf(user1), amt);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transferFrom updates correctly
    //TransferFrom where transfer value is always less than inactive balance
    //so that NFT amounts do not get adjusted
    function testERC20TransferFrom_fuzz3(uint256 amt) public {
        purseToken404.mintERC721();
        //Increase inactive balance to non-zero value
        uint256 additionalBalance = 7_777_777 ether;
        purseToken404.mint(owner, additionalBalance);

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        amt = bound(amt, 0, inactiveBalanceBefore);

        purseToken404.approve(user1, balanceOfBefore);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, amt);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        assertEq(balanceOfAfter, balanceOfBefore - amt);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore - amt);
        assertEq(activeBalanceAfter, activeBalanceBefore);
        assertEq(erc721BalanceAfter, erc721BalanceBefore);
        assertEq(purseToken404.allowance(owner, user1), balanceOfBefore - amt);

        assertEq(purseToken404.balanceOf(user1), amt);
        assertEq(purseToken404.erc721BalanceOf(user1), 0);
        assertEq(purseToken404.activeBalance(user1), 0);
    }

    ///@dev Test ERC20 transferFrom updates correctly in a self transfer
    function testSelfTransferFromERC20() public {
        //Without any NFT minted
        purseToken404.approve(owner, 1_000_000 ether);
        purseToken404.transferFrom(owner, owner, 1_000_000 ether);
        assertEq(purseToken404.balanceOf(owner), balanceOnDeployment);
        assertEq(purseToken404.allowance(owner, owner), 0);

        //After NFT minted - there should be only be NFT changes
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.approve(owner, 4_007_777 ether);
        purseToken404.transferFrom(owner, owner, 4_007_777 ether);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 tokensBurned = 4_007_777 ether / UNITS + (4_007_777 ether % UNITS == 0 ? 0 : 1);

        assertEq(balanceOfAfter, balanceOfBefore);
        assertEq(inactiveBalanceAfter, tokensBurned * UNITS);
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensBurned * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensBurned);
        assertEq(tokensBurned, erc721BalanceBefore - erc721BalanceAfter);
        assertEq(purseToken404.allowance(owner, owner), 0);
    }

    ///@dev Test ERC20 transferFrom updates correctly in a self transfer
    function testSelfTransferFromERC20_fuzz(uint256 amt) public {
        amt = amt % balanceOnDeployment + 1;
        purseToken404.mintERC721();

        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        purseToken404.approve(owner, balanceOfBefore);
        purseToken404.transferFrom(owner, owner, amt);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        uint256 tokensBurned = amt / UNITS + (amt % UNITS == 0 ? 0 : 1);

        assertEq(balanceOfAfter, balanceOfBefore);
        assertEq(inactiveBalanceAfter, tokensBurned * UNITS); 
        assertEq(activeBalanceAfter, activeBalanceBefore - tokensBurned * UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - tokensBurned);
        assertEq(tokensBurned, erc721BalanceBefore - erc721BalanceAfter);
        assertEq(purseToken404.allowance(owner, owner), balanceOfBefore - amt);
    }

    ///@dev Test ERC20 transferFrom fails correctly
    function testERC20TransferFrom_failure() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, balanceOnDeployment
            )
        );
        purseToken404.transferFrom(owner, user1, balanceOnDeployment);
        vm.stopPrank();

        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        purseToken404.transferFrom(owner, address(0), 1_000_000 ether);
    }

    ///@dev Test ERC20 transferFrom fails correctly
    function testERC20TransferFrom_failure_fuzz(uint256 amt, uint256 amt2) public {
        //Bound amount to more than zero because zero approval amount does not make sense
        vm.assume(amt > 0);
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, amt
            )
        );
        purseToken404.transferFrom(owner, user1, amt);
        vm.stopPrank();

        amt2 = bound(amt2, 0, balanceOnDeployment);
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        purseToken404.transferFrom(owner, address(0), 1_000_000 ether);
    }

    ///@dev Test ERC721 transferFrom, updates correctly
    //Regular ERC721 transferFrom where operator is the sender
    function testERC721TransferFrom1() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 5_000_000 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = ID_ENCODING_PREFIX + 2359;
        purseToken404.transferFrom(owner, user1, tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);
        
        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 transferFrom updates correctly
    //Regular ERC721 transferFrom where operator is approved
    function testERC721TransferFrom2() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 5_000_000 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //Approve an operator to transfer the token
        uint256 tokenId = ID_ENCODING_PREFIX + 343;
        purseToken404.approve(user1, tokenId);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, tokenId);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);
        
        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 transferFrom updates correctly
    //Regular ERC721 transferFrom where operator is approved
    function testERC721TransferFrom_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 5_000_000 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);


        //Approve an operator to transfer the token
        uint256 tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());
        purseToken404.approve(user1, tokenId);

        vm.startPrank(user1);
        purseToken404.transferFrom(owner, user1, tokenId);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);
        
        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 transferFrom updates correctly in a self transfer
    function testERC721TransferFromSelf() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 5_000_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = ID_ENCODING_PREFIX + 343;
        purseToken404.transferFrom(owner, owner, tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore);
        assertEq(erc721BalanceAfter, erc721BalanceBefore);        
        assertEq(ownerOfToken, owner);
    }

    ///@dev Test ERC721 transferFrom updates correctly in a self transfer
    function testERC721TransferFromSelf_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 5_000_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());
        purseToken404.transferFrom(owner, owner, tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore);
        assertEq(erc721BalanceAfter, erc721BalanceBefore);        
        assertEq(ownerOfToken, owner);
    }

    ///@dev Test ERC721 transferFrom fails correctly
    function testERC721TransferFrom_failure() public {
        purseToken404.mintERC721();

        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        purseToken404.transferFrom(owner, address(0), ID_ENCODING_PREFIX + 1);

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        purseToken404.transferFrom(owner, user1, ID_ENCODING_PREFIX + 343);
    }

    ///@dev Test ERC721 transferFrom fails correctly
    function testERC721TransferFrom_failure_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        _tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());

        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        purseToken404.transferFrom(owner, address(0), _tokenId);

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        purseToken404.transferFrom(owner, user1, _tokenId);
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is sender, to EOA
    function testERC721SafeTransferFrom1A() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = ID_ENCODING_PREFIX + 343;
        purseToken404.safeTransferFrom(owner, user1, tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);

        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is sender, to EOA
    function testERC721SafeTransferFrom1A_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());
        purseToken404.safeTransferFrom(owner, user1, tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);

        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is sender, to contract
    function testERC721SafeTransferFrom1B() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = ID_ENCODING_PREFIX + 343;
        purseToken404.safeTransferFrom(owner, address(safeERC721Recipient), tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.inactiveBalance(address(safeERC721Recipient)), 0);
        assertEq(purseToken404.activeBalance(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.erc721BalanceOf(address(safeERC721Recipient)), 1);

        assertEq(ownerOfToken, address(safeERC721Recipient));
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is sender, to contract
    function testERC721SafeTransferFrom1B_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //No need approval since operator == sender
        uint256 tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());
        purseToken404.safeTransferFrom(owner, address(safeERC721Recipient), tokenId);

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.inactiveBalance(address(safeERC721Recipient)), 0);
        assertEq(purseToken404.activeBalance(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.erc721BalanceOf(address(safeERC721Recipient)), 1);

        assertEq(ownerOfToken, address(safeERC721Recipient));
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is approved, to EOA
    function testERC721SafeTransferFrom2A() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //Approve an operator to transfer the token
        uint256 tokenId = ID_ENCODING_PREFIX + 343;
        purseToken404.approve(user1, tokenId);

        vm.startPrank(user1);
        purseToken404.safeTransferFrom(owner, user1, tokenId);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);
        
        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is approved, to EOA
    function testERC721SafeTransferFrom2A_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
        purseToken404.mint(user1, 32_000 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //Approve an operator to transfer the token
        uint256 tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());
        purseToken404.approve(user1, tokenId);

        vm.startPrank(user1);
        purseToken404.safeTransferFrom(owner, user1, tokenId);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(user1), UNITS + 32_000 ether);
        assertEq(purseToken404.inactiveBalance(user1), 32_000 ether);
        assertEq(purseToken404.activeBalance(user1), UNITS);
        assertEq(purseToken404.erc721BalanceOf(user1), 1);
        
        assertEq(ownerOfToken, user1);
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is approved, to contract
    function testERC721SafeTransferFrom2B() public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //Approve an operator to transfer the token
        uint256 tokenId = ID_ENCODING_PREFIX + 343;
        purseToken404.approve(user1, tokenId);

        vm.startPrank(user1);
        purseToken404.safeTransferFrom(owner, address(safeERC721Recipient), tokenId);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.inactiveBalance(address(safeERC721Recipient)), 0);
        assertEq(purseToken404.activeBalance(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.erc721BalanceOf(address(safeERC721Recipient)), 1);

        assertEq(ownerOfToken, address(safeERC721Recipient));
    }

    ///@dev Test ERC721 safeTransferFrom updates correctly
    //Regular ERC721 safeTransferFrom where operator is approved, to contract
    function testERC721SafeTransferFrom2B_fuzz(uint256 _tokenId) public {
        purseToken404.mintERC721();

        //Increase inactive balances to non-zero value
        purseToken404.mint(owner, 3_434_343 ether);
    
        uint256 balanceOfBefore = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceBefore = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceBefore = purseToken404.activeBalance(owner);
        uint256 erc721BalanceBefore = purseToken404.erc721BalanceOf(owner);

        //Approve an operator to transfer the token
        uint256 tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());
        purseToken404.approve(user1, tokenId);

        vm.startPrank(user1);
        purseToken404.safeTransferFrom(owner, address(safeERC721Recipient), tokenId);
        vm.stopPrank();

        uint256 balanceOfAfter = purseToken404.balanceOf(owner);
        uint256 inactiveBalanceAfter = purseToken404.inactiveBalance(owner);
        uint256 activeBalanceAfter = purseToken404.activeBalance(owner);
        uint256 erc721BalanceAfter = purseToken404.erc721BalanceOf(owner);

        address ownerOfToken = purseToken404.ownerOf(tokenId);

        assertEq(balanceOfAfter, balanceOfBefore - UNITS);
        assertEq(inactiveBalanceAfter, inactiveBalanceBefore);
        assertEq(activeBalanceAfter, activeBalanceBefore - UNITS);
        assertEq(erc721BalanceAfter, erc721BalanceBefore - 1);

        assertEq(purseToken404.balanceOf(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.inactiveBalance(address(safeERC721Recipient)), 0);
        assertEq(purseToken404.activeBalance(address(safeERC721Recipient)), UNITS);
        assertEq(purseToken404.erc721BalanceOf(address(safeERC721Recipient)), 1);

        assertEq(ownerOfToken, address(safeERC721Recipient));
    }


    ///@dev Test ERC721 safeTransferFrom fails correctly
    function testERC721SafeTransferFrom_failure() public {
        purseToken404.mintERC721();

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC721InvalidReceiver(address)")),
                address(unsafeERC721Recipient)
            )
        );
        purseToken404.safeTransferFrom(owner, address(unsafeERC721Recipient), ID_ENCODING_PREFIX + 1);

        purseToken404.approve(user1, ID_ENCODING_PREFIX + 1);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC721InvalidReceiver(address)")),
                address(unsafeERC721Recipient)
            )
        );
        purseToken404.safeTransferFrom(owner, address(unsafeERC721Recipient), ID_ENCODING_PREFIX + 1);
        vm.stopPrank();
    }

    ///@dev Test ERC721 safeTransferFrom fails correctly
    function testERC721SafeTransferFrom_failure_fuzz(uint256 _tokenId) public {
        _tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());

        purseToken404.mintERC721();

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC721InvalidReceiver(address)")),
                address(unsafeERC721Recipient)
            )
        );
        purseToken404.safeTransferFrom(owner, address(unsafeERC721Recipient), _tokenId);

        purseToken404.approve(user1, _tokenId);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC721InvalidReceiver(address)")),
                address(unsafeERC721Recipient)
            )
        );
        purseToken404.safeTransferFrom(owner, address(unsafeERC721Recipient), _tokenId);
        vm.stopPrank();
    }

    ///@dev Test set base uri updates correctly
    function testSetBaseURI() public {
        string memory uri = "https://www.example.com/";
        purseToken404.setBaseURI(uri);
        assertEq(purseToken404.baseTokenURI(), uri);
    }

    ///@dev Test valid token URI for minted token ids
    function testValidTokenURI_fuzz(uint256 _tokenId) public {
        string memory uri = "https://www.example.com/";
        purseToken404.setBaseURI(uri);

        purseToken404.mintERC721();
        _tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());

        string memory tokenURI = purseToken404.tokenURI(_tokenId);
        string memory expectedURI = string(abi.encodePacked(uri, Strings.toString(_tokenId)));

        assertEq(tokenURI, expectedURI);
    }

    ///@dev Test un-minted token id fails when getting token URI
    function testValidTokenURI_failure1(uint256 _tokenId) public {
        string memory uri = "https://www.example.com/";
        purseToken404.setBaseURI(uri);

        _tokenId = bound(_tokenId, ID_ENCODING_PREFIX + 1, purseToken404.erc721MaxTokenId());

        vm.expectRevert("ERC721Metadata: URI query for nonexistent token");
        string memory tokenURI = purseToken404.tokenURI(_tokenId);
    }

    ///@dev Test un-minted token id fails when getting token URI
    function testValidTokenURI_failure2(uint256 _tokenId) public {
        string memory uri = "https://www.example.com/";
        purseToken404.setBaseURI(uri);

        purseToken404.mintERC721();
        _tokenId = bound(_tokenId, purseToken404.erc721MaxTokenId() + 1, purseToken404.erc721MaxTokenId() + 10000);

        vm.expectRevert("ERC721Metadata: URI query for nonexistent token");
        string memory tokenURI = purseToken404.tokenURI(_tokenId);
    }

    //function testRevokeApproval() public {}

    // //When a sender burns an NFT from a transfer, that token id is stored.
    // //The next minted NFT should be that token id
    // function testTransferAndMintTokenId() public {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {FlapPresaleFactory} from "src/FlapPresaleFactory.sol";
import {FlapPresale} from "src/FlapPresale.sol";
import {FlapTokenFactory} from "src/FlapTokenFactory.sol";
import {FlapTaxTokenV3} from "src/FlapTaxTokenV3.sol";
import {FlapTaxProcessor} from "src/FlapTaxProcessor.sol";
import {IFlapTaxTokenV3} from "src/interfaces/IFlapTaxTokenV3.sol";
import {MockWBNB} from "./FlapTokenFactory.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Full-featured mock router: pair creation + addLiquidityETH for E2E presale flow.
contract MockFullRouter {
    address public immutable factory;
    address public immutable WETH;

    constructor(address _factory, address _weth) {
        factory = _factory;
        WETH = _weth;
    }

    function addLiquidityETH(
        address,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external payable returns (uint256, uint256, uint256) {
        return (amountTokenDesired, msg.value, 1000 ether);
    }
}

contract FlapPresaleFactoryTest is Test {
    FlapTokenFactory public tokenFactory;
    FlapPresaleFactory public presaleFactory;
    MockFullRouter public router;
    MockWBNB public wbnb;
    address public feeReceiver = address(0x7A7);

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function setUp() public {
        wbnb = new MockWBNB();

        // Minimal mock factory for pair creation
        MockPairFactory pairFactory = new MockPairFactory();
        router = new MockFullRouter(address(pairFactory), address(wbnb));

        FlapTaxTokenV3 tokenImpl = new FlapTaxTokenV3(1000 ether, 10000 ether);
        tokenFactory = new FlapTokenFactory(
            address(tokenImpl),
            address(new FlapTaxProcessor()),
            address(router),
            address(wbnb)
        );
        presaleFactory = new FlapPresaleFactory(address(new FlapPresale()));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _createToken(address recipient) internal returns (address) {
        FlapTokenFactory.CreateTokenParams memory params = FlapTokenFactory.CreateTokenParams({
            name: "Test Token",
            symbol: "TEST",
            meta: "ipfs://test",
            buyTax: 500,
            sellTax: 500,
            feeReceiver: feeReceiver,
            dividendContract: address(0),
            liqExpectedOutputAmount: 0,
            taxDuration: 30 days,
            antiFarmerDuration: 1 days
        });
        vm.prank(recipient);
        (address token, ) = tokenFactory.createTaxToken(params);
        return token;
    }

    function _presaleParams(address token)
        internal
        view
        returns (FlapPresale.PresaleInitParams memory)
    {
        return FlapPresale.PresaleInitParams({
            creator: alice, // overridden by factory with msg.sender
            token: token,
            router: address(router),
            hardcap: 10 ether,
            minBuyPerWallet: 0.1 ether,
            maxBuyPerWallet: 5 ether,
            startTime: 0,
            endTime: 0,
            tgePercentage: 2000,
            vestingDuration: 10 days
        });
    }

    function test_CreatePresale_CustodiesSupplyAndOwnership() public {
        address token = _createToken(alice);
        assertEq(FlapTaxTokenV3(token).balanceOf(alice), 1_000_000_000 ether);
        assertEq(FlapTaxTokenV3(token).owner(), alice);

        // Approve factory to pull supply
        vm.startPrank(alice);
        FlapTaxTokenV3(token).approve(address(presaleFactory), 1_000_000_000 ether);
        address presale = presaleFactory.createPresale(_presaleParams(token));
        vm.stopPrank();

        // Full supply custodied into presale; creator then hands over token ownership
        assertEq(FlapTaxTokenV3(token).balanceOf(presale), 1_000_000_000 ether);
        assertEq(FlapTaxTokenV3(token).balanceOf(alice), 0);
        assertEq(FlapTaxTokenV3(token).owner(), alice);
        assertEq(FlapPresale(payable(presale)).creator(), alice);
        assertEq(presaleFactory.presaleOfToken(token), presale);
        assertEq(presaleFactory.totalPresales(), 1);

        // Creator transfers token ownership to the presale
        vm.prank(alice);
        FlapTaxTokenV3(token).transferOwnership(presale);
        assertEq(FlapTaxTokenV3(token).owner(), presale);
    }

    function test_CreatePresale_RevertIfNotTokenOwner() public {
        address token = _createToken(alice);

        vm.prank(bob); // bob doesn't own the token
        vm.expectRevert(
            abi.encodeWithSelector(
                FlapPresaleFactory.NotTokenOwner.selector,
                bob,
                alice
            )
        );
        presaleFactory.createPresale(_presaleParams(token));
    }

    function test_CreatePresale_RevertWithoutApproval() public {
        address token = _createToken(alice);

        vm.prank(alice); // no approve
        vm.expectRevert(); // ERC20 insufficient allowance
        presaleFactory.createPresale(_presaleParams(token));
    }

    function test_CreatePresale_RevertTwiceForSameToken() public {
        address token = _createToken(alice);

        vm.startPrank(alice);
        FlapTaxTokenV3(token).approve(address(presaleFactory), 1_000_000_000 ether);
        presaleFactory.createPresale(_presaleParams(token));

        // Second attempt must fail (no tokens left anyway + already registered)
        vm.expectRevert();
        presaleFactory.createPresale(_presaleParams(token));
        vm.stopPrank();
    }

    function test_EndToEnd_Deposit_Finalize_Claim() public {
        address token = _createToken(alice);

        // Alice creates presale via factory
        vm.startPrank(alice);
        FlapTaxTokenV3(token).approve(address(presaleFactory), 1_000_000_000 ether);
        address presaleAddr = presaleFactory.createPresale(_presaleParams(token));
        vm.stopPrank();
        FlapPresale presale = FlapPresale(payable(presaleAddr));

        // Hand over token ownership so the presale can migrate on finalize
        vm.prank(alice);
        FlapTaxTokenV3(token).transferOwnership(presaleAddr);

        // Bob participates in presale
        vm.prank(bob);
        presale.deposit{value: 2 ether}();

        // Creator finalizes: adds liquidity, burns LP, migrates state
        vm.prank(alice);
        presale.finalizePresale();

        assertEq(uint8(FlapTaxTokenV3(token).state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));
        assertTrue(presale.presaleFinalized());

        // Bob is the only depositor: his 2 BNB = 100% of presale → 200M tokens; TGE 20% = 40M
        assertEq(presale.getClaimableAmount(bob), 40_000_000 ether);

        vm.prank(bob);
        presale.claim();
        assertEq(FlapTaxTokenV3(token).balanceOf(bob), 40_000_000 ether);

        // Warp to full vesting end: remaining 160M claimable
        vm.warp(block.timestamp + 10 days);
        assertEq(presale.getClaimableAmount(bob), 160_000_000 ether);

        vm.prank(bob);
        presale.claim();
        assertEq(FlapTaxTokenV3(token).balanceOf(bob), 200_000_000 ether);
    }
}

contract MockPairFactory {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB)))));
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
    }
}

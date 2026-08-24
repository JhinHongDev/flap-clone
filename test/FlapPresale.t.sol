// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FlapPresale} from "../src/FlapPresale.sol";
import {FlapTaxTokenV3} from "../src/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "../src/interfaces/IFlapTaxTokenV3.sol";
import {IPancakeFactory, IPancakeRouter02} from "../src/Interfaces.sol";
import {ERC20} from "../src/OpenZeppelinDependencies.sol";

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
}

contract MockPancakeRouterPresale {
    address public factory;
    address public WETH;
    address public lastLPReceiver;
    uint256 public lastTokenAmount;
    uint256 public lastETHAmount;

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
        lastTokenAmount = amountTokenDesired;
        lastETHAmount = msg.value;
        lastLPReceiver = to;
        return (amountTokenDesired, msg.value, 1000 ether);
    }
}

contract FlapPresaleTest is Test {
    FlapPresale public presale;
    FlapTaxTokenV3 public token;
    MockWBNB public wbnb;
    MockPancakeRouterPresale public router;

    address public creator = address(0xC1EA7012);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public taxProcessor = address(0x7A7);
    address public blackHole = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        wbnb = new MockWBNB();
        router = new MockPancakeRouterPresale(address(0), address(wbnb));

        // 1. Deploy token implementation & clone
        FlapTaxTokenV3 tokenImpl = new FlapTaxTokenV3(1000 ether, 10000 ether);
        token = FlapTaxTokenV3(Clones.clone(address(tokenImpl)));

        // 2. Deploy presale implementation & clone
        FlapPresale presaleImpl = new FlapPresale();
        presale = FlapPresale(payable(Clones.clone(address(presaleImpl))));

        // 3. Initialize presale
        presale.initialize(
            FlapPresale.PresaleInitParams({
                creator: creator,
                token: address(token),
                router: address(router),
                hardcap: 10 ether,
                minBuyPerWallet: 0.1 ether,
                maxBuyPerWallet: 5 ether,
                startTime: 0,
                endTime: 0,
                tgePercentage: 2000,       // 20% TGE
                vestingDuration: 10 days   // 10 days linear release
            })
        );

        // 4. Initialize token with presale contract as initial recipient of all 1B supply
        address[] memory pools = new address[](1);
        pools[0] = address(0x999); // mock pool address

        token.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "Test Token",
                symbol: "TEST",
                meta: "ipfs://test",
                buyTax: 500,
                sellTax: 500,
                taxProcessor: taxProcessor,
                dividendContract: address(0),
                quoteToken: address(wbnb),
                liqExpectedOutputAmount: 0,
                taxDuration: 30 days,
                pools: pools,
                v2Router: address(router),
                antiFarmerDuration: 1 days
            })
        );

        // Token was minted to this test contract during initialize(); transfer 1B tokens & ownership to presale
        token.transfer(address(presale), 1_000_000_000 ether);
        token.transferOwnership(address(presale));

        // Fund test users
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_Deposit_Success() public {
        vm.prank(alice);
        presale.deposit{value: 2 ether}();

        assertEq(presale.userDeposits(alice), 2 ether);
        assertEq(presale.totalDepositedBNB(), 2 ether);
        assertEq(presale.totalParticipants(), 1);
    }

    function test_Deposit_RevertBelowMinBuy() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlapPresale.BelowMinBuy.selector, 0.05 ether, 0.1 ether));
        presale.deposit{value: 0.05 ether}();
    }

    function test_Deposit_RevertExceedsMaxBuy() public {
        vm.startPrank(alice);
        presale.deposit{value: 3 ether}();

        vm.expectRevert(abi.encodeWithSelector(FlapPresale.ExceedsMaxBuy.selector, 6 ether, 5 ether));
        presale.deposit{value: 3 ether}();
        vm.stopPrank();
    }

    function test_FinalizePresale_And_Liquidity_Burned() public {
        // Alice deposits 3 BNB, Bob deposits 1 BNB (Total 4 BNB)
        vm.prank(alice);
        presale.deposit{value: 3 ether}();

        vm.prank(bob);
        presale.deposit{value: 1 ether}();

        // Creator finalizes presale
        vm.prank(creator);
        presale.finalizePresale();

        assertTrue(presale.presaleFinalized());
        // Verify PancakeRouter received 800M tokens + 4 BNB, sent to BLACK_HOLE
        assertEq(router.lastTokenAmount(), 800_000_000 ether);
        assertEq(router.lastETHAmount(), 4 ether);
        assertEq(router.lastLPReceiver(), blackHole);

        // Verify token state migrated to TaxEnforcedAntiFarmer (state 2)
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));

        // Verify token ownership passed to creator
        assertEq(token.owner(), creator);
    }

    function test_VestingClaim_TGE_And_Linear() public {
        // Alice deposits 4 BNB (100% of presale) -> entitled to 200,000,000 tokens
        vm.prank(alice);
        presale.deposit{value: 4 ether}();

        vm.prank(creator);
        presale.finalizePresale();

        // 1. Immediately after finalization: Alice claims 20% TGE
        // 20% of 200,000,000 = 40,000,000 tokens
        assertEq(presale.getClaimableAmount(alice), 40_000_000 ether);

        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 40_000_000 ether);
        assertEq(presale.getClaimableAmount(alice), 0);

        // 2. Warp 5 days (50% of the 10-day vesting duration)
        // Remaining 160,000,000 * 50% = 80,000,000 tokens unlocked
        vm.warp(block.timestamp + 5 days);
        assertEq(presale.getClaimableAmount(alice), 80_000_000 ether);

        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 120_000_000 ether); // 40M + 80M

        // 3. Warp another 5 days (total 10 days - 100% complete)
        vm.warp(block.timestamp + 5 days);
        assertEq(presale.getClaimableAmount(alice), 80_000_000 ether); // Final 80M

        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 200_000_000 ether); // 100% of 200M presale allocation
        assertEq(presale.getClaimableAmount(alice), 0);
    }
}

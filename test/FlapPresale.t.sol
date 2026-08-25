// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FlapPresale} from "src/FlapPresale.sol";
import {FlapTaxTokenV3} from "src/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/interfaces/IFlapTaxTokenV3.sol";
import {IPancakeFactory, IPancakeRouter02} from "src/interfaces/IPancakeRouter02.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
                userCliff: 7 days,             // 7 days lock before user vesting starts (0 at TGE)
                userVestingDuration: 10 days,  // 10 days linear release after cliff
                creatorCliff: 30 days,         // 30 days lock before creator vesting starts
                creatorVestingDuration: 60 days // 60 days linear release after cliff
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

        // Token was minted to this test contract during initialize(); transfer full custody amount
        // (100% = 1B = 200M liquidity + 500M presale + 300M creator locked) & ownership to presale.
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
        // Verify PancakeRouter received 200M tokens + 4 BNB, sent to BLACK_HOLE
        assertEq(router.lastTokenAmount(), 200_000_000 ether);
        assertEq(router.lastETHAmount(), 4 ether);
        assertEq(router.lastLPReceiver(), blackHole);

        // Verify token state migrated to TaxEnforcedAntiFarmer (state 2)
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));

        // Verify token ownership passed to creator
        assertEq(token.owner(), creator);
    }

    function test_VestingClaim_Cliff_And_Linear() public {
        // Alice deposits 4 BNB (100% of presale) -> entitled to 500,000,000 tokens
        vm.prank(alice);
        presale.deposit{value: 4 ether}();

        vm.prank(creator);
        presale.finalizePresale();

        // 1. Immediately after finalization: Alice has 0 claimable tokens (during 7-day Cliff)
        assertEq(presale.getClaimableAmount(alice), 0);
        assertEq(token.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(FlapPresale.NothingToClaim.selector);
        presale.claim();

        // 2. Warp 3 days (still within Cliff) -> still 0 claimable
        vm.warp(block.timestamp + 3 days);
        assertEq(presale.getClaimableAmount(alice), 0);

        // 3. Warp to end of user Cliff (day 7) -> 0 linear elapsed
        vm.warp(block.timestamp + 4 days);
        assertEq(presale.getClaimableAmount(alice), 0);

        // 4. Warp 5 days into user vesting (50% of the 10-day vesting duration)
        // 50% of 500,000,000 = 250,000,000 tokens unlocked
        vm.warp(block.timestamp + 5 days);
        assertEq(presale.getClaimableAmount(alice), 250_000_000 ether);

        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 250_000_000 ether);
        assertEq(presale.getClaimableAmount(alice), 0);

        // 5. Warp another 5 days (total 10 days vesting complete)
        // Remaining 250,000,000 tokens unlocked
        vm.warp(block.timestamp + 5 days);
        assertEq(presale.getClaimableAmount(alice), 250_000_000 ether);

        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 500_000_000 ether); // 100% of 500M presale allocation
        assertEq(presale.getClaimableAmount(alice), 0);
    }

    function test_CreatorVesting_CliffAndLinear() public {
        vm.prank(alice);
        presale.deposit{value: 4 ether}();

        vm.prank(creator);
        presale.finalizePresale();

        // 1. Immediately after finalize: Creator has 0 claimable tokens during Cliff (30 days)
        assertEq(presale.getClaimableCreatorAmount(), 0);
        assertEq(token.balanceOf(creator), 0);

        vm.prank(creator);
        vm.expectRevert(FlapPresale.NothingToClaim.selector);
        presale.claimCreator();

        // 2. Warp 15 days (still within Cliff) -> still 0 claimable
        vm.warp(block.timestamp + 15 days);
        assertEq(presale.getClaimableCreatorAmount(), 0);

        // 3. Warp to end of Cliff (day 30) -> 0 linear elapsed
        vm.warp(block.timestamp + 15 days);
        assertEq(presale.getClaimableCreatorAmount(), 0);

        // 4. Warp 30 days into creator vesting (50% of 60 days vesting duration)
        // 50% of 300,000,000 = 150,000,000 ether
        vm.warp(block.timestamp + 30 days);
        assertEq(presale.getClaimableCreatorAmount(), 150_000_000 ether);

        vm.prank(creator);
        presale.claimCreator();
        assertEq(token.balanceOf(creator), 150_000_000 ether);
        assertEq(presale.getClaimableCreatorAmount(), 0);

        // 5. Warp remaining 30 days (total 60 days vesting complete)
        // Remaining 150,000,000 ether unlocked
        vm.warp(block.timestamp + 30 days);
        assertEq(presale.getClaimableCreatorAmount(), 150_000_000 ether);

        vm.prank(creator);
        presale.claimCreator();
        assertEq(token.balanceOf(creator), 300_000_000 ether); // Full 300M creator allocation
        assertEq(presale.getClaimableCreatorAmount(), 0);
    }

    function test_CreatorVesting_RevertUnauthorized() public {
        vm.prank(alice);
        presale.deposit{value: 4 ether}();

        vm.prank(creator);
        presale.finalizePresale();

        vm.warp(block.timestamp + 100 days);

        vm.prank(bob);
        vm.expectRevert(FlapPresale.CallerNotAuthorized.selector);
        presale.claimCreator();
    }

    function test_CreatorVesting_RevertBeforeFinalized() public {
        vm.prank(alice);
        presale.deposit{value: 4 ether}();

        vm.prank(creator);
        vm.expectRevert(FlapPresale.PresaleNotFinalized.selector);
        presale.claimCreator();
    }

    function test_CreatorVesting_ZeroDurationImmediateAfterCliff() public {
        // Deploy separate token for this test
        FlapTaxTokenV3 token2 = FlapTaxTokenV3(Clones.clone(address(new FlapTaxTokenV3(1000 ether, 10000 ether))));
        address[] memory pools = new address[](1);
        pools[0] = address(0x999);
        token2.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "Test Token 2",
                symbol: "TEST2",
                meta: "ipfs://test2",
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

        // Deploy a new presale instance with creatorVestingDuration = 0
        FlapPresale zeroVestingPresale = FlapPresale(payable(Clones.clone(address(new FlapPresale()))));
        zeroVestingPresale.initialize(
            FlapPresale.PresaleInitParams({
                creator: creator,
                token: address(token2),
                router: address(router),
                hardcap: 10 ether,
                minBuyPerWallet: 0.1 ether,
                maxBuyPerWallet: 5 ether,
                startTime: 0,
                endTime: 0,
                userCliff: 0,
                userVestingDuration: 0,
                creatorCliff: 10 days,
                creatorVestingDuration: 0 // Unlocks 100% immediately when cliff ends
            })
        );

        token2.transfer(address(zeroVestingPresale), 1_000_000_000 ether);
        token2.transferOwnership(address(zeroVestingPresale));

        vm.prank(alice);
        zeroVestingPresale.deposit{value: 2 ether}();

        vm.prank(creator);
        zeroVestingPresale.finalizePresale();

        // During cliff: 0 claimable
        assertEq(zeroVestingPresale.getClaimableCreatorAmount(), 0);

        // After cliff: 100% (300M) unlocked immediately
        vm.warp(block.timestamp + 10 days);
        assertEq(zeroVestingPresale.getClaimableCreatorAmount(), 300_000_000 ether);

        vm.prank(creator);
        zeroVestingPresale.claimCreator();
        assertEq(token2.balanceOf(creator), 300_000_000 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FlapTaxProcessor} from "../src/FlapTaxProcessor.sol";
import {TaxProcessorInitParams, PackedFeeConfig} from "../src/interfaces/ITaxProcessor.sol";
import {IDividend} from "../src/interfaces/IDividend.sol";
import {ERC20} from "../src/OpenZeppelinDependencies.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract MockRouter {
    address public WETH;

    constructor(address _weth) {
        WETH = _weth;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external {
        // Mock swap: Transfer quoteToken to `to` at 1:1 for simplicity
        address quoteToken = path[1];
        ERC20(quoteToken).transfer(to, amountIn);
    }

    function addLiquidity(
        address,
        address,
        uint256 amountTokenDesired,
        uint256 amountQuoteDesired,
        uint256,
        uint256,
        address,
        uint256
    ) external pure returns (uint256, uint256, uint256) {
        return (amountTokenDesired, amountQuoteDesired, 1000 ether);
    }
}

contract MockDividend is IDividend {
    uint256 public totalDeposited;

    function initialize(address, address, uint256) external {}
    function setShare(address, uint256) external {}
    function deposit(uint256 amount) external returns (bool) {
        totalDeposited += amount;
        return true;
    }
    function distributeDividend(address[] calldata) external returns (uint256) { return 0; }
    function withdrawDividends() external returns (bool) { return true; }
    function withdrawDividendsFor(address) external returns (bool) { return true; }
    function withdrawDividendsFor(address, bool) external returns (bool) { return true; }
    function withdrawableDividends(address) external pure returns (uint256) { return 0; }
    function excludeAddress(address) external {}
    function totalShares() external pure returns (uint256) { return 0; }
    function minimumShareBalance() external pure returns (uint256) { return 0; }
    function withdrawnDividends(address) external pure returns (uint256) { return 0; }
    function emergencyWithdraw(address, uint256, address) external {}
}

contract FlapTaxProcessorTest is Test {
    FlapTaxProcessor public processor;
    MockToken public taxToken;
    MockToken public quoteToken;
    MockRouter public router;
    MockDividend public dividend;

    address public owner = address(this);
    address public marketingWallet = address(0x1111);
    address public blackHole = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        quoteToken = new MockToken("Wrapped BNB", "WBNB");
        taxToken = new MockToken("Flap Tax Token", "FLAP");
        router = new MockRouter(address(quoteToken));
        dividend = new MockDividend();

        FlapTaxProcessor impl = new FlapTaxProcessor();
        processor = FlapTaxProcessor(payable(Clones.clone(address(impl))));

        // Initialize processor with 25% for each channel (total 10000 bps)
        processor.initialize(
            TaxProcessorInitParams({
                quoteToken: address(quoteToken),
                router: address(router),
                feeReceiver: address(0),
                marketAddress: marketingWallet,
                dividendAddress: address(dividend),
                taxToken: address(taxToken),
                feeRate: 0,
                marketBps: 2500,     // 25%
                deflationBps: 2500,  // 25%
                lpBps: 2500,         // 25%
                dividendBps: 2500,   // 25%
                dividendToken: address(quoteToken),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: 500 ether
            })
        );

        // Fund router with quoteTokens for mock swap
        quoteToken.transfer(address(router), 10_000 ether);
    }

    function test_InitialConfiguration() public view {
        PackedFeeConfig memory config = processor.feeConfig();
        assertEq(config.marketBps, 2500);
        assertEq(config.deflationBps, 2500);
        assertEq(config.lpBps, 2500);
        assertEq(config.dividendBps, 2500);
        assertEq(processor.marketAddress(), marketingWallet);
        assertEq(processor.dividendAddress(), address(dividend));
    }

    function test_SetFeeDistribution_Success() public {
        // Change to: 40% Marketing, 20% Burn, 20% Dividend, 20% LP = 10000
        processor.setFeeDistribution(4000, 2000, 2000, 2000);

        PackedFeeConfig memory config = processor.feeConfig();
        assertEq(config.marketBps, 4000);
        assertEq(config.deflationBps, 2000);
        assertEq(config.dividendBps, 2000);
        assertEq(config.lpBps, 2000);
    }

    function test_SetFeeDistribution_RevertIfTotalNot10000() public {
        vm.expectRevert(abi.encodeWithSelector(FlapTaxProcessor.InvalidFeeSplit.selector, 9000));
        processor.setFeeDistribution(3000, 2000, 2000, 2000);
    }

    function test_ProcessTaxTokens_FullCycle() public {
        uint256 taxAmount = 1000 ether;

        // Give taxToken balance and approve processor as the taxToken contract
        taxToken.transfer(address(taxToken), taxAmount);

        vm.startPrank(address(taxToken));
        taxToken.approve(address(processor), taxAmount);
        int8 direction = processor.processTaxTokens(taxAmount);
        vm.stopPrank();

        // Verify Deflation: 25% of 1000 ether = 250 ether sent to blackHole
        assertEq(taxToken.balanceOf(blackHole), 250 ether);

        // Direction was calculated against expected output (500 ether)
        // With mock 1:1 swap on remaining 625 ether -> output (625) > expected (500) -> direction = -1
        assertEq(direction, -1);
    }

    function test_SetReceivers() public {
        address newMarketing = address(0x2222);
        address newDividend = address(0x3333);

        processor.setReceivers(newMarketing, address(0), newDividend);

        assertEq(processor.marketAddress(), newMarketing);
        assertEq(processor.dividendAddress(), newDividend);
    }
}

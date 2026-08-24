// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FlapTaxProcessor} from "src/FlapTaxProcessor.sol";
import {TaxProcessorInitParams, PackedFeeConfig} from "src/interfaces/ITaxProcessor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract MockRouter {
    address public immutable WETH;

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
        // Mock 1:1 swap: transfer quoteToken (path[1]) to `to`
        ERC20(path[1]).transfer(to, amountIn);
    }
}

contract FlapTaxProcessorTest is Test {
    FlapTaxProcessor public processor;
    MockToken public taxToken;
    MockToken public quoteToken;
    MockRouter public router;

    address public owner = address(this);
    address public feeReceiver = address(0x1111);

    function setUp() public {
        quoteToken = new MockToken("Wrapped BNB", "WBNB");
        taxToken = new MockToken("Flap Tax Token", "FLAP");
        router = new MockRouter(address(quoteToken));

        FlapTaxProcessor impl = new FlapTaxProcessor();
        processor = FlapTaxProcessor(payable(Clones.clone(address(impl))));

        processor.initialize(
            TaxProcessorInitParams({
                quoteToken: address(quoteToken),
                router: address(router),
                feeReceiver: feeReceiver,
                marketAddress: address(0),
                dividendAddress: address(0),
                taxToken: address(taxToken),
                feeRate: 0,
                marketBps: 0,
                deflationBps: 0,
                lpBps: 0,
                dividendBps: 0,
                dividendToken: address(0),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: 500 ether
            })
        );

        // Fund router so the mock swap has quote tokens to send out
        quoteToken.transfer(address(router), 10_000 ether);
    }

    function test_InitialConfiguration() public view {
        assertEq(processor.getQuoteToken(), address(quoteToken));
    }

    function test_ProcessTaxTokens_ForwardsAllQuoteToFeeReceiver() public {
        uint256 taxAmount = 1000 ether;

        // Simulate tax collected on the tax token contract (self-held balance)
        taxToken.transfer(address(taxToken), taxAmount);

        vm.startPrank(address(taxToken));
        taxToken.approve(address(processor), taxAmount);
        int8 direction = processor.processTaxTokens(taxAmount);
        vm.stopPrank();

        // Mock swap is 1:1 -> quoteReceived = 1000 ether > 500 ether reference -> direction = -1
        assertEq(direction, -1);
        assertEq(quoteToken.balanceOf(feeReceiver), 1000 ether);
        assertEq(processor.totalQuoteSentToFeeReceiver(), 1000 ether);
    }

    function test_ProcessTaxTokens_ZeroAmountReturnsZeroDirection() public {
        vm.prank(address(taxToken));
        int8 direction = processor.processTaxTokens(0);
        assertEq(direction, 0);
    }

    function test_SetFeeReceiver() public {
        address newReceiver = address(0x2222);
        processor.setFeeReceiver(newReceiver);
        assertEq(processor.feeReceiver(), newReceiver);
    }

    function test_SetLiqExpectedOutputAmount() public {
        processor.setLiqExpectedOutputAmount(1000 ether);
        assertEq(processor.liqExpectedOutputAmount(), 1000 ether);
    }

    function test_OnlyTaxTokenCanProcess() public {
        vm.expectRevert(FlapTaxProcessor.ZeroAddress.selector);
        processor.processTaxTokens(100 ether);
    }

    function test_SetFeeReceiver_RevertZeroAddress() public {
        vm.expectRevert(FlapTaxProcessor.ZeroAddress.selector);
        processor.setFeeReceiver(address(0));
    }

    function test_FeeConfigStubs() public view {
        PackedFeeConfig memory config = processor.feeConfig();
        assertEq(config.marketBps, 0);
        assertEq(processor.marketAddress(), address(0));
        assertEq(processor.dividendAddress(), address(0));
        assertEq(processor.feeQuoteBalance(), 0);
        assertEq(processor.requiresMEVProtection(), false);
    }

    function test_ProcessBondingCurveTax_NotSupported() public {
        vm.expectRevert(FlapTaxProcessor.OperateNotSupported.selector);
        processor.processBondingCurveTax(100 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/FlapTaxTokenV3.sol";
import {FlapTokenFactory} from "src/FlapTokenFactory.sol";
import {FlapTaxProcessor} from "src/FlapTaxProcessor.sol";
import {IFlapTaxTokenV3} from "src/interfaces/IFlapTaxTokenV3.sol";
import {IPancakeFactory, IPancakeRouter02} from "src/interfaces/IPancakeRouter02.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
}

contract MockPancakeFactory is IPancakeFactory {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB, block.timestamp)))));
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
    }

    function feeTo() external view returns (address) { return address(0); }
    function feeToSetter() external view returns (address) { return address(0); }
    function allPairs(uint) external view returns (address) { return address(0); }
    function allPairsLength() external view returns (uint) { return 0; }
    function setFeeTo(address) external {}
    function setFeeToSetter(address) external {}
    function INIT_CODE_PAIR_HASH() external view returns (bytes32) { return bytes32(0); }
}

contract MockPancakeRouter {
    address public factory;
    address public WETH;

    constructor(address _factory, address _weth) {
        factory = _factory;
        WETH = _weth;
    }
}

contract FlapTokenFactoryTest is Test {
    FlapTaxTokenV3 public implementation;
    FlapTokenFactory public factory;
    MockPancakeFactory public pancakeFactory;
    MockPancakeRouter public pancakeRouter;
    MockWBNB public wbnb;

    address public alice = address(0xA11CE);
    address public feeReceiver = address(0x7A7);
    address public taxProcessorImplementation;

    function setUp() public {
        wbnb = new MockWBNB();
        pancakeFactory = new MockPancakeFactory();
        pancakeRouter = new MockPancakeRouter(address(pancakeFactory), address(wbnb));

        // Deploy implementations
        implementation = new FlapTaxTokenV3(1000 ether, 10000 ether);
        taxProcessorImplementation = address(new FlapTaxProcessor());

        // Deploy factory
        factory = new FlapTokenFactory(
            address(implementation),
            taxProcessorImplementation,
            address(pancakeRouter),
            address(wbnb)
        );
    }

    function test_CreateTaxToken() public {
        FlapTokenFactory.CreateTokenParams memory params = _defaultParams();

        vm.prank(alice);
        (address token, address pair) = factory.createTaxToken(params);

        assertTrue(token != address(0));
        assertTrue(pair != address(0));
        assertEq(IFlapTaxTokenV3(token).name(), "Flap Token");
        assertEq(IFlapTaxTokenV3(token).symbol(), "FLAP");
        assertEq(IFlapTaxTokenV3(token).balanceOf(alice), 1e9 ether);
        assertEq(IFlapTaxTokenV3(token).mainPool(), pair);
        assertEq(uint8(IFlapTaxTokenV3(token).state()), uint8(IFlapTaxTokenV3.PoolState.BondingCurve));

        // A dedicated tax processor is auto-deployed and bound to the token
        address taxProcessor = factory.taxProcessorOfToken(token);
        assertTrue(taxProcessor != address(0));
        assertEq(FlapTaxProcessor(payable(taxProcessor)).taxToken(), token);
        assertEq(FlapTaxProcessor(payable(taxProcessor)).feeReceiver(), feeReceiver);
        assertEq(IFlapTaxTokenV3(token).taxProcessor(), taxProcessor);
    }

    function test_CreateTaxToken_RevertIfTaxExceedsLimit() public {
        FlapTokenFactory.CreateTokenParams memory params = _defaultParams();
        params.buyTax = 1001; // > 10% (1000 bps)

        vm.expectRevert(abi.encodeWithSelector(FlapTokenFactory.TaxRateExceedsLimit.selector, 1001));
        factory.createTaxToken(params);
    }

    function test_CreateTaxToken_AcceptsAtExactLimit() public {
        FlapTokenFactory.CreateTokenParams memory params = _defaultParams();
        params.buyTax = 1000;
        params.sellTax = 1000;

        vm.prank(alice);
        (address token, ) = factory.createTaxToken(params);
        assertEq(IFlapTaxTokenV3(token).buyTaxRate(), 1000);
        assertEq(IFlapTaxTokenV3(token).sellTaxRate(), 1000);
    }

    function _defaultParams() internal pure returns (FlapTokenFactory.CreateTokenParams memory) {
        return FlapTokenFactory.CreateTokenParams({
            name: "Flap Token",
            symbol: "FLAP",
            meta: "ipfs://test",
            buyTax: 500,
            sellTax: 500,
            feeReceiver: address(0x7A7),
            dividendContract: address(0),
            liqExpectedOutputAmount: 0,
            taxDuration: 7 days,
            antiFarmerDuration: 1 days
        });
    }
}

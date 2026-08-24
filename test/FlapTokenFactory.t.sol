// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "../src/FlapTaxTokenV3.sol";
import {FlapTokenFactory} from "../src/FlapTokenFactory.sol";
import {IFlapTaxTokenV3} from "../src/interfaces/IFlapTaxTokenV3.sol";
import {IPancakeFactory, IPancakeRouter02} from "../src/Interfaces.sol";
import {ERC20} from "../src/OpenZeppelinDependencies.sol";

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
    address public taxProcessor = address(0x7A7);

    function setUp() public {
        wbnb = new MockWBNB();
        pancakeFactory = new MockPancakeFactory();
        pancakeRouter = new MockPancakeRouter(address(pancakeFactory), address(wbnb));

        // Deploy implementation
        implementation = new FlapTaxTokenV3(1000 ether, 10000 ether);

        // Deploy factory
        factory = new FlapTokenFactory(
            address(implementation),
            address(pancakeRouter),
            address(wbnb)
        );
    }

    function test_CreateTaxToken() public {
        FlapTokenFactory.CreateTokenParams memory params = _defaultParams();

        vm.prank(alice);
        (address token, address pair) = factory.createTaxToken(params, alice);

        assertTrue(token != address(0));
        assertTrue(pair != address(0));
        assertEq(IFlapTaxTokenV3(token).name(), "Flap Token");
        assertEq(IFlapTaxTokenV3(token).symbol(), "FLAP");
        assertEq(IFlapTaxTokenV3(token).balanceOf(alice), 1e9 ether);
        assertEq(IFlapTaxTokenV3(token).mainPool(), pair);
        assertEq(uint8(IFlapTaxTokenV3(token).state()), uint8(IFlapTaxTokenV3.PoolState.BondingCurve));
    }

    function test_CreateTaxToken_RevertIfTaxExceedsLimit() public {
        FlapTokenFactory.CreateTokenParams memory params = _defaultParams();
        params.buyTax = 1001; // > 10% (1000 bps)

        vm.expectRevert(abi.encodeWithSelector(FlapTokenFactory.TaxRateExceedsLimit.selector, 1001));
        factory.createTaxToken(params, alice);
    }

    function test_CreateTaxToken_AcceptsAtExactLimit() public {
        FlapTokenFactory.CreateTokenParams memory params = _defaultParams();
        params.buyTax = 1000;
        params.sellTax = 1000;

        vm.prank(alice);
        (address token, ) = factory.createTaxToken(params, alice);
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
            taxProcessor: address(0x7A7),
            dividendContract: address(0),
            liqExpectedOutputAmount: 0,
            taxDuration: 7 days,
            antiFarmerDuration: 1 days
        });
    }
}

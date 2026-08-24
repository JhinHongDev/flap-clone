// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";

import {FlapTaxTokenV3} from "src/FlapTaxTokenV3.sol";
import {FlapTaxProcessor} from "src/FlapTaxProcessor.sol";
import {FlapTokenFactory} from "src/FlapTokenFactory.sol";
import {FlapPresale} from "src/FlapPresale.sol";
import {FlapPresaleFactory} from "src/FlapPresaleFactory.sol";

/// @title Deploy
/// @notice Deploys the full Flap infrastructure (token/tax-processor/presale implementations
///         plus both factories) to the target chain. Defaults to BSC testnet constants.
/// @dev Usage:
///      export PRIVATE_KEY=0x...
///      export BSCSCAN_API_KEY=<Etherscan V2 API key, BSC chain requires a paid plan>
///      forge script script/Deploy.s.sol:Deploy --rpc-url bsc-testnet --private-key $PRIVATE_KEY --broadcast --verify
///
///      Optional env overrides:
///        - PCS_ROUTER:       PancakeSwap V2 router (default: BSC testnet router)
///        - QUOTE_TOKEN:      quote token (default: BSC testnet WBNB)
///        - MIN_LIQ_THRESHOLD: min liquidation threshold (default: 1000 ether)
///        - START_LIQ_THRESHOLD: starting liquidation threshold (default: 10000 ether)
///      Deployment addresses are written to script/deployments/bsc-testnet.json.
contract Deploy is Script {
    /// @notice BSC testnet PancakeSwap V2 router (used by the legacy contracts).
    address public constant PCS_V2_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    /// @notice BSC testnet WBNB.
    address public constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    function run() external {
        uint256 minLiqThreshold = vm.envOr("MIN_LIQ_THRESHOLD", uint256(1000 ether));
        uint256 startLiqThreshold = vm.envOr("START_LIQ_THRESHOLD", uint256(10000 ether));
        address router = vm.envOr("PCS_ROUTER", PCS_V2_ROUTER);
        address quoteToken = vm.envOr("QUOTE_TOKEN", WBNB);

        vm.startBroadcast();

        // 1. Implementation contracts (EIP-1167 clone targets)
        FlapTaxTokenV3 tokenImpl = new FlapTaxTokenV3(minLiqThreshold, startLiqThreshold);
        FlapTaxProcessor taxProcessorImpl = new FlapTaxProcessor();
        FlapPresale presaleImpl = new FlapPresale();

        // 2. Factories
        FlapTokenFactory tokenFactory = new FlapTokenFactory(
            address(tokenImpl), address(taxProcessorImpl), router, quoteToken
        );
        FlapPresaleFactory presaleFactory = new FlapPresaleFactory(address(presaleImpl));

        vm.stopBroadcast();

        // 3. Log + persist deployment addresses
        console2.log("Deployer: %s", msg.sender);
        console2.log("FlapTaxTokenV3 implementation: %s", address(tokenImpl));
        console2.log("FlapTaxProcessor implementation: %s", address(taxProcessorImpl));
        console2.log("FlapPresale implementation: %s", address(presaleImpl));
        console2.log("FlapTokenFactory: %s", address(tokenFactory));
        console2.log("FlapPresaleFactory: %s", address(presaleFactory));

        string memory json = vm.serializeAddress("deploy", "FlapTaxTokenV3", address(tokenImpl));
        json = vm.serializeAddress("deploy", "FlapTaxProcessor", address(taxProcessorImpl));
        json = vm.serializeAddress("deploy", "FlapPresale", address(presaleImpl));
        json = vm.serializeAddress("deploy", "FlapTokenFactory", address(tokenFactory));
        json = vm.serializeAddress("deploy", "FlapPresaleFactory", address(presaleFactory));
        json = vm.serializeUint("deploy", "chainId", block.chainid);
        vm.writeJson(json, "script/deployments/bsc-testnet.json");
    }
}
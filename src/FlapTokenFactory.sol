// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IFlapTaxTokenV3} from "src/interfaces/IFlapTaxTokenV3.sol";
import {ITaxProcessor, TaxProcessorInitParams} from "src/interfaces/ITaxProcessor.sol";
import {IPancakeFactory, IPancakeRouter02} from "src/interfaces/IPancakeRouter02.sol";

/// @title FlapTokenFactory
/// @notice Factory contract for deploying and initializing FlapTaxTokenV3 minimal proxies on BSC.
/// @dev Uses EIP-1167 minimal proxies for gas-efficient deployment. Each created token also
///      gets its own dedicated FlapTaxProcessor clone, bound 1:1 to the token.
contract FlapTokenFactory is Ownable {
    using Clones for address;
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error TaxRateExceedsLimit(uint16 taxRate);
    error InvalidDuration(uint256 taxDuration, uint256 antiFarmerDuration);
    error PairCreationFailed();

    // --- Events ---
    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed mainPool,
        address taxProcessor,
        string name,
        string symbol,
        uint16 buyTax,
        uint16 sellTax
    );
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event QuoteTokenUpdated(address indexed oldQuoteToken, address indexed newQuoteToken);

    // --- Constants ---
    uint16 public constant MAX_TAX_RATE = 1000; // max tax limit in basis points

    // --- State Variables ---
    /// @notice The immutable FlapTaxTokenV3 implementation contract address.
    address public immutable tokenImplementation;

    /// @notice The immutable FlapTaxProcessor implementation used for per-token clones.
    address public immutable taxProcessorImplementation;

    /// @notice The PancakeSwap V2 router address on BSC.
    address public v2Router;

    /// @notice The quote token address (WBNB).
    address public quoteToken;

    /// @notice List of all deployed token addresses.
    address[] private _allTokens;

    /// @notice Mapping from creator address to array of deployed token addresses.
    mapping(address => address[]) private _tokensByCreator;

    /// @notice Mapping from token address to its dedicated tax processor instance.
    mapping(address => address) public taxProcessorOfToken;

    /// @notice Struct for token creation parameters.
    struct CreateTokenParams {
        string name;
        string symbol;
        string meta;
        uint16 buyTax;
        uint16 sellTax;
        address feeReceiver;
        address dividendContract;
        uint256 liqExpectedOutputAmount;
        uint256 taxDuration;
        uint256 antiFarmerDuration;
    }

    /// @notice Contract constructor.
    /// @param tokenImplementation_ Address of the FlapTaxTokenV3 implementation.
    /// @param taxProcessorImplementation_ Address of the FlapTaxProcessor implementation.
    /// @param v2Router_ Address of the PancakeSwap V2 router.
    /// @param quoteToken_ Address of the quote token (WBNB).
    constructor(
        address tokenImplementation_,
        address taxProcessorImplementation_,
        address v2Router_,
        address quoteToken_
    ) Ownable() {
        if (
            tokenImplementation_ == address(0) || taxProcessorImplementation_ == address(0) || v2Router_ == address(0)
                || quoteToken_ == address(0)
        ) {
            revert ZeroAddress();
        }
        tokenImplementation = tokenImplementation_;
        taxProcessorImplementation = taxProcessorImplementation_;
        v2Router = v2Router_;
        quoteToken = quoteToken_;
    }

    // --- Admin Functions ---

    /// @notice Updates the PancakeSwap V2 router address.
    /// @param newRouter New router address.
    function setV2Router(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(v2Router, newRouter);
        v2Router = newRouter;
    }

    /// @notice Updates the quote token address (WBNB).
    /// @param newQuoteToken New quote token address.
    function setQuoteToken(address newQuoteToken) external onlyOwner {
        if (newQuoteToken == address(0)) revert ZeroAddress();
        emit QuoteTokenUpdated(quoteToken, newQuoteToken);
        quoteToken = newQuoteToken;
    }

    // --- Factory Functions ---

    /// @notice Deploys a new FlapTaxTokenV3 clone (plus a dedicated FlapTaxProcessor clone)
    ///         and initializes both. Caller receives the full 1B supply and token ownership.
    /// @param params Token configuration parameters.
    /// @return tokenAddress The deployed token proxy address.
    /// @return pairAddress The PancakeSwap V2 pair address created for this token.
    function createTaxToken(CreateTokenParams calldata params)
        external
        returns (address tokenAddress, address pairAddress)
    {
        if (params.feeReceiver == address(0)) revert ZeroAddress();
        if (params.buyTax > MAX_TAX_RATE) revert TaxRateExceedsLimit(params.buyTax);
        if (params.sellTax > MAX_TAX_RATE) revert TaxRateExceedsLimit(params.sellTax);
        if (params.taxDuration < params.antiFarmerDuration) {
            revert InvalidDuration(params.taxDuration, params.antiFarmerDuration);
        }

        // 1. Clone implementation proxy
        tokenAddress = tokenImplementation.clone();

        // 2. Resolve / create PancakeSwap pair
        address factory = IPancakeRouter02(v2Router).factory();
        pairAddress = IPancakeFactory(factory).getPair(tokenAddress, quoteToken);
        if (pairAddress == address(0)) {
            pairAddress = IPancakeFactory(factory).createPair(tokenAddress, quoteToken);
            if (pairAddress == address(0)) revert PairCreationFailed();
        }

        // 3. Dedicated tax processor for this token (clone + initialize, bound to tokenAddress)
        address taxProcessor = _createTaxProcessor(tokenAddress, params.feeReceiver, params.liqExpectedOutputAmount);

        // 4. Initialize token and finish setup
        _finalizeToken(tokenAddress, pairAddress, taxProcessor, params);
    }

    // --- Internal ---

    /// @dev Clones and initializes a dedicated FlapTaxProcessor bound to a single token.
    function _createTaxProcessor(address tokenAddress, address feeReceiver, uint256 liqExpectedOutputAmount)
        internal
        returns (address taxProcessor)
    {
        taxProcessor = taxProcessorImplementation.clone();
        ITaxProcessor(taxProcessor).initialize(
            TaxProcessorInitParams({
                quoteToken: quoteToken,
                router: v2Router,
                feeReceiver: feeReceiver,
                marketAddress: address(0),
                dividendAddress: address(0),
                taxToken: tokenAddress,
                feeRate: 0,
                marketBps: 0,
                deflationBps: 0,
                lpBps: 0,
                dividendBps: 0,
                dividendToken: address(0),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: liqExpectedOutputAmount
            })
        );
    }

    /// @dev Initializes the token, transfers supply/ownership, and records tracking.
    function _finalizeToken(
        address tokenAddress,
        address pairAddress,
        address taxProcessor,
        CreateTokenParams calldata params
    ) internal {
        address[] memory pools = new address[](1);
        pools[0] = pairAddress;

        IFlapTaxTokenV3(tokenAddress).initialize(
            IFlapTaxTokenV3.InitParams({
                name: params.name,
                symbol: params.symbol,
                meta: params.meta,
                buyTax: params.buyTax,
                sellTax: params.sellTax,
                taxProcessor: taxProcessor,
                dividendContract: params.dividendContract,
                quoteToken: quoteToken,
                liqExpectedOutputAmount: params.liqExpectedOutputAmount,
                taxDuration: params.taxDuration,
                pools: pools,
                v2Router: v2Router,
                antiFarmerDuration: params.antiFarmerDuration
            })
        );

        // Transfer all minted supply to recipient
        uint256 total = IERC20(tokenAddress).balanceOf(address(this));
        if (total > 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, total);
        }

        // Transfer ownership to recipient
        OwnableUpgradeable(tokenAddress).transferOwnership(msg.sender);

        // Record tracking
        _allTokens.push(tokenAddress);
        _tokensByCreator[msg.sender].push(tokenAddress);
        taxProcessorOfToken[tokenAddress] = taxProcessor;

        emit TokenCreated(
            tokenAddress,
            msg.sender,
            pairAddress,
            taxProcessor,
            params.name,
            params.symbol,
            params.buyTax,
            params.sellTax
        );
    }

    // --- View Functions ---

    /// @notice Returns the total count of deployed tokens.
    function totalTokens() external view returns (uint256) {
        return _allTokens.length;
    }

    /// @notice Returns all deployed tokens.
    function allTokens() external view returns (address[] memory) {
        return _allTokens;
    }

    /// @notice Returns deployed token addresses for a specific creator.
    /// @param creator The address of the creator.
    function getTokensByCreator(address creator) external view returns (address[] memory) {
        return _tokensByCreator[creator];
    }
}

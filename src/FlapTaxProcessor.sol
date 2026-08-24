// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITaxProcessor, PackedFeeConfig, PackedFeeConfigV2, TaxProcessorInitParams} from "src/interfaces/ITaxProcessor.sol";
import {IPancakeRouter02} from "src/interfaces/IPancakeRouter02.sol";

/// @title FlapTaxProcessor
/// @notice Single-channel tax processor for FlapTaxTokenV3 on BSC.
/// @dev Current business flow (modeled on the legacy contract): all collected tax tokens
///      are swapped to the quote token (WBNB) and 100% forwarded to a single `feeReceiver`.
///      No deflation / auto-LP / dividend / commission / converter channels are used — those
///      interface methods are implemented as no-op stubs for interface compatibility and are
///      not exercised by the tax token. The fee strategy will be expanded later if needed.
contract FlapTaxProcessor is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, ITaxProcessor {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error SwapFailed();
    error OperateNotSupported();

    // --- Events ---
    event TaxProcessed(uint256 taxAmount, uint256 quoteReceived, int8 liqThresholdDirection);
    event FeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event LiqExpectedOutputAmountUpdated(uint256 oldAmount, uint256 newAmount);

    // --- State ---
    /// @notice Quote token (WBNB on BSC).
    address private _quoteToken;
    /// @notice The tax token that calls processTaxTokens.
    address private _taxToken;
    /// @notice PancakeSwap V2 router.
    address private _router;
    /// @notice Sole recipient of all swapped tax proceeds.
    address private _feeReceiver;
    /// @notice Reference expected output for threshold direction.
    uint256 private _liqExpectedOutputAmount;
    /// @notice Cumulative quote tokens forwarded to feeReceiver.
    uint256 private _totalQuoteSentToFeeReceiver;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the TaxProcessor instance.
    /// @dev Only quoteToken/router/feeReceiver/taxToken/liqExpectedOutputAmount are used;
    ///      the remaining params exist for interface compatibility and are ignored.
    /// @param params Initialization parameters (full V2/V3 struct).
    function initialize(TaxProcessorInitParams memory params) external override initializer {
        if (
            params.quoteToken == address(0) || params.router == address(0) || params.feeReceiver == address(0)
                || params.taxToken == address(0)
        ) revert ZeroAddress();

        __Ownable_init();
        __ReentrancyGuard_init();

        _quoteToken = params.quoteToken;
        _router = params.router;
        _feeReceiver = params.feeReceiver;
        _taxToken = params.taxToken;
        _liqExpectedOutputAmount = params.liqExpectedOutputAmount;

        // Pre-approve the router to spend the tax token for swaps.
        IERC20(_taxToken).approve(_router, type(uint256).max);
    }

    // --- Core Tax Processing ---

    /// @notice Swaps the full tax amount to quote and forwards 100% to feeReceiver.
    /// @dev Only callable by the tax token. Direction signal: output vs liqExpectedOutputAmount.
    /// @param taxAmount Total tax tokens to process.
    /// @return liqThresholdDirection -1 (above ref), +1 (below ref), 0 (no ref / exact).
    function processTaxTokens(uint256 taxAmount)
        external
        override
        onlyTaxToken
        nonReentrant
        returns (int8 liqThresholdDirection)
    {
        if (taxAmount == 0) return 0;

        // 1. Pull tax tokens
        IERC20(_taxToken).safeTransferFrom(msg.sender, address(this), taxAmount);

        // 2. Swap all tokens to quote token
        uint256 quoteReceived = _swapTokensForQuote(taxAmount);

        // 3. Compute direction signal
        if (_liqExpectedOutputAmount > 0 && quoteReceived > 0) {
            if (quoteReceived > _liqExpectedOutputAmount) {
                liqThresholdDirection = -1; // Price strong -> lower threshold
            } else if (quoteReceived < _liqExpectedOutputAmount) {
                liqThresholdDirection = 1; // Price weak -> raise threshold
            }
        }

        // 4. Forward 100% to the fee receiver
        if (quoteReceived > 0) {
            _totalQuoteSentToFeeReceiver += quoteReceived;
            IERC20(_quoteToken).safeTransfer(_feeReceiver, quoteReceived);
        }

        emit TaxProcessed(taxAmount, quoteReceived, liqThresholdDirection);
    }

    /// @dev Unsupported — no bonding curve / inside market in this project.
    function processBondingCurveTax(uint256) external pure override {
        revert OperateNotSupported();
    }

    /// @dev No-op — single channel forwards immediately during processTaxTokens, nothing accumulates.
    function dispatch() external override {}

    // --- Admin Functions ---

    /// @notice Updates the sole fee receiver.
    /// @param newReceiver New receiver address.
    function setFeeReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert ZeroAddress();
        emit FeeReceiverUpdated(_feeReceiver, newReceiver);
        _feeReceiver = newReceiver;
    }

    /// @notice Updates the liquidation threshold direction reference.
    /// @param newExpectedOutput New reference output in quote wei (0 disables the signal).
    function setLiqExpectedOutputAmount(uint256 newExpectedOutput) external onlyOwner {
        emit LiqExpectedOutputAmountUpdated(_liqExpectedOutputAmount, newExpectedOutput);
        _liqExpectedOutputAmount = newExpectedOutput;
    }

    // --- Internal ---

    /// @dev Swaps tax tokens for quote via the PancakeSwap V2 router.
    function _swapTokensForQuote(uint256 tokenAmount) internal returns (uint256 quoteReceived) {
        address[] memory path = new address[](2);
        path[0] = _taxToken;
        path[1] = _quoteToken;

        uint256 quoteBefore = IERC20(_quoteToken).balanceOf(address(this));

        try IPancakeRouter02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        ) {
            uint256 quoteAfter = IERC20(_quoteToken).balanceOf(address(this));
            quoteReceived = quoteAfter > quoteBefore ? quoteAfter - quoteBefore : 0;
        } catch {
            revert SwapFailed();
        }
    }

    // --- Modifiers ---
    modifier onlyTaxToken() {
        if (msg.sender != _taxToken) revert ZeroAddress();
        _;
    }

    // --- View Functions (ITaxProcessor implementation) ---

    function getQuoteToken() external view override returns (address) { return _quoteToken; }
    function weth() external view override returns (address) { return IPancakeRouter02(_router).WETH(); }
    function flapBlackHole() external pure override returns (address) {
        return 0x000000000000000000000000000000000000dEaD;
    }
    function taxToken() external view override returns (address) { return _taxToken; }
    function router() external view override returns (address) { return _router; }
    function feeReceiver() external view override returns (address) { return _feeReceiver; }
    function marketAddress() external pure override returns (address) { return address(0); }
    function dividendAddress() external pure override returns (address) { return address(0); }
    function commissionReceiver() external pure override returns (address) { return address(0); }
    function converter() external pure override returns (address) { return address(0); }
    function dividendToken() external pure override returns (address) { return address(0); }
    function swapRegistry() external pure override returns (address) { return address(0); }

    function feeQuoteBalance() external pure override returns (uint256) { return 0; }
    function lpQuoteBalance() external pure override returns (uint256) { return 0; }
    function marketQuoteBalance() external pure override returns (uint256) { return 0; }
    function pendingDividendQuoteTokenBalance() external pure override returns (uint256) { return 0; }
    function dividendQuoteBalance() external pure override returns (uint256) { return 0; }
    function dividendTokenBalance() external pure override returns (uint256) { return 0; }
    function commissionQuoteBalance() external pure override returns (uint256) { return 0; }

    function feeConfig() external pure override returns (PackedFeeConfig memory) {
        return PackedFeeConfig(0, 0, 0, 0, 0, false);
    }
    function feeConfigV2() external pure override returns (PackedFeeConfigV2 memory) {
        return PackedFeeConfigV2(0, 0, 0, 0, 0, false, 0, address(0));
    }
    function commissionBps() external pure override returns (uint16) { return 0; }
    function liqExpectedOutputAmount() external view override returns (uint256) { return _liqExpectedOutputAmount; }
    function requiresMEVProtection() external pure override returns (bool) { return false; }

    function totalDividendTokenSent() external pure override returns (uint256) { return 0; }
    function totalQuoteSentToDividend() external pure override returns (uint256) { return 0; }
    function totalQuoteAddedToLiquidity() external pure override returns (uint256) { return 0; }
    function totalTokenAddedToLiquidity() external pure override returns (uint256) { return 0; }
    function totalQuoteSentToMarketing() external pure override returns (uint256) { return 0; }

    /// @notice Cumulative quote tokens forwarded to feeReceiver (single-channel total).
    function totalQuoteSentToFeeReceiver() external view returns (uint256) { return _totalQuoteSentToFeeReceiver; }

    receive() external payable {}
}

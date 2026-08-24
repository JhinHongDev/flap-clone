// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITaxProcessor, PackedFeeConfig, PackedFeeConfigV2, TaxProcessorInitParams} from "./interfaces/ITaxProcessor.sol";
import {IDividend} from "./interfaces/IDividend.sol";
import {IPancakeRouter02} from "./legacy/Interfaces.sol";

/// @title FlapTaxProcessor
/// @notice Dedicated tax processing contract for FlapTaxTokenV3 on BSC.
/// @dev Handles 4-way tax routing: Marketing/Creator, Deflation (Burn), Dividends, and Auto-LP.
///      Proportions are protocol-managed and adjustable by the contract Owner.
contract FlapTaxProcessor is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, ITaxProcessor {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error InvalidFeeSplit(uint256 totalBps);
    error OnlyTaxToken(address caller);
    error SwapFailed();
    error LiquidityFailed();
    error DividendDepositFailed();
    error UnauthorizedConverter(address caller);

    // --- Events ---
    event TaxProcessed(
        uint256 totalTax,
        uint256 burnedAmount,
        uint256 lpTokenAmount,
        uint256 swappedQuoteAmount
    );
    event FeeDistributionUpdated(
        uint16 marketBps,
        uint16 deflationBps,
        uint16 dividendBps,
        uint16 lpBps
    );
    event ReceiversUpdated(
        address indexed marketAddress,
        address indexed feeReceiver,
        address indexed dividendAddress
    );
    event DispatchExecuted(
        uint256 marketSent,
        uint256 dividendSent,
        uint256 feeSent,
        uint256 lpAdded
    );

    // --- Constants ---
    uint256 public constant BPS_DENOMINATOR = 10000;
    address public constant BLACK_HOLE = 0x000000000000000000000000000000000000dEaD;

    // --- Core Addresses ---
    address private _quoteToken;
    address private _taxToken;
    address private _router;
    address private _feeReceiver;
    address private _marketAddress;
    address private _dividendAddress;
    address private _commissionReceiver;
    address private _converter;
    address private _dividendToken;
    address private _swapRegistry;

    // --- Configuration ---
    uint16 private _feeRate;
    uint16 private _marketBps;
    uint16 private _deflationBps;
    uint16 private _lpBps;
    uint16 private _dividendBps;
    uint16 private _commissionBps;
    bool private _isWeth;
    uint256 private _liqExpectedOutputAmount;

    // --- Balances ---
    uint256 private _feeQuoteBalance;
    uint256 private _lpQuoteBalance;
    uint256 private _marketQuoteBalance;
    uint256 private _pendingDividendQuoteBalance;
    uint256 private _dividendTokenBalance;
    uint256 private _commissionQuoteBalance;
    uint256 private _lpPendingTokenBalance;

    // --- Cumulative Totals ---
    uint256 private _totalDividendTokenSent;
    uint256 private _totalQuoteAddedToLiquidity;
    uint256 private _totalTokenAddedToLiquidity;
    uint256 private _totalQuoteSentToMarketing;

    // --- Modifiers ---
    modifier onlyTaxToken() {
        if (msg.sender != _taxToken) revert OnlyTaxToken(msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the TaxProcessor instance.
    /// @param params Initialization parameters struct.
    function initialize(TaxProcessorInitParams memory params) external override initializer {
        if (params.taxToken == address(0) || params.router == address(0) || params.quoteToken == address(0)) {
            revert ZeroAddress();
        }

        uint256 totalBps = uint256(params.marketBps) + params.deflationBps + params.lpBps + params.dividendBps;
        if (totalBps != BPS_DENOMINATOR) {
            revert InvalidFeeSplit(totalBps);
        }

        __Ownable_init();
        __ReentrancyGuard_init();

        _quoteToken = params.quoteToken;
        _taxToken = params.taxToken;
        _router = params.router;
        _feeReceiver = params.feeReceiver;
        _marketAddress = params.marketAddress != address(0) ? params.marketAddress : msg.sender;
        _dividendAddress = params.dividendAddress;
        _commissionReceiver = params.commissionReceiver;
        _converter = params.converter;
        _dividendToken = params.dividendToken;

        _feeRate = params.feeRate;
        _marketBps = params.marketBps;
        _deflationBps = params.deflationBps;
        _lpBps = params.lpBps;
        _dividendBps = params.dividendBps;
        _commissionBps = params.commissionBps;
        _liqExpectedOutputAmount = params.liqExpectedOutputAmount;

        // Auto-detect if quoteToken matches WETH on router
        address wethAddr = IPancakeRouter02(_router).WETH();
        _isWeth = (_quoteToken == wethAddr);

        // Pre-approve router to spend quoteToken and taxToken for swaps/liquidity
        IERC20(_quoteToken).approve(_router, type(uint256).max);
        IERC20(_taxToken).approve(_router, type(uint256).max);
    }

    // --- Core Tax Processing ---

    /// @notice Processes collected tax tokens sent from FlapTaxTokenV3.
    /// @dev Splits tax into Burn, Auto-LP, Marketing, and Dividend channels.
    /// @param taxAmount Total tax tokens to process.
    /// @return liqThresholdDirection Directional indicator (-1, 0, or 1) for liquidation threshold adjustment.
    function processTaxTokens(uint256 taxAmount)
        external
        override
        onlyTaxToken
        nonReentrant
        returns (int8 liqThresholdDirection)
    {
        if (taxAmount == 0) return 0;

        // 1. Pull tax tokens from TaxToken contract
        IERC20(_taxToken).safeTransferFrom(msg.sender, address(this), taxAmount);

        // 2. Channel 1: Deflation (Direct Burn to Black Hole)
        uint256 burnAmount = (taxAmount * _deflationBps) / BPS_DENOMINATOR;
        if (burnAmount > 0) {
            IERC20(_taxToken).safeTransfer(BLACK_HOLE, burnAmount);
        }

        // 3. Channel 2: Auto-LP token allocation
        // Keep half of the LP allocation as tokens, swap the other half to quoteToken
        uint256 totalLpAlloc = (taxAmount * _lpBps) / BPS_DENOMINATOR;
        uint256 lpTokenPortion = totalLpAlloc / 2;
        _lpPendingTokenBalance += lpTokenPortion;

        // 4. Calculate total tokens to swap into Quote Token (WBNB)
        // Tokens to swap = Tax Amount - Burn Amount - LP Token Portion
        uint256 tokensToSwap = taxAmount - burnAmount - lpTokenPortion;
        uint256 quoteReceived = 0;

        if (tokensToSwap > 0) {
            uint256 beforeQuoteBalance = IERC20(_quoteToken).balanceOf(address(this));
            _swapTokensForQuote(tokensToSwap);
            uint256 afterQuoteBalance = IERC20(_quoteToken).balanceOf(address(this));
            quoteReceived = afterQuoteBalance > beforeQuoteBalance ? afterQuoteBalance - beforeQuoteBalance : 0;
        }

        // 5. Calculate directional indicator for liquidation threshold adjustment
        if (_liqExpectedOutputAmount > 0 && quoteReceived > 0) {
            if (quoteReceived > _liqExpectedOutputAmount) {
                liqThresholdDirection = -1; // Price/depth strong -> reduce threshold
            } else if (quoteReceived < _liqExpectedOutputAmount) {
                liqThresholdDirection = 1; // Price/depth weak -> increase threshold
            }
        }

        // 6. Split received quote tokens among Marketing, Dividends, and LP Quote Portion
        if (quoteReceived > 0) {
            uint256 nonBurnBps = BPS_DENOMINATOR - _deflationBps - (_lpBps / 2);
            if (nonBurnBps > 0) {
                // LP Quote share
                uint256 lpQuoteShare = (quoteReceived * (_lpBps / 2)) / nonBurnBps;
                _lpQuoteBalance += lpQuoteShare;

                // Dividend share
                uint256 dividendQuoteShare = (quoteReceived * _dividendBps) / nonBurnBps;
                _pendingDividendQuoteBalance += dividendQuoteShare;

                // Marketing share (remainder to avoid rounding dust loss)
                uint256 marketQuoteShare = quoteReceived > (lpQuoteShare + dividendQuoteShare)
                    ? quoteReceived - lpQuoteShare - dividendQuoteShare
                    : 0;
                _marketQuoteBalance += marketQuoteShare;
            } else {
                _marketQuoteBalance += quoteReceived;
            }
        }

        // 7. Auto-execute dispatch to distribute funds and add LP
        _executeAutoDispatch();

        emit TaxProcessed(taxAmount, burnAmount, lpTokenPortion, quoteReceived);
    }

    /// @notice Accepts bonding curve quote tokens for distribution.
    /// @param quoteAmount Quote token amount received from bonding curve.
    function processBondingCurveTax(uint256 quoteAmount) external override nonReentrant {
        if (quoteAmount == 0) return;
        IERC20(_quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);

        // Distribute according to active ratios
        uint256 totalShares = _marketBps + _dividendBps + _lpBps;
        if (totalShares > 0) {
            _marketQuoteBalance += (quoteAmount * _marketBps) / totalShares;
            _pendingDividendQuoteBalance += (quoteAmount * _dividendBps) / totalShares;
            _lpQuoteBalance += (quoteAmount * _lpBps) / totalShares;
        } else {
            _marketQuoteBalance += quoteAmount;
        }

        _executeAutoDispatch();
    }

    /// @notice Manually triggers dispatch of accumulated balances.
    function dispatch() external override nonReentrant {
        _executeAutoDispatch();
    }

    // --- Internal Operations ---

    /// @dev Swaps exact tax tokens for quote tokens via PancakeRouter.
    function _swapTokensForQuote(uint256 tokenAmount) internal {
        address[] memory path = new address[](2);
        path[0] = _taxToken;
        path[1] = _quoteToken;

        try IPancakeRouter02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        ) {} catch {
            // Log/swallow swap failure to prevent reverting the entire transfer transaction
        }
    }

    /// @dev Internal dispatch routine.
    function _executeAutoDispatch() internal {
        uint256 marketSent = 0;
        uint256 dividendSent = 0;
        uint256 lpAdded = 0;

        // 1. Dispatch Marketing Share
        if (_marketQuoteBalance > 0 && _marketAddress != address(0)) {
            marketSent = _marketQuoteBalance;
            _marketQuoteBalance = 0;
            _totalQuoteSentToMarketing += marketSent;
            IERC20(_quoteToken).safeTransfer(_marketAddress, marketSent);
        }

        // 2. Dispatch Dividend Share
        if (_pendingDividendQuoteBalance > 0 && _dividendAddress != address(0)) {
            dividendSent = _pendingDividendQuoteBalance;
            _pendingDividendQuoteBalance = 0;
            _totalDividendTokenSent += dividendSent;

            IERC20(_quoteToken).approve(_dividendAddress, dividendSent);
            try IDividend(_dividendAddress).deposit(dividendSent) {} catch {
                // If deposit fails, return balance to pending storage
                _pendingDividendQuoteBalance += dividendSent;
                _totalDividendTokenSent -= dividendSent;
            }
        }

        // 3. Auto-Add Liquidity (if both LP token and LP quote balances are available)
        if (_lpPendingTokenBalance > 0 && _lpQuoteBalance > 0) {
            uint256 tokenAmt = _lpPendingTokenBalance;
            uint256 quoteAmt = _lpQuoteBalance;

            _lpPendingTokenBalance = 0;
            _lpQuoteBalance = 0;

            try IPancakeRouter02(_router).addLiquidity(
                _taxToken,
                _quoteToken,
                tokenAmt,
                quoteAmt,
                0,
                0,
                BLACK_HOLE, // Send LP tokens to Black Hole (Locked forever)
                block.timestamp
            ) returns (uint256 amountToken, uint256 amountQuote, uint256 /*liquidity*/) {
                _totalTokenAddedToLiquidity += amountToken;
                _totalQuoteAddedToLiquidity += amountQuote;
                lpAdded = amountQuote;

                // Refund leftover unspent amounts back to pool balances
                if (tokenAmt > amountToken) {
                    _lpPendingTokenBalance = tokenAmt - amountToken;
                }
                if (quoteAmt > amountQuote) {
                    _lpQuoteBalance = quoteAmt - amountQuote;
                }
            } catch {
                // If liquidity addition fails, retain balances for next attempt
                _lpPendingTokenBalance = tokenAmt;
                _lpQuoteBalance = quoteAmt;
            }
        }

        emit DispatchExecuted(marketSent, dividendSent, 0, lpAdded);
    }

    // --- Admin Configuration Functions ---

    /// @notice Updates the 4-way tax split proportions.
    /// @dev Only callable by Owner. Total BPS must equal 10000 (100%).
    /// @param marketBps_ Marketing / Creator share (bps).
    /// @param deflationBps_ Token burn share (bps).
    /// @param dividendBps_ Staking / Holders dividend share (bps).
    /// @param lpBps_ Auto-LP injection share (bps).
    function setFeeDistribution(
        uint16 marketBps_,
        uint16 deflationBps_,
        uint16 dividendBps_,
        uint16 lpBps_
    ) external onlyOwner {
        uint256 total = uint256(marketBps_) + deflationBps_ + dividendBps_ + lpBps_;
        if (total != BPS_DENOMINATOR) revert InvalidFeeSplit(total);

        _marketBps = marketBps_;
        _deflationBps = deflationBps_;
        _dividendBps = dividendBps_;
        _lpBps = lpBps_;

        emit FeeDistributionUpdated(marketBps_, deflationBps_, dividendBps_, lpBps_);
    }

    /// @notice Updates the destination addresses for fee routing.
    /// @param marketAddress_ New marketing receiver address.
    /// @param feeReceiver_ New protocol fee receiver address.
    /// @param dividendAddress_ New dividend contract address.
    function setReceivers(
        address marketAddress_,
        address feeReceiver_,
        address dividendAddress_
    ) external onlyOwner {
        if (marketAddress_ == address(0)) revert ZeroAddress();
        _marketAddress = marketAddress_;
        _feeReceiver = feeReceiver_;
        _dividendAddress = dividendAddress_;

        emit ReceiversUpdated(marketAddress_, feeReceiver_, dividendAddress_);
    }

    /// @notice Updates the liquidation expected output benchmark.
    /// @param newExpectedOutput New reference output amount in quote token wei.
    function setLiqExpectedOutputAmount(uint256 newExpectedOutput) external onlyOwner {
        _liqExpectedOutputAmount = newExpectedOutput;
    }

    // --- View Functions (ITaxProcessor Implementation) ---

    function getQuoteToken() external view override returns (address) { return _quoteToken; }
    function weth() external view override returns (address) { return IPancakeRouter02(_router).WETH(); }
    function flapBlackHole() external pure override returns (address) { return BLACK_HOLE; }
    function taxToken() external view override returns (address) { return _taxToken; }
    function router() external view override returns (address) { return _router; }
    function feeReceiver() external view override returns (address) { return _feeReceiver; }
    function marketAddress() external view override returns (address) { return _marketAddress; }
    function dividendAddress() external view override returns (address) { return _dividendAddress; }
    function commissionReceiver() external view override returns (address) { return _commissionReceiver; }
    function converter() external view override returns (address) { return _converter; }
    function dividendToken() external view override returns (address) { return _dividendToken; }
    function swapRegistry() external view override returns (address) { return _swapRegistry; }

    function feeQuoteBalance() external view override returns (uint256) { return _feeQuoteBalance; }
    function lpQuoteBalance() external view override returns (uint256) { return _lpQuoteBalance; }
    function marketQuoteBalance() external view override returns (uint256) { return _marketQuoteBalance; }
    function pendingDividendQuoteTokenBalance() external view override returns (uint256) { return _pendingDividendQuoteBalance; }
    function dividendQuoteBalance() external view override returns (uint256) { return _pendingDividendQuoteBalance; }
    function dividendTokenBalance() external view override returns (uint256) { return _dividendTokenBalance; }
    function commissionQuoteBalance() external view override returns (uint256) { return _commissionQuoteBalance; }

    function feeConfig() external view override returns (PackedFeeConfig memory) {
        return PackedFeeConfig({
            marketBps: _marketBps,
            deflationBps: _deflationBps,
            lpBps: _lpBps,
            dividendBps: _dividendBps,
            feeRate: _feeRate,
            isWeth: _isWeth
        });
    }

    function feeConfigV2() external view override returns (PackedFeeConfigV2 memory) {
        return PackedFeeConfigV2({
            marketBps: _marketBps,
            deflationBps: _deflationBps,
            lpBps: _lpBps,
            dividendBps: _dividendBps,
            feeRate: _feeRate,
            isWeth: _isWeth,
            commissionBps: _commissionBps,
            dividendToken: _dividendToken
        });
    }

    function commissionBps() external view override returns (uint16) { return _commissionBps; }
    function liqExpectedOutputAmount() external view override returns (uint256) { return _liqExpectedOutputAmount; }
    function requiresMEVProtection() external view override returns (bool) {
        return _dividendToken != address(0) && _dividendToken != _quoteToken && _dividendToken != _taxToken;
    }

    function totalDividendTokenSent() external view override returns (uint256) { return _totalDividendTokenSent; }
    function totalQuoteSentToDividend() external view override returns (uint256) { return _totalDividendTokenSent; }
    function totalQuoteAddedToLiquidity() external view override returns (uint256) { return _totalQuoteAddedToLiquidity; }
    function totalTokenAddedToLiquidity() external view override returns (uint256) { return _totalTokenAddedToLiquidity; }
    function totalQuoteSentToMarketing() external view override returns (uint256) { return _totalQuoteSentToMarketing; }

    receive() external payable {}
}

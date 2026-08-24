// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFlapTaxTokenV3} from "src/interfaces/IFlapTaxTokenV3.sol";
import {IPancakeRouter02} from "src/interfaces/IPancakeRouter02.sol";

/// @title FlapPresale
/// @notice Manages BNB presale subscriptions, PancakeSwap V2 liquidity injection with burned LP,
///         and linear vesting claim schedules for FlapTaxTokenV3 on BSC.
/// @dev Supply split: LIQUIDITY_TOKEN_AMOUNT for liquidity, PRESALE_TOKEN_AMOUNT for presale,
///      and the remainder (TOTAL_SUPPLY - CUSTODY_TOKEN_AMOUNT) held by the creator.
///      Only CUSTODY_TOKEN_AMOUNT is custodied here (see constants).
contract FlapPresale is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error PresaleNotActive();
    error PresaleAlreadyFinalized();
    error PresaleNotFinalized();
    error HardcapExceeded(uint256 requested, uint256 available);
    error BelowMinBuy(uint256 sent, uint256 minBuy);
    error ExceedsMaxBuy(uint256 totalUserBuy, uint256 maxBuy);
    error NoBNBDeposited();
    error InsufficientTokenBalance();
    error TokenOwnershipNotHeld(address currentOwner);
    error ClaimNotAvailable();
    error NothingToClaim();
    error InvalidVestingParams(uint16 tgePercentage);
    error CallerNotAuthorized();

    // --- Events ---
    event PresaleInitialized(
        address indexed token,
        address indexed creator,
        uint256 hardcap,
        uint256 startTime,
        uint256 endTime,
        uint16 tgePercentage,
        uint256 vestingDuration
    );
    event PresaleDeposited(address indexed user, uint256 bnbAmount, uint256 totalUserDeposit);
    event PresaleFinalized(
        uint256 totalRaisedBNB,
        uint256 liquidityTokens,
        uint256 presaleTokens,
        uint256 timestamp
    );
    event TokensClaimed(address indexed user, uint256 amount, uint256 totalClaimed);

    // --- Constants ---
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;       // 10 亿固定总量
    uint256 public constant LIQUIDITY_TOKEN_AMOUNT = 200_000_000 ether; // 加池份额（可调）
    uint256 public constant PRESALE_TOKEN_AMOUNT = 500_000_000 ether;   // 预售份额（可调）
    /// @notice 托管在本合约内的代币总量 = 加池份额 + 预售份额。
    ///        其余部分（TOTAL_SUPPLY - CUSTODY_TOKEN_AMOUNT）由创建者自持，不进入本合约。
    uint256 public constant CUSTODY_TOKEN_AMOUNT = LIQUIDITY_TOKEN_AMOUNT + PRESALE_TOKEN_AMOUNT;
    uint256 public constant BPS_DENOMINATOR = 10000;
    address public constant BLACK_HOLE = 0x000000000000000000000000000000000000dEaD;

    // --- Configuration Struct ---
    struct PresaleInitParams {
        address creator;
        address token;
        address router;
        uint256 hardcap;
        uint256 minBuyPerWallet;
        uint256 maxBuyPerWallet;
        uint256 startTime;
        uint256 endTime;
        uint16 tgePercentage;      // bps (e.g. 2000 = 20% unlocked at TGE)
        uint256 vestingDuration;   // seconds (e.g. 30 days linear release)
    }

    // --- State Variables ---
    address public creator;
    address public token;
    address public router;

    uint256 public hardcap;
    uint256 public minBuyPerWallet;
    uint256 public maxBuyPerWallet;
    uint256 public startTime;
    uint256 public endTime;

    uint16 public tgePercentage;
    uint256 public vestingDuration;

    uint256 public totalDepositedBNB;
    bool public presaleFinalized;
    uint256 public vestingStartTime;

    mapping(address => uint256) public userDeposits;
    mapping(address => uint256) public userClaimed;
    address[] public participants;
    mapping(address => bool) private _isParticipant;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the presale clone with configuration parameters.
    /// @param params Presale configuration struct.
    function initialize(PresaleInitParams calldata params) external initializer {
        if (params.creator == address(0) || params.token == address(0) || params.router == address(0)) {
            revert ZeroAddress();
        }
        if (params.tgePercentage > BPS_DENOMINATOR) {
            revert InvalidVestingParams(params.tgePercentage);
        }

        __Ownable_init();
        __ReentrancyGuard_init();

        creator = params.creator;
        token = params.token;
        router = params.router;

        hardcap = params.hardcap;
        minBuyPerWallet = params.minBuyPerWallet;
        maxBuyPerWallet = params.maxBuyPerWallet;
        startTime = params.startTime;
        endTime = params.endTime;

        tgePercentage = params.tgePercentage;
        vestingDuration = params.vestingDuration;

        emit PresaleInitialized(
            params.token,
            params.creator,
            params.hardcap,
            params.startTime,
            params.endTime,
            params.tgePercentage,
            params.vestingDuration
        );
    }

    // --- User Actions ---

    /// @notice Deposit BNB to subscribe to presale token allocation.
    function deposit() external payable nonReentrant {
        if (presaleFinalized) revert PresaleAlreadyFinalized();
        if (startTime != 0 && block.timestamp < startTime) revert PresaleNotActive();
        if (endTime != 0 && block.timestamp > endTime) revert PresaleNotActive();
        if (msg.value == 0) revert NoBNBDeposited();

        if (minBuyPerWallet > 0 && msg.value < minBuyPerWallet) {
            revert BelowMinBuy(msg.value, minBuyPerWallet);
        }

        uint256 newTotalUserDeposit = userDeposits[msg.sender] + msg.value;
        if (maxBuyPerWallet > 0 && newTotalUserDeposit > maxBuyPerWallet) {
            revert ExceedsMaxBuy(newTotalUserDeposit, maxBuyPerWallet);
        }

        if (hardcap > 0 && (totalDepositedBNB + msg.value > hardcap)) {
            uint256 available = hardcap > totalDepositedBNB ? hardcap - totalDepositedBNB : 0;
            revert HardcapExceeded(msg.value, available);
        }

        userDeposits[msg.sender] = newTotalUserDeposit;
        totalDepositedBNB += msg.value;

        if (!_isParticipant[msg.sender]) {
            _isParticipant[msg.sender] = true;
            participants.push(msg.sender);
        }

        emit PresaleDeposited(msg.sender, msg.value, newTotalUserDeposit);
    }

    /// @notice Claim unlocked tokens according to the linear vesting schedule.
    function claim() external nonReentrant {
        if (!presaleFinalized) revert PresaleNotFinalized();

        uint256 claimable = getClaimableAmount(msg.sender);
        if (claimable == 0) revert NothingToClaim();

        userClaimed[msg.sender] += claimable;
        IERC20(token).safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable, userClaimed[msg.sender]);
    }

    // --- Settlement & Liquidity Injection ---

    /// @notice Finalizes the presale: injects LIQUIDITY_TOKEN_AMOUNT to PancakeSwap, burns LP, and activates trading.
    /// @dev Can be called by the Presale Creator or Protocol Admin.
    function finalizePresale() external nonReentrant {
        if (msg.sender != creator && msg.sender != owner()) {
            revert CallerNotAuthorized();
        }
        if (presaleFinalized) revert PresaleAlreadyFinalized();
        if (totalDepositedBNB == 0) revert NoBNBDeposited();

        uint256 contractTokenBal = IERC20(token).balanceOf(address(this));
        if (contractTokenBal < CUSTODY_TOKEN_AMOUNT) revert InsufficientTokenBalance();

        // Creator must have handed over token ownership so this presale can migrate the state machine
        address tokenOwner = OwnableUpgradeable(token).owner();
        if (tokenOwner != address(this)) revert TokenOwnershipNotHeld(tokenOwner);

        presaleFinalized = true;
        vestingStartTime = block.timestamp;

        // 1. Approve PancakeSwap Router to spend LIQUIDITY_TOKEN_AMOUNT for liquidity
        IERC20(token).approve(router, LIQUIDITY_TOKEN_AMOUNT);

        // 2. Add full BNB raised + LIQUIDITY_TOKEN_AMOUNT to PancakeSwap V2, LP Token sent directly to BLACK_HOLE
        IPancakeRouter02(router).addLiquidityETH{value: totalDepositedBNB}(
            token,
            LIQUIDITY_TOKEN_AMOUNT,
            0,
            0,
            BLACK_HOLE, // LP token is burned forever
            block.timestamp
        );

        // 3. Activate token state machine: startMigration -> finalizeMigration
        IFlapTaxTokenV3(token).startMigration();
        IFlapTaxTokenV3(token).finalizeMigration();

        // 4. Transfer token ownership to creator
        OwnableUpgradeable(token).transferOwnership(creator);

        emit PresaleFinalized(totalDepositedBNB, LIQUIDITY_TOKEN_AMOUNT, PRESALE_TOKEN_AMOUNT, block.timestamp);
    }

    // --- View Functions ---

    /// @notice Computes total token allocation for a user based on BNB contribution.
    /// @param user Address of the participant.
    /// @return Total presale tokens allocated to the user.
    function getUserTotalTokens(address user) public view returns (uint256) {
        if (totalDepositedBNB == 0) return 0;
        return (userDeposits[user] * PRESALE_TOKEN_AMOUNT) / totalDepositedBNB;
    }

    /// @notice Computes currently claimable tokens for a user based on linear vesting formula.
    /// @param user Address of the participant.
    /// @return claimable Amount of tokens available to claim right now.
    function getClaimableAmount(address user) public view returns (uint256 claimable) {
        if (!presaleFinalized) return 0;

        uint256 totalUserTokens = getUserTotalTokens(user);
        if (totalUserTokens == 0) return 0;

        uint256 unlocked;
        uint256 elapsed = block.timestamp > vestingStartTime ? block.timestamp - vestingStartTime : 0;

        if (vestingDuration == 0 || elapsed >= vestingDuration) {
            unlocked = totalUserTokens;
        } else {
            uint256 tgeAmount = (totalUserTokens * tgePercentage) / BPS_DENOMINATOR;
            uint256 remaining = totalUserTokens - tgeAmount;
            uint256 vested = (remaining * elapsed) / vestingDuration;
            unlocked = tgeAmount + vested;
        }

        uint256 alreadyClaimed = userClaimed[user];
        if (unlocked > alreadyClaimed) {
            claimable = unlocked - alreadyClaimed;
        }
    }

    /// @notice Returns full presale summary for a specific user.
    function getUserInfo(address user)
        external
        view
        returns (
            uint256 depositBNB,
            uint256 totalTokens,
            uint256 claimedTokens,
            uint256 claimableTokens
        )
    {
        depositBNB = userDeposits[user];
        totalTokens = getUserTotalTokens(user);
        claimedTokens = userClaimed[user];
        claimableTokens = getClaimableAmount(user);
    }

    /// @notice Returns total number of unique presale participants.
    function totalParticipants() external view returns (uint256) {
        return participants.length;
    }

    receive() external payable {
        // Direct transfer behaves same as deposit()
        if (presaleFinalized) revert PresaleAlreadyFinalized();
        if (startTime != 0 && block.timestamp < startTime) revert PresaleNotActive();
        if (endTime != 0 && block.timestamp > endTime) revert PresaleNotActive();
        if (msg.value == 0) revert NoBNBDeposited();

        if (minBuyPerWallet > 0 && msg.value < minBuyPerWallet) {
            revert BelowMinBuy(msg.value, minBuyPerWallet);
        }

        uint256 newTotalUserDeposit = userDeposits[msg.sender] + msg.value;
        if (maxBuyPerWallet > 0 && newTotalUserDeposit > maxBuyPerWallet) {
            revert ExceedsMaxBuy(newTotalUserDeposit, maxBuyPerWallet);
        }

        if (hardcap > 0 && (totalDepositedBNB + msg.value > hardcap)) {
            uint256 available = hardcap > totalDepositedBNB ? hardcap - totalDepositedBNB : 0;
            revert HardcapExceeded(msg.value, available);
        }

        userDeposits[msg.sender] = newTotalUserDeposit;
        totalDepositedBNB += msg.value;

        if (!_isParticipant[msg.sender]) {
            _isParticipant[msg.sender] = true;
            participants.push(msg.sender);
        }

        emit PresaleDeposited(msg.sender, msg.value, newTotalUserDeposit);
    }
}

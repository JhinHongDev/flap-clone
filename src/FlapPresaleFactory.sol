// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

import {FlapPresale} from "src/FlapPresale.sol";

/// @title FlapPresaleFactory
/// @notice Deploys FlapPresale clones for tokens already created via FlapTokenFactory.
/// @dev Pulls the full 1B token supply and ownership from the caller into the presale contract,
///      so the presale can later inject 80% liquidity and migrate the token state machine.
contract FlapPresaleFactory is Ownable {
    using Clones for address;
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error PresaleAlreadyExists();
    error NotTokenOwner(address caller, address actualOwner);
    error InsufficientTokenBalance(uint256 balance, uint256 required);

    // --- Events ---
    event PresaleCreated(
        address indexed presale,
        address indexed creator,
        address indexed token
    );

    // --- State ---
    /// @notice Immutable FlapPresale implementation address used for cloning.
    address public immutable presaleImplementation;

    /// @notice Fixed total supply that must be custodied into each presale (1B tokens).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @notice All presales created by this factory.
    address[] private _allPresales;

    /// @notice Creator address => list of presale addresses created by them.
    mapping(address => address[]) private _presalesByCreator;

    /// @notice Token address => presale address (zero if no presale).
    mapping(address => address) public presaleOfToken;

    constructor(address presaleImplementation_) Ownable() {
        if (presaleImplementation_ == address(0)) revert ZeroAddress();
        presaleImplementation = presaleImplementation_;
    }

    /// @notice Creates a presale for an existing token owned by the caller.
    /// @dev Caller must hold the full 1B supply, approve this factory to pull it, and own the token.
    /// @param params Presale configuration (token, router, caps, vesting, etc.).
    ///        `params.creator` is overridden with `msg.sender`.
    /// @return presale Address of the newly deployed presale clone.
    function createPresale(FlapPresale.PresaleInitParams calldata params)
        external
        returns (address presale)
    {
        if (params.token == address(0) || params.router == address(0)) revert ZeroAddress();
        if (OwnableUpgradeable(params.token).owner() != msg.sender) {
            revert NotTokenOwner(msg.sender, OwnableUpgradeable(params.token).owner());
        }
        if (presaleOfToken[params.token] != address(0)) revert PresaleAlreadyExists();

        uint256 requiredSupply = TOTAL_SUPPLY;
        uint256 balance = IERC20(params.token).balanceOf(msg.sender);
        if (balance < requiredSupply) {
            revert InsufficientTokenBalance(balance, requiredSupply);
        }

        // 1. Clone the presale implementation
        presale = presaleImplementation.clone();

        // 2. Initialize with the caller as creator
        FlapPresale(payable(presale)).initialize(
            FlapPresale.PresaleInitParams({
                creator: msg.sender,
                token: params.token,
                router: params.router,
                hardcap: params.hardcap,
                minBuyPerWallet: params.minBuyPerWallet,
                maxBuyPerWallet: params.maxBuyPerWallet,
                startTime: params.startTime,
                endTime: params.endTime,
                tgePercentage: params.tgePercentage,
                vestingDuration: params.vestingDuration
            })
        );

        // 3. Custody: pull full supply from caller into presale
        IERC20(params.token).safeTransferFrom(msg.sender, presale, requiredSupply);

        // 4. Record indexes
        _allPresales.push(presale);
        _presalesByCreator[msg.sender].push(presale);
        presaleOfToken[params.token] = presale;

        // NOTE: Token ownership is NOT taken by this factory (avoids custodial trust).
        // The creator must call `token.transferOwnership(presale)` afterwards;
        // `finalizePresale` enforces this by verifying ownership before migration.

        emit PresaleCreated(presale, msg.sender, params.token);
    }

    // --- View Functions ---

    /// @notice Total number of presales created through this factory.
    function totalPresales() external view returns (uint256) {
        return _allPresales.length;
    }

    /// @notice All presale addresses created through this factory.
    function allPresales() external view returns (address[] memory) {
        return _allPresales;
    }

    /// @notice All presales created by a specific creator.
    function getPresalesByCreator(address creator) external view returns (address[] memory) {
        return _presalesByCreator[creator];
    }
}

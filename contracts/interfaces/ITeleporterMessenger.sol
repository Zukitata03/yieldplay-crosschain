// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─── Structs ───────────────────────────────────────────────────────────────────

struct TeleporterFeeInfo {
    address feeTokenAddress;
    uint256 amount;
}

struct TeleporterMessageInput {
    bytes32 destinationBlockchainID;
    address destinationAddress;
    TeleporterFeeInfo feeInfo;
    uint256 requiredGasLimit;
    address[] allowedRelayerAddresses; // empty = any relayer
    bytes message;
}

// ─── Interface ─────────────────────────────────────────────────────────────────

/**
 * @title ITeleporterMessenger
 * @notice Minimal interface for sending cross-chain messages via Avalanche Teleporter.
 *
 * The TeleporterMessenger contract is pre-deployed on every avalanche-cli local subnet
 * and on Avalanche Fuji/Mainnet at the universal address:
 *   0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf
 *
 * Source: https://github.com/ava-labs/teleporter
 */
interface ITeleporterMessenger {
    /**
     * @notice Send a cross-chain message to a contract on another EVM L1.
     * @param messageInput All parameters for the outgoing message.
     * @return bytes32 The unique message ID assigned by Teleporter.
     */
    function sendCrossChainMessage(
        TeleporterMessageInput calldata messageInput
    ) external returns (bytes32);
}

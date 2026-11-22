// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {QueuedTokenRecovery} from "../HyperionTypes.sol";

/// @title Router-owned accidental token recovery
/// @notice Timelocked recovery of accidental, unencumbered ERC20 custody held by the router.
interface ITokenRecoveryManager {
    /// @notice Record the complete fixed recovery proposal and its execution window.
    /// @param id The unique proposal identifier.
    /// @param token The unregistered ERC20 whose accidental custody may be recovered.
    /// @param recipient The fixed recipient authorized by the router admin.
    /// @param amount The exact token base units proposed for recovery.
    /// @param eta The first timestamp when execution is permitted.
    /// @param expiresAt The final timestamp when execution is permitted.
    event TokenRecoveryQueued(
        uint64 indexed id,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint64 eta,
        uint64 expiresAt
    );
    /// @notice Identify a cancelled proposal and the authorized actor who cancelled it.
    /// @param id The cancelled proposal identifier.
    /// @param by The router admin or guardian who cancelled it.
    event TokenRecoveryCancelled(uint64 indexed id, address indexed by);
    /// @notice Confirm the exact recovery asset, recipient and credited amount.
    /// @param id The executed proposal identifier.
    /// @param token The recovered ERC20.
    /// @param recipient The fixed recipient who received the token units.
    /// @param amount The exact recovered token base units.
    event TokenRecovered(uint64 indexed id, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Return the immutable router that holds custody and controls this manager.
    /// @return The immutable router address.
    function ROUTER() external view returns (address);
    /// @notice Return the exact unsettled claim custody reserved for this token.
    /// @param token The ERC20 whose outstanding liability is requested.
    /// @return The exact token base units reserved for unsettled claims.
    function claimLiability(address token) external view returns (uint256);
    /// @notice Reserve newly parked claim custody; only the immutable router may call.
    /// @param token The ERC20 backing the parked claim.
    /// @param amount The exact claim amount to reserve in token base units.
    function recordClaim(address token, uint256 amount) external;
    /// @notice Release liability after exact settlement; only the immutable router may call.
    /// @param token The ERC20 whose claim was settled.
    /// @param amount The exact settled amount to release in token base units.
    function releaseClaim(address token, uint256 amount) external;
    /// @notice Queue an admin-authorized recovery against current unregistered-token surplus.
    /// @param token The unregistered ERC20 to recover.
    /// @param recipient The fixed authorized recipient.
    /// @param amount The exact recovery amount in token base units.
    /// @return id The unique queued proposal identifier.
    function queueTokenRecovery(
        address token,
        address recipient,
        uint256 amount /* token base units */
    )
        external
        returns (uint64 id);
    /// @notice Let the router admin or guardian cancel an unexecuted proposal.
    /// @param id The proposal to cancel.
    function cancelTokenRecovery(uint64 id) external;
    /// @notice Execute a mature admin-authorized proposal after rechecking exact surplus and payout.
    /// @param id The mature proposal to execute.
    function executeTokenRecovery(uint64 id) external;
    /// @notice Return a proposal, including its recipient, amount, window and final state.
    /// @param id The proposal to inspect.
    /// @return The complete fixed proposal and its execution/cancellation state.
    function queuedTokenRecovery(uint64 id) external view returns (QueuedTokenRecovery memory);
    /// @notice Return the number of recovery proposals ever queued.
    /// @return The number of proposals, including executed or cancelled ones.
    function tokenRecoveryCount() external view returns (uint64);
}

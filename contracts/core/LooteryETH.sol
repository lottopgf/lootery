// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Lootery} from "./Lootery.sol";

/// @title Lootery
/// @notice Lotto the ultimate
contract LooteryETH is Lootery {
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialisoooooooor
    function init(
        address owner_,
        string memory name_,
        string memory symbol_,
        uint8 numPicks_,
        uint8 maxBallValue_,
        uint256 gamePeriod_,
        uint256 ticketPrice_,
        uint256 communityFeeBps_,
        address randomiser_
    ) public payable initializer {
        __Lootery_init(
            owner_,
            name_,
            symbol_,
            numPicks_,
            maxBallValue_,
            gamePeriod_,
            ticketPrice_,
            communityFeeBps_,
            randomiser_
        ); // NB: Initialises first game (gameId==0)

        // Seed the jackpot if ETH was transferred as part of the tx
        if (msg.value > type(uint128).max) {
            revert JackpotOverflow(msg.value);
        }
        gameData[0].jackpot = uint128(msg.value);
    }

    function _token() internal pure override returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function _seedJackpot(uint128 amount) internal override {
        // Sanity check that included ETH is the same as the specified amount
        if (amount != msg.value) {
            revert IncorrectPaymentAmount(amount, msg.value);
        }
        // We allow seeding jackpot during purchase phase only, so we don't
        // have to fuck around with accounting
        if (gameState != GameState.Purchase) {
            revert UnexpectedState(gameState, GameState.Purchase);
        }
        gameData[currentGameId].jackpot += uint128(msg.value);
    }

    function _handlePayment(
        Ticket[] calldata tickets
    ) internal override returns (uint256 jackpotShare, uint256 feeShare) {
        uint256 ticketsCount = tickets.length;
        uint256 totalPrice = ticketPrice * ticketsCount;
        if (msg.value != totalPrice) {
            revert IncorrectPaymentAmount(msg.value, totalPrice);
        }
        // Handle fee splits
        feeShare = (totalPrice * communityFeeBps) / 10000;
        jackpotShare = totalPrice - feeShare;
        // Account for fee share income
        accruedFees += feeShare;
        return (jackpotShare, feeShare);
    }

    function _consumeOperationalFunds(uint256 amount) internal override {
        if (accruedFees < amount) {
            revert InsufficientOperationalFunds(accruedFees, amount);
        }
        // With ETH, we just share accrued fees and operational funds
        accruedFees -= amount;
    }

    function _addOperationalFunds(uint256 amount) internal override {
        // With ETH, we just share accrued fees and operational funds
        if (msg.value != amount) {
            revert IncorrectPaymentAmount(msg.value, amount);
        }
        accruedFees += amount;
    }

    /// @notice Transfer via raw call; revert on failure
    /// @param to Address to transfer to
    /// @param value Value (in wei) to transfer
    function _transferOrBust(address to, uint256 value) internal override {
        (bool success, bytes memory retval) = to.call{value: value}("");
        if (!success) {
            revert TransferFailure(to, value, retval);
        }
        emit Transferred(to, value);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.23;

import {FeistelShuffleOptimised} from "./lib/FeistelShuffleOptimised.sol";
import {Sort} from "./lib/Sort.sol";
import {ERC721, ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IRandomiserCallback} from "./interfaces/IRandomiserCallback.sol";
import {IRandomiserGen2} from "./interfaces/IRandomiserGen2.sol";

/// @title Lootery
/// @notice Lotto the ultimate
contract Lootery is IRandomiserCallback, ERC721Enumerable {
    using Sort for uint8[];

    enum GameState {
        /// @notice This is the only state where the jackpot can increase
        Purchase,
        /// @notice Waiting for VRF fulfilment
        DrawPending
    }

    struct RandomnessRequest {
        uint208 requestId;
        uint48 timestamp;
    }

    /// @notice How many numbers must be picked per draw (and per ticket)
    ///     The range of this number should be something like 3-7
    uint256 public immutable numPicks;
    /// @notice Maximum value of a ball (pick) s.t. value \in [1, maxBallValue]
    uint256 public immutable maxBallValue;
    /// @notice How long a game lasts in seconds (before numbers are drawn)
    uint256 public immutable gamePeriod;
    /// @notice Trusted randomiser
    address public immutable randomiser;
    /// @notice Ticket price
    uint256 public immutable ticketPrice;

    /// @notice State of the game
    GameState public gameState;
    /// @notice Monotonically increasing game id
    uint256 public currentGameId;
    /// @notice Current random request details
    RandomnessRequest public randomnessRequest;
    /// @notice Winning pick identities per game, once they've been drawn
    mapping(uint256 gameId => uint256) public winningPickIds;
    /// @notice token id => picks
    mapping(uint256 tokenId => uint8[]) public tokenIdToTicket;
    /// @notice token id => game id
    mapping(uint256 tokenId => uint256) public tokenIdToGameId;
    /// @notice Game id => pick identity => tokenIds
    mapping(uint256 gameId => mapping(uint256 id => uint256[]))
        public tokenByPickIdentity;
    /// @notice Number of tickets sold per game
    mapping(uint256 gameId => uint256) public ticketsSold;
    /// @notice Current jackpot (in wei)
    mapping(uint256 gameId => uint256) public jackpots;

    event TicketPurchased(
        uint256 indexed gameId,
        address indexed whomst,
        uint256 indexed tokenId,
        uint8[] picks
    );
    event GameFinalised(uint256 gameId, uint8[] winningPicks);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 numPicks_,
        uint256 maxBallValue_,
        uint256 ticketPrice_
    ) payable ERC721(name_, symbol_) {
        require(numPicks > 0, "Number of picks must be nonzero");
        numPicks = numPicks_;
        // We exclude 0 as a pickable number
        require(maxBallValue < 255, "Domain too large");
        maxBallValue = maxBallValue_;
        ticketPrice = ticketPrice_;
        // Seed the jackpot
        jackpots[0] += msg.value;
    }

    /// @notice Seed the jackpot
    function seedJackpot() external payable {
        // We allow seeding jackpot during purchase phase only, so we don't
        // have to fuck around with accounting
        require(gameState == GameState.Purchase, "Already drawn");
        jackpots[currentGameId] += msg.value;
    }

    /// @notice Compute the identity of an ordered set of numbers
    function computePickIdentity(
        uint8[] memory picks
    ) internal pure returns (uint256 id) {
        assembly {
            let len := mload(picks)
            let p := add(0x20, picks)
            id := keccak256(p, len)
        }
    }

    /// @notice Purchase a ticket
    /// TODO: Relayable (EIP-712 sig)
    /// TODO: Purchase multiple tickets at once
    /// @param whomst For whomst shall this purchase be made out to?
    /// @param picks Lotto numbers, pick wisely! Picks must be ASCENDINGLY
    ///     ORDERED, with NO DUPLICATES!
    function purchase(address whomst, uint8[] calldata picks) external payable {
        require(msg.value == ticketPrice, "Incorrect payment");
        // TODO: Fee splits
        uint256 gameId = currentGameId;
        jackpots[gameId] += ticketPrice;

        require(picks.length == numPicks, "Invalid number of picks");
        // Assert picks are ascendingly sorted, with no possibility of duplicates
        uint8 lastPick;
        for (uint256 i = 0; i < numPicks; ++i) {
            uint8 pick = picks[i];
            require(pick > lastPick, "Picks not ordered");
            require(pick <= maxBallValue, "Ball outside domain");
            lastPick = pick;
        }
        // Record picked numbers
        uint256 tokenId = totalSupply() + 1;
        tokenIdToTicket[tokenId] = picks;
        ticketsSold[gameId] += 1;
        _safeMint(whomst, tokenId);
        // Account for this pick set
        uint256 id = computePickIdentity(picks);
        tokenByPickIdentity[gameId][id].push(tokenId);
        emit TicketPurchased(gameId, whomst, tokenId, picks);
    }

    /// @notice Draw numbers, picking potential jackpot winners and ending the
    ///     current game. This should be automated by a keeper.
    function draw() external {
        require(gameState == GameState.Purchase, "Game already drawn");
        gameState = GameState.DrawPending;

        RandomnessRequest memory randReq = randomnessRequest;
        require(
            randReq.requestId == 0 ||
                block.timestamp > (randReq.timestamp + 1 hours),
            "Request already inflight"
        );
        uint256 requestId = IRandomiserGen2(randomiser).getRandomNumber(
            address(this),
            500_000,
            6
        );
        require(requestId <= type(uint208).max, "Request id out of range");
        randomnessRequest = RandomnessRequest({
            requestId: uint208(requestId),
            timestamp: uint48(block.timestamp)
        });
    }

    function receiveRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        require(msg.sender == randomiser, "Only callable by randomiser");
        require(gameState == GameState.DrawPending, "Wrong state");
        require(
            randomnessRequest.requestId == requestId,
            "Request id mismatch"
        );
        randomnessRequest = RandomnessRequest({requestId: 0, timestamp: 0});

        require(randomWords.length > 0, "Where da randomness");

        // Pick numbers
        uint8[] memory balls = new uint8[](numPicks);
        for (uint256 i; i < numPicks; ++i) {
            balls[i] = uint8(
                1 +
                    FeistelShuffleOptimised.shuffle(
                        i,
                        maxBallValue,
                        randomWords[0],
                        4
                    )
            );
        }
        balls = balls.sort();
        uint256 gameId = currentGameId++;
        emit GameFinalised(gameId, balls);

        // Record winning pick identity only (constant 32B)
        winningPickIds[gameId] = computePickIdentity(balls);

        // Ready for next game
        gameState = GameState.Purchase;
    }

    /// @notice Claim a share of the jackpot with a winning ticket
    function claimWinnings(uint256 tokenId) external {
        address whomst = _ownerOf(tokenId);
        require(whomst != address(0), "Ticket doesn't exist");
        _burn(tokenId);

        // Check winning balls from game
        uint256 gameId = tokenIdToGameId[tokenId];
        uint256 winningPickId = winningPickIds[gameId];
        uint256 ticketPickId = computePickIdentity(tokenIdToTicket[tokenId]);
        require(winningPickId == ticketPickId, "Not a winning ticket");

        // Determine if the jackpot was won
        uint256 jackpot = jackpots[gameId];
        uint256 numWinners = tokenByPickIdentity[gameId][winningPickId].length;
        uint256 share;
        if (numWinners > 0) {
            // Transfer share of jackpot to ticket holder
            share = jackpot / numWinners;
        } else {
            // No jackpot winners :(
            // Jackpot is shared between all tickets
            share = jackpot / ticketsSold[gameId];
        }
        (bool success, bytes memory data) = payable(whomst).call{value: share}(
            ""
        );
        require(success, string(data));
    }
}
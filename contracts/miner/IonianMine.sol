// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../utils/IDigestHistory.sol";
import "../utils/DigestHistory.sol";
import "../utils/BitMask.sol";
import "../dataFlow/IFlow.sol";
import "../utils/Blake2b.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "hardhat/console.sol";

contract IonianMine {
    uint256 private constant BYTES32_PER_SECTOR = 8;
    uint256 private constant BYTES_PER_SECTOR = BYTES32_PER_SECTOR * 32;
    uint256 private constant SECTORS_PER_PRICING = (8 * (1 << 30)) / 256;
    uint256 private constant SECTORS_PER_CHUNK = 1024;
    uint256 private constant SECTORS_PER_SEAL = 16;
    uint256 private constant SCRATCHPAD_REPEAT = 4;

    uint256 private constant SCRATCHPAD_SEGMENTS =
        SECTORS_PER_CHUNK / SECTORS_PER_SEAL / SCRATCHPAD_REPEAT;
    uint256 private constant HASHES_PER_SEGMENT = 64; //TODO: formula
    uint256 private constant BYTES32_PER_SEAL =
        SECTORS_PER_SEAL * BYTES32_PER_SECTOR;

    uint256 private constant MAX_MINING_LENGTH = (8 * (1 << 40)) / 256;

    bytes32 private constant EMPTY_HASH =
        hex"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

    uint256 private constant DIFFICULTY_ADJUST_PERIOD = 100;
    uint256 private constant TARGET_PERIOD = 100;

    // Settings bit
    uint256 private constant NO_DATA_SEAL = 0x1;
    uint256 private constant NO_DATA_PROOF = 0x2;

    // Options for ionian-mine development
    bool public immutable sealDataEnabled;
    bool public immutable dataProofEnabled;

    IFlow public flow;
    uint256 public lastMinedEpoch = 0;
    uint256 public targetQuality;
    mapping(address => bytes32) public minerIds;

    uint256 public totalMiningTime;
    uint256 public totalSubmission;

    constructor(address _flow, uint256 settings) {
        flow = IFlow(_flow);
        targetQuality = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        sealDataEnabled = (settings & NO_DATA_SEAL == 0);
        dataProofEnabled = (settings & NO_DATA_PROOF == 0);
    }

    struct PoraAnswer {
        bytes32 contextDigest;
        bytes32 nonce;
        bytes32 minerId;
        uint256 startPosition;
        uint256 mineLength;
        uint256 recallPosition;
        uint256 sealOffset;
        bytes32 sealedContextDigest;
        bytes32[BYTES32_PER_SEAL] sealedData;
        bytes32[] merkleProof;
    }

    function submit(PoraAnswer calldata answer) public {
        flow.makeContext();
        MineContext memory context = flow.getContext();
        require(
            context.digest == answer.contextDigest,
            "Inconsistent mining digest"
        );
        require(context.digest != EMPTY_HASH, "Empty digest can not mine");
        require(context.epoch > lastMinedEpoch, "Epoch has been mined");
        lastMinedEpoch = context.epoch;

        // Step 1: basic check for submission
        basicCheck(answer, context);

        // Step 2: check merkle root
        bytes32[BYTES32_PER_SEAL] memory unsealedData;
        if (sealDataEnabled) {
            unsealedData = unseal(answer);
        } else {
            unsealedData = answer.sealedData;
        }
        if (dataProofEnabled) {
            bytes32 flowRoot = recoverMerkleRoot(answer, unsealedData);
            require(flowRoot == context.flowRoot, "Inconsistent merkle root");
        }
        delete unsealedData;

        // Step 3: compute PoRA quality
        bytes32 quality = PoRA(answer);
        require(
            uint256(quality) <= targetQuality,
            "Do not reach target quality"
        );

        // TODO: Step 4: adjust quality
        // _adjustQuality(context);

        // TODO: Step 5: reward fee
    }

    function basicCheck(PoraAnswer calldata answer, MineContext memory context)
        public
        view
    {
        uint256 maxLength = (context.flowLength / SECTORS_PER_CHUNK) *
            SECTORS_PER_CHUNK;

        require(
            answer.startPosition + answer.mineLength <= maxLength,
            "Mining range overflow"
        );
        require(
            answer.mineLength <= MAX_MINING_LENGTH,
            "Mining range too long"
        );

        require(
            answer.startPosition % SECTORS_PER_PRICING == 0,
            "Start position is not aligned"
        );

        uint256 requiredLength = Math.min(maxLength, MAX_MINING_LENGTH);

        require(answer.mineLength >= requiredLength, "Mining range too short");

        EpochRange memory range = flow.getEpochRange(
            answer.sealedContextDigest
        );
        uint256 recallEndPosition = answer.recallPosition + SECTORS_PER_SEAL;
        require(
            range.start < recallEndPosition && range.end >= recallEndPosition,
            "Invalid sealed context digest"
        );
    }

    function PoRA(PoraAnswer calldata answer) public view returns (bytes32) {
        bytes32 minerId = minerIds[msg.sender];
        require(answer.minerId != bytes32(0x0), "Miner ID does not exist");
        require(answer.minerId == minerId, "Miner ID is inconsistent");

        bytes32[5] memory seedInput = [
            minerId,
            answer.nonce,
            answer.contextDigest,
            bytes32(answer.startPosition),
            bytes32(answer.mineLength)
        ];

        bytes32[2] memory blake2bHash = Blake2b.blake2b(seedInput);

        uint256 scratchPadOffset = answer.sealOffset % SCRATCHPAD_SEGMENTS;
        bytes32[BYTES32_PER_SEAL] memory scratchPad;

        for (uint256 i = 0; i < scratchPadOffset; i += 1) {
            for (uint256 j = 0; j < HASHES_PER_SEGMENT; j += 1) {
                blake2bHash = Blake2b.blake2b(blake2bHash);
            }
        }

        for (uint256 i = 0; i < BYTES32_PER_SEAL; i += 2) {
            blake2bHash = Blake2b.blake2b(blake2bHash);
            scratchPad[i] = blake2bHash[0] ^ answer.sealedData[i];
            scratchPad[i + 1] = blake2bHash[1] ^ answer.sealedData[i + 1];
        }

        for (
            uint256 i = scratchPadOffset + 1;
            i < SCRATCHPAD_SEGMENTS;
            i += 1
        ) {
            for (uint256 j = 0; j < HASHES_PER_SEGMENT; j += 1) {
                blake2bHash = Blake2b.blake2b(blake2bHash);
            }
        }

        uint256 chunkOffset = uint256(keccak256(abi.encode(blake2bHash))) %
            (answer.mineLength / SECTORS_PER_CHUNK);

        require(
            answer.recallPosition ==
                answer.startPosition +
                    chunkOffset *
                    SECTORS_PER_CHUNK +
                    answer.sealOffset *
                    SECTORS_PER_SEAL,
            "Incorrect recall position"
        );

        bytes32[2] memory h;
        h[0] = Blake2b.BLAKE2B_INIT_STATE0;
        h[1] = Blake2b.BLAKE2B_INIT_STATE1;

        h = Blake2b.blake2bF(
            h,
            bytes32(answer.sealOffset),
            minerId,
            answer.nonce,
            answer.contextDigest,
            128,
            false
        );
        h = Blake2b.blake2bF(
            h,
            bytes32(answer.startPosition),
            bytes32(answer.mineLength),
            bytes32(0),
            bytes32(0),
            256,
            false
        );
        for (uint256 i = 0; i < BYTES32_PER_SEAL - 4; i += 4) {
            uint256 length;
            unchecked {
                length = 256 + 32 * (i + 4);
            }
            h = Blake2b.blake2bF(
                h,
                scratchPad[i],
                scratchPad[i + 1],
                scratchPad[i + 2],
                scratchPad[i + 3],
                length,
                false
            );
        }
        h = Blake2b.blake2bF(
            h,
            scratchPad[BYTES32_PER_SEAL - 4],
            scratchPad[BYTES32_PER_SEAL - 3],
            scratchPad[BYTES32_PER_SEAL - 2],
            scratchPad[BYTES32_PER_SEAL - 1],
            256 + BYTES32_PER_SEAL * 32,
            true
        );
        delete scratchPad;
        return h[0];
    }

    function unseal(PoraAnswer calldata answer)
        public
        pure
        returns (bytes32[BYTES32_PER_SEAL] memory unsealedData)
    {
        unsealedData[0] =
            answer.sealedData[0] ^
            keccak256(
                abi.encode(
                    answer.minerId,
                    answer.sealedContextDigest,
                    answer.recallPosition
                )
            );
        for (uint256 i = 1; i < BYTES32_PER_SEAL; i += 1) {
            unsealedData[i] =
                answer.sealedData[i] ^
                keccak256(abi.encode(answer.sealedData[i - 1]));
        }
    }

    function recoverMerkleRoot(
        PoraAnswer calldata answer,
        bytes32[BYTES32_PER_SEAL] memory unsealedData
    ) public pure returns (bytes32) {
        // console.log("Compute leaf");
        // Compute leaf of hash
        for (uint256 i = 0; i < BYTES32_PER_SEAL; i += BYTES32_PER_SECTOR) {
            bytes32 x;
            assembly {
                x := keccak256(
                    add(unsealedData, mul(i, 32)),
                    256 /*BYTES_PER_SECTOR*/
                )
            }
            unsealedData[i] = x;
            // console.logBytes32(x);
        }

        for (uint256 i = BYTES32_PER_SECTOR; i < BYTES32_PER_SEAL; i <<= 1) {
            // console.log("i=%d", i);
            for (uint256 j = 0; j < BYTES32_PER_SEAL; j += i << 1) {
                bytes32 left = unsealedData[j];
                bytes32 right = unsealedData[j + i];
                unsealedData[j] = keccak256(abi.encode(left, right));
                // console.logBytes32(unsealedData[j]);
            }
        }
        bytes32 currentHash = unsealedData[0];
        delete unsealedData;

        // console.log("Seal root");
        // console.logBytes32(currentHash);

        uint256 unsealedIndex = answer.recallPosition / SECTORS_PER_SEAL;

        for (uint256 i = 0; i < answer.merkleProof.length; i += 1) {
            bytes32 left;
            bytes32 right;
            if (unsealedIndex % 2 == 0) {
                left = currentHash;
                right = answer.merkleProof[i];
            } else {
                left = answer.merkleProof[i];
                right = currentHash;
            }
            currentHash = keccak256(abi.encode(left, right));
            // console.log("sibling");
            // console.logBytes32(answer.merkleProof[i]);
            // console.log("current");
            // console.logBytes32(currentHash);
            unsealedIndex /= 2;
        }
        return currentHash;
    }

    function _adjustQuality(MineContext memory context) internal {
        uint256 miningTime = block.number - context.mineStart;
        totalMiningTime += miningTime;
        totalSubmission += 1;
        if (totalSubmission == DIFFICULTY_ADJUST_PERIOD) {
            uint256 targetMiningTime = TARGET_PERIOD * totalSubmission;
            (bool overflow, uint256 multiply) = SafeMath.tryMul(
                targetQuality,
                targetMiningTime
            );
            if (overflow) {
                targetQuality = Math.mulDiv(
                    targetQuality,
                    targetMiningTime,
                    totalMiningTime
                );
            } else {
                targetQuality = multiply / totalMiningTime;
            }
            totalMiningTime = 0;
            totalSubmission = 0;
        }
    }
}

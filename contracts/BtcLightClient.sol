pragma solidity 0.6.12;

import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./interface/ILightClient.sol";
import "./interface/ISystemReward.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ICandidateHub.sol";
import "./lib/SafeMath.sol";
import "./System.sol";

contract BtcLightClient is ILightClient, System, IParamSubscriber{
  using SafeMath for uint256;

  // error codes for storeBlockHeader
  int256 public constant ERR_DIFFICULTY = 10010; // difficulty didn't match current difficulty
  int256 public constant ERR_RETARGET = 10020;  // difficulty didn't match retarget
  int256 public constant ERR_NO_PREV_BLOCK = 10030;
  int256 public constant ERR_BLOCK_ALREADY_EXISTS = 10040;
  int256 public constant ERR_MERKLE = 10050;
  int256 public constant ERR_PROOF_OF_WORK = 10090;

  // for verifying Bitcoin difficulty
  uint32 public constant DIFFICULTY_ADJUSTMENT_INTERVAL = 2016; // Bitcoin adjusts every 2 weeks
  uint64 public constant TARGET_TIMESPAN = 14 * 24 * 60 * 60; // 2 weeks
  uint64 public constant TARGET_TIMESPAN_DIV_4 = TARGET_TIMESPAN / 4;
  uint64 public constant TARGET_TIMESPAN_MUL_4 = TARGET_TIMESPAN * 4;
  int256 public constant UNROUNDED_MAX_TARGET = 2**224 - 1; // different from (2**16-1)*2**208 http://bitcoin.stackexchange.com/questions/13803/how-exactly-was-the-original-coefficient-for-difficulty-determined

  bytes public constant INIT_CONSENSUS_STATE_BYTES = hex"000040209acaa5d26d392ace656c2428c991b0a3d3d773845a1300000000000000000000aa8e225b1f3ea6c4b7afd5aa1cecf691a8beaa7fa1e579ce240e4a62b5ac8ecc2141d9618b8c0b170d5c05bb";
  uint32 public constant INIT_CHAIN_HEIGHT = 717696;

  uint256 public highScore;
  bytes32 public heaviestBlock;
  bytes32 public initBlockHash;

  uint256 constant public INIT_REWARD_FOR_SYNC_HEADER = 1e19;
  uint256 public constant CALLER_COMPENSATION_MOLECULE = 50;
  uint256 public constant ROUND_SIZE=100;
  uint256 public constant MAXIMUM_WEIGHT=20;
  uint256 public constant CONFIRM_BLOCK = 6;
  uint256 public constant INIT_ROUND_INTERVAL = 1800;

  uint256 public callerCompensationMolecule;
  uint256 public rewardForSyncHeader;
  uint256 public roundSize;
  uint256 public maximumWeight;
  uint256 public countInRound=0;
  uint256 public collectedRewardForHeaderRelayer=0;
  uint256 public roundInterval;

  address payable[] public headerRelayerAddressRecord;
  mapping(address => uint256) public headerRelayersSubmitCount;
  mapping(address => uint256) public relayerRewardVault;

  struct RoundMinersPower {
    bytes20[] miners;
    mapping(bytes20 => uint256) powerMap;
  }
  mapping(uint256 => RoundMinersPower) roundMinerPowerMap;

  /**
   * key is blockHash, value composites of following elements
   * | header   | reversed | coinbase | score    | height  | ADJUSTMENT Hashes index |
   * | 80 bytes | 4 bytes  | 20 bytes | 16 bytes | 4 bytes | 4 bytes                 |
   * header := version, prevBlock, MerkleRoot, Time, Bits, Nonce
   */
  mapping(bytes32 => bytes) public blockChain;
  mapping(uint32 => bytes32) public adjustmentHashes;
  mapping(bytes32 => address payable) public submitters;

  event initBlock(uint64 initHeight, bytes32 btcHash, address coinbaseAddr);
  event StoreHeaderFailed(bytes32 indexed blockHash, int256 indexed returnCode);
  event StoreHeader(bytes32 indexed blockHash, bytes20 coinbasePkHash, uint32 coinbaseAddrType, int256 indexed height);
  event paramChange(string key, bytes value);
  
  /* solium-disable-next-line */
  constructor() public {}

  function init() external onlyNotInit {
    bytes32 blockHash = doubleShaFlip(INIT_CONSENSUS_STATE_BYTES);
    bytes20 coinbaseAddr;

    highScore = 1;
    uint256 scoreBlock = 1;
    heaviestBlock = blockHash;
    initBlockHash = blockHash;

    bytes memory initBytes = INIT_CONSENSUS_STATE_BYTES;
    uint32 adjustment = INIT_CHAIN_HEIGHT / DIFFICULTY_ADJUSTMENT_INTERVAL;
    adjustmentHashes[adjustment] = blockHash;
    bytes memory nodeBytes = encode(initBytes, coinbaseAddr, scoreBlock, INIT_CHAIN_HEIGHT, adjustment);
    blockChain[blockHash] = nodeBytes;
    rewardForSyncHeader = INIT_REWARD_FOR_SYNC_HEADER;
    callerCompensationMolecule=CALLER_COMPENSATION_MOLECULE;
    roundSize = ROUND_SIZE;
    maximumWeight = MAXIMUM_WEIGHT;
    roundInterval = INIT_ROUND_INTERVAL;
    alreadyInit = true;
  }

  function storeBlockHeader(bytes calldata blockBytes) external onlyRelayer {
    bytes memory headerBytes = slice(blockBytes, 0, 80);
    bytes32 blockHash = doubleShaFlip(headerBytes);
    require(submitters[blockHash] == address(0x0), "can't sync duplicated header");

    (uint32 blockHeight, uint256 scoreBlock, int256 errCode) = checkProofOfWork(headerBytes, blockHash);
    if (errCode != 0) {
        emit StoreHeaderFailed(blockHash, errCode);
        return;
    }

    require(blockHeight + 2160 > getHeight(heaviestBlock), "can't sync header 15 days ago");

    // verify MerkleRoot & pickup coinbase address.
    uint256 length = blockBytes.length + 32;
    bytes memory input = slice(blockBytes, 0, blockBytes.length);
    bytes32[4] memory result;
    bytes20 coinbaseAddr;
    uint32 coinbaseAddrType;
    /* solium-disable-next-line */
    assembly {
      // call validateBtcHeader precompile contract
      // Contract address: 0x64
      if iszero(staticcall(not(0), 0x64, input, length, result, 128)) {
        revert(0, 0)
      }
      coinbaseAddr := mload(add(result, 0))
      coinbaseAddrType := mload(add(result, 0x20))
    }

    uint32 adjustment = blockHeight / DIFFICULTY_ADJUSTMENT_INTERVAL;
    // save
    blockChain[blockHash] = encode(headerBytes, coinbaseAddr, scoreBlock, blockHeight, adjustment);
    if (blockHeight % DIFFICULTY_ADJUSTMENT_INTERVAL == 0) {
      adjustmentHashes[adjustment] = blockHash;
    }
    submitters[blockHash] = msg.sender;

    collectedRewardForHeaderRelayer = collectedRewardForHeaderRelayer.add(rewardForSyncHeader);
    if (headerRelayersSubmitCount[msg.sender]==0) {
      headerRelayerAddressRecord.push(msg.sender);
    }
    headerRelayersSubmitCount[msg.sender]++;
    if (++countInRound >= roundSize) {
      uint256 callerHeaderReward = distributeRelayerReward();
      relayerRewardVault[msg.sender] = relayerRewardVault[msg.sender].add(callerHeaderReward);
      countInRound = 0;
    }

    // equality allows block with same score to become an (alternate) Tip, so
    // that when an (existing) Tip becomes stale, the chain can continue with
    // the alternate Tip
    if (scoreBlock >= highScore) {
      if (blockHeight > getHeight(heaviestBlock)) {
        addMinerPower(blockHash);
      }
      heaviestBlock = blockHash;
      highScore = scoreBlock;
    }

    emit StoreHeader(blockHash, coinbaseAddr, coinbaseAddrType, blockHeight);
  }

  function addMinerPower(bytes32 preHash) internal {
    for(uint256 i = 0; i < CONFIRM_BLOCK; ++i){
      if (preHash == initBlockHash) return;
      preHash = getPrevHash(preHash);
    }
    uint256 roundTimeTag = getTimestamp(preHash) / roundInterval;
    bytes20 miner = getCoinbase(preHash);
    RoundMinersPower storage r = roundMinerPowerMap[roundTimeTag];
    uint256 power = r.powerMap[miner];
    if (power == 0) r.miners.push(miner);
    r.powerMap[miner] = power + 1;
  }

  function claimRelayerReward(address relayerAddr) external {
     uint256 reward = relayerRewardVault[relayerAddr];
     require(reward > 0, "no relayer reward");
     relayerRewardVault[relayerAddr] = 0;
     address payable recipient = address(uint160(relayerAddr));
     ISystemReward(SYSTEM_REWARD_ADDR).claimRewards(recipient, reward);
  }

  function distributeRelayerReward() internal returns (uint256) {
    uint256 totalReward = collectedRewardForHeaderRelayer;

    uint256 totalWeight=0;
    address payable[] memory relayers = headerRelayerAddressRecord;
    uint256[] memory relayerWeight = new uint256[](relayers.length);
    for (uint256 index = 0; index < relayers.length; index++) {
      address relayer = relayers[index];
      uint256 weight = calculateRelayerWeight(headerRelayersSubmitCount[relayer]);
      relayerWeight[index] = weight;
      totalWeight = totalWeight.add(weight);
    }

    uint256 callerReward = totalReward.mul(callerCompensationMolecule).div(10000);
    totalReward = totalReward.sub(callerReward);
    uint256 remainReward = totalReward;
    for (uint256 index = 1; index < relayers.length; index++) {
      uint256 reward = relayerWeight[index].mul(totalReward).div(totalWeight);
      relayerRewardVault[relayers[index]] = relayerRewardVault[relayers[index]].add(reward);
      remainReward = remainReward.sub(reward);
    }
    relayerRewardVault[relayers[0]] = relayerRewardVault[relayers[0]].add(remainReward);

    collectedRewardForHeaderRelayer = 0;
    for (uint256 index = 0; index < relayers.length; index++) {
      delete headerRelayersSubmitCount[relayers[index]];
    }
    delete headerRelayerAddressRecord;
    return callerReward;
  }

  function calculateRelayerWeight(uint256 count) public view returns(uint256) {
    if (count <= maximumWeight) {
      return count;
    } else if (maximumWeight < count && count <= 2*maximumWeight) {
      return maximumWeight;
    } else if (2*maximumWeight < count && count <= (2*maximumWeight + 3*maximumWeight/4)) {
      return 3*maximumWeight - count;
    } else {
      return count/4;
    }
  }
  
  function slice(bytes memory input, uint256 start, uint256 end) internal pure returns (bytes memory _output) {
    uint256 length = end - start;
    _output = new bytes(length);
    uint256 src = Memory.dataPtr(input);
    uint256 dest;
    assembly {
      dest := add(add(_output, 0x20), start)
    }
    Memory.copy(src, dest, length);
    return _output;
  }
  
  function encode(bytes memory headerBytes, bytes20 coinbaseAddr, uint256 scoreBlock,
      uint32 blockHeight, uint32 adjustment) internal pure returns (bytes memory nodeBytes) {
    nodeBytes = new bytes(128);
    uint256 coinbaseValue = uint256(uint160(coinbaseAddr)) << 96;
    uint256 v = (scoreBlock << (128)) + (uint256(blockHeight) << (96)) + (uint256(adjustment) << 64);

    assembly {
        // copy header
        let mc := add(nodeBytes, 0x20)
        let end := add(mc, 80)
        for {
        // The multiplication in the next line has the same exact purpose
        // as the one above.
            let cc := add(headerBytes, 0x20)
        } lt(mc, end) {
            mc := add(mc, 0x20)
            cc := add(cc, 0x20)
        } {
            mstore(mc, mload(cc))
        }
        // fill reserved bytes
        mstore(end, 0)
        // copy coinbase
        mc := add(end, 4)
        mstore(mc, coinbaseValue)
        // store score, height, adjustment index
        mc := add(mc, 20)
        mstore(mc, v)
    }
    return nodeBytes;
  }
  
  function checkProofOfWork(bytes memory headerBytes, bytes32 blockHash) internal view returns (
      uint32 blockHeight, uint256 scoreBlock, int256 errCode) {
    bytes32 hashPrevBlock = flip32Bytes(bytes32(loadInt256(36, headerBytes))); // 4 is offset for hashPrevBlock
    
    uint256 scorePrevBlock = getScore(hashPrevBlock);
    if (scorePrevBlock == 0) {
        return (blockHeight, scoreBlock, ERR_NO_PREV_BLOCK);
    }
    scoreBlock = getScore(blockHash);
    if (scoreBlock != 0) {
        // block already stored/exists
        return (blockHeight, scoreBlock, ERR_BLOCK_ALREADY_EXISTS);
    }
    uint32 bits = flip4Bytes(uint32(loadInt256(104, headerBytes) >> 224)); // 72 is offset for 'bits'
    uint256 target = targetFromBits(bits);

    // Check proof of work matches claimed amount
    // we do not do other validation (eg timestamp) to save gas
    if (blockHash == 0 || uint256(blockHash) >= target) {
      return (blockHeight, scoreBlock, ERR_PROOF_OF_WORK);
    }
    blockHeight = 1 + getHeight(hashPrevBlock);
    uint32 prevBits = getBits(hashPrevBlock);
    if (blockHeight % DIFFICULTY_ADJUSTMENT_INTERVAL != 0) {// since blockHeight is 1 more than blockNumber; OR clause is special case for 1st header
      /* we need to check prevBits isn't 0 otherwise the 1st header
       * will always be rejected (since prevBits doesn't exist for the initial parent)
       * This allows blocks with arbitrary difficulty from being added to
       * the initial parent, but as these forks will have lower score than
       * the main chain, they will not have impact.
       */
      if (bits != prevBits && prevBits != 0) {
        return (blockHeight, scoreBlock, ERR_DIFFICULTY);
      }
    } else {
      uint256 prevTarget = targetFromBits(prevBits);
      uint64 prevTime = getTimestamp(hashPrevBlock);

      // (blockHeight - DIFFICULTY_ADJUSTMENT_INTERVAL) is same as [getHeight(hashPrevBlock) - (DIFFICULTY_ADJUSTMENT_INTERVAL - 1)]
      bytes32 startBlock = getAdjustmentHash(hashPrevBlock);
      uint64 startTime = getTimestamp(startBlock);

      // compute new bits
      uint64 actualTimespan = prevTime - startTime;
      if (actualTimespan < TARGET_TIMESPAN_DIV_4) {
          actualTimespan = TARGET_TIMESPAN_DIV_4;
      }
      if (actualTimespan > TARGET_TIMESPAN_MUL_4) {
          actualTimespan = TARGET_TIMESPAN_MUL_4;
      }
      uint256 newTarget;
      assembly{
        newTarget := div(mul(actualTimespan, prevTarget), TARGET_TIMESPAN)
      }
      uint32 newBits = toCompactBits(newTarget);
      if (bits != newBits && newBits != 0) { // newBits != 0 to allow first header
        return (blockHeight, scoreBlock, ERR_RETARGET);
      }
    }
    
    // # https://en.bitcoin.it/wiki/Difficulty
    uint256 blockDifficulty = 0x00000000FFFF0000000000000000000000000000000000000000000000000000 / target;
    scoreBlock = scorePrevBlock + blockDifficulty;
    return (blockHeight, scoreBlock, 0);
  } 

  // reverse 32 bytes given by value
  function flip32Bytes(bytes32 input) internal pure returns (bytes32 v) {
    v = input;

    // swap bytes
    v = ((v & 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00) >> 8) |
        ((v & 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF) << 8);

    // swap 2-byte long pairs
    v = ((v & 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000) >> 16) |
        ((v & 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF) << 16);

    // swap 4-byte long pairs
    v = ((v & 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000) >> 32) |
        ((v & 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF) << 32);

    // swap 8-byte long pairs
    v = ((v & 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000) >> 64) |
        ((v & 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF) << 64);

    // swap 16-byte long pairs
    v = (v >> 128) | (v << 128);
  }
  
  // reverse 4 bytes given by value
  function flip4Bytes(uint32 input) internal pure returns (uint32 v) {
    v = input;

    // swap bytes
    v = ((v & 0xFF00FF00) >> 8) | ((v & 0x00FF00FF) << 8);

    // swap 2-byte long pairs
    v = (v >> 16) | (v << 16);
  }
  
  // Bitcoin-way of hashing
  function doubleShaFlip(bytes memory dataBytes) internal pure returns (bytes32) {
    return flip32Bytes(sha256(abi.encodePacked(sha256(dataBytes))));
  }
  
  // get the 'timestamp' field from a Bitcoin blockheader
  function getTimestamp(bytes32 hash) public view returns (uint64) {
    return flip4Bytes(uint32(loadInt256(100, blockChain[hash])>>224));
  }
  
  // get the 'bits' field from a Bitcoin blockheader
  function getBits(bytes32 hash) public view returns (uint32) {
    return flip4Bytes(uint32(loadInt256(104, blockChain[hash])>>224));
  }
  
  // Get the score of block
  function getScore(bytes32 hash) public view returns (uint256) {
    return (loadInt256(136, blockChain[hash]) >> 128);
  }

  function getPrevHash(bytes32 hash) public view returns (bytes32) {
    return flip32Bytes(bytes32(loadInt256(36, blockChain[hash])));
  }

  function getHeight(bytes32 hash) public view returns (uint32) {
    return uint32(loadInt256(152, blockChain[hash]) >> 224);
  }
  
  function getAdjustmentIndex(bytes32 hash) public view returns (uint32) {
    return uint32(loadInt256(156, blockChain[hash]) >> 224);
  }
  
  function getAdjustmentHash(bytes32 hash) public view returns (bytes32) {
    uint32 index = uint32(loadInt256(156, blockChain[hash]) >> 224);
    return adjustmentHashes[index];
  }

  function getCoinbase(bytes32 hash) public view returns (bytes20) {
    return bytes20(uint160(loadInt256(116, blockChain[hash]) >> 96));
  }

  // Bitcoin-way of computing the target from the 'bits' field of a blockheader
  // based on http://www.righto.com/2014/02/bitcoin-mining-hard-way-algorithms.html#ref3
  function targetFromBits(uint32 bits) internal pure returns (uint256 target) {
    int nSize = bits >> 24;
    uint32 nWord = bits & 0x00ffffff;
    if (nSize <= 3) {
        nWord >>= 8 * (3 - nSize);
        target = nWord;
    } else {
        target = nWord;
        target <<= 8 * (nSize - 3);
    }

    return (target);
  }

  // Convert uint256 to compact encoding
  // based on https://github.com/petertodd/python-bitcoinlib/blob/2a5dda45b557515fb12a0a18e5dd48d2f5cd13c2/bitcoin/core/serialize.py
  function toCompactBits(uint256 val) internal pure returns (uint32) {
    // calc bit length of val
    uint32 length = 0;
    uint256 int_value = val;
    while (int_value != 0) {
        int_value >>= 1;
        length ++;
    }
    uint32 nbytes = (length + 7) >> 3;
    uint32 compact = 0;
    if (nbytes <= 3) {
        compact = uint32(val & 0xFFFFFF) << (8 * (3 - nbytes));
    } else {
        compact = uint32(val >> (8 * (nbytes - 3)));
        compact = compact & 0xFFFFFF;
    }

    // If the sign bit (0x00800000) is set, divide the mantissa by 256 and
    // increase the exponent to get an encoding without it set.
    if ((compact & 0x00800000) != 0) {
        compact = compact >> 8;
        nbytes ++;
    }
    return (compact | (nbytes << 24));
  }

  function loadInt256(uint256 _offst, bytes memory _input) internal pure returns (uint256 _output) {
    assembly {
        _output := mload(add(_input, _offst))
    }
  }

  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov{
    if (Memory.compareStrings(key,"rewardForSyncHeader")) {
      require(value.length == 32, "length of rewardForSyncHeader mismatch");
      uint256 newRewardForSyncHeader = BytesToTypes.bytesToUint256(32, value);
      require(newRewardForSyncHeader > 0, "the newRewardForSyncHeader out of range");
      rewardForSyncHeader = newRewardForSyncHeader;
    } else if (Memory.compareStrings(key,"callerCompensationMolecule")) {
      require(value.length == 32, "length of callerCompensationMolecule mismatch");
      uint256 newCallerCompensationMolecule = BytesToTypes.bytesToUint256(32, value);
      require(newCallerCompensationMolecule <= 10000, "new callerCompensationMolecule shouldn't be in range [0,10000]");
      callerCompensationMolecule = newCallerCompensationMolecule;
    } else if (Memory.compareStrings(key,"roundSize")) {
      require(value.length == 32, "length of roundSize mismatch");
      uint256 newRoundSize = BytesToTypes.bytesToUint256(32, value);
      require(newRoundSize >= maximumWeight, "new newRoundSize shouldn't be greater than maximumWeight");
      roundSize = newRoundSize;
    } else if (Memory.compareStrings(key,"maximumWeight")) {
      require(value.length == 32, "length of maximumWeight mismatch");
      uint256 newMaximumWeight = BytesToTypes.bytesToUint256(32, value);
      require(newMaximumWeight != 0 && roundSize >= newMaximumWeight, "the newMaximumWeight must not be zero and no less than newRoundSize");
      maximumWeight = newMaximumWeight;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  function isHeaderSynced(bytes32 btcHash) external override view returns (bool) {
    return getHeight(btcHash) >= INIT_CHAIN_HEIGHT;
  }

  function getSubmitter(bytes32 btcHash) external override view returns (address payable) {
    return submitters[btcHash];
  }

  function getChainTip() external override view returns (bytes32) {
    return heaviestBlock;
  }

  function getMiner(bytes32 btcHash) public override view returns (bytes20) {
    if(getHeight(btcHash) == 0) return bytes20(0);
    return getCoinbase(btcHash);
  }

  function getRoundPowers(uint256 roundTimeTag) external override view returns (bytes20[] memory miners, uint256[] memory powers) {
    RoundMinersPower storage r = roundMinerPowerMap[roundTimeTag];
    uint256 count = r.miners.length;
    if (count == 0) return (miners,powers);
    miners = new bytes20[](count);
    powers = new uint256[](count);
    for (uint256 i = 0; i < count; ++i){
      miners[i] = r.miners[i];
      powers[i] = r.powerMap[miners[i]];
    }
    return (miners,powers);
  }

  function getRoundMiners(uint256 roundTimeTag) external override view returns (bytes20[] memory miners) {
    RoundMinersPower storage r = roundMinerPowerMap[roundTimeTag];
    /*uint256 count = r.miners.length;
    if (count > 0) {
      miners = new bytes20[](count);
      for (uint256 i = 0; i < count; ++i){
        miners[i] = r.miners[i];
      }
    }*/
    return r.miners;
  }
}

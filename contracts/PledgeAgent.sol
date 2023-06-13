// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IPledgeAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ICandidateHub.sol";
import "./interface/ISystemReward.sol";
import "./interface/ILightClient.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./System.sol";

/// This contract manages user delegate, also known as stake
/// Including both coin delegate and hash delegate
contract PledgeAgent is IPledgeAgent, System, IParamSubscriber {
  uint256 public constant INIT_REQUIRED_COIN_DEPOSIT = 1e18;
  uint256 public constant INIT_HASH_POWER_FACTOR = 20000;
  uint256 public constant POWER_BLOCK_FACTOR = 1e18;

  uint256 public requiredCoinDeposit;

  // powerFactor/10000 determines the weight of BTC hash power vs CORE stakes
  // the default value of powerFactor is set to 20000 
  // which means the overall BTC hash power takes 2/3 total weight 
  // when calculating hybrid score and distributing block rewards
  uint256 public powerFactor;

  // key: candidate's operateAddr
  mapping(address => Agent) public agentsMap;

  // This field is used to store `special` reward records of delegators. 
  // There are two cases
  //  1, distribute hash power rewards dust to one miner when turn round
  //  2, save the amount of tokens failed to claim by coin delegators
  // key: delegator address
  // value: amount of CORE tokens claimable
  mapping(address => uint256) public rewardMap;

  // This field is not used in the latest implementation
  // It stays here in order to keep data compatibility for TestNet upgrade
  mapping(bytes20 => address) public btc2ethMap;

  // key: round index
  // value: useful state information of round
  mapping(uint256 => RoundState) public stateMap;

  // roundTag is set to be timestamp / round interval,
  // the valid value should be greater than 10,000 since the chain started.
  // It is initialized to 1.
  uint256 public roundTag;

  mapping(address => TransferReward) public transferRewardMap;

  struct TransferReward {
    uint256 round;
    uint256 deposit;
  }

  struct CoinDelegator {
    uint256 deposit;
    uint256 newDeposit;
    uint256 changeRound;
    uint256 rewardIndex;
  }

  struct Reward {
    uint256 totalReward;
    uint256 remainReward;
    uint256 score;
    uint256 coin;
    uint256 round;
  }

  // The Agent struct for Candidate.
  struct Agent {
    uint256 totalDeposit;
    mapping(address => CoinDelegator) cDelegatorMap;
    Reward[] rewardSet;
    uint256 power;
    uint256 coin;
    uint256 transferAttenuation;
  }

  struct RoundState {
    uint256 power;
    uint256 coin;
    uint256 powerFactor;
    uint256 transferReward;
    uint256 transferDeposit;
    uint256 felonyDeposit;
  }

  /*********************** events **************************/
  event paramChange(string key, bytes value);
  event delegatedCoin(address indexed agent, address indexed delegator, uint256 amount, uint256 totalAmount);
  event undelegatedCoin(address indexed agent, address indexed delegator, uint256 amount);
  event transferredCoin(
    address indexed sourceAgent,
    address indexed targetAgent,
    address indexed delegator,
    uint256 amount,
    uint256 totalAmount
  );
  event roundReward(address indexed agent, uint256 coinReward, uint256 powerReward);
  event claimedReward(address indexed delegator, address indexed operator, uint256 amount, bool success);

  /// The validator candidate is inactive, it is expected to be active
  /// @param candidate Address of the validator candidate
  error InactiveAgent(address candidate);

  /// Same source/target addressed provided, it is expected to be different
  /// @param source Address of the source candidate
  /// @param target Address of the target candidate
  error SameCandidate(address source, address target);

  function init() external onlyNotInit {
    requiredCoinDeposit = INIT_REQUIRED_COIN_DEPOSIT;
    powerFactor = INIT_HASH_POWER_FACTOR;
    roundTag = 7;
    alreadyInit = true;
  }

  /*********************** Interface implementations ***************************/
  /// Receive round rewards from ValidatorSet, which is triggered at the beginning of turn round
  /// @param agentList List of validator operator addresses
  /// @param rewardList List of reward amount
  function addRoundReward(address[] calldata agentList, uint256[] calldata rewardList)
    external
    payable
    override
    onlyValidator
  {
    uint256 agentSize = agentList.length;
    require(agentSize == rewardList.length, "the length of agentList and rewardList should be equal");
    RoundState memory rs = stateMap[roundTag];
    for (uint256 i = 0; i < agentSize; ++i) {
      Agent storage a = agentsMap[agentList[i]];
      if (a.rewardSet.length == 0) {
        continue;
      }
      Reward storage r = a.rewardSet[a.rewardSet.length - 1];
      uint256 roundScore = r.score;
      if (roundScore == 0) {
        delete a.rewardSet[a.rewardSet.length - 1];
        continue;
      }
      if (rewardList[i] == 0) {
        continue;
      }
      r.totalReward = rewardList[i];
      r.remainReward = rewardList[i];
      uint256 coinReward = rewardList[i] * a.coin * rs.power / roundScore;
      uint256 powerReward = rewardList[i] * a.power * rs.coin / 10000 * rs.powerFactor / roundScore;
      emit roundReward(agentList[i], coinReward, powerReward);
    }
  }

  /// Calculate hybrid score for all candidates
  /// @param candidates List of candidate operator addresses
  /// @param powers List of power value in this round
  /// @return scores List of hybrid scores of all validator candidates in this round
  /// @return totalPower Total power delegate in this round
  /// @return totalCoin Total coin delegate in this round
  function getHybridScore(address[] calldata candidates, uint256[] calldata powers
  ) external override onlyCandidate
      returns (uint256[] memory scores, uint256 totalPower, uint256 totalCoin) {
    uint256 candidateSize = candidates.length;
    require(candidateSize == powers.length, "the length of candidates and powers should be equal");

    totalPower = 1;
    totalCoin = 1;
    // setup `power` and `coin` values for every candidate
    for (uint256 i = 0; i < candidateSize; ++i) {
      Agent storage a = agentsMap[candidates[i]];
      // in order to improve accuracy, the calculation of power is based on 10^18
      a.power = powers[i] * POWER_BLOCK_FACTOR;
      a.coin = a.totalDeposit;
      totalPower += a.power;
      totalCoin += a.coin;
    }

    // calc hybrid score
    scores = new uint256[](candidateSize);
    for (uint256 i = 0; i < candidateSize; ++i) {
      Agent storage a = agentsMap[candidates[i]];
      scores[i] = a.power * totalCoin * powerFactor / 10000 + a.coin * totalPower;
    }
    return (scores, totalPower, totalCoin);
  }

  /// Start new round, this is called by the CandidateHub contract
  /// @param validators List of elected validators in this round
  /// @param totalPower Total power delegate in this round
  /// @param totalCoin Total coin delegate in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 totalPower,
      uint256 totalCoin, uint256 round) external override onlyCandidate {
    RoundState memory rs;
    rs.power = totalPower;
    rs.coin = totalCoin;
    rs.powerFactor = powerFactor;
    stateMap[round] = rs;

    roundTag = round;
    uint256 validatorSize = validators.length;
    for (uint256 i = 0; i < validatorSize; ++i) {
      Agent storage a = agentsMap[validators[i]];
      a.transferAttenuation = 0;
      uint256 score = a.power * rs.coin * powerFactor / 10000 + a.coin * rs.power;
      a.rewardSet.push(Reward(0, 0, score, a.coin, round));
    }
  }

  /// Distribute rewards for delegated hash power on one validator candidate
  /// This method is called at the beginning of `turn round` workflow
  /// @param lastCandidates The operation addresses of the validators from the previous round
  function distributePowerReward(address[] memory lastCandidates) external override onlyCandidate {
    // distribute rewards to every miner
    // note that the miners are represented in the form of reward addresses
    // and they can be duplicated because everytime a miner delegates a BTC block
    // to a validator on Core blockchain, a new record is added in BTCLightClient
    uint256 totalAbandonedReward;
    uint256 totalRewardCoin;
    RoundState storage rs = stateMap[roundTag];
    uint256 rsCoin = rs.coin;
    for (uint256 i = 0; i < lastCandidates.length; i++) {
      address candidate = lastCandidates[i];
      address[] memory miners = ILightClient(LIGHT_CLIENT_ADDR).getRoundMiners(roundTag-7, candidate);
      Agent storage a = agentsMap[candidate];
      uint256 l = a.rewardSet.length;
      if (l == 0) {
        continue;
      }
      Reward storage r = a.rewardSet[l-1];
      uint256 totalReward = r.totalReward;
      if (totalReward == 0 || r.round != roundTag) {
        continue;
      }
      uint256 rCoin = r.coin;
      uint256 abandonedReward;
      {
        uint256 reward = rsCoin * POWER_BLOCK_FACTOR * rs.powerFactor / 10000 * totalReward / r.score;
        uint256 minerSize = miners.length;
        uint256 powerReward = reward * minerSize;
        
        if (a.coin > rCoin) {
          abandonedReward = totalReward * (a.coin - rCoin) * rs.power / r.score;
        }
        require(r.remainReward >= powerReward + abandonedReward, "there is not enough reward");

        for (uint256 j = 0; j < minerSize; j++) {
          rewardMap[miners[j]] += reward;
        }

        if (rCoin == 0) {
          abandonedReward = r.remainReward - powerReward;
          delete a.rewardSet[l-1];
        } else if (powerReward != 0 || abandonedReward != 0) {
          r.remainReward -= (powerReward + abandonedReward);
        }
      }
      totalRewardCoin += rCoin;
      totalAbandonedReward += abandonedReward;
    }
    
    if (totalAbandonedReward != 0) {
      uint256 transferReward = rs.transferDeposit * totalAbandonedReward / (rsCoin - 1 - totalRewardCoin - rs.felonyDeposit);
      rs.transferReward = transferReward;
      if (totalAbandonedReward > transferReward) {
        ISystemReward(SYSTEM_REWARD_ADDR).receiveRewards{ value: totalAbandonedReward - transferReward }();
      }
    }
  }

  function onSlash(address agent, uint256 count, uint256 misdemeanorThreshold, uint256 felonyThreshold) external override onlySlash {
    Agent storage a = agentsMap[agent];
    uint256 attenuationThreshold = misdemeanorThreshold / 5;
    if (count >= misdemeanorThreshold) {
      a.transferAttenuation = 10000; 
    } else if (count > attenuationThreshold) {
      a.transferAttenuation = (count - attenuationThreshold) * 10000 / (misdemeanorThreshold - attenuationThreshold);
    }

    if (count >= felonyThreshold) {
      RoundState storage rs = stateMap[roundTag];
      uint256 l = a.rewardSet.length;
      if (l == 0) {
        return;
      }
      Reward memory r = a.rewardSet[l-1];
      rs.felonyDeposit += r.coin;
    }
  }

  /*********************** External methods ***************************/
  /// Delegate coin to a validator
  /// @param agent The operator address of validator
  function delegateCoin(address agent) external payable {
    if (!ICandidateHub(CANDIDATE_HUB_ADDR).canDelegate(agent)) {
      revert InactiveAgent(agent);
    }
    uint256 newDeposit = delegateCoin(agent, msg.sender, msg.value);
    emit delegatedCoin(agent, msg.sender, msg.value, newDeposit);
  }

  /// Undelegate coin from a validator
  /// @param agent The operator address of validator
  function undelegateCoin(address agent) external {
    undelegateCoin(agent, 0);
  }

  /// Undelegate coin from a validator
  /// @param agent The operator address of validator
  /// @param amount The coin amount for undelegate
  function undelegateCoin(address agent, uint256 amount) public {
    (amount,) = undelegateCoin(agent, msg.sender, amount);

    (bool success, ) = msg.sender.call{value: amount, gas: 50000}("");
    if (!success) {
      rewardMap[msg.sender] += amount;
    }

    emit undelegatedCoin(agent, msg.sender, amount);
  }

  /// Transfer coin stake to a new validator
  /// @param sourceAgent The validator to transfer coin stake from
  /// @param targetAgent The validator to transfer coin stake to
  function transferCoin(address sourceAgent, address targetAgent) external {
    transferCoin(sourceAgent, targetAgent, 0);
  }

  /// Transfer coin stake to a new validator
  /// @param sourceAgent The validator to transfer coin stake from
  /// @param targetAgent The validator to transfer coin stake to
  /// @param amount The coin amount for transfer
  function transferCoin(address sourceAgent, address targetAgent, uint256 amount) public {
    if (!ICandidateHub(CANDIDATE_HUB_ADDR).canDelegate(targetAgent)) {
      revert InactiveAgent(targetAgent);
    }
    if (sourceAgent == targetAgent) {
      revert SameCandidate(sourceAgent, targetAgent);
    }
    (uint256 deposit, uint256 deductedDeposit) = undelegateCoin(sourceAgent, msg.sender, amount);
    uint256 newDeposit = delegateCoin(targetAgent, msg.sender, deposit);
    emit transferredCoin(sourceAgent, targetAgent, msg.sender, deposit, newDeposit);

    deductedDeposit = deductedDeposit * (10000 - agentsMap[sourceAgent].transferAttenuation) / 10000;
    if(deductedDeposit > 0) {
      TransferReward storage tr = transferRewardMap[msg.sender];
      uint256 curRound = roundTag;
      uint256 trRound = tr.round;
      if (trRound != 0 && trRound != curRound) {
        RoundState memory rs = stateMap[tr.round];
        uint256 reward = tr.deposit * rs.transferReward / rs.transferDeposit;
        delete transferRewardMap[msg.sender];
        distributeReward(payable(msg.sender), reward);
      }
      if (trRound == curRound) {
        tr.deposit += deductedDeposit;
      } else {
        tr.round = curRound;
        tr.deposit = deductedDeposit;
      }
      stateMap[curRound].transferDeposit += deductedDeposit;
    }
  }

  /// Claim reward for delegator
  /// @param agentList The list of validators to claim rewards on, it can be empty
  /// @return (Amount claimed, Are all rewards claimed)
  function claimReward(address[] calldata agentList) external returns (uint256, bool) {
    // limit round count to control gas usage
    int256 roundLimit = 500;
    uint256 reward;
    uint256 rewardSum = rewardMap[msg.sender];
    if (rewardSum != 0) {
      rewardMap[msg.sender] = 0;
    }

    uint256 agentSize = agentList.length;
    for (uint256 i = 0; i < agentSize; ++i) {
      Agent storage a = agentsMap[agentList[i]];
      if (a.rewardSet.length == 0) continue;
      CoinDelegator storage d = a.cDelegatorMap[msg.sender];
      if (d.newDeposit == 0) continue;
      int256 roundCount = int256(a.rewardSet.length - d.rewardIndex);
      reward = collectCoinReward(a, d, roundLimit);
      roundLimit -= roundCount;
      rewardSum += reward;
      // if there are rewards to be collected, leave them there
      if (roundLimit < 0) break;
    }

    uint256 transferReward = getTransferReward(msg.sender);
    if (transferReward != 0) {
      rewardSum += transferReward;
      delete transferRewardMap[msg.sender];
    }

    if (rewardSum != 0) {
      distributeReward(payable(msg.sender), rewardSum);
    }
    return (rewardSum, roundLimit >= 0);
  }

  /*********************** Internal methods ***************************/
  function distributeReward(address payable delegator, uint256 reward) internal {
    (bool success,) = delegator.call{value: reward, gas: 50000}("");
    emit claimedReward(delegator, msg.sender, reward, success);
    if (!success) {
      rewardMap[msg.sender] += reward;
    }
  }

  function delegateCoin(
    address agent,
    address delegator,
    uint256 deposit
  ) internal returns (uint256) {
    require(deposit >= requiredCoinDeposit, "deposit is too small");
    Agent storage a = agentsMap[agent];
    uint256 newDeposit = a.cDelegatorMap[delegator].newDeposit + deposit;

    a.totalDeposit += deposit;
    if (newDeposit == deposit) {
      uint256 rewardIndex = a.rewardSet.length;
      a.cDelegatorMap[delegator] = CoinDelegator(0, deposit, roundTag, rewardIndex);
    } else {
      CoinDelegator storage d = a.cDelegatorMap[delegator];
      uint256 rewardAmount = collectCoinReward(a, d, 0x7FFFFFFF);
      if (d.changeRound < roundTag) {
        d.deposit = d.newDeposit;
        d.changeRound = roundTag;
      }
      d.newDeposit = newDeposit;
      if (rewardAmount != 0) {
        distributeReward(payable(delegator), rewardAmount);
      }
    }
    return newDeposit;
  }

  function undelegateCoin(address agent, address delegator, uint256 amount) internal returns (uint256, uint256) {
    Agent storage a = agentsMap[agent];
    CoinDelegator storage d = a.cDelegatorMap[delegator];
    uint256 newDeposit = d.newDeposit;
    if (amount == 0) amount = newDeposit;
    require(newDeposit != 0, "delegator does not exist");
    if (newDeposit != amount) {
      require(amount >= requiredCoinDeposit, "undelegate amount is too small"); 
      require(newDeposit >= requiredCoinDeposit + amount, "remain amount is too small");
    }
    uint256 rewardAmount = collectCoinReward(a, d, 0x7FFFFFFF);
    a.totalDeposit -= amount;

    uint256 deductedDeposit;
    uint256 deposit = d.deposit;
    if (a.rewardSet.length != 0) {
      Reward storage r = a.rewardSet[a.rewardSet.length - 1];
      if (r.round == roundTag) {
        if (d.changeRound < roundTag) {
          deductedDeposit = amount;
          deposit = newDeposit - deductedDeposit;
        } else if (newDeposit < amount + deposit) {
            deductedDeposit = deposit + amount - newDeposit;
            deposit -= deductedDeposit;
        }
        if (deductedDeposit != 0) r.coin -= deductedDeposit;
      }
    }

    if (newDeposit == amount) {
      delete a.cDelegatorMap[delegator];
    } else {
      d.deposit = deposit;
      d.newDeposit = newDeposit - amount;
      d.changeRound = roundTag;
    }

    if (rewardAmount != 0) {
      distributeReward(payable(delegator), rewardAmount);
    }
    return (amount, deductedDeposit);
  }

  function collectCoinReward(
    Agent storage a,
    CoinDelegator storage d,
    int256 roundLimit
  ) internal returns (uint256 rewardAmount) {
    uint256 rewardLength = a.rewardSet.length;
    uint256 rewardIndex = d.rewardIndex;
    rewardAmount = 0;
    if (rewardIndex >= rewardLength) {
      return rewardAmount;
    }
    if (rewardIndex + uint256(roundLimit) < rewardLength) {
      rewardLength = rewardIndex + uint256(roundLimit);
    }
    uint256 curReward;
    uint256 changeRound = d.changeRound;

    while (rewardIndex < rewardLength) {
      Reward storage r = a.rewardSet[rewardIndex];
      if (r.round == roundTag) break;
      uint256 deposit = d.newDeposit;
      if (r.round == changeRound) {
        deposit = d.deposit;
        d.deposit = d.newDeposit;
      }
      require(r.coin >= deposit, "reward is not enough");
      if (r.coin == deposit) {
        curReward = r.remainReward;
        delete a.rewardSet[rewardIndex];
      } else {
        uint256 rsPower = stateMap[r.round].power;
        curReward = (r.totalReward * deposit * rsPower) / r.score;
        require(r.remainReward >= curReward, "there is not enough reward");
        r.coin -= deposit;
        r.remainReward -= curReward;
      }
      rewardAmount += curReward;
      rewardIndex++;
    }

    // update index whenever claim happens
    d.rewardIndex = rewardIndex;
    return rewardAmount;
  }

  /*********************** Governance ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "requiredCoinDeposit")) {
      uint256 newRequiredCoinDeposit = BytesToTypes.bytesToUint256(32, value);
      if (newRequiredCoinDeposit == 0) {
        revert OutOfBounds(key, newRequiredCoinDeposit, 1, type(uint256).max);
      }
      requiredCoinDeposit = newRequiredCoinDeposit;
    } else if (Memory.compareStrings(key, "powerFactor")) {
      uint256 newHashPowerFactor = BytesToTypes.bytesToUint256(32, value);
      if (newHashPowerFactor == 0) {
        revert OutOfBounds(key, newHashPowerFactor, 1, type(uint256).max);
      }
      powerFactor = newHashPowerFactor;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  /*********************** Public view ********************************/
  /// Get delegator information
  /// @param agent The operator address of validator
  /// @param delegator The delegator address
  /// @return CoinDelegator Information of the delegator
  function getDelegator(address agent, address delegator) external view returns (CoinDelegator memory) {
    return agentsMap[agent].cDelegatorMap[delegator];
  }

  /// Get reward information of a validator by index
  /// @param agent The operator address of validator
  /// @param index The reward index
  /// @return Reward The reward information
  function getReward(address agent, uint256 index) external view returns (Reward memory) {
    Agent storage a = agentsMap[agent];
    require(index < a.rewardSet.length, "out of up bound");
    return a.rewardSet[index];
  }

  /// Get transfer reward value
  /// @param delegator The delegator address
  /// @return Reward The transfer reward value
  function getTransferReward(address delegator) public view returns (uint256) {
    TransferReward memory tr = transferRewardMap[delegator];
    if (tr.round != 0 && tr.round != roundTag) {
      RoundState memory rs = stateMap[tr.round];
      return tr.deposit * rs.transferReward / rs.transferDeposit;
    }
    return 0;
  }
}

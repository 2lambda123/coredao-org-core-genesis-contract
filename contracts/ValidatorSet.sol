pragma solidity 0.6.12;

import "./System.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/IValidatorSet.sol";
import "./interface/IPledgeAgent.sol";
import "./interface/ISystemReward.sol";
import "./interface/ICandidateHub.sol";
import "./lib/SafeMath.sol";
import "./lib/RLPDecode.sol";

contract ValidatorSet is IValidatorSet, System, IParamSubscriber {
  using SafeMath for uint256;

  using RLPDecode for *;

  uint256 public constant BLOCK_REWARD = 3e18;
  uint256 public constant BLOCK_REWARD_INCENTIVE_PERCENT = 10;

  bytes public constant INIT_VALIDATORSET_BYTES = hex"ebea9401bca3615d24d3c638836691517b2b9b49b054b19401bca3615d24d3c638836691517b2b9b49b054b1";

  /*********************** state of the contract **************************/
  uint256 public blockReward;
  uint256 public blockRewardIncentivePercent;
  Validator[] public currentValidatorSet;
  uint256 public totalInCome;

  // key is the `consensusAddress` of `Validator`,
  // value is the index of the element in `currentValidatorSet`.
  mapping(address => uint256) public currentValidatorSetMap;

  struct Validator {
    address operateAddress;
    address consensusAddress;
    address payable feeAddress;
    uint256 commissionThousandths;
    uint256 income;
  }

  /*********************** events **************************/
  event validatorSetUpdated();
  event systemTransfer(uint256 amount);
  event directTransfer(
    address indexed operateAddress,
    address payable indexed validator,
    uint256 amount,
    uint256 totalReward
  );
  event directTransferFail(
    address indexed operateAddress,
    address payable indexed validator,
    uint256 amount,
    uint256 totalReward
  );
  event deprecatedDeposit(address indexed validator, uint256 amount);
  event validatorDeposit(address indexed validator, uint256 amount);
  event validatorMisdemeanor(address indexed validator, uint256 amount);
  event validatorFelony(address indexed validator, uint256 amount);
  event paramChange(string key, bytes value);

  /*********************** init **************************/
  function init() external onlyNotInit {
    (Validator[] memory validatorSet, bool valid) = decodeValidatorSet(INIT_VALIDATORSET_BYTES);
    require(valid, "failed to parse init validatorSet");
    for (uint256 i = 0; i < validatorSet.length; i++) {
      currentValidatorSet.push(validatorSet[i]);
      currentValidatorSetMap[validatorSet[i].consensusAddress] = i + 1;
    }
    blockReward = BLOCK_REWARD;
    blockRewardIncentivePercent = BLOCK_REWARD_INCENTIVE_PERCENT;
    alreadyInit = true;
  }

  /*********************** External Functions **************************/
  function isValidator(address addr) public override returns (bool) {
    return currentValidatorSetMap[addr] > 0;
  }

  function deposit(address valAddr) external payable onlyCoinbase onlyInit onlyZeroGasPrice {
    uint256 value = msg.value;
    if (address(this).balance >= totalInCome + value + blockReward) {
      value += blockReward;
    }
    uint256 index = currentValidatorSetMap[valAddr];
    if (index > 0) {
      Validator storage validator = currentValidatorSet[index - 1];
      totalInCome = totalInCome + value;
      validator.income = validator.income + value;
      emit validatorDeposit(valAddr, value);
    } else {
      emit deprecatedDeposit(valAddr, value);
    }
  }

  function distributeReward() external override onlyCandidate {
    address payable feeAddress;
    uint256 validatorReward;

    uint256 incentiveSum = 0;
    for (uint256 i = 0; i < currentValidatorSet.length; i++) {
      Validator storage v = currentValidatorSet[i];
      uint256 incentiveValue = (v.income * blockRewardIncentivePercent) / 100;
      incentiveSum += incentiveValue;
      v.income -= incentiveValue;
    }
    ISystemReward(SYSTEM_REWARD_ADDR).receiveRewards{ value: incentiveSum }();

    address[] memory operateAddressList = new address[](currentValidatorSet.length);
    uint256[] memory rewardList = new uint256[](currentValidatorSet.length);
    uint256 rewardSum = 0;
    for (uint256 i = 0; i < currentValidatorSet.length; i++) {
      Validator storage v = currentValidatorSet[i];
      operateAddressList[i] = v.operateAddress;
      if (v.income > 0) {
        feeAddress = v.feeAddress;
        validatorReward = (v.income * v.commissionThousandths) / 1000;
        if (v.income > validatorReward) {
          rewardList[i] = v.income - validatorReward;
          rewardSum += rewardList[i];
        }

        bool success = feeAddress.send(validatorReward);
        if (success) {
          emit directTransfer(v.operateAddress, feeAddress, validatorReward, v.income);
        } else {
          emit directTransferFail(v.operateAddress, feeAddress, validatorReward, v.income);
        }
        v.income = 0;
      }
    }

    IPledgeAgent(PLEDGE_AGENT_ADDR).addRoundReward{ value: rewardSum }(operateAddressList, rewardList);
    totalInCome = 0;
  } 

  function updateValidatorSet(
    address[] memory operateAddrList,
    address[] memory consensusAddrList,
    address payable[] memory feeAddrList,
    uint256[] memory commissionThousandthsList
  ) external override onlyCandidate {
    // do verify.
    checkValidatorSet(operateAddrList, consensusAddrList, feeAddrList, commissionThousandthsList);
    if (consensusAddrList.length == 0) {
      return;
    }
    // do update validator set state
    uint256 i;
    uint256 lastLength = currentValidatorSet.length;
    uint256 currentLength = consensusAddrList.length;
    for (i = 0; i < lastLength; i++) {
      delete currentValidatorSetMap[currentValidatorSet[i].consensusAddress];
    }
    for (i = currentLength; i < lastLength; i++) {
      currentValidatorSet.pop();
    }

    for (i = 0; i < currentLength; ++i) {
      if (i >= lastLength) {
        currentValidatorSet.push(Validator(operateAddrList[i], consensusAddrList[i], feeAddrList[i],commissionThousandthsList[i], 0));
      } else {
        currentValidatorSet[i] = Validator(operateAddrList[i], consensusAddrList[i], feeAddrList[i],commissionThousandthsList[i], 0);
      }
      currentValidatorSetMap[consensusAddrList[i]] = i + 1;
    }

    emit validatorSetUpdated();
  }

  function getValidators() external view returns (address[] memory) {
    address[] memory consensusAddrs = new address[](currentValidatorSet.length);
    for (uint256 i = 0; i < currentValidatorSet.length; i++) {
      consensusAddrs[i] = currentValidatorSet[i].consensusAddress;
    }
    return consensusAddrs;
  }

  function getIncoming(address validator) external view returns (uint256) {
    uint256 index = currentValidatorSetMap[validator];
    if (index <= 0) {
      return 0;
    }
    return currentValidatorSet[index - 1].income;
  }

  /*********************** For slash **************************/
  function misdemeanor(address validator) external override onlySlash {
    uint256 index = currentValidatorSetMap[validator];
    if (index <= 0) {
      return;
    }
    // the actually index
    index = index - 1;
    uint256 income = currentValidatorSet[index].income;
    currentValidatorSet[index].income = 0;
    uint256 rest = currentValidatorSet.length - 1;
    address operateAddress = currentValidatorSet[index].operateAddress;
    emit validatorMisdemeanor(operateAddress, income);
    if (rest == 0) {
      // should not happen, but still protect
      return;
    }
    uint256 averageDistribute = income / rest;
    if (averageDistribute != 0) {
      for (uint256 i = 0; i < index; i++) {
        currentValidatorSet[i].income += averageDistribute;
      }
      uint256 n = currentValidatorSet.length;
      for (uint256 i = index + 1; i < n; i++) {
        currentValidatorSet[i].income += averageDistribute;
      }
    }
  }

  function felony(address validator, uint256 felonyRound, int256 felonyDeposit) external override onlySlash {
    uint256 index = currentValidatorSetMap[validator];
    if (index <= 0) {
      return;
    }
    // the actually index
    index = index - 1;
    uint256 income = currentValidatorSet[index].income;
    uint256 rest = currentValidatorSet.length - 1;
    if (rest == 0) {
      // will not remove the validator if it is the only one validator.
      currentValidatorSet[index].income = 0;
      return;
    }
    address operateAddress = currentValidatorSet[index].operateAddress;
    emit validatorFelony(operateAddress, income);
    delete currentValidatorSetMap[validator];
    // It is ok that the validatorSet is not in order.
    if (index != currentValidatorSet.length - 1) {
      currentValidatorSet[index] = currentValidatorSet[currentValidatorSet.length - 1];
      currentValidatorSetMap[currentValidatorSet[index].consensusAddress] = index + 1;
    }
    currentValidatorSet.pop();
    uint256 averageDistribute = income / rest;
    if (averageDistribute != 0) {
      uint256 n = currentValidatorSet.length;
      for (uint256 i = 0; i < n; i++) {
        currentValidatorSet[i].income += averageDistribute;
      }
    }
    ICandidateHub(CANDIDATE_HUB_ADDR).jailValidator(operateAddress, felonyRound, felonyDeposit);
  }

  /*********************** Param update ********************************/
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (Memory.compareStrings(key, "blockReward")) {
      require(value.length == 32, "length of blockReward mismatch");
      uint256 newBlockReward = BytesToTypes.bytesToUint256(32, value);
      require(newBlockReward <= BLOCK_REWARD * 10, "the blockReward out of range");
      blockReward = newBlockReward;
    } else if (Memory.compareStrings(key, "blockRewardIncentivePercent")) {
      require(value.length == 32, "length of blockRewardIncentivePercent mismatch");
      uint256 newBlockRewardIncentivePercent = BytesToTypes.bytesToUint256(32, value);
      require(newBlockRewardIncentivePercent > 0 && newBlockRewardIncentivePercent < 100, "the blockRewardIncentivePercent out of range");
      blockRewardIncentivePercent = newBlockRewardIncentivePercent;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  /*********************** Internal Functions **************************/

  function checkValidatorSet(
    address[] memory operateAddrList,
    address[] memory consensusAddrList,
    address payable[] memory feeAddrList,
    uint256[] memory commissionThousandthsList
  ) private pure {
    require(
      consensusAddrList.length == operateAddrList.length,
      "the numbers of consensusAddresses and operateAddresses should be equal"
    );
    require(
      consensusAddrList.length == feeAddrList.length,
      "the numbers of consensusAddresses and feeAddresses should be equal"
    );
    require(
      consensusAddrList.length == commissionThousandthsList.length,
      "the numbers of consensusAddresses and commissionThousandthss should be equal"
    );
    for (uint256 i = 0; i < consensusAddrList.length; i++) {
      for (uint256 j = 0; j < i; j++) {
        require(consensusAddrList[i] != consensusAddrList[j], "duplicate consensus address");
      }
      require(commissionThousandthsList[i] <= 1000, "commissionThousandths out of bound");
    }
  }

  //rlp encode & decode function
  function decodeValidatorSet(bytes memory msgBytes) internal pure returns (Validator[] memory, bool) {
    RLPDecode.RLPItem[] memory items = msgBytes.toRLPItem().toList();
    Validator[] memory validatorSet = new Validator[](items.length);
    for (uint256 j = 0; j < items.length; j++) {
      (Validator memory val, bool ok) = decodeValidator(items[j]);
      if (!ok) {
        return (validatorSet, false);
      }
      validatorSet[j] = val;
    }
    bool success = items.length > 0;
    return (validatorSet, success);
  }

  function decodeValidator(RLPDecode.RLPItem memory itemValidator) internal pure returns (Validator memory, bool) {
    Validator memory validator;
    RLPDecode.Iterator memory iter = itemValidator.iterator();
    bool success = false;
    while (iter.hasNext()) {
      validator.consensusAddress = iter.next().toAddress();
      validator.feeAddress = address(uint160(iter.next().toAddress()));
      validator.operateAddress = validator.feeAddress;
      validator.commissionThousandths = 1000;
      success = true;
    }
    return (validator, success);
  }
}

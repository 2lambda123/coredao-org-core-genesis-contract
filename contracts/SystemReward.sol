// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;
import "./System.sol";
import "./interface/ISystemReward.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/IBurn.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./registry/Registry.sol";


/// This smart contract manages funds for relayers and verifiers
contract SystemReward is System, ISystemReward, IParamSubscriber {
  uint256 public constant INCENTIVE_BALANCE_CAP = 1e25;

  uint256 public incentiveBalanceCap;
  bool isBurn;

  /*********************** init **************************/
  constructor(Registry registry) System(registry) {
    incentiveBalanceCap = INCENTIVE_BALANCE_CAP;
  }

  modifier onlyOperator() {
    require(_isOperator(msg.sender), "only operator is allowed to call the method");
    _;
  }

  /*********************** events **************************/
  event rewardTo(address indexed to, uint256 amount);
  event rewardEmpty();
  event receiveDeposit(address indexed from, uint256 amount);
  event paramChange(string key, bytes value);

  receive() external payable {
    if (msg.value != 0) {
      emit receiveDeposit(msg.sender, msg.value);
    }
  }

  /// Receive funds from system, burn the portion which exceeds cap
  function receiveRewards() external payable override onlyInit {
    if (msg.value != 0) {
      if (address(this).balance > incentiveBalanceCap) {
        uint256 value = address(this).balance - incentiveBalanceCap;
        if (isBurn) {
          _burnContract().burn{ value: value }();
        } else {
          _transfer(_foundationPayable(), value);
        }
      }
      emit receiveDeposit(msg.sender, msg.value);
    }
  }

  /// Claim rewards, this method can only be called by valid operator addresses
  /// @param to The address to claim rewards to
  /// @param amount The amount to claim
  function claimRewards(address payable to, uint256 amount)
    external
    override(ISystemReward)
    onlyInit
    onlyOperator
    returns (uint256)
  {
    uint256 actualAmount = amount < address(this).balance ? amount : address(this).balance;
    if (to != address(0) && actualAmount != 0) {
      _transfer(to, actualAmount);
      emit rewardTo(to, actualAmount);
    } else {
      emit rewardEmpty();
    }
    return actualAmount;
  }

  /// Whether the given address is a valid operator
  /// @param addr The address to check
  /// @return true/false
  function isOperator(address addr) external returns (bool) {
    return _isOperator(addr);
  }

  /*********************** Param update ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (Memory.compareStrings(key, "incentiveBalanceCap")) {
      require(value.length == 32, "length of incentiveBalanceCap mismatch");
      uint256 newIncentiveBalanceCap = BytesToTypes.bytesToUint256(32, value);
      require(newIncentiveBalanceCap != 0, "the incentiveBalanceCap out of range");
      incentiveBalanceCap = newIncentiveBalanceCap;
    } else if (Memory.compareStrings(key, "isBurn")) {
      require(value.length == 32, "length of isBurn mismatch");
      uint256 newIsBurn = BytesToTypes.bytesToUint256(32, value);
      require(newIsBurn <= 1, "the newIsBurn out of range");
      isBurn = newIsBurn == 1;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  function _isOperator(address addr) internal virtual returns (bool) {
    return addr == address(_lightClient()) || addr == address(_slashIndicator());
  }
}

// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

abstract contract ContractAddresses {
  //@correlate network code: core/systemcontracts/const.go  

  address public constant VALIDATOR_CONTRACT_ADDR = 0x0000000000000000000000000000000000001000;
  address public constant SLASH_CONTRACT_ADDR = 0x0000000000000000000000000000000000001001;
  address public constant SYSTEM_REWARD_ADDR = 0x0000000000000000000000000000000000001002;
  address public constant LIGHT_CLIENT_ADDR = 0x0000000000000000000000000000000000001003;
  address public constant RELAYER_HUB_ADDR = 0x0000000000000000000000000000000000001004;
  address public constant CANDIDATE_HUB_ADDR = 0x0000000000000000000000000000000000001005;
  address public constant GOV_HUB_ADDR = 0x0000000000000000000000000000000000001006;
  address public constant PLEDGE_AGENT_ADDR = 0x0000000000000000000000000000000000001007;
  address public constant BURN_ADDR = 0x0000000000000000000000000000000000001008;
  address public constant FOUNDATION_ADDR = 0x0000000000000000000000000000000000001009;


  struct AllContracts {
    IBurn burn;
    IBtcLightClient lightClient;
    ISlashIndicator slashIndicator;
    ISystemReward systemReward;
    ICandidateHub candidateHub;
    IPledgeAgent pledgeAgent;        
    IValidatorSet validatorSet;
    IRelayerHub relayerHub;
    address foundationAddr;
    address govHubAddr;
  }

}
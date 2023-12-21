// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {BtcLightClient} from "../contracts/BtcLightClient.sol";
import {System} from "../contracts/System.sol";
import {Burn} from "../contracts/Burn.sol";
import {CandidateHub} from "../contracts/CandidateHub.sol";
import {Foundation} from "../contracts/Foundation.sol";
import {GovHub} from "../contracts/GovHub.sol";
import {PledgeAgent} from "../contracts/PledgeAgent.sol";
import {RelayerHub} from "../contracts/RelayerHub.sol";
import {SlashIndicator} from "../contracts/SlashIndicator.sol";
import {ValidatorSet} from "../contracts/ValidatorSet.sol";
import {SystemRewardMock} from "../contracts/mock/SystemRewardMock.sol";


contract Deployer is Script, System {
    address public validatorSetAddr;
    address public slashAddr ;
    address public systemRewardAddr;
    address public lightAddr;
    address public relayerHubAddr;
    address public candidateHubAddr;
    address public govHubAddr ;
    address public pledgeAgentAddr;
    address public burnAddr ;
    address public foundationAddr;

    function run() external {
	    // vm.startBroadcast(); 
        if (_useDynamicAddr()) {
            _performActualDeployment();
        } else {
            // rely on the already deployed contracts
            _useAlreadyDeployedAddresses();
        }
        // vm.stopBroadcast();
    }

    function _performActualDeployment() private {        
        console.log("deploying on network %s", block.chainid);
        
        Burn burn = new Burn();
        BtcLightClient lightClient = new BtcLightClient();
        SlashIndicator slashIndicator = new SlashIndicator();
        SystemRewardMock systemReward = new SystemRewardMock(); // must use mock else onlyOperator() will fail 
        CandidateHub candidateHub = new CandidateHub();
        PledgeAgent pledgeAgent = new PledgeAgent();
        ValidatorSet validatorSet = new ValidatorSet();
        RelayerHub relayerHub = new RelayerHub();
        Foundation foundation = new Foundation();
        GovHub govHub = new GovHub();

        validatorSetAddr = address(validatorSet);
        slashAddr = address(slashIndicator);
        systemRewardAddr = address(systemReward);
        lightAddr = address(lightClient);
        relayerHubAddr = address(relayerHub);
        candidateHubAddr = address(candidateHub);
        govHubAddr = address(govHub);
        pledgeAgentAddr = address(pledgeAgent);
        burnAddr = address(burn);
        foundationAddr = address(foundation);

        // update contracts in local-node testing mode:
        burn.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        lightClient.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        slashIndicator.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        systemReward.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        candidateHub.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        pledgeAgent.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        validatorSet.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        relayerHub.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        foundation.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);
        govHub.updateContractAddr(validatorSetAddr, slashAddr, systemRewardAddr, lightAddr, relayerHubAddr,
                                candidateHubAddr, govHubAddr, pledgeAgentAddr, burnAddr, foundationAddr);

        // and call init() after setting of addresses
        burn.init();
        lightClient.init();
        slashIndicator.init();
        systemReward.init();      
        candidateHub.init();
        pledgeAgent.init();
        validatorSet.init();
        relayerHub.init();
        //foundation.init(); -- non existent 
        govHub.init();
    }

    function _useAlreadyDeployedAddresses() private {        
        console.log("using pre-deployed contracts on network %s", block.chainid);
        
        validatorSetAddr = _VALIDATOR_CONTRACT_ADDR;
        slashAddr = _SLASH_CONTRACT_ADDR;
        systemRewardAddr = _SYSTEM_REWARD_ADDR;
        lightAddr = _LIGHT_CLIENT_ADDR;
        relayerHubAddr = _RELAYER_HUB_ADDR;
        candidateHubAddr = _CANDIDATE_HUB_ADDR;
        govHubAddr = _GOV_HUB_ADDR;
        pledgeAgentAddr = _PLEDGE_AGENT_ADDR;
        burnAddr = _BURN_ADDR;
        foundationAddr = _FOUNDATION_ADDR;
    }    
}
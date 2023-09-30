// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "../GovHub.sol";
import "../registry/Registry.sol";

contract GovHubMock is GovHub {
    constructor(Registry registry, uint256 votingPeriod_, uint256 executingPeriod_, bytes memory membersBytes_) 
            GovHub(registry, votingPeriod_, executingPeriod_, membersBytes_) {}
        
    
    function _loadInitialMembers(bytes memory membersBytes_) internal override {}

    function developmentInit() external {
        votingPeriod = 20;
        address[2] memory initMembers = [
            address(0x9fB29AAc15b9A4B7F17c3385939b007540f4d791),
            address(0x96C42C56fdb78294F96B0cFa33c92bed7D75F96a)
        ];
        delete memberSet;
        for (uint256 i = 0; i < initMembers.length; i++) {
            memberSet.push(initMembers[i]);
            members[initMembers[i]] = memberSet.length;
        }
    }

    function resetMembers(address[] calldata newMembers) external {
        delete memberSet;
        for (uint256 i = 0; i < newMembers.length; i++) {
            memberSet.push(newMembers[i]);
            members[newMembers[i]] = memberSet.length;
        }
    }
}

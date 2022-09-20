pragma solidity 0.6.12;

interface ICandidateHub {
  function canDelegate(address agent) external view returns(bool);
  function jailValidator(address operateAddress, uint round, int256 fine) external;
}

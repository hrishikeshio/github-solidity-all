pragma solidity ^0.4.21;

import "../controller/Controller.sol";
import "../controller/Avatar.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";
import "zeppelin-solidity/contracts/token/ERC20/StandardToken.sol";


contract UniversalSchemeInterface {

    function updateParameters(bytes32 _hashedParameters) public;

    function getParametersFromController(Avatar _avatar) internal view returns(bytes32);
}

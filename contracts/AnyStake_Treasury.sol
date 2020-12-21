// SPDX-License-Identifier: DeFiat and Friends (Zeppelin, MIT...)

// MAINNET VERSION.

pragma solidity ^0.6.6;

import "./AnyStake_Libraries.sol";
import "./AnyStake_Interfaces.sol";


// Vault distributes fees equally amongst staked pools

contract Treasury {
    using SafeMath for uint256;
    address public AnyStake;

    constructor(address _anystake) public {
        AnyStake = _anystake;
    }
    
    function pullRewards(address _token) external {
        require(msg.sender == AnyStake);
        uint256 _amount = IERC20(_token).balanceOf(address(this)).div(100); //1% of total treasury
        IERC20(_token).transfer(AnyStake, _amount);
        IAnyStake(AnyStake).updateRewards(); //updates rewards
    }
    
}

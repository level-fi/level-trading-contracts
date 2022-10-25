// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import {ERC20Burnable} from "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

/// @title LP Token
/// @author YAPP
/// @notice User will receive LP Token when deposit their token to protocol; and it can be redeem to receive
/// any token of their choice
contract LPToken is ERC20Burnable {
    address public minter;
    mapping(address => uint256) public lastMinted;
    /// @notice only redeem after this time, counting from last minted
    uint256 public immutable redeemCooldown;

    constructor(string memory _name, string memory _symbol, address _minter, uint256 _redeemCooldown)
        ERC20(_name, _symbol)
    {
        require(_minter != address(0), "LPToken: address 0");
        minter = _minter;
        redeemCooldown = _redeemCooldown;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == minter, "LPToken: !minter");
        lastMinted[_to] = block.timestamp;
        _mint(_to, _amount);
    }

    function burnFrom(address _account, uint256 _amount) public override {
        require(lastMinted[_account] + redeemCooldown <= block.timestamp, "LPToken: redemption delayed");
        _burn(_account, _amount);
    }
}

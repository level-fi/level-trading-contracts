//SPDX-License-Identifier: UNLCIENSED

pragma solidity >=0.8.0;

import "openzeppelin/token/ERC20/ERC20.sol";

/**
 * @dev THIS CONTRACT IS FOR TESTING PURPOSES ONLY.
 */
contract MockERC20 is ERC20 {
    uint8 internal decimals_;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol) {
        decimals_ = _decimals;
    }

    function mint(uint256 _amount) public {
        _mint(msg.sender, _amount);
    }

    function mintTo(uint256 _amount, address _to) public {
        _mint(_to, _amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return decimals_;
    }
}

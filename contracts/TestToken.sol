// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC20 } from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 10_000_000 * 10 ** decimals());
    }
}

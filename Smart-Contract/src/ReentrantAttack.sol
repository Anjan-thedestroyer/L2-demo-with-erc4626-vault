//SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/Console.sol";
import {Vault} from "../src/Vault.sol";
import {Strategy} from "../src/Strategy.sol";
import {Token} from "../src/Token.sol";
contract ReentrancyAttacker {
    Vault public vault;
    IERC20 public token;

    constructor(address _vault, address _token) {
        vault = Vault(_vault);
        token = IERC20(_token);
    }

    // Try to reenter during fallback
    fallback() external payable {
        vault.withdraw(1 ether, address(this), address(this));
    }
    function attack() external {
        token.approve(address(vault), 2 ether);
        vault.deposit(2 ether, address(this));

        // Attempt attack
        vault.withdraw(1 ether, address(this), address(this));
    }
}
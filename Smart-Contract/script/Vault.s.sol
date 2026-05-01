//SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {Strategy} from "../src/Strategy.sol";
import {Token} from "../src/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {IStrategy} from "../src/Vault.sol";
import {console} from  "forge-std/console.sol";
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        Token token = new Token();

        Vault vault = new Vault(
            IERC20(address(token)),
            "Vault Share",
            "VSH",
            200 
        );

        Strategy strategy1 = new Strategy(
            IERC20(address(token)),
            address(vault),
            5, 1, 9, 1
        );

        Strategy strategy2 = new Strategy(
            IERC20(address(token)),
            address(vault),
            10, 5, 6, 2
        );

        Strategy strategy3 = new Strategy(
            IERC20(address(token)),
            address(vault),
            20, 10, 3, 5
        );

        IStrategy[3] memory strats = [
            IStrategy(address(strategy1)),
            IStrategy(address(strategy2)),
            IStrategy(address(strategy3))
        ];

        vault.setStrategies(strats);
        vm.stopBroadcast();
        console.log("Token:", address(token));
        console.log("Vault:", address(vault));
        console.log("Strategy1:", address(strategy1));
        console.log("Strategy2:", address(strategy2));
        console.log("Strategy3:", address(strategy3));
    }
}
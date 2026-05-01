// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockToken
 * @notice A simple ERC20 token used for testing the Yield Aggregator Vault.
 * @dev This contract allows for unrestricted minting and burning, 
 * intended ONLY for local development or testnet environments.
 */
contract Token is ERC20 {
    
    /**
     * @notice Deploys the token and mints an initial supply to the creator.
     */
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    /**
     * @notice Mints new tokens to a specific address.
     * @dev In a production environment, this should be restricted with 'onlyOwner'.
     * @param account The address that will receive the minted tokens.
     * @param value The amount of tokens to mint.
     */
    function mint(address account, uint256 value) public {
        _mint(account, value);
    }

    /**
     * @notice Destroys tokens from a specific address.
     * @param account The address whose tokens will be burned.
     * @param value The amount of tokens to burn.
     */
    function burn(address account, uint256 value) public {
        _burn(account, value);
    }
}
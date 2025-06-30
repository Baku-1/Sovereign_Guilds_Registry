
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Guild.sol";

/**
 * @title GuildFactory
 * @dev Deploys new on-chain Guild contracts for the NexusLabs ecosystem.
 */
contract GuildFactory {
    address public immutable stakingTokenAddress;
    address public immutable gnosisProxyFactoryAddress;
    address public immutable gnosisSingletonAddress;

    event GuildCreated(
        address indexed guildContractAddress,
        address indexed guildMaster,
        string name
    );

    constructor(
        address _stakingToken,
        address _proxyFactory,
        address _singleton
    ) {
        stakingTokenAddress = _stakingToken;
        gnosisProxyFactoryAddress = _proxyFactory;
        gnosisSingletonAddress = _singleton;
    }

    /**
     * @notice Deploys a new Guild contract with all its features.
     * @param name The name of the guild (e.g., "Cyber Dragons").
     * @param symbol The symbol for the guild's passport NFTs (e.g., "CYD").
     * @param guildMaster The address of the user creating the guild.
     */
    function createGuild(
        string memory name,
        string memory symbol,
        address guildMaster
    ) external returns (address) {
        Guild newGuild = new Guild(
            name,
            symbol,
            guildMaster,
            stakingTokenAddress,
            gnosisProxyFactoryAddress,
            gnosisSingletonAddress
        );
        
        address guildAddress = address(newGuild);
        emit GuildCreated(guildAddress, guildMaster, name);
        return guildAddress;
    }
}
